import AppKit
import CloudKit
import Combine
import Security

nonisolated struct ICloudSyncJournal: Codable {
    var version = 1
    var enabled = false
    var deviceID = UUID().uuidString
    var accountID: String?
    var zoneEstablished: Bool?
    var counter: UInt64 = 0
    var documents: [String: SyncDocument] = [:]
    var baseline: [String: [String: Data]] = [:]
    var dirty: Set<String> = []
    var systemFields: [String: Data] = [:]
    var engineState: CKSyncEngine.State.Serialization?
    mutating func edit(_ name: String, values: [String: Data]) throws {
        var document = documents[name] ?? SyncDocument()
        guard !document.deleted else { return }
        let old = baseline[name] ?? [:]
        for key in Set(old.keys).union(values.keys) where old[key] != values[key] {
            guard counter < UInt64.max - 2 else { throw ICloudSyncFailure.invalidData }
            counter += 1
            document.fields[key] = SyncField(value: values[key], stamp: SyncStamp(counter: counter, device: deviceID))
            dirty.insert(name)
        }
        documents[name] = document
        baseline[name] = values
    }
    mutating func merge(_ name: String, document remote: SyncDocument) throws {
        var local = documents[name] ?? SyncDocument()
        try local.merge(remote)
        counter = max(counter, remote.fields.values.map(\.stamp.counter).max() ?? 0)
        documents[name] = local
        if local != remote { dirty.insert(name) }
    }
}

@MainActor final class ICloudSync: ObservableObject, CKSyncEngineDelegate {
    static let containerIdentifier = "iCloud.app.tryloaf.loaf"
    static let zoneID = CKRecordZone.ID(zoneName: "LoafSyncV1", ownerName: CKCurrentUserDefaultName)
    static let recordType = "LoafSyncDocumentV1"
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "sync is off"
    @Published private(set) var lastSync: Date?
    @Published private(set) var otherMacs: [SyncedMac] = []
    @Published private(set) var needsCacheRepair = false
    private weak var application: BrowserApplication?
    private let file: URL
    private var journal = ICloudSyncJournal()
    private var engine: CKSyncEngine?
    private var starting = false
    private var bootstrapping = false
    private var applying = false
    private var failed = false
    private var operationFailed = false
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    init(application: BrowserApplication) {
        self.application = application
        file = application.directory.appendingPathComponent("icloud-sync-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                journal = try JSONDecoder().decode(ICloudSyncJournal.self, from: Data(contentsOf: file))
                guard journal.version == 1, journal.counter < UInt64.max - 2 else {
                    throw ICloudSyncFailure.invalidData
                }
                enabled = journal.enabled
            } catch {
                failed = true
                needsCacheRepair = true
                status = "sync data couldn’t be restored. The file is retained; local browsing still works."
            }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.refresh() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .sink { [weak self] _ in Task { await self?.checkAccount() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.application?.persistSoon() }.store(in: &observers)
    }
    deinit { refreshTask?.cancel() }

    private static var signedForICloud: Bool {
        guard
            FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL
                    .appendingPathComponent("Contents/embedded.provisionprofile").path)
        else { return false }
        var code: SecCode?
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let values = info as? [String: Any],
            let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let services = entitlements["com.apple.developer.icloud-services"] as? [String],
            services.contains("CloudKit"),
            let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return containers.contains(containerIdentifier)
    }
    func resume() async {
        guard enabled else { return }
        beginRefreshLoop()
        await start(explicit: false)
    }
    func setEnabled(_ value: Bool) async {
        if !value {
            stop(message: "sync is off")
            busy = false
            return
        }
        guard !busy, !needsCacheRepair else { return }
        if failed {
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    journal = try JSONDecoder().decode(ICloudSyncJournal.self, from: Data(contentsOf: file))
                    guard journal.version == 1 else { throw ICloudSyncFailure.invalidData }
                }
                failed = false
            } catch {
                needsCacheRepair = true
                status = "sync data couldn’t be restored. Reset the local sync cache to retry."
                return
            }
        }
        await start(explicit: true)
    }
    private func start(explicit: Bool) async {
        guard !starting, engine == nil, !failed, application != nil else { return }
        guard Self.signedForICloud else {
            status = "this build needs an Apple provisioning profile with iCloud enabled"
            return
        }
        starting = true
        busy = true
        let ticket = generation
        defer {
            starting = false
            busy = false
        }
        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let accountStatus = try await container.accountStatus()
            guard ticket == generation else { return }
            switch accountStatus {
            case .noAccount, .restricted:
                stop(message: ICloudSyncFailure.unavailable.localizedDescription)
                return
            case .available: break
            default: throw CKError(.serviceUnavailable)
            }
            let account = try await container.userRecordID().recordName
            guard ticket == generation else { return }
            if let previous = journal.accountID, previous != account {
                guard explicit else {
                    stop(message: ICloudSyncFailure.accountChanged.localizedDescription)
                    return
                }

                let deviceID = journal.deviceID
                journal = ICloudSyncJournal()
                journal.deviceID = deviceID
            }

            if journal.zoneEstablished == true {
                let zones = try await container.privateCloudDatabase.allRecordZones()
                guard ticket == generation else { return }
                if !zones.contains(where: { $0.zoneID == Self.zoneID }) {
                    clearCloudCache()
                    if !explicit {
                        stop(message: "iCloud data was removed. Local data is kept; turn sync on to start again.")
                        return
                    }
                }
            }
            journal.accountID = account
            journal.enabled = true
            enabled = true
            try captureCurrent()
            try applyDocuments()
            try save()
            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase, stateSerialization: journal.engineState, delegate: self)

            configuration.automaticallySync = false
            bootstrapping = true
            let engine = CKSyncEngine(configuration)
            self.engine = engine
            NSApplication.shared.registerForRemoteNotifications()
            status = "syncing with iCloud…"
            beginRefreshLoop()
            Task { await self.refresh() }
        } catch {
            if ticket == generation {
                if error is CKError {
                    status = Self.message(error)
                } else if journal.enabled {
                    pause(error)
                } else {
                    status = Self.message(error)
                }
            }
        }
    }
    private func beginRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.refresh()
            }
        }
    }
    private func clearCloudCache() {
        journal.engineState = nil
        journal.zoneEstablished = nil
        journal.documents = [:]
        journal.baseline = [:]
        journal.systemFields = [:]
        journal.dirty = []
    }
    private func stop(message: String) {
        generation = UUID()
        enabled = false
        journal.enabled = false
        let old = engine
        engine = nil
        refreshTask?.cancel()
        refreshTask = nil
        otherMacs = []
        status = message
        do { try save() } catch { pause(error) }
        Task { await old?.cancelOperations() }
    }
    private func checkAccount() async {
        guard enabled, Self.signedForICloud else { return }
        let ticket = generation
        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let accountStatus = try await container.accountStatus()
            guard enabled, ticket == generation else { return }
            switch accountStatus {
            case .noAccount, .restricted:
                stop(message: ICloudSyncFailure.unavailable.localizedDescription)
                return
            case .available: break
            default: throw CKError(.serviceUnavailable)
            }
            let account = try await container.userRecordID().recordName
            guard enabled, ticket == generation else { return }
            if account != journal.accountID { stop(message: ICloudSyncFailure.accountChanged.localizedDescription) }
        } catch { if enabled, ticket == generation { status = Self.message(error) } }
    }
    func refresh() async {
        guard enabled, !failed else { return }
        if engine == nil {
            await start(explicit: false)
            return
        }
        guard !busy, let engine else { return }
        busy = true
        let ticket = generation
        defer { if ticket == generation { busy = false } }
        do {
            try captureCurrent()
            enqueueDirty(engine)
            try await engine.fetchChanges()
            guard enabled, self.engine === engine else { return }
            if bootstrapping {
                var configuration = CKSyncEngine.Configuration(
                    database: engine.database,
                    stateSerialization: journal.engineState, delegate: self)
                configuration.automaticallySync = true
                let automatic = CKSyncEngine(configuration)
                self.engine = automatic
                bootstrapping = false
                automatic.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueueDirty(automatic)
                try await automatic.sendChanges()
            } else {
                try await engine.sendChanges()
            }
        } catch { if enabled && ticket == generation { status = Self.message(error) } }
    }
    func capture(_ snapshot: BrowserSnapshot) {
        guard enabled, !failed, !applying else { return }
        do {
            try captureSnapshot(snapshot)
            try save()
            if let engine { enqueueDirty(engine) }
        } catch { pause(error) }
    }
    private func captureCurrent() throws {
        guard let snapshot = application?.syncSnapshot() else { return }
        try captureSnapshot(snapshot)
        try save()
    }
    private func captureSnapshot(_ snapshot: BrowserSnapshot) throws {
        let profiles = snapshot.profiles.filter { !$0.privateMode }
        let current = Set(profiles.map { "profile." + $0.id.uuidString })
        for name in journal.baseline.keys where name.hasPrefix("profile.") && !current.contains(name) {
            journal.documents[name] = SyncDocument(deleted: true)
            journal.baseline[name] = nil
            journal.dirty.insert(name)
        }
        for name in Array(journal.documents.keys) where name.hasPrefix("chat.") {
            let parts = name.split(separator: ".")
            if parts.count == 3 && !profiles.contains(where: { $0.id.uuidString == parts[1] }) {
                journal.documents[name] = SyncDocument(deleted: true)
                journal.baseline[name] = nil
                journal.dirty.insert(name)
            }
        }
        for profile in profiles {
            try journal.edit("profile." + profile.id.uuidString, values: ICloudSyncProjection.profile(profile))
        }
        if snapshot.preferences.syncSideChats == true, let application {
            for profile in profiles {
                let values = try application.chatArchive.syncValues(profileID: profile.id)

                for (id, data) in values {
                    try journal.edit("chat." + profile.id.uuidString + "." + id, values: ["conversation": data])
                }
                let prefix = "chat." + profile.id.uuidString + "."
                for name in Array(journal.baseline.keys)
                where name.hasPrefix(prefix) && values[String(name.dropFirst(prefix.count))] == nil {
                    try journal.edit(name, values: [:])
                }
            }
        }
        var preferences = try ICloudSyncProjection.preferences(snapshot.preferences)
        preferences["profileOrder"] = try ICloudSyncProjection.data(profiles.map { $0.id.uuidString })
        preferences["appearanceMode"] = try ICloudSyncProjection.data(
            UserDefaults.standard.string(forKey: "loaf.appearance") ?? "system")
        try journal.edit("preferences", values: preferences)
        var mac = ICloudSyncProjection.mac(
            snapshot, id: journal.deviceID, name: Host.current().localizedName ?? "Mac", now: .distantPast)
        guard mac.tabs.count <= 2000 else { throw ICloudSyncFailure.tooLarge }
        let name = "mac." + journal.deviceID
        let baseline = try ICloudSyncProjection.encoded(mac)
        if journal.baseline[name]?["snapshot"] != baseline {
            mac.updatedAt = Date()
            try journal.edit(name, values: ["snapshot": try ICloudSyncProjection.encoded(mac)])
            journal.baseline[name] = ["snapshot": baseline]
        }
        for name in journal.dirty {
            guard let document = journal.documents[name], try JSONEncoder().encode(document).count <= 700_000 else {
                throw ICloudSyncFailure.tooLarge
            }
        }
    }
    private func enqueueDirty(_ engine: CKSyncEngine) {
        engine.state.add(pendingRecordZoneChanges: journal.dirty.sorted().map { .saveRecord(recordID($0)) })
    }
    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: Self.zoneID) }
    private func save() throws {
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func pause(_ error: Error) {
        failed = true
        enabled = false
        journal.enabled = false
        generation = UUID()
        let old = engine
        engine = nil
        refreshTask?.cancel()
        refreshTask = nil
        status = Self.message(error)
        Task { await old?.cancelOperations() }
    }
    private static func message(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure: return "offline — changes will sync when your connection returns"
            case .quotaExceeded: return "iCloud storage is full. Free up space, then sync again."
            case .notAuthenticated: return "sign in to iCloud in System Settings to resume sync"
            case .permissionFailure, .badContainer, .missingEntitlement: return "iCloud isn’t configured for this build"
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud is temporarily unavailable — changes are queued"
            default: return "iCloud sync needs attention (\(ck.code.rawValue)); local data is retained"
            }
        }
        return error.localizedDescription
    }
    private func archive(_ record: CKRecord) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private func record(_ name: String) throws -> CKRecord? {
        guard let document = journal.documents[name] else { return nil }
        let record: CKRecord
        if let data = journal.systemFields[name] {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            guard let decoded = CKRecord(coder: coder) else { throw ICloudSyncFailure.invalidData }
            coder.finishDecoding()
            record = decoded
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: recordID(name))
        }
        record.encryptedValues["payloadV1"] = try JSONEncoder().encode(document) as CKRecordValue
        return record
    }
    private func receive(_ record: CKRecord) throws {
        let name = record.recordID.recordName
        guard record.recordID.zoneID == Self.zoneID, record.recordType == Self.recordType else { return }
        guard name == "preferences" || name.hasPrefix("profile.") || name.hasPrefix("mac.") || name.hasPrefix("chat."),
            let data = record.encryptedValues["payloadV1"] as? Data, data.count <= 700_000
        else { throw ICloudSyncFailure.invalidData }
        try journal.merge(name, document: JSONDecoder().decode(SyncDocument.self, from: data))
        journal.systemFields[name] = try archive(record)
    }
    private func applyDocuments() throws {
        guard let application else { return }
        applying = true
        defer { applying = false }

        var profiles = application.profiles
        let deletions = journal.documents.filter { $0.key.hasPrefix("profile.") && $0.value.deleted }.keys
            .compactMap { UUID(uuidString: String($0.dropFirst(8))) }
        for (name, document) in journal.documents.sorted(by: { $0.key < $1.key })
        where name.hasPrefix("profile.") && !document.deleted {
            guard let id = UUID(uuidString: String(name.dropFirst(8))) else { throw ICloudSyncFailure.invalidData }
            let original = profiles.first { $0.id == id } ?? Profile(id: id, name: "profile")
            guard !original.privateMode else { throw ICloudSyncFailure.invalidData }
            let updated = try ICloudSyncProjection.applyProfile(document, to: original)
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index] = updated
            } else {
                profiles.append(updated)
            }
        }
        guard profiles.count <= 64 else { throw ICloudSyncFailure.tooLarge }
        var preferences = application.preferences
        if let document = journal.documents["preferences"] {
            preferences = try ICloudSyncProjection.applyPreferences(document, to: preferences)
            let regular = try ICloudSyncProjection.ordered(
                profiles.filter { !$0.privateMode }, document: document, key: "profileOrder")
            profiles = regular + profiles.filter(\.privateMode)
        }
        var macs: [SyncedMac] = []
        for (name, document) in journal.documents
        where name.hasPrefix("mac.") && name != "mac." + journal.deviceID && !document.deleted {
            guard let data = document.fields["snapshot"]?.value else { continue }
            var mac = try JSONDecoder().decode(SyncedMac.self, from: data)
            guard name == "mac." + mac.id, mac.tabs.count <= 2000 else { throw ICloudSyncFailure.invalidData }
            mac.tabs = mac.tabs.filter {
                ICloudSyncProjection.address($0.address) != nil && !deletions.contains($0.profileID)
            }
            mac.name = String(mac.name.prefix(128))

            if mac.updatedAt > Date().addingTimeInterval(-30 * 86_400) { macs.append(mac) }
        }
        var appearanceMode: String?
        if let blob = journal.documents["preferences"]?.fields["appearanceMode"]?.value {
            let value = try ICloudSyncProjection.value(blob)
            if let mode = value as? String, ["system", "light", "dark"].contains(mode) { appearanceMode = mode }
        }
        if application.preferences.syncSideChats == true {
            for (name, document) in journal.documents where name.hasPrefix("chat.") && !document.deleted {
                let parts = name.split(separator: ".")
                guard parts.count == 3, let profileID = UUID(uuidString: String(parts[1])),
                    let chatID = UUID(uuidString: String(parts[2])),
                    profiles.contains(where: { $0.id == profileID && !$0.privateMode })
                else { continue }
                if let field = document.fields["conversation"] {
                    try application.chatArchive.merge(
                        profileID: profileID, document: SyncDocument(fields: [chatID.uuidString: field]))
                }
            }
        }
        application.profiles = profiles
        application.preferences = preferences
        application.reconcileSyncedPins()
        if let appearanceMode { UserDefaults.standard.set(appearanceMode, forKey: "loaf.appearance") }
        if !profiles.contains(where: { !$0.privateMode && !deletions.contains($0.id) }) {
            application.profiles.append(Profile(name: "personal", emoji: "🌱"))
        }

        for id in deletions where application.canDeleteProfile(id) {
            Task {
                do { try await application.deleteProfile(id) } catch {
                    application.error = "Synced profile cleanup is pending: \(error.localizedDescription)"
                }
            }
        }
        otherMacs = macs.sorted { $0.updatedAt > $1.updatedAt }
        try application.persistSyncedSession()

        for profile in application.profiles where !profile.privateMode && !deletions.contains(profile.id) {
            journal.baseline["profile." + profile.id.uuidString] = try ICloudSyncProjection.profile(profile)
        }
        var baseline = try ICloudSyncProjection.preferences(application.preferences)
        baseline["profileOrder"] = try ICloudSyncProjection.data(
            application.profiles.filter { !$0.privateMode && !deletions.contains($0.id) }.map { $0.id.uuidString })
        baseline["appearanceMode"] = try ICloudSyncProjection.data(
            UserDefaults.standard.string(forKey: "loaf.appearance") ?? "system")
        journal.baseline["preferences"] = baseline
    }

    func mergeFetchedRecords(_ records: [CKRecord], deletions: [CKRecord.ID] = []) throws {
        guard enabled, !failed else { return }
        try captureCurrent()
        for record in records { try receive(record) }
        for deletion in deletions where deletion.zoneID == Self.zoneID {
            let name = deletion.recordName
            journal.documents[name] = SyncDocument(deleted: true)
            journal.dirty.remove(name)
            journal.systemFields[name] = nil
        }
        try applyDocuments()
        try save()
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard enabled, !failed, engine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let event): journal.engineState = event.stateSerialization
            case .accountChange(let event):
                if case .signIn(let currentUser) = event.changeType, currentUser.recordName == journal.accountID {
                    break
                } else {
                    stop(message: ICloudSyncFailure.accountChanged.localizedDescription)
                    return
                }
            case .fetchedDatabaseChanges(let event):
                if event.modifications.contains(where: { $0.zoneID == Self.zoneID }) { journal.zoneEstablished = true }
                if event.deletions.contains(where: { $0.zoneID == Self.zoneID }) {

                    clearCloudCache()
                    stop(message: "iCloud data was removed. Local data is kept; turn sync on to start again.")
                    return
                }
            case .fetchedRecordZoneChanges(let event):
                try mergeFetchedRecords(event.modifications.map(\.record), deletions: event.deletions.map(\.recordID))
                enqueueDirty(syncEngine)
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords {
                    let name = record.recordID.recordName
                    journal.systemFields[name] = try archive(record)
                    if let data = record.encryptedValues["payloadV1"] as? Data,
                        try JSONDecoder().decode(SyncDocument.self, from: data) == journal.documents[name]
                    {
                        journal.dirty.remove(name)
                    } else {
                        journal.dirty.insert(name)
                    }
                }
                for failure in event.failedRecordSaves {
                    let name = failure.record.recordID.recordName
                    switch failure.error.code {
                    case .serverRecordChanged:
                        guard let server = failure.error.serverRecord else { throw ICloudSyncFailure.invalidData }
                        try captureCurrent()
                        try receive(server)
                        journal.dirty.insert(name)
                        try applyDocuments()
                    case .zoneNotFound:
                        if journal.zoneEstablished == true {
                            clearCloudCache()
                            stop(message: "iCloud data was removed. Local data is kept; turn sync on to start again.")
                            return
                        }
                        journal.systemFields[name] = nil
                        journal.dirty.insert(name)
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    case .unknownItem:

                        journal.documents[name] = SyncDocument(deleted: true)
                        journal.systemFields[name] = nil
                        journal.dirty.remove(name)
                        try applyDocuments()
                    default:
                        operationFailed = true
                        status = Self.message(failure.error)
                    }
                }
                enqueueDirty(syncEngine)
                if event.failedRecordSaves.isEmpty && !operationFailed {
                    lastSync = Date()
                    status = journal.dirty.isEmpty ? "up to date" : "syncing with iCloud…"
                }
            case .sentDatabaseChanges(let event):
                if event.savedZones.contains(where: { $0.zoneID == Self.zoneID }) { journal.zoneEstablished = true }
                if let error = event.failedZoneSaves.first?.error {
                    operationFailed = true
                    status = Self.message(error)
                }
            case .didFetchRecordZoneChanges(let event):
                if let error = event.error {
                    operationFailed = true
                    status = Self.message(error)
                }
            case .willFetchChanges:
                operationFailed = false
                status = "syncing with iCloud…"
            case .willSendChanges: if !operationFailed { status = "syncing with iCloud…" }
            case .didFetchChanges, .didSendChanges:
                if journal.dirty.isEmpty && !operationFailed {
                    lastSync = Date()
                    status = "up to date"
                }
            default: break
            }
            try save()
        } catch { pause(error) }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        guard enabled, !failed, engine === syncEngine else { return nil }
        do {
            try captureCurrent()
            let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
                .prefix(200)
            var records: [CKRecord] = []
            for change in changes {
                if case .saveRecord(let id) = change, let record = try record(id.recordName) { records.append(record) }
            }
            guard !records.isEmpty else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: [])
        } catch {
            pause(error)
            return nil
        }
    }
    func resetLocalCache() async {
        guard !busy else { return }
        let old = engine
        generation = UUID()
        enabled = false
        engine = nil
        refreshTask?.cancel()
        refreshTask = nil
        otherMacs = []
        busy = true
        defer { busy = false }
        await old?.cancelOperations()
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = file.deletingLastPathComponent().appendingPathComponent(
                    "icloud-sync-backup-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: file, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            journal = ICloudSyncJournal()
            try save()
            failed = false
            needsCacheRepair = false
            status = "local sync cache reset. Turn sync on to reconnect to iCloud."
        } catch {
            failed = true
            needsCacheRepair = true
            status = error.localizedDescription
        }
    }
    func removeCloudData() async {
        guard !busy, Self.signedForICloud, !needsCacheRepair else { return }
        busy = true
        defer { busy = false }
        let old = engine
        stop(message: "removing iCloud data…")
        await old?.cancelOperations()
        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            guard try await container.accountStatus() == .available else { throw ICloudSyncFailure.unavailable }
            let accountID = try await container.userRecordID().recordName
            if let previous = journal.accountID, previous != accountID { throw ICloudSyncFailure.accountChanged }
            do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: Self.zoneID) } catch let error
                as CKError where error.code == .zoneNotFound
            {}
            let deviceID = journal.deviceID
            journal = ICloudSyncJournal()
            journal.deviceID = deviceID
            journal.accountID = accountID
            try save()
            failed = false
            status = "iCloud data removed. Local profiles, tabs and settings are kept."
        } catch { status = Self.message(error) }
    }
}

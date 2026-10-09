import AppKit
import Combine
import WebKit

@MainActor final class BrowserApplication: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var preferences = BrowserPreferences()
    @Published var ready = false
    @Published var onboardingVisible = false
    @Published var error: String?
    @Published var windows: [BrowserWindowState] = []
    let directory: URL
    let blocker = ContentBlocker()
    let downloads = DownloadManager()
    let weather = WeatherService()
    private var resourceMonitor: ResourceMonitor?
    var resources: ResourceMonitor {
        if let resourceMonitor { return resourceMonitor }
        let monitor = ResourceMonitor(application: self)
        resourceMonitor = monitor
        return monitor
    }
    lazy var notifications = WebNotifications(application: self)
    private let suppliedChatGPTAccount: ChatGPTAccount?
    lazy var chatGPTAccount = suppliedChatGPTAccount ?? ChatGPTAccount()
    let favicons: FaviconService
    let sites = PopularSites()
    let tabPreviews = TabPreviewCache()
    weak var coordinator: WindowCoordinator?
    var runtimes: [UUID: ProfileRuntime] = [:]
    private var saveTask: Task<Void, Never>?
    private let sessionWriter = SessionWriter()
    private var sleepingTask: Task<Void, Never>?
    private var restoredWindows: [SavedWindow] = []
    private var pendingProfileDeletions = Set<UUID>()
    private var observers = Set<AnyCancellable>()
    func setAIFeaturesEnabled(_ enabled: Bool) {
        preferences.aiFeaturesEnabled = enabled
        if !enabled {
            for runtime in runtimes.values { for tab in runtime.tabs.values { tab.existingChatGPTSearch?.clear() } }
        }
        persistSoon()
    }

    init(directory override: URL? = nil, prepareServices: Bool = true, chatGPTAccount: ChatGPTAccount? = nil,
        faviconService: FaviconService? = nil) {
        suppliedChatGPTAccount = chatGPTAccount
        directory =
            override
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BrowserBrand.supportDirectory, isDirectory: true)
        favicons = faviconService ?? FaviconService(directory: directory.appendingPathComponent("Favicons"))
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let deletions = directory.appendingPathComponent("pending-profile-deletions.json")
            if FileManager.default.fileExists(atPath: deletions.path) {
                pendingProfileDeletions = try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: deletions))
            }
            let file = directory.appendingPathComponent("session.json")
            onboardingVisible = override == nil && !FileManager.default.fileExists(atPath: file.path)
            if FileManager.default.fileExists(atPath: file.path) {
                let snapshot = try JSONDecoder().decode(BrowserSnapshot.self, from: Data(contentsOf: file))
                guard [1, 2].contains(snapshot.version), !snapshot.profiles.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                profiles = snapshot.profiles.filter { !$0.privateMode }
                preferences = snapshot.preferences
                if override == nil, preferences.onboardingCompleted == false { onboardingVisible = true }
                if snapshot.version == 1 {
                    try FileManager.default.copyItem(
                        at: file, to: directory.appendingPathComponent("session-v1-backup-\(UUID().uuidString).json"))
                    restoredWindows = [
                        SavedWindow(
                            selectedProfile: snapshot.selectedProfile,
                            workspaces: Dictionary(
                                uniqueKeysWithValues: profiles.map {
                                    ($0.id, WindowWorkspace(tabs: $0.tabs, selectedTab: $0.selectedTab))
                                }))
                    ]
                    if preferences.sidebarWidth == 206 { preferences.sidebarWidth = 220 }
                } else {
                    restoredWindows = snapshot.windows ?? []
                }
                migratePinnedShortcuts()
                for index in profiles.indices {
                    profiles[index].tabs = []
                    profiles[index].selectedTab = nil
                }
            }
        } catch {
            let file = directory.appendingPathComponent("session.json")
            try? FileManager.default.copyItem(
                at: file, to: directory.appendingPathComponent("session-unreadable-\(UUID().uuidString).json"))
            self.error = "The session couldn’t be restored. A backup was retained: \(error.localizedDescription)"
        }
        profiles.removeAll { pendingProfileDeletions.contains($0.id) }
        restoredWindows = restoredWindows.compactMap { record in
            var record = record
            record.workspaces = record.workspaces.filter { !pendingProfileDeletions.contains($0.key) }
            guard !record.workspaces.isEmpty else { return nil }
            if pendingProfileDeletions.contains(record.selectedProfile) {
                record.selectedProfile = record.workspaces.keys.sorted { $0.uuidString < $1.uuidString }.first!
            }
            return record
        }
        if profiles.isEmpty {
            profiles = [Profile(name: "personal", emoji: "🌱"), Profile(name: "school", emoji: "📝", tint: 1)]
        }
        for index in profiles.indices where profiles[index].personalization?.background == "lime" {
            profiles[index].personalization?.background = "profile"
        }
        preferences.sidebarWidth = min(360, max(192, preferences.sidebarWidth))
        if preferences.sidebarOnlyChrome == false { preferences.insetCollapsedPage = false }
        if preferences.aiProvider == .privateCloud { preferences.aiProvider = .onDevice }
        if preferences.aiProvider == .onDevice, AppleIntelligence.unavailableReason(for: .onDevice) != nil {
            preferences.aiProvider = .chatgpt
        }
        if preferences.alternateSearch?.provider == .appleIntelligence,
            AppleIntelligence.unavailableReason(for: .onDevice) != nil
        {
            preferences.alternateSearch?.enabled = false
        }
        if preferences.searchEngine == .googleAIOverview { preferences.searchEngine = .google }
        if preferences.alternateSearch?.provider == .googleAIOverview { preferences.alternateSearch?.provider = .google }
        downloads.configure(directory: directory)
        for publisher in [
            blocker.objectWillChange, downloads.objectWillChange, weather.objectWillChange, sites.objectWillChange,
            tabPreviews.objectWillChange,
        ] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        }
        Task {
            if prepareServices, !(await LegalAcceptance.shared.waitUntilAccepted()) { return }
            if !pendingProfileDeletions.isEmpty {
                do {
                    try persistProfileDeletion()
                    for id in pendingProfileDeletions { try await finishProfileDeletion(id) }
                } catch { self.error = "Profile data cleanup is pending: \(error.localizedDescription)" }
            }
            if prepareServices { await blocker.prepare() }
            ready = true
            for window in windows { window.restoreTabs(for: window.selectedProfileID) }
            if prepareServices {
                let owner = self
                resources.objectWillChange.sink { [weak owner] in owner?.objectWillChange.send() }.store(in: &observers)
                startIdleTabSleeping()
                TopLevelDomains.shared.start(directory: directory)
                await sites.refresh(directory: directory, allowNetwork: preferences.remoteSites == true)
                if !preferences.weatherCity.isEmpty {
                    await weather.fetch(
                        city: preferences.weatherCity, fahrenheit: preferences.fahrenheit,
                        preferredProvider: preferences.weatherProvider ?? "automatic")
                }
            }
        }
    }
    private func migratePinnedShortcuts() {
        for windowIndex in restoredWindows.indices {
            for profileID in Array(restoredWindows[windowIndex].workspaces.keys) {
                guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
                    var workspace = restoredWindows[windowIndex].workspaces[profileID]
                else { continue }
                for index in workspace.tabs.indices where workspace.tabs[index].pinned {
                    let id = workspace.tabs[index].pinnedShortcutID ?? workspace.tabs[index].id
                    workspace.tabs[index].pinnedShortcutID = id
                    if !(profiles[profileIndex].pinShortcuts ?? []).contains(where: { $0.id == id }) {
                        var shortcut = workspace.tabs[index]
                        shortcut.id = id
                        shortcut.pinnedShortcutID = nil
                        shortcut.pinnedAddress = shortcut.pinnedAddress ?? shortcut.address
                        shortcut.address = shortcut.pinnedAddress
                        profiles[profileIndex].pinShortcuts = (profiles[profileIndex].pinShortcuts ?? []) + [shortcut]
                    }
                }
                restoredWindows[windowIndex].workspaces[profileID] = workspace
            }
        }
    }
    private func startIdleTabSleeping() {
        sleepingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.sleepOneIdleTab()
            }
        }
    }
    func sleepOneIdleTab(at now: Date = Date()) async {
        guard preferences.sleepIdleTabs == true || resources.saverEnabled else { return }
        let candidates = runtimes.values.flatMap { $0.tabs.values }
            .filter {
                $0.canSleep(
                    at: now,
                    idleInterval: resources.saverEnabled
                        ? min(300, preferences.sleepInterval) : preferences.sleepInterval)
            }.sorted { $0.lastActivated < $1.lastActivated }

        for tab in candidates.prefix(1) {
            await tab.sleepIfIdle(
                at: now,
                idleInterval: resources.saverEnabled ? min(300, preferences.sleepInterval) : preferences.sleepInterval)
        }
    }
    deinit { sleepingTask?.cancel() }

    func initialWindows() -> [BrowserWindowState] {
        if windows.isEmpty {
            let saved = preferences.restoreSession == false ? [] : restoredWindows
            if saved.isEmpty { _ = makeWindow() } else { for record in saved { _ = makeWindow(saved: record) } }
        }
        return windows
    }
    @discardableResult func makeWindow(profileID: UUID? = nil, saved: SavedWindow? = nil, restore: Bool = true)
        -> BrowserWindowState
    {
        let window = BrowserWindowState(application: self, saved: saved, profileID: profileID)
        windows.append(window)
        if ready && restore { window.restoreTabs(for: window.selectedProfileID) }
        return window
    }
    func runtime(for id: UUID) -> ProfileRuntime {
        if let runtime = runtimes[id] { return runtime }
        guard let profile = profiles.first(where: { $0.id == id }) else { preconditionFailure("Unknown profile") }
        let runtime = ProfileRuntime(profile: profile, application: self)
        runtimes[id] = runtime
        runtime.extensionRestoration = Task { await runtime.extensions.restore() }
        return runtime
    }
    func updateProfile(_ id: UUID, _ update: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var profile = profiles[index]
        update(&profile)
        profile.tabs = []
        profile.selectedTab = nil

        profiles[index] = profile
        persistSoon()
    }
    func endPrivateProfile(_ id: UUID) {
        guard profiles.first(where: { $0.id == id })?.privateMode == true else { return }
        for window in windows { window.forgetProfile(id) }
        favicons.forgetPrivate(id)
        downloads.forgetPrivate(id)
        tabPreviews.forgetProfile(id)
        runtimes.removeValue(forKey: id)
        profiles.removeAll { $0.id == id }
        persistSoon()
    }
    func canDeleteProfile(_ id: UUID) -> Bool {
        profiles.contains { $0.id == id && !$0.privateMode }
            && profiles.filter { !$0.privateMode }.count > 1 && !pendingProfileDeletions.contains(id)
    }
    func deleteProfile(_ id: UUID) async throws {
        guard canDeleteProfile(id) else {
            throw ProfileImport.Failure(message: "Keep at least one regular profile in loaf.")
        }


        var pending = pendingProfileDeletions
        pending.insert(id)
        try writeProfileDeletions(pending)
        pendingProfileDeletions = pending
        runtimes[id]?.extensionRestoration?.cancel()
        runtimes[id]?.extensions.shutDown()
        for window in windows { window.forgetProfile(id) }
        coordinator?.forgetProfile(id)
        downloads.forgetProfile(id)
        notifications.forgetProfile(id)
        tabPreviews.forgetProfile(id)
        runtimes.removeValue(forKey: id)
        profiles.removeAll { $0.id == id }
        restoredWindows = restoredWindows.compactMap { record in
            var record = record
            record.workspaces.removeValue(forKey: id)
            guard !record.workspaces.isEmpty else { return nil }
            if record.selectedProfile == id { record.selectedProfile = record.workspaces.keys.first! }
            return record
        }
        try persistProfileDeletion()
        await Task.yield()
        try await finishProfileDeletion(id)
    }
    private func persistProfileDeletion() throws {
        saveTask?.cancel()
        saveTask = nil
        guard var snapshot = sessionSnapshot() else { throw CocoaError(.fileWriteUnknown) }
        if windows.isEmpty { snapshot.windows = restoredWindows }
        let revision = sessionWriter.reserve()
        try sessionWriter.commit(try SessionWrite(snapshot: snapshot).encoded(),
            to: directory.appendingPathComponent("session.json"), revision: revision)
    }
    private func writeProfileDeletions(_ ids: Set<UUID>) throws {
        let file = directory.appendingPathComponent("pending-profile-deletions.json")
        try JSONEncoder().encode(ids).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func finishProfileDeletion(_ id: UUID) async throws {
        try PasswordVault.deleteAll(profileID: id)
        await clearDeletedProfileWebsiteData(id)


        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            where file.lastPathComponent.hasPrefix("session-v1-backup-") || file.lastPathComponent.hasPrefix("session-unreadable-") {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                var backup = try? JSONDecoder().decode(BrowserSnapshot.self, from: Data(contentsOf: file)),
                backup.profiles.contains(where: { $0.id == id }) else { continue }
            backup.profiles.removeAll { $0.id == id }
            if backup.profiles.isEmpty { try FileManager.default.removeItem(at: file); continue }
            if backup.selectedProfile == id { backup.selectedProfile = backup.profiles[0].id }
            backup.windows = backup.windows?.compactMap { record in
                var record = record
                record.workspaces.removeValue(forKey: id)
                guard !record.workspaces.isEmpty else { return nil }
                if record.selectedProfile == id { record.selectedProfile = record.workspaces.keys.first! }
                return record
            }
            try JSONEncoder().encode(backup).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let configuration = WKWebExtensionController.Configuration(identifier: id)
        let controller = WKWebExtensionController(configuration: configuration)
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
        await controller.removeData(ofTypes: types, from: records)
        if let error = records.flatMap(\.errors).first { throw error }
        let extensions = directory.appendingPathComponent("Extensions/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: extensions.path) { try FileManager.default.removeItem(at: extensions) }


        for attempt in 0..<4 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                break
            } catch {
                guard attempt < 3 else { throw error }
                try await Task.sleep(for: .milliseconds([100, 300, 1_000][attempt]))
            }
        }
        var pending = pendingProfileDeletions
        pending.remove(id)
        try writeProfileDeletions(pending)
        pendingProfileDeletions = pending
    }
    private func clearDeletedProfileWebsiteData(_ id: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func persistSoon() {

        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            guard let snapshot = self.sessionSnapshot() else { return }
            let payload = SessionWrite(snapshot: snapshot)
            let writer = self.sessionWriter
            let revision = writer.reserve()
            let file = self.directory.appendingPathComponent("session.json")
            do {
                try await Task.detached(priority: .utility) {
                    let data = try payload.encoded()
                    try writer.commit(data, to: file, revision: revision)
                }.value
            } catch {
                if writer.isCurrent(revision) { self.reportSaveError(error) }
            }
            self.downloads.persist()
        }
    }
    private func sessionSnapshot() -> BrowserSnapshot? {
        let persistent = profiles.filter { !$0.privateMode }
        guard let first = persistent.first else { return nil }
        let records = windows.compactMap { $0.snapshot() }
        return BrowserSnapshot(
            version: 2, profiles: persistent, selectedProfile: records.first?.selectedProfile ?? first.id,
            preferences: preferences, windows: records)
    }
    private func reportSaveError(_ error: Error) {
        let message = "The session couldn’t be saved: \(error.localizedDescription)"
        self.error = message
        (coordinator?.focused ?? windows.first)?.error = message
    }
    func persist() {
        resourceMonitor?.save()
        saveTask?.cancel()
        saveTask = nil
        guard let snapshot = sessionSnapshot() else { return }
        let revision = sessionWriter.reserve()
        do {
            let data = try SessionWrite(snapshot: snapshot).encoded()
            try sessionWriter.commit(data, to: directory.appendingPathComponent("session.json"), revision: revision)
        } catch { reportSaveError(error) }
        downloads.persist()
    }
}

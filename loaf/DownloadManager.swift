import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

struct DownloadRecord: Codable {
    var id: UUID
    var profileID: UUID
    var windowID: UUID
    var name: String
    var date: Date
    var destination: String?
    var finished: Bool
    var error: String?
    var resumeData: Data?
    var transfer: String?
    var bookmark: Data?
    var transferComplete: Bool? = nil
    var downloadOrigin: String? = nil
    var sourceURL: String? = nil
    var folderBookmark: Bool? = nil
    var openWhenFinished: Bool? = nil
    var reservedDestination: Bool? = nil
    var statistics: DownloadStatistics? = nil
}
@MainActor final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID
    let profileID: UUID
    var windowID: UUID
    let date: Date
    var download: WKDownload?
    var sourceWebView: WKWebView?
    weak var owner: BrowserWindowState?
    var privateMode = false
    var downloadOrigin: String?
    var sourceURL: URL?
    var folderBookmark = false
    var reservedDestination = false
    @Published var openWhenFinished = false
    @Published var starting = false
    var transfer: URL?
    var bookmark: Data?
    var transferComplete = false
    var clickOrigin: DownloadClickOrigin?
    var announced = false
    @Published var name = "preparing download…"
    @Published var destination: URL?
    @Published var finished = false
    @Published private(set) var fileMissing = false
    @Published var error: String?
    @Published var fraction = 0.0
    @Published var resumeData: Data?
    @Published private(set) var statistics = DownloadStatistics()
    private var transferClock = DownloadTransferClock()
    private var lastStatisticsSample: TimeInterval = 0
    var observation: NSKeyValueObservation?
    init(_ download: WKDownload, owner: BrowserWindowState, profileID: UUID) {
        id = UUID()
        date = Date()
        self.download = download
        sourceURL = download.originalRequest?.url
        self.profileID = profileID
        windowID = owner.id
        self.owner = owner
        privateMode = owner.profileFor(profileID).privateMode
    }
    init(record: DownloadRecord) {
        id = record.id
        profileID = record.profileID
        windowID = record.windowID
        date = record.date
        name = record.name
        destination = record.destination.map { URL(fileURLWithPath: $0) }
        finished = record.finished
        fraction = record.finished || record.transferComplete == true ? 1 : 0
        transferComplete = record.transferComplete == true
        downloadOrigin = record.downloadOrigin
        sourceURL = record.sourceURL.flatMap(URL.init(string:))
        folderBookmark = record.folderBookmark == true
        reservedDestination = record.reservedDestination == true
        openWhenFinished = record.openWhenFinished == true
        error = record.finished ? record.error : record.error ?? "interrupted"
        resumeData = record.resumeData
        transfer = record.transfer.map { URL(fileURLWithPath: $0) }
        bookmark = record.bookmark
        statistics = record.statistics ?? DownloadStatistics()
        statistics.bytesPerSecond = nil
        refreshFileAvailability()
    }
    func beginTransfer(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !transferComplete else { return }
        transferClock.begin(statistics, at: time)
        lastStatisticsSample = time - 1
    }
    func refreshTransferStatistics(at time: TimeInterval = ProcessInfo.processInfo.systemUptime, force: Bool = false) {
        guard let progress = download?.progress, force || time - lastStatisticsSample >= 0.5 else { return }
        lastStatisticsSample = time
        // WebKit can briefly expose a zero counter while attaching a resumed download.
        let received = max(statistics.receivedBytes, progress.completedUnitCount)
        let next = transferClock.sample(statistics, received: received, total: progress.totalUnitCount, at: time)
        if next != statistics { statistics = next }
    }
    func endTransfer(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        refreshTransferStatistics(at: time, force: true)
        statistics = transferClock.stop(statistics, at: time)
    }
    func resetTransferStatistics() {
        transferClock = DownloadTransferClock()
        statistics = DownloadStatistics()
    }
    func receivedResponse(_ response: URLResponse) {
        if response.expectedContentLength > 0 {
            statistics.totalBytes = max(statistics.totalBytes ?? 0, response.expectedContentLength)
        }
    }
    func refreshFileAvailability(refreshSize: Bool = false) {
        guard finished, let destination else { return }
        var stale = false
        let scoped = bookmark.flatMap {
            try? URL(
                resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale)
        }
        let scope = scoped ?? destination
        let access = scope.startAccessingSecurityScopedResource()
        defer { if access { scope.stopAccessingSecurityScopedResource() } }
        let file =
            folderBookmark ? (scoped?.appendingPathComponent(destination.lastPathComponent) ?? destination) : scope
        do {
            let reachable = try file.checkResourceIsReachable()
            var relationship: FileManager.URLRelationship = .other
            if reachable {
                try? FileManager.default.getRelationship(
                    &relationship, of: .trashDirectory, in: .userDomainMask, toItemAt: file)
            }
            let inTrash = relationship == .contains
            let missing = !reachable || inTrash
            if fileMissing != missing { fileMissing = missing }
            if !missing, self.destination != file { self.destination = file }
            if !missing, refreshSize || statistics.totalBytes == nil,
                let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            {
                let bytes = Int64(size)
                if statistics.totalBytes != bytes || statistics.receivedBytes != bytes {
                    statistics.totalBytes = bytes
                    statistics.receivedBytes = bytes
                }
            }
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            {
                if !fileMissing { fileMissing = true }
            }
        }
    }
    var active: Bool { !finished && error == nil && (download != nil || starting) }
    var canResume: Bool { !active && !finished && resumeData != nil }
    var canRestart: Bool { !active && !finished && !canRetrySave && sourceURL != nil }
    var canRetrySave: Bool {
        download == nil && fraction == 1 && !finished
            && transfer.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    var compactStatus: String {
        if finished { return fileMissing ? "deleted" : "saved" }
        if error != nil && (transferComplete || canRetrySave) { return "save failed" }
        if let error { return error.localizedCaseInsensitiveContains("cancel") ? "cancelled" : "failed" }
        return "\(Int(fraction * 100))%"
    }
    var record: DownloadRecord {
        DownloadRecord(
            id: id, profileID: profileID, windowID: windowID, name: name, date: date, destination: destination?.path,
            finished: finished, error: error, resumeData: resumeData, transfer: transfer?.path, bookmark: bookmark,
            transferComplete: transferComplete, downloadOrigin: downloadOrigin,
            sourceURL: sourceURL?.absoluteString, folderBookmark: folderBookmark, openWhenFinished: openWhenFinished,
            reservedDestination: reservedDestination, statistics: statistics)
    }
}

@MainActor final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    let progress = DownloadProgressState()
    private var dockView: DownloadDockProgress?
    private var dockTimer: Timer?
    private var cacheTimer: Timer?
    private var availabilityTimer: Timer?
    var cacheRetentionDays: () -> Int = { 7 }
    var hasActiveDownloads: Bool { items.contains { $0.active } }
    private var file: URL?
    private var transferFolder: URL?
    private final class DestinationRequest {
        let item: DownloadItem
        private var callback: ((URL?) -> Void)?
        init(item: DownloadItem, completion: @escaping (URL?) -> Void) {
            self.item = item
            callback = completion
        }
        func completion(_ url: URL?) {
            let completion = callback
            callback = nil
            completion?(url)
        }
    }
    private var queues: [UUID: [DestinationRequest]] = [:]
    private var panels: [UUID: NSSavePanel] = [:]
    private var permissionAlerts: [UUID: NSAlert] = [:]
    private var choosing = Set<UUID>()

    var destinationChooser: ((DownloadItem, @escaping (URL?) -> Void) -> Void)?
    var permissionChooser: ((DownloadItem, @escaping (Bool?) -> Void) -> Void)?
    nonisolated static func websiteOrigin(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.scheme?.lowercased() == "blob" {
            return URL(string: String(url.absoluteString.dropFirst(5))).flatMap(BrowserAddress.websiteOrigin)
        }
        return BrowserAddress.websiteOrigin(url)
    }
    func permission(for item: DownloadItem) -> Bool? {
        guard let origin = item.downloadOrigin,
            let profile = item.owner?.application.profiles.first(where: { $0.id == item.profileID })
        else { return nil }
        return profile.siteSettings?[origin]?.downloads
    }
    private func rememberPermission(_ allowed: Bool, for item: DownloadItem) {
        guard let origin = item.downloadOrigin, let owner = item.owner,
            owner.application.profiles.contains(where: { $0.id == item.profileID })
        else { return }
        owner.application.updateProfile(item.profileID) { profile in
            var settings =
                profile.siteSettings?[origin]
                ?? SiteSettings(userAgent: owner.preferences.userAgentMode ?? .desktop)
            settings.downloads = allowed
            profile.siteSettings = profile.siteSettings ?? [:]
            profile.siteSettings?[origin] = settings
        }
    }
    func configure(directory: URL) {
        file = directory.appendingPathComponent("downloads.json")
        transferFolder = directory.appendingPathComponent("Transfers")
        try? FileManager.default.createDirectory(
            at: transferFolder!, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let file, let data = try? Data(contentsOf: file),
            let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        {
            items = records.map(DownloadItem.init)
        }
    }
    func startCacheMaintenance() {
        cacheTimer?.invalidate()
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.cleanupCache(olderThanDays: self.cacheRetentionDays()) } }
        }
        availabilityTimer?.invalidate()
        availabilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.isActive else { return }
                self?.refreshFileAvailability()
            }
        }
        refreshFileAvailability()
    }
    func refreshFileAvailability() {
        for item in items where item.finished { item.refreshFileAvailability() }
    }
    func persist() {
        updateDockProgress()
        guard let file else { return }
        try? JSONEncoder().encode(items.filter { !$0.privateMode }.prefix(200).map(\.record)).write(
            to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func add(_ download: WKDownload, owner: BrowserWindowState, profileID: UUID, source: WKWebView? = nil) {
        let item = DownloadItem(download, owner: owner, profileID: profileID)
        item.sourceWebView = source
        item.clickOrigin = (source as? LoafWebView)?.browserTab?.downloadClickOrigin?.recent
        items.insert(item, at: 0)
        observe(item, download)
        updateDockProgress()
        persist()
    }
    private func observe(_ item: DownloadItem, _ download: WKDownload) {
        download.delegate = self
        item.download = download
        item.starting = false
        item.resumeData = nil
        item.error = nil
        if item.destination != nil && item.transfer != nil { item.beginTransfer() }
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self, weak item, weak download] progress, _ in
            Task { @MainActor [weak self, weak item, weak download] in
                guard let item, let download, item.download === download else { return }
                let fraction = progress.fractionCompleted
                item.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
                self?.updateDockProgress()
            }
        }
    }
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let item = items.first(where: { $0.download === download }) else {
            completionHandler(nil)
            return
        }
        item.name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        item.receivedResponse(response)
        if item.sourceURL == nil { item.sourceURL = download.originalRequest?.url ?? response.url }
        item.downloadOrigin =
            Self.websiteOrigin(for: response.url)
            ?? Self.websiteOrigin(for: download.originalRequest?.url)
            ?? Self.websiteOrigin(for: item.sourceWebView?.url)
        queues[item.windowID, default: []].append(DestinationRequest(item: item, completion: completionHandler))
        presentNext(item.windowID)
    }
    private func presentNext(_ id: UUID) {
        guard !choosing.contains(id), let request = queues[id]?.first else { return }
        guard request.item.owner?.nativeWindow?.isVisible == true else {
            queues[id]?.removeFirst()
            request.item.error = "cancelled: window closed"
            request.completion(nil)
            presentNext(id)
            return
        }
        choosing.insert(id)
        authorize(request, windowID: id)
    }
    private func authorize(_ request: DestinationRequest, windowID id: UUID) {
        guard let owner = request.item.owner,
            owner.application.profiles.contains(where: { $0.id == request.item.profileID })
        else {
            request.completion(nil)
            finishSheet(id, request: request)
            return
        }
        if let allowed = permission(for: request.item) {
            permissionResolved(allowed, for: request, windowID: id, remember: false)
            return
        }
        if owner.preferences.asksBeforeDownloading == false {
            permissionResolved(true, for: request, windowID: id, remember: false)
            return
        }
        let completion: (Bool?) -> Void = { [weak self] allowed in
            self?.permissionResolved(allowed, for: request, windowID: id, remember: true)
        }
        if let permissionChooser {
            permissionChooser(request.item, completion)
            return
        }
        guard let coordinator = owner.application.coordinator else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        if let origin = request.item.downloadOrigin {
            let site = BrowserAddress.visible(origin)
            let name = request.item.name
            alert.messageText = "\(site) wants to download \(name)."
            alert.informativeText =
                request.item.privateMode
                ? "your choice applies only to this private session."
                : "loaf will remember your choice for this site in this profile. you can change it in website settings."
        } else {
            alert.messageText = "allow this download?"
            alert.informativeText = "\(request.item.name). loaf can’t identify the site, so this choice won’t be saved."
        }
        alert.addButton(withTitle: "allow downloads")
        alert.addButton(withTitle: "don’t allow")
        alert.addButton(withTitle: "not now").keyEquivalent = "\u{1b}"
        permissionAlerts[id] = alert
        coordinator.alert(alert, for: owner) { response in
            completion(response == .alertFirstButtonReturn ? true : response == .alertSecondButtonReturn ? false : nil)
        }
    }
    private func permissionResolved(
        _ allowed: Bool?, for request: DestinationRequest, windowID id: UUID, remember: Bool
    ) {
        guard queues[id]?.first === request else { return }
        guard request.item.owner?.nativeWindow?.isVisible == true,
            request.item.owner?.application.profiles.contains(where: { $0.id == request.item.profileID }) == true,
            request.item.error == nil
        else {
            request.completion(nil)
            finishSheet(id, request: request)
            return
        }
        if remember, let allowed { rememberPermission(allowed, for: request.item) }
        guard allowed == true else {
            request.item.error = allowed == false ? "blocked by website settings" : "cancelled"
            request.item.resumeData = nil
            request.completion(nil)
            finishSheet(id, request: request)
            return
        }
        presentDestination(request, windowID: id)
    }
    private func presentDestination(_ request: DestinationRequest, windowID id: UUID) {
        guard let window = request.item.owner?.nativeWindow else {
            request.completion(nil)
            finishSheet(id, request: request)
            return
        }
        if request.item.destination != nil, let transfer = request.item.transfer, request.item.bookmark != nil {
            request.item.beginTransfer()
            request.completion(transfer)
            announce(request.item)
            finishSheet(id, request: request)
            return
        }
        if let destinationChooser {
            destinationChooser(request.item) { [weak self] destination in
                self?.chooseDestination(destination, for: request, windowID: id)
            }
            return
        }

        let panel = NSSavePanel()
        panels[id] = panel
        panel.nameFieldStringValue = request.item.name
        panel.title = "save download"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let owner = request.item.owner, let coordinator = owner.application.coordinator else {
            request.completion(nil)
            finishSheet(id, request: request)
            return
        }
        coordinator.enqueueSheet(
            for: owner,
            cancel: { [weak self] in
                request.item.error = "cancelled: window closed"
                request.completion(nil)
                self?.finishSheet(id, request: request)
            }
        ) { [weak self] done in
            panel.beginSheetModal(for: window) { result in
                guard let self else {
                    request.completion(nil)
                    done()
                    return
                }
                self.chooseDestination(result == .OK ? panel.url : nil, for: request, windowID: id)
                done()
            }
        }
    }
    private func chooseDestination(_ destination: URL?, for request: DestinationRequest, windowID: UUID) {
        guard queues[windowID]?.first === request else { return }
        request.item.destination = destination
        if let destination, let folder = transferFolder {

            request.item.folderBookmark = false
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try Data().write(to: destination, options: .withoutOverwriting)
                    request.item.reservedDestination = true
                } catch {
                    request.item.error = "couldn’t prepare the save location: " + error.localizedDescription
                    request.completion(nil)
                    finishSheet(windowID, request: request)
                    return
                }
            }
            request.item.bookmark = try? destination.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let transfer =
                request.item.transferComplete
                ? request.item.transfer ?? folder.appendingPathComponent(request.item.id.uuidString)
                : folder.appendingPathComponent(request.item.id.uuidString)
            request.item.transfer = transfer
            request.item.beginTransfer()
            request.completion(transfer)
            announce(request.item)
        } else {
            request.item.error = "cancelled"
            request.completion(nil)
        }
        finishSheet(windowID, request: request)
    }
    private func finishSheet(_ id: UUID, request: DestinationRequest) {
        guard queues[id]?.first === request else { return }
        choosing.remove(id)
        permissionAlerts.removeValue(forKey: id)
        panels.removeValue(forKey: id)
        queues[id]?.removeFirst()
        persist()
        DispatchQueue.main.async { [weak self] in self?.presentNext(id) }
    }
    private func announce(_ item: DownloadItem) {
        guard !item.announced, let owner = item.owner, owner.selectedProfileID == item.profileID else { return }
        item.announced = true
        owner.downloadFeedback.launch(from: item.clickOrigin, name: item.name, profileID: item.profileID, owner: owner)
        item.clickOrigin = nil
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.endTransfer()
        item.transferComplete = true
        item.fraction = 1
        item.observation = nil
        item.download = nil
        item.sourceWebView = nil
        item.resumeData = nil
        saveTransferredFile(item)
    }
    private func saveTransferredFile(_ item: DownloadItem) {
        do {
            var stale = false
            let resolved =
                item.bookmark.flatMap {
                    try? URL(
                        resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil,
                        bookmarkDataIsStale: &stale)
                }
            let scope = resolved ?? item.destination?.deletingLastPathComponent()
            let destination =
                item.folderBookmark
                ? scope?.appendingPathComponent(item.destination?.lastPathComponent ?? item.name)
                : resolved ?? item.destination
            guard let destination, let transfer = item.transfer else { throw CocoaError(.fileWriteUnknown) }
            let access = scope?.startAccessingSecurityScopedResource() == true
            defer { if access { scope?.stopAccessingSecurityScopedResource() } }
            try Self.completeTransfer(from: transfer, to: destination)
            item.destination = destination
            item.finished = true
            item.reservedDestination = false
            item.error = nil
            item.transfer = nil
            item.refreshFileAvailability(refreshSize: true)
            if item.owner?.selectedProfileID == item.profileID { item.owner?.downloadFeedback.completed() }
            if item.openWhenFinished { NSWorkspace.shared.open(destination) }
        } catch { item.error = "transfer complete, save failed: " + error.localizedDescription }
        persist()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let item = items.first { $0.download === download }
        item?.endTransfer()
        if !["paused", "cancelled", "blocked by website settings"].contains(item?.error ?? "") {
            item?.error = error.localizedDescription
        }
        item?.observation = nil
        item?.download = nil
        item?.resumeData = ["blocked by website settings", "cancelled"].contains(item?.error ?? "") ? nil : resumeData
        item?.sourceWebView = nil
        item?.starting = false
        if let item, item.resumeData == nil { discardTransfer(item) }
        persist()
    }
    static func completeTransfer(from source: URL, to destination: URL) throws {

        var coordinationError: NSError?
        var writingError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) {
            url in
            do { try Data(contentsOf: source, options: .mappedIfSafe).write(to: url, options: .atomic) } catch {
                writingError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writingError { throw writingError }
        try? FileManager.default.removeItem(at: source)
    }
    func retrySave(_ item: DownloadItem, in window: BrowserWindowState) {
        guard item.canRetrySave, item.profileID == window.selectedProfileID else { return }
        item.owner = window
        item.windowID = window.id
        discardReservedDestination(item)
        item.error = nil
        item.bookmark = nil
        queues[item.windowID, default: []].append(
            DestinationRequest(item: item) { [weak self, weak item] transfer in
                guard transfer != nil, let item else { return }
                self?.saveTransferredFile(item)
            })
        presentNext(item.windowID)
    }
    func pause(_ item: DownloadItem) {
        guard item.active else { return }
        stop(item, message: "paused")
        if item.owner?.selectedProfileID == item.profileID {
            item.owner?.feedback.show(.status, icon: .pause, text: "download paused")
        }
    }
    func cancel(_ item: DownloadItem) {
        if item.download != nil {
            stop(item, message: "cancelled")
        } else {
            item.error = "cancelled"
            item.resumeData = nil
            item.starting = false
            discardTransfer(item)
            persist()
        }
    }
    private func stop(_ item: DownloadItem, message: String) {
        guard item.download != nil else { return }
        item.endTransfer()
        item.error = message
        if queues[item.windowID]?.first?.item === item {
            if let alert = permissionAlerts[item.windowID], let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            }
            panels[item.windowID]?.cancel(nil)
        }
        item.download?.cancel { [weak self, weak item] data in
            guard let self, let item else { return }
            item.download = nil
            item.sourceWebView = nil
            item.resumeData = message == "paused" ? data : nil
            if item.resumeData == nil { self.discardTransfer(item) }
            if item.privateMode && !self.items.contains(where: { $0.id == item.id }) {
                item.resumeData = nil
                if let transfer = item.transfer { try? FileManager.default.removeItem(at: transfer) }
            }
            self.persist()
        }
        item.observation = nil
        persist()
    }
    func resume(_ item: DownloadItem, in window: BrowserWindowState) {
        guard !item.active, let data = item.resumeData, item.profileID == window.selectedProfileID,
            let web = window.selectedTab?.webView
        else { return }
        item.owner = window
        guard permission(for: item) != false else {
            item.error = "blocked by website settings"
            persist()
            return
        }
        item.windowID = window.id
        item.error = nil
        item.starting = true
        item.resumeData = nil
        item.sourceWebView = web
        web.resumeDownload(fromResumeData: data) { [weak self, weak item] download in
            guard let self, let item else { return }
            guard item.starting else {
                download.cancel { _ in }
                return
            }
            self.observe(item, download)
            self.persist()
        }
    }
    func restart(_ item: DownloadItem, in window: BrowserWindowState) {
        guard item.canRestart, item.profileID == window.selectedProfileID,
            let url = item.sourceURL, let web = window.selectedTab?.webView
        else { return }
        item.owner = window
        guard permission(for: item) != false else { return }
        discardTransfer(item)
        item.windowID = window.id
        item.error = nil
        item.starting = true
        item.fraction = 0
        item.resetTransferStatistics()
        item.resumeData = nil
        item.transferComplete = false
        item.sourceWebView = web
        web.startDownload(using: URLRequest(url: url)) { [weak self, weak item] download in
            guard let self, let item else { return }
            guard item.starting else {
                download.cancel { _ in }
                return
            }
            self.observe(item, download)
            self.persist()
        }
    }
    private func discardReservedDestination(_ item: DownloadItem) {
        guard item.reservedDestination, let destination = item.destination else { return }
        var stale = false
        let scoped =
            item.bookmark.flatMap {
                try? URL(
                    resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale
                )
            } ?? destination
        let access = scoped.startAccessingSecurityScopedResource()
        defer { if access { scoped.stopAccessingSecurityScopedResource() } }
        if (try? scoped.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            try? FileManager.default.removeItem(at: scoped)
        }
        item.reservedDestination = false
    }
    private func discardTransfer(_ item: DownloadItem) {
        discardReservedDestination(item)
        if let transfer = item.transfer { try? FileManager.default.removeItem(at: transfer) }
        item.transfer = nil
        item.transferComplete = false
    }
    func remove(_ item: DownloadItem) {
        guard !item.active else { return }
        discardTransfer(item)
        items.removeAll { $0.id == item.id }
        persist()
    }
    func cleanupCache(olderThanDays days: Int, now: Date = Date()) {
        guard let folder = transferFolder else { return }
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        for item in items
        where !item.active && item.download == nil && item.resumeData == nil && !item.canRetrySave {
            discardTransfer(item)
        }
        let retained = Set(
            items.filter {
                $0.download != nil || $0.active
                    || (days == 0 || $0.date > cutoff) && ($0.resumeData != nil || $0.canRetrySave)
            }
            .compactMap { $0.transfer?.resolvingSymlinksInPath().path })
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            if !retained.contains(url.resolvingSymlinksInPath().path) { try? FileManager.default.removeItem(at: url) }
        }
        for item in items
        where !item.active && days > 0 && item.date <= cutoff && (item.transfer != nil || item.resumeData != nil) {
            discardTransfer(item)
            item.resumeData = nil
            if !item.finished { item.error = "cached transfer expired" }
        }
        persist()
    }
    private func updateDockProgress() {
        let active = items.filter(\.active)
        let time = ProcessInfo.processInfo.systemUptime
        for item in active { item.refreshTransferStatistics(at: time) }
        progress.update(active)
        guard let dock = NSApp?.dockTile else { return }
        guard !active.isEmpty else {
            dockTimer?.invalidate()
            dockTimer = nil
            if let dockView, dock.contentView === dockView {
                dock.contentView = nil
                dock.badgeLabel = nil
                dock.display()
            }
            self.dockView = nil
            return
        }
        let view = dockView ?? DownloadDockProgress(frame: NSRect(origin: .zero, size: dock.size))
        dockView = view
        dock.contentView = view
        let summary = DownloadProgressSummary(items: active)
        view.indeterminate = summary.indeterminate
        view.fraction = summary.fraction
        view.needsDisplay = true
        dock.badgeLabel = active.count > 1 ? String(active.count) : nil
        dock.display()
        if dockTimer == nil {
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDockProgress() }
            }
        }
    }
    func prepareToQuit() async {
        for item in items where item.starting && item.download == nil {
            item.starting = false
            item.error = "paused"
            discardTransfer(item)
        }
        for item in items where item.download != nil {
            guard let download = item.download else { continue }
            item.endTransfer()
            item.error = "paused"
            item.observation = nil
            let data: Data? = await withCheckedContinuation { continuation in
                download.cancel { continuation.resume(returning: $0) }
            }
            item.resumeData = item.privateMode ? nil : data
            if item.resumeData == nil { discardTransfer(item) }
            item.download = nil
            item.sourceWebView = nil
        }
        persist()
    }
    func closeWindow(_ id: UUID) {
        if let alert = permissionAlerts.removeValue(forKey: id), let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        if let panel = panels[id] { panel.cancel(nil) }
        let start = panels[id] == nil ? 0 : 1
        for request in (queues[id] ?? []).dropFirst(start) { request.completion(nil) }
        if start == 1 { queues[id] = Array((queues[id] ?? []).prefix(1)) } else { queues[id] = [] }
        if start == 0 { choosing.remove(id) }
    }
    func clear(profileID: UUID, since date: Date) {
        for item in items where item.profileID == profileID && item.date >= date && !item.active {
            discardTransfer(item)
        }
        items.removeAll { $0.profileID == profileID && $0.date >= date && !($0.active) }
        persist()
    }
    func forgetPrivate(_ id: UUID) {
        for item in items where item.profileID == id {

            item.privateMode = true
            cancel(item)
            if item.download == nil, let transfer = item.transfer { try? FileManager.default.removeItem(at: transfer) }
        }
        for windowID in Array(queues.keys) {
            let requests = queues[windowID] ?? []
            if requests.first?.item.profileID == id,
                let alert = permissionAlerts.removeValue(forKey: windowID), let parent = alert.window.sheetParent
            {
                parent.endSheet(alert.window, returnCode: .abort)
            }
            if requests.first?.item.profileID == id { panels[windowID]?.cancel(nil) }
            queues[windowID] = requests.enumerated().filter { index, request in
                if request.item.profileID != id || (index == 0 && panels[windowID] != nil) { return true }
                request.completion(nil)
                return false
            }.map(\.element)
            if requests.first?.item.profileID == id, panels[windowID] == nil {
                choosing.remove(windowID)
                DispatchQueue.main.async { [weak self] in self?.presentNext(windowID) }
            }
        }
        items.removeAll { $0.profileID == id }
    }
    func forgetProfile(_ id: UUID) {
        forgetPrivate(id)
        persist()
    }
}

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
    var transfer: URL?
    var bookmark: Data?
    var transferComplete = false
    @Published var name = "preparing download…"
    @Published var destination: URL?
    @Published var finished = false
    @Published var error: String?
    @Published var fraction = 0.0
    @Published var resumeData: Data?
    var observation: NSKeyValueObservation?
    init(_ download: WKDownload, owner: BrowserWindowState, profileID: UUID) {
        id = UUID()
        date = Date()
        self.download = download
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
        error = record.finished ? record.error : record.error ?? "interrupted"
        resumeData = record.resumeData
        transfer = record.transfer.map { URL(fileURLWithPath: $0) }
        bookmark = record.bookmark
    }
    var canRetrySave: Bool {
        download == nil && fraction == 1 && !finished
            && transfer.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    var record: DownloadRecord {
        DownloadRecord(
            id: id, profileID: profileID, windowID: windowID, name: name, date: date, destination: destination?.path,
            finished: finished, error: error, resumeData: resumeData, transfer: transfer?.path, bookmark: bookmark,
            transferComplete: transferComplete, downloadOrigin: downloadOrigin)
    }
}

@MainActor final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    private var dockView: DownloadDockProgress?
    private var dockTimer: Timer?
    var hasActiveDownloads: Bool { items.contains { $0.download != nil && $0.error == nil } }
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
        items.insert(item, at: 0)
        observe(item, download)
        updateDockProgress()
        persist()
    }
    private func observe(_ item: DownloadItem, _ download: WKDownload) {
        download.delegate = self
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self, weak item] progress, _ in
            Task { @MainActor [weak self, weak item] in
                item?.fraction = progress.fractionCompleted
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
            request.completion(transfer)
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
            request.item.bookmark = try? destination.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let transfer = folder.appendingPathComponent(request.item.id.uuidString)
            request.item.transfer = transfer
            request.completion(transfer)
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
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.download === download }) else { return }
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
            let destination =
                item.bookmark.flatMap {
                    try? URL(
                        resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil,
                        bookmarkDataIsStale: &stale)
                } ?? item.destination
            guard let destination, let transfer = item.transfer else { throw CocoaError(.fileWriteUnknown) }
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            try Self.completeTransfer(from: transfer, to: destination)
            item.destination = destination
            item.finished = true
            item.error = nil
            item.transfer = nil
            item.bookmark = nil
        } catch { item.error = "transfer complete, save failed: " + error.localizedDescription }
        persist()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let item = items.first { $0.download === download }
        if !["paused", "cancelled", "blocked by website settings"].contains(item?.error ?? "") {
            item?.error = error.localizedDescription
        }
        item?.observation = nil
        item?.download = nil
        item?.resumeData = item?.error == "blocked by website settings" ? nil : resumeData
        item?.sourceWebView = nil
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
        item.error = nil
        queues[item.windowID, default: []].append(
            DestinationRequest(item: item) { [weak self, weak item] transfer in
                guard transfer != nil, let item else { return }
                self?.saveTransferredFile(item)
            })
        presentNext(item.windowID)
    }
    func pause(_ item: DownloadItem) { stop(item, message: "paused") }
    func cancel(_ item: DownloadItem) { stop(item, message: "cancelled") }
    private func stop(_ item: DownloadItem, message: String) {
        guard item.download != nil else { return }
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
            item.resumeData = data
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
        guard let data = item.resumeData, item.profileID == window.selectedProfileID,
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
        item.sourceWebView = web
        web.resumeDownload(fromResumeData: data) { [weak self, weak item] download in
            guard let self, let item else { return }
            self.observe(item, download)
            self.persist()
        }
    }
    private func updateDockProgress() {
        let active = items.filter { $0.download != nil && $0.error == nil }
        let dock = NSApp.dockTile
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
        view.indeterminate = active.contains { ($0.download?.progress.totalUnitCount ?? -1) <= 0 }
        let total = active.reduce(0.0) { $0 + Double(max(0, $1.download?.progress.totalUnitCount ?? 0)) }
        let completed = active.reduce(0.0) { $0 + Double(max(0, $1.download?.progress.completedUnitCount ?? 0)) }
        view.fraction = total > 0 ? completed / total : active.map(\.fraction).reduce(0, +) / Double(active.count)
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
        for item in items where item.download != nil {
            guard let download = item.download else { continue }
            item.error = "paused"
            item.observation = nil
            let data: Data? = await withCheckedContinuation { continuation in
                download.cancel { continuation.resume(returning: $0) }
            }
            item.resumeData = item.privateMode ? nil : data
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
        items.removeAll { $0.profileID == profileID && $0.date >= date && $0.download == nil }
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

import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    let profileID: UUID
    weak var application: BrowserApplication?
    var store: BrowserStore? {
        application?.coordinator?.focused.flatMap { $0.selectedProfileID == profileID ? $0 : nil } ?? application?
            .windows.first { $0.selectedProfileID == profileID } ?? application?.windows.first
    }
    let controller: WKWebExtensionController
    var window: ExtensionWindow { store!.extensionWindow(for: profileID) }
    @Published var contexts: [UUID: WKWebExtensionContext] = [:]
    @Published var installing = false
    private var isDisposed = false
    private weak var actionOwner: BrowserStore?
    private var popupPanel: ExtensionPopupPanel?
    private var popupRecordID: UUID?
    private var loadRevisions: [UUID: UUID] = [:]
    private var folder: URL {
        application!.directory.appendingPathComponent("Extensions/\(profileID.uuidString)", isDirectory: true)
    }

    init(profileID: UUID, dataStore: WKWebsiteDataStore, application: BrowserApplication) {
        self.profileID = profileID
        self.application = application
        let config: WKWebExtensionController.Configuration =
            application.profiles.first { $0.id == profileID }!.privateMode
            ? .nonPersistent() : .init(identifier: profileID)
        config.defaultWebsiteDataStore = dataStore
        let web = WKWebViewConfiguration()
        web.websiteDataStore = dataStore
        config.webViewConfiguration = web
        controller = WKWebExtensionController(configuration: config)
        super.init()
        controller.delegate = self
    }

    func restore() async {
        guard !isDisposed, let store else { return }
        for record in store.profileFor(profileID).extensions where record.enabled {
            guard !isDisposed, !Task.isCancelled else { return }
            guard store.profileFor(profileID).extensions.contains(where: { $0.id == record.id && $0.enabled }) else {
                continue
            }
            do { try await load(record) } catch is CancellationError { continue } catch {
                application?.updateProfile(profileID) { profile in
                    if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) {
                        profile.extensions[index].enabled = false
                        profile.extensions[index].status = "installed · load failed · disabled"
                        profile.extensions[index].diagnostics =
                            (profile.extensions[index].diagnostics ?? []) + [error.localizedDescription]
                    }
                }
                store.error = "\(record.name) could not load: \(error.localizedDescription)"
            }
        }
    }

    func install(owner: BrowserStore? = nil) async {
        guard let store = owner ?? store, !store.profileFor(profileID).privateMode else { return }
        let panel = NSOpenPanel()
        panel.title = "choose an extension folder or CRX3 package"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard let coordinator = application?.coordinator else { return }
        let response = await withCheckedContinuation { continuation in
            coordinator.enqueueSheet(
                for: store, cancel: { continuation.resume(returning: NSApplication.ModalResponse.abort) }
            ) { done in
                guard let window = store.nativeWindow else {
                    continuation.resume(returning: .abort)
                    done()
                    return
                }
                panel.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result)
                    done()
                }
            }
        }
        guard response == .OK, let source = panel.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        installing = true
        defer { installing = false }
        do {
            if source.pathExtension.lowercased() == "crx" {
                let data = try Data(contentsOf: source)
                let verified = try CRXVerifier.verify(data)
                try await installPackage(data, verified: verified, confirm: true, owner: store)
            } else {
                try await installFolder(source, confirm: true, owner: store)
            }
        } catch { store.error = "extension installation failed: " + error.localizedDescription }
    }
    func installStore(_ input: String, owner: BrowserStore? = nil) async {
        guard !installing else { return }
        guard let store = owner ?? store, !store.profileFor(profileID).privateMode,
            let id = ChromeStore.identifier(input)
        else {
            self.store?.error = "enter a Chrome Web Store URL or a 32-character extension ID"
            return
        }
        installing = true
        defer { installing = false }
        do {
            let versionData = try await AssetRequest.data(
                URL(
                    string:
                        "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?pageSize=1"
                )!)
            guard let json = try JSONSerialization.jsonObject(with: versionData) as? [String: Any],
                let versions = json["versions"] as? [[String: Any]], let version = versions.first?["version"] as? String
            else { throw PackageError(reason: "Couldn't determine the current extension package version.") }
            let data = try await AssetRequest.data(
                ChromeStore.packageURL(id: id, version: version), limit: 50_000_000, timeout: 90)
            let verified = try CRXVerifier.verify(data, expectedID: id, requirePublisher: true)
            try await installPackage(data, verified: verified, confirm: true, owner: store)
        } catch { store.error = error.localizedDescription }
    }
    func installPackage(_ package: Data, verified: CRXVerifier.Verified, confirm: Bool, owner: BrowserStore? = nil)
        async throws
    {
        let staging = folder.appendingPathComponent("staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ExtensionArchive.extract(verified.zip, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await installFolder(staging, package: package, storeID: verified.id, confirm: confirm, owner: owner)
    }
    func installFolder(
        _ source: URL, package: Data? = nil, storeID: String? = nil, confirm: Bool, owner: BrowserStore? = nil
    ) async throws {
        guard !isDisposed, let application, let profile = application.profiles.first(where: { $0.id == profileID }),
            !profile.privateMode
        else { throw PackageError(reason: "Extensions cannot be installed in a private profile.") }
        try validateFolder(source)
        let ext = try await WKWebExtension(resourceBaseURL: source)
        guard !isDisposed else { throw CancellationError() }
        let raw = ext.manifest
        let rawPermissions = raw["permissions"] as? [String] ?? []
        let permissions = Array(
            Set(
                ext.requestedPermissions.map(\.rawValue)
                    + rawPermissions.filter { !$0.contains("://") && $0 != "<all_urls>" })
        ).sorted()
        let hosts = ext.requestedPermissionMatchPatterns.map(\.string).sorted()
        if confirm {
            let alert = NSAlert()
            alert.messageText = "install \(ext.displayName ?? "extension") in \(profile.name)?"
            alert.informativeText =
                "requested permissions: "
                + (permissions.isEmpty
                    ? "none" : permissions.map(ExtensionPermissionText.permission).joined(separator: "\n"))
                + "\n\nwebsite access:\n"
                + (hosts.isEmpty ? "none" : hosts.map(ExtensionPermissionText.website).joined(separator: "\n"))
                + "\n\nCompatibility is checked after installation. Extensions cannot launch other apps."
            alert.addButton(withTitle: "install")
            alert.addButton(withTitle: "cancel")
            guard let owner = owner ?? store, let coordinator = application.coordinator else {
                throw PackageError(reason: "No browser window is available for installation.")
            }
            let response = await withCheckedContinuation { continuation in
                coordinator.alert(alert, for: owner) { continuation.resume(returning: $0) }
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        guard !isDisposed, application.profiles.contains(where: { $0.id == profileID }) else { throw CancellationError() }
        guard storeID == nil || !profile.extensions.contains(where: { $0.storeID == storeID }) else {
            throw PackageError(reason: "This extension is already installed in this profile.")
        }
        var record = InstalledExtension(
            name: ext.displayName ?? "extension", enabled: false, permissions: permissions, hosts: hosts,
            storeID: storeID, version: raw["version"] as? String, diagnostics: ext.errors.map(\.localizedDescription),
            status: "installed · compatibility pending")
        let root = folder.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("original"))
            if let package { try package.write(to: root.appendingPathComponent("original.crx"), options: .atomic) }
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("runtime"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        do {
            record.diagnostics =
                (record.diagnostics ?? [])
                + (try ExtensionCompatibility.prepare(
                    root.appendingPathComponent("runtime"), extensionID: record.storeID))
            try await load(record)
            record.enabled = true
            record.status = "installed · compatibility unverified"
        } catch {
            record.diagnostics = (record.diagnostics ?? []) + [error.localizedDescription]
            record.status = "installed · incompatible · disabled"
        }
        guard !isDisposed else { throw CancellationError() }
        application.updateProfile(profileID) { $0.extensions.append(record) }
        application.persistSoon()
    }

    private func validateFolder(_ source: URL) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey])
        else { throw CocoaError(.fileReadUnknown) }
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            bytes += values.fileSize ?? 0
            guard bytes < 200_000_000 else { throw CocoaError(.fileReadTooLarge) }
        }
    }

    private func load(_ record: InstalledExtension) async throws {
        guard !isDisposed else { throw CancellationError() }
        guard contexts[record.id] == nil else { return }
        let revision = loadRevisions[record.id]
        let root = folder.appendingPathComponent(record.id.uuidString)
        let runtime = root.appendingPathComponent("runtime")
        if record.storeID == ExtensionCompatibility.vimiumID,
            FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path),
            !FileManager.default.fileExists(
                atPath: runtime.appendingPathComponent(ExtensionCompatibility.vimiumMarker).path)
        {
            let diagnostic = try ExtensionCompatibility.prepareVimium(
                runtime, original: root.appendingPathComponent("original"))
            application?.updateProfile(profileID) { profile in
                if let index = profile.extensions.firstIndex(where: { $0.id == record.id }),
                    !(profile.extensions[index].diagnostics ?? []).contains(diagnostic)
                {
                    profile.extensions[index].diagnostics = (profile.extensions[index].diagnostics ?? []) + [diagnostic]
                }
            }
        }
        if record.storeID == "mnjggcdmjocbbbhaepdhchncahnbgone",
            FileManager.default.fileExists(atPath: root.appendingPathComponent("original").path),
            !FileManager.default.fileExists(
                atPath: runtime.appendingPathComponent(ExtensionCompatibility.sponsorBlockMarker).path)
        {
            let diagnostic = try ExtensionCompatibility.prepareSponsorBlock(
                runtime, original: root.appendingPathComponent("original"))
            application?.updateProfile(profileID) { profile in
                if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) {
                    profile.extensions[index].diagnostics = (profile.extensions[index].diagnostics ?? []) + [diagnostic]
                }
            }
        }

        for name in ["_loaf_bridge.js"] {
            let bridge = runtime.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: bridge.path),
                (try String(contentsOf: bridge, encoding: .utf8)) != ExtensionCompatibility.script
            {
                try Data(ExtensionCompatibility.script.utf8).write(to: bridge, options: .atomic)
            }
        }
        let resourceFolder = FileManager.default.fileExists(atPath: runtime.path) ? runtime : root
        try ExtensionResourceURLs.normalize(in: resourceFolder, identifier: record.storeID ?? record.id.uuidString)
        let ext: WKWebExtension
        do {
            ext = try await WKWebExtension(
                resourceBaseURL: FileManager.default.fileExists(atPath: runtime.path) ? runtime : root)
        } catch {
            if loadRevisions[record.id] != revision { throw CancellationError() }
            throw error
        }
        guard !isDisposed, loadRevisions[record.id] == revision else { throw CancellationError() }

        guard contexts[record.id] == nil else { return }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = record.storeID ?? record.id.uuidString
        context.baseURL = URL(string: "webkit-extension://\((record.storeID ?? record.id.uuidString).lowercased())/")!
        for permission in record.permissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for host in record.hosts {
            if let pattern = try? WKWebExtension.MatchPattern(string: host) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        if FileManager.default.fileExists(atPath: runtime.path) {
            context.setPermissionStatus(.grantedExplicitly, for: .init(rawValue: "nativeMessaging"))
        }
        try controller.load(context)
        contexts[record.id] = context
        store?.objectWillChange.send()
    }
    func shutDown() {
        isDisposed = true
        popupPanel?.close()
        popupPanel = nil
        popupRecordID = nil
        actionOwner = nil
        controller.delegate = nil
        for context in contexts.values { try? controller.unload(context) }
        contexts.removeAll()
    }

    func setEnabled(_ record: InstalledExtension, _ enabled: Bool) async {
        if !enabled, popupRecordID == record.id {
            popupPanel?.close()
            popupPanel = nil
            popupRecordID = nil
        }
        guard let store else { return }
        let revision = UUID()
        loadRevisions[record.id] = revision
        do {
            if enabled {
                try await load(record)
            } else if let context = contexts[record.id] {
                try controller.unload(context)
                contexts.removeValue(forKey: record.id)
            }
            guard loadRevisions[record.id] == revision else { return }
            store.updateProfile(profileID) { p in
                if let index = p.extensions.firstIndex(where: { $0.id == record.id }) {
                    p.extensions[index].enabled = enabled
                    p.extensions[index].status =
                        enabled
                        ? ((p.extensions[index].diagnostics ?? []).contains { $0.hasPrefix("Background error: ") }
                            ? "installed · runtime errors · see diagnostics" : "installed · compatibility unverified")
                        : "installed · disabled"
                }
            }
            store.persistSoon()
        } catch {
            guard loadRevisions[record.id] == revision else { return }
            store.updateProfile(profileID) { profile in
                if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) {
                    profile.extensions[index].enabled = false
                    profile.extensions[index].status = "installed · load failed · disabled"
                    profile.extensions[index].diagnostics =
                        (profile.extensions[index].diagnostics ?? []) + [error.localizedDescription]
                }
            }
            store.error = error.localizedDescription
        }
    }

    func remove(_ record: InstalledExtension) {
        guard let store else { return }
        if popupRecordID == record.id {
            popupPanel?.close()
            popupPanel = nil
            popupRecordID = nil
        }
        loadRevisions[record.id] = UUID()
        do {
            if let context = contexts[record.id] {
                try controller.unload(context)
                contexts.removeValue(forKey: record.id)
            }

            try FileManager.default.trashItem(
                at: folder.appendingPathComponent(record.id.uuidString), resultingItemURL: nil)
            store.updateProfile(profileID) { $0.extensions.removeAll { $0.id == record.id } }
            store.persistSoon()
        } catch { store.error = error.localizedDescription }
    }

    func perform(_ record: InstalledExtension) {
        guard let context = contexts[record.id], let tab = store?.selectedTab, tab.profileID == profileID else {
            return
        }
        if popupRecordID == record.id, let panel = popupPanel, panel.isVisible, panel.parent === tab.store?.nativeWindow
        {
            panel.close()
            popupPanel = nil
            popupRecordID = nil
            return
        }
        actionOwner = tab.store
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
    }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext)
        -> [any WKWebExtensionWindow]
    {
        (application?.windows ?? []).filter { $0.workspaces[profileID] != nil }.map {
            $0.extensionWindow(for: profileID)
        }
    }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext)
        -> (any WKWebExtensionWindow)?
    {
        guard let focused = application?.coordinator?.focused, focused.selectedProfileID == profileID else {
            return nil
        }
        return focused.extensionWindow(for: profileID)
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, openNewTabUsing config: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let owner = (config.window as? ExtensionWindow)?.store ?? store
        let tab = owner?.newTab(
            url: config.url, profileID: profileID, showOmnibar: false, activate: config.shouldBeActive)
        tab?.pinned = config.shouldBePinned
        if let tab, let owner {
            owner.updateProfile(profileID) { profile in
                guard let current = profile.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                let saved = profile.tabs.remove(at: current)
                let requested = config.index == NSNotFound ? profile.tabs.count : min(config.index, profile.tabs.count)
                profile.tabs.insert(saved, at: max(0, requested))
            }
            owner.tabChanged(tab)
        }
        completionHandler(tab, nil)
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing config: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        guard !config.shouldBePrivate,
            let owner = application?.coordinator?.newWindow(profileID: profileID, url: config.tabURLs.first)
        else {
            completionHandler(
                nil,
                NSError(
                    domain: "loaf", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "A private window cannot share this extension's profile."]))
            return
        }
        for url in config.tabURLs.dropFirst() { _ = owner.newTab(url: url, showOmnibar: false) }
        completionHandler(owner.extensionWindow(for: profileID), nil)
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let url = context.optionsPageURL {
            _ = store?.newTab(
                url: url, profileID: profileID, showOmnibar: false, configuration: context.webViewConfiguration)
        }
        completionHandler(nil)
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        approve(
            context, tab: tab,
            details: permissions.map(\.rawValue).sorted().map(ExtensionPermissionText.permission).joined(
                separator: "\n")
        ) { completionHandler($0 ? permissions : [], nil) }
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        approve(context, tab: tab, details: urls.map(\.absoluteString).sorted().joined(separator: "\n")) {
            completionHandler($0 ? urls : [], nil)
        }
    }
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        approve(context, tab: tab, details: patterns.map(\.string).sorted().joined(separator: "\n")) {
            completionHandler($0 ? patterns : [], nil)
        }
    }
    private func approve(
        _ context: WKWebExtensionContext, tab: (any WKWebExtensionTab)?, details: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let owner = (tab as? BrowserTab)?.store ?? actionOwner ?? store,
            let coordinator = application?.coordinator
        else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "allow \(context.webExtension.displayName ?? "extension") access?"
        alert.informativeText = details
        alert.addButton(withTitle: "allow")
        alert.addButton(withTitle: "deny")
        coordinator.alert(alert, for: owner) { completion($0 == .alertFirstButtonReturn) }
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier identifier: String?, for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        func deny(_ reason: String) { replyHandler(nil, PackageError(reason: reason)) }
        guard identifier == ExtensionCompatibility.host,
            let installed = contexts.first(where: { $0.value === context }),
            let record = application?.profiles.first(where: { $0.id == profileID })?.extensions.first(where: {
                $0.id == installed.key
            }),
            let message = message as? [String: Any], let operation = message["operation"] as? String
        else {
            deny("loaf does not allow arbitrary native messaging hosts")
            return
        }
        switch operation {
        case "runtime.reportError":
            guard let args = message["args"] as? [String: Any], let raw = args["message"] as? String,
                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                deny("Missing background error message")
                return
            }
            let diagnostic = "Background error: " + String(raw.prefix(512))
            let errors = (record.diagnostics ?? []).filter { $0.hasPrefix("Background error: ") }
            if !errors.contains(diagnostic), errors.count < 5 {
                application?.updateProfile(profileID) { profile in
                    if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) {
                        profile.extensions[index].diagnostics =
                            (profile.extensions[index].diagnostics ?? []) + [diagnostic]
                        profile.extensions[index].status = "installed · runtime errors · see diagnostics"
                    }
                }
                application?.persistSoon()
            }
            replyHandler(["value": true], nil)
        case "runtime.getBrowserInfo":
            replyHandler(
                [
                    "value": [
                        "name": "loaf", "vendor": "Owen",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                        "buildID": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                    ]
                ], nil)
        case "runtime.getPlatformInfo":
            #if arch(arm64)
                let architecture = "arm"
            #else
                let architecture = "x86-64"
            #endif
            replyHandler(["value": ["os": "mac", "arch": architecture, "nacl_arch": architecture]], nil)
        case "theme.getCurrent":
            guard record.permissions.contains("theme") else {
                deny("theme permission was not granted")
                return
            }
            replyHandler(
                [
                    "value": [
                        "colors": ExtensionTheme.colors,
                        "properties": ["color_scheme": LoafAppearance.shared.systemScheme == .dark ? "dark" : "light"],
                    ]
                ], nil)
        case "fontSettings.getFontList":
            guard record.permissions.contains("fontSettings") else {
                deny("fontSettings permission was not granted")
                return
            }
            let list = NSFontManager.shared.availableFonts.sorted().map { name in
                ["fontId": name, "displayName": NSFont(name: name, size: 12)?.displayName ?? name]
            }
            replyHandler(["value": list], nil)
        default: deny("unsupported extension API: " + operation.replacingOccurrences(of: "unsupported.", with: ""))
        }
    }
    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        guard let web = action.popupWebView, let owner = (actionOwner ?? store)?.nativeWindow else {
            completionHandler(PackageError(reason: "No active browser window."))
            return
        }
        popupPanel?.close()
        let panel = ExtensionPopupPanel(action: action, title: context.webExtension.displayName ?? "extension")
        panel.followSystemTheme(webView: web)
        if let controller = action.popupPopover?.contentViewController {
            panel.install(controller: controller)
        } else {
            panel.contentView = web
        }
        owner.addChildWindow(panel, ordered: .above)
        let visible = owner.screen?.visibleFrame ?? owner.frame
        let requested = panel.contentViewController?.preferredContentSize ?? web.bounds.size
        let size = panel.boundedSize(requested)
        panel.setFrame(
            SitePanelPlacement.frame(
                anchor: CGRect(x: owner.frame.minX + 16, y: owner.frame.maxY - 48, width: 1, height: 1),
                visible: visible, size: size), display: true)
        popupPanel = panel
        popupRecordID = contexts.first { $0.value === context }?.key
        panel.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

@MainActor final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let profileID: UUID
    weak var store: BrowserStore?
    init(profileID: UUID, store: BrowserStore) {
        self.profileID = profileID
        self.store = store
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store else { return [] }
        let runtime = store.runtime(for: profileID)
        return store.profileFor(profileID).tabs.compactMap { runtime.tabs[$0.id] }
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store, let id = store.profileFor(profileID).selectedTab else { return nil }
        return store.runtime(for: profileID).tabs[id]
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { store?.profileFor(profileID).privateMode ?? false }
}

extension ExtensionWindow {
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = store?.nativeWindow else { return .normal }
        return window.styleMask.contains(.fullScreen)
            ? .fullscreen : window.isMiniaturized ? .minimized : window.isZoomed ? .maximized : .normal
    }
    func setWindowState(
        _ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let window = store?.nativeWindow else {
            completionHandler(PackageError(reason: "window is closed"))
            return
        }
        if state == .fullscreen {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        } else {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            if state == .minimized {
                window.miniaturize(nil)
            } else {
                window.deminiaturize(nil)
                if (state == .maximized) != window.isZoomed { window.zoom(nil) }
            }
        }
        completionHandler(nil)
    }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { store?.nativeWindow?.screen?.frame ?? .zero }
    func frame(for context: WKWebExtensionContext) -> CGRect { store?.nativeWindow?.frame ?? .zero }
    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = store?.nativeWindow,
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        else {
            completionHandler(PackageError(reason: "invalid window frame"))
            return
        }
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let store else {
            completionHandler(PackageError(reason: "window is closed"))
            return
        }
        store.switchProfile(profileID)
        store.nativeWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = store?.nativeWindow else {
            completionHandler(PackageError(reason: "window is closed"))
            return
        }
        window.performClose(nil)
        completionHandler(nil)
    }
}

nonisolated enum ExtensionPermissionText {
    static func permission(_ value: String) -> String {
        let descriptions = [
            "storage": "save extension settings and data",
            "unlimitedStorage": "store extension data without a size limit",
            "tabs": "read open tab titles and addresses",
            "activeTab": "access the current tab when you use the extension",
            "tabCapture": "capture audio and video from a tab",
            "desktopCapture": "capture screen content with your permission",
            "scripting": "run scripts on permitted websites",
            "cookies": "read and change cookies on permitted websites",
            "history": "read and change browsing history", "bookmarks": "read and change bookmarks",
            "downloads": "start and manage downloads", "notifications": "show notifications",
            "clipboardRead": "read your clipboard",
            "clipboardWrite": "write to your clipboard", "webRequest": "observe requests on permitted websites",
            "webRequestBlocking": "block or change requests on permitted websites",
            "declarativeNetRequest": "filter network requests",
            "declarativeNetRequestWithHostAccess": "filter requests on permitted websites",
            "declarativeNetRequestFeedback": "read request-filtering activity",
            "contextMenus": "add items to website menus", "menus": "add items to website menus",
            "alarms": "schedule extension tasks",
            "fontSettings": "read and change font preferences", "privacy": "read and change privacy preferences",
            "nativeMessaging": "communicate with another app (not supported)", "geolocation": "request your location",
            "management": "read installed extensions", "offscreen": "run an extension page in the background",
            "idle": "detect idle activity",
            "webNavigation": "observe page navigation", "identity": "connect an extension account",
            "sidePanel": "show an extension side panel",
        ]
        return descriptions[value]
            ?? value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
    }
    static func website(_ pattern: String) -> String {
        if pattern == "<all_urls>" || pattern == "*://*/*" { return "read and change data on all websites" }
        return "read and change data on "
            + pattern.replacingOccurrences(of: "*://", with: "").replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "/*", with: "")
    }
}

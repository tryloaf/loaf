import AppKit
import Combine
import WebKit

struct MediaSource: Identifiable {
    let id: String
    let elementID: String
    let frameID: String
    let frame: WKFrameInfo
    var title: String
    var artist: String
    var paused: Bool
    var muted: Bool
    var volume: Double
    var position: Double
    var duration: Double
    var supportsAirPlay = false
    var pictureInPicture = false
    var firstSeen = Date()
    var updated = Date()
    func samePresentation(as other: MediaSource) -> Bool {
        id == other.id && title == other.title && artist == other.artist && paused == other.paused
            && muted == other.muted && volume == other.volume && position == other.position
            && duration == other.duration && pictureInPicture == other.pictureInPicture
            && supportsAirPlay == other.supportsAirPlay
    }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, WKWebExtensionTab
{
    let id: UUID
    let profileID: UUID
    let windowID: UUID
    weak var store: BrowserStore?
    let passwordSuggestions = PasswordSuggestionState()
    private(set) var existingWebView: WKWebView?
    weak var webViewHost: WebViewHost.HostView?

    private weak var disposedWebView: WKWebView?
    private var pendingConfiguration: WKWebViewConfiguration?
    private(set) var isDisposed = false
    private var requestedURL: URL?
    private var activeNavigation: WKNavigation?
    var lastActivated = Date()
    var sleepState: Any?
    var sleepScrollPosition: CGPoint?
    var sleepRestoreURL: URL?
    var restoringFromSleep = false
    var sleepEligibleNavigation = false
    @Published var sleeping = false

    var webView: WKWebView {
        if isDisposed {

            guard let disposedWebView else { preconditionFailure("A closed lazy tab has no web view") }
            return disposedWebView
        }
        if let existingWebView { return existingWebView }
        return makeWebView()
    }
    let finder = WebKitAdapter.FindController()
    @Published var title: String
    @Published var url: URL?
    @Published var page: BrowserPage
    private(set) var existingChatGPTSearch: ChatGPTSearch?
    var chatGPTSearch: ChatGPTSearch {
        if let existingChatGPTSearch { return existingChatGPTSearch }
        guard let store, !isDisposed else { preconditionFailure("Cannot create a search for a closed tab") }
        let search = ChatGPTSearch(
            account: store.application.chatGPTAccount,
            provider: { [weak store] in store?.preferences.aiProvider ?? .chatgpt },
            enabled: { [weak store] in store.map { $0.preferences.aiFeaturesEnabled != false } ?? false })
        existingChatGPTSearch = search
        return search
    }
    @Published var pinned: Bool
    @Published var pinnedTitle: String?
    @Published var pinnedIcon: String?
    @Published var pinPresentation: String?
    var pinnedAddress: String?
    var pinnedShortcutID: UUID?
    @Published var customIcon: String?
    @Published var customTitle: String?
    var groupID: UUID?
    var groupMemberID: UUID?
    var sidebarTitle: String { pinned ? pinnedTitle ?? customTitle ?? title : customTitle ?? title }
    @Published var loading = false
    @Published var fullscreenState: WKWebView.FullscreenState = .notInFullscreen
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var secure = false
    @Published var favicon: NSImage?
    @Published private(set) var hoveredLink: String?
    private var hoveredLinkFrame: String?
    @Published var chromePrefersDark: Bool?
    @Published var chromeColor: NSColor?
    @Published var navigationError: String?
    @Published var readerArticle: String?
    @Published var readerDocument: ReaderDocument?
    weak var readerWebView: WKWebView?
    var visibleWebView: WKWebView? { readerDocument != nil ? readerWebView : existingWebView }
    @Published var media: [MediaSource] = []
    private var mediaFramesSeen: [String: Date] = [:]
    @Published var dismissedMedia = Set<String>()
    var navigationID = UUID()
    var pointerCapturePosition = PointerCapturePosition()
    var pointerCaptureFrame: WKFrameInfo?
    func restoreCapturedCursor(confirmed: Bool = false) {
        pointerCaptureFrame = nil
        guard let point = pointerCapturePosition.release(confirmed: confirmed) else { return }

        DispatchQueue.main.async { CGWarpMouseCursorPosition(point) }
    }
    struct PendingLoginUsername {
        let origin: String
        let username: String
        let date: Date
    }
    var pendingLoginUsername: PendingLoginUsername?
    var approvedPasswordFill: (origin: String, username: String, date: Date)?
    var automaticPasswordTarget: String?
    func hasPasswordApproval(origin: String, username: String) -> Bool {
        guard let approval = approvedPasswordFill else { return false }
        return approval.origin == origin && approval.username == username
            && Date().timeIntervalSince(approval.date) < 300
    }
    func loginUsername(for origin: String) -> String? {
        guard let pending = pendingLoginUsername, pending.origin == origin, Date().timeIntervalSince(pending.date) < 300
        else { return nil }
        return pending.username
    }
    private var observations: [NSKeyValueObservation] = []
    private var chromeColorObservation: ChromeColorObservation?
    var loaded = false
    var defaultUserAgent: String?
    private var appliedRules: [WKContentRuleList] = []
    private var extensionThemeObservation: AnyCancellable?
    private var faviconTask: Task<Void, Never>?
    private var faviconOrigin: String?
    private var faviconLinks: [URL] = []
    var saved: SavedTab {
        SavedTab(
            id: id, title: title, address: url?.user == nil ? url?.absoluteString : nil, pinned: pinned, page: page,
            pinnedTitle: pinnedTitle, pinnedIcon: pinnedIcon, pinPresentation: pinPresentation,
            pinnedAddress: pinnedAddress.flatMap { address in
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.user == nil else {
                    return nil
                }
                return url.absoluteString
            }, pinnedShortcutID: pinnedShortcutID, customTitle: customTitle, groupID: groupID,
            groupMemberID: groupMemberID, customIcon: customIcon)
    }
    var isEmptyNewTab: Bool {
        page == .web && url == nil && existingWebView?.url == nil && !loading && navigationError == nil
    }
    var visibleMedia: [MediaSource] {
        media.filter {
            !dismissedMedia.contains($0.id) && Date().timeIntervalSince(mediaFramesSeen[$0.frameID] ?? $0.updated) < 8
        }
    }

    init(saved: SavedTab, profileID: UUID, store: BrowserStore, configuration: WKWebViewConfiguration? = nil) {
        id = saved.id
        self.profileID = profileID
        self.store = store
        windowID = store.id
        title = saved.title == "New Tab" && saved.address == nil && saved.page == .web ? "new tab" : saved.title
        url = saved.address.flatMap(URL.init(string:))
        page = saved.page
        pinned = saved.pinned
        pinnedTitle = saved.pinnedTitle
        pinnedIcon = saved.pinnedIcon
        pinPresentation = saved.pinPresentation
        customIcon = saved.customIcon
        pinnedAddress = saved.pinnedAddress ?? (saved.pinned ? saved.address : nil)
        pinnedShortcutID = saved.pinnedShortcutID
        customTitle = saved.customTitle
        groupID = saved.groupID
        groupMemberID = saved.groupMemberID
        pendingConfiguration = configuration
        super.init()
        if page == .web, let url { prepareFavicon(for: url) }
    }

    private func makeWebView() -> WKWebView {
        guard let store else { preconditionFailure("Cannot create a page for a disposed tab") }
        let config = pendingConfiguration ?? WKWebViewConfiguration()
        pendingConfiguration = nil
        config.userContentController = WKUserContentController()
        config.websiteDataStore = store.runtime(for: profileID).dataStore
        config.webExtensionController = store.runtime(for: profileID).extensions.controller
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.preferences.isElementFullscreenEnabled = true
        WebKitAdapter.enablePictureInPicture(config.preferences)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.upgradeKnownHostsToHTTPS = true

        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(
            WKUserScript(
                source: SiteShortcutBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .defaultClient))
        config.userContentController.addUserScript(
            WKUserScript(
                source: NotificationScriptHandler.script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .page))
        config.userContentController.addScriptMessageHandler(
            NotificationScriptHandler(self), contentWorld: .page, name: "loafNotification")
        config.userContentController.addUserScript(
            WKUserScript(
                source: StorePageIntegration.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                in: .defaultClient))
        config.userContentController.addUserScript(
            WKUserScript(
                source: PageScripts.linkPreview, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .defaultClient))
        config.userContentController.addUserScript(
            WKUserScript(
                source: PageScripts.favicon, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .defaultClient))
        config.userContentController.addUserScript(
            WKUserScript(
                source: PageScripts.media, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        if !store.profileFor(profileID).privateMode
            && (store.preferences.savePasswords || store.preferences.autofillPasswords != false)
        {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: PageScripts.passwordCapture, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                    in: PageScripts.passwordWorld))
        }
        let webView = LoafWebView(frame: .zero, configuration: config)
        if url?.scheme?.hasSuffix("-extension") == true { extensionThemeObservation = ExtensionTheme.bind(webView) }
        webView.browserTab = self
        existingWebView = webView
        finder.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        WebKitAdapter.setInspectionEnabled(webView, store.preferences.developerMenu == true)
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "loafLinkPreview")
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "loafFavicon")
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "loafMedia")
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "loafStore")
        config.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "loafShortcut")
        config.userContentController.add(
            WeakScriptHandler(self), contentWorld: PageScripts.passwordWorld, name: "loafPassword")
        updateBlocker()
        observe()
        return webView
    }

    private func observe() {
        chromeColorObservation = ChromeColorObservation(webView: webView) { [weak self] in self?.refreshChromeContrast()
        }
        observations = [
            webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.refreshChromeContrast()
                }
            },
            webView.observe(\.fullscreenState, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.fullscreenState = view.fullscreenState
                    if view.fullscreenState == .notInFullscreen {
                        (view.superview as? WebViewHost.HostView)?.restoreAfterFullscreen()
                    }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view, self.page == .web else { return }
                    if let title = view.title, !title.isEmpty { self.title = title }
                    self.store?.tabChanged(self)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view, self.page == .web, self.requestedURL == nil,
                        let committedURL = view.url
                    else { return }
                    self.url = committedURL
                    self.store?.tabChanged(self)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.loading = view.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.progress = view.estimatedProgress
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.canGoBack = view.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.canGoForward = view.canGoForward
                }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.existingWebView === view else { return }
                    self.secure = view.hasOnlySecureContent
                }
            },
        ]
    }
    private func refreshChromeContrast() {
        guard let view = existingWebView else { return }
        let sample = ChromePalette.meaningfulColor(WebKitAdapter.topChromeColor(view))
        let next = ChromePalette.prefersDark(on: sample)
        if chromeColor != sample { chromeColor = sample }
        if chromePrefersDark != next { chromePrefersDark = next }
    }

    func ensureLoaded() {
        guard !isDisposed else { return }
        lastActivated = Date()
        if sleeping, page == .web, let state = sleepState {
            sleeping = false
            sleepState = nil
            loaded = true
            restoringFromSleep = true
            let view = webView
            if let url { applySiteSettings(url) }
            view.interactionState = state
        } else if !loaded, page == .web, let url {
            load(url)
        }
    }
    func load(_ url: URL) {
        guard !isDisposed, ["https", "http", "webkit-extension"].contains(url.scheme) else { return }
        existingChatGPTSearch?.clear()
        existingChatGPTSearch = nil
        navigationID = UUID()
        clearHoveredLink()
        prepareFavicon(for: url, fetch: true)
        if store?.selectedTab?.id == id || store?.passwordFillOffer?.tabID == id { store?.cancelPasswordFill() }
        loaded = true
        sleeping = false
        sleepState = nil
        sleepScrollPosition = nil
        sleepRestoreURL = nil
        restoringFromSleep = false
        if readerDocument != nil { exitReader() }
        page = .web
        self.url = url
        title = url.host ?? "new tab"
        navigationError = nil
        readerArticle = nil
        readerDocument = nil
        let view = webView
        requestedURL = url
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: nil)
        media = []
        mediaFramesSeen = [:]
        dismissedMedia = []
        applySiteSettings(url)
        activeNavigation = view.load(URLRequest(url: url))
        store?.tabChanged(self)
    }
    func reload() {
        guard !isDisposed, page == .web else { return }
        if let requestedURL {
            load(requestedURL)
        } else if !loaded || navigationError != nil, let url {
            load(url)
        } else {
            existingWebView?.reload()
        }
    }

    func applySiteSettings(_ url: URL) {
        guard let store, let webView = existingWebView, let origin = BrowserAddress.websiteOrigin(url) else { return }
        let settings =
            store.profileFor(profileID).siteSettings?[origin]
            ?? SiteSettings(
                userAgent: store.preferences.userAgentMode ?? .automatic,
                customUserAgent: store.preferences.customUserAgent)
        if webView.pageZoom != settings.zoom { webView.pageZoom = settings.zoom }
        let userAgent = DesktopIdentity.userAgent(
            mode: settings.userAgent,
            defaultUA: defaultUserAgent
                ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            custom: settings.customUserAgent)
        if webView.customUserAgent != userAgent { webView.customUserAgent = userAgent }
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let settings = navigationAction.request.url.flatMap(BrowserAddress.websiteOrigin).flatMap {
            store?.profileFor(profileID).siteSettings?[$0]
        }
        preferences.allowsContentJavaScript = settings?.javascript ?? true
        WebKitAdapter.setSiteAutoplay(preferences, allowed: settings?.autoplay == true)
        WebKitAdapter.setSitePopups(preferences, allowed: settings?.automaticPopups == true)
        self.webView(webView, decidePolicyFor: navigationAction) { decisionHandler($0, preferences) }
    }
    func updateBlocker() {
        guard let store, let webView = existingWebView else { return }
        let controller = webView.configuration.userContentController
        let profile = store.profileFor(profileID)
        let rules =
            profile.blockerEnabled && !(url?.host.map { profile.allowedSites.contains($0) } ?? false)
            ? store.blocker.ruleLists : []

        appliedRules.filter { previous in !rules.contains { $0 === previous } }.forEach { controller.remove($0) }
        rules.filter { next in !appliedRules.contains { $0 === next } }.forEach { controller.add($0) }
        appliedRules = rules
    }

    func updatePasswordCapture() {
        guard let store, let webView = existingWebView else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(
                source: SiteShortcutBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .defaultClient))
        controller.addUserScript(
            WKUserScript(
                source: NotificationScriptHandler.script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .page))
        controller.addUserScript(
            WKUserScript(
                source: StorePageIntegration.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                in: .defaultClient))
        controller.addUserScript(
            WKUserScript(
                source: PageScripts.linkPreview, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .defaultClient))
        controller.addUserScript(
            WKUserScript(
                source: PageScripts.favicon, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .defaultClient))
        controller.addUserScript(
            WKUserScript(
                source: PageScripts.media, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        if (store.preferences.savePasswords || store.preferences.autofillPasswords != false)
            && !store.profileFor(profileID).privateMode
        {
            controller.addUserScript(
                WKUserScript(
                    source: PageScripts.passwordCapture, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                    in: PageScripts.passwordWorld))
        }

    }

    func dispose() {
        guard !isDisposed else { return }
        existingChatGPTSearch?.clear()
        existingChatGPTSearch = nil
        isDisposed = true
        store?.sidebarMedia.remove(id)
        if store?.selectedTab?.id == id || store?.passwordFillOffer?.tabID == id { store?.cancelPasswordFill() }
        disposedWebView = existingWebView
        exitReader()
        store?.application.tabPreviews.remove(id)
        restoreCapturedCursor()
        if store?.pointerLockOffer?.tabID == id { store?.cancelPointerLock() }
        pendingLoginUsername = nil
        finder.reset(clearQuery: true)
        faviconTask?.cancel()
        observations.removeAll()
        chromeColorObservation?.invalidate()
        chromeColorObservation = nil
        pendingConfiguration = nil
        sleepState = nil
        sleepScrollPosition = nil
        releaseWebView()
    }

    func releaseWebView() {
        clearHoveredLink()
        faviconTask?.cancel()
        observations.removeAll()
        chromeColorObservation?.invalidate()
        chromeColorObservation = nil
        guard let webView = existingWebView else { return }
        existingWebView = nil
        extensionThemeObservation = nil
        activeNavigation = nil
        requestedURL = nil
        WebKitAdapter.closeInspector(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafLinkPreview", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafFavicon", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafMedia", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafStore", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafShortcut", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafNotification", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "loafPassword", contentWorld: PageScripts.passwordWorld)
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        media.removeAll()
        finder.webView = nil
        webView.removeFromSuperview()

        let close = NSSelectorFromString("_close")
        if webView.responds(to: close) { webView.perform(close) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard existingWebView === webView, page == .web else {
            decisionHandler(.cancel)
            return
        }
        guard let target = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = target.scheme?.lowercased() ?? ""
        guard ["https", "http", "webkit-extension", "about", "blob"].contains(scheme) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["mailto", "tel"].contains(scheme) {
                let alert = NSAlert()
                alert.messageText = "open another app?"
                alert.informativeText = String(target.absoluteString.prefix(300))
                alert.addButton(withTitle: "open")
                alert.addButton(withTitle: "cancel")
                if let store, let coordinator = store.application.coordinator {
                    coordinator.alert(alert, for: store) {
                        if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(target) }
                    }
                }
            }
            return
        }
        if action.navigationType == .linkActivated, let destination = LinkOpenDestination.from(action.modifierFlags),
            ["http", "https"].contains(scheme), !action.shouldPerformDownload,
            (action.request.httpMethod ?? "GET") == "GET", let store
        {
            decisionHandler(.cancel)
            store.openLink(target, destination: destination, profileID: profileID, source: self)
            return
        }
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
            store?.preferences.linkTabGroups == true, !action.shouldPerformDownload,
            (action.request.httpMethod ?? "GET") == "GET", ["http", "https"].contains(scheme), let store
        {
            decisionHandler(.cancel)
            store.openLink(target, destination: .foregroundTab, profileID: profileID, source: self)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            sleepEligibleNavigation =
                (action.request.httpMethod ?? "GET") == "GET" && ["http", "https"].contains(scheme)
            if pendingLoginUsername?.origin != BrowserAddress.origin(target) { pendingLoginUsername = nil }

            if url != target { prepareFavicon(for: target, fetch: true) }
            url = target
            updateBlocker()
            applySiteSettings(target)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard existingWebView === webView, page == .web else {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(
            Self.responsePolicy(
                response.response, canShowMIMEType: response.canShowMIMEType, mainFrame: response.isForMainFrame))
    }

    nonisolated static func responsePolicy(
        _ response: URLResponse, canShowMIMEType: Bool, mainFrame: Bool
    ) -> WKNavigationResponsePolicy {
        if let http = response as? HTTPURLResponse {
            if (300..<400).contains(http.statusCode) || [204, 205].contains(http.statusCode) { return .allow }
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?
                .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
            if disposition == "attachment" { return mainFrame ? .download : .cancel }
            if http.value(forHTTPHeaderField: "Content-Type") == nil { return .allow }
        }
        guard let mime = response.mimeType, !mime.isEmpty else { return .allow }
        if canShowMIMEType || isDisplayableDocument(mime) { return .allow }
        return mainFrame ? .download : .cancel
    }

    private nonisolated static func isDisplayableDocument(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return [
            "text/html", "application/xhtml+xml", "text/plain", "application/pdf",
            "image/gif", "image/jpeg", "image/png", "image/svg+xml", "image/webp",
        ].contains(mimeType)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store.map { $0.downloads.add(download, owner: $0, profileID: profileID, source: webView) }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store.map { $0.downloads.add(download, owner: $0, profileID: profileID, source: webView) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard existingWebView === webView, page == .web else { return }
        if requestedURL != nil, let activeNavigation, let navigation, activeNavigation !== navigation { return }
        webViewHost?.invalidatePreparedResizeSnapshot()
        activeNavigation = navigation
        clearHoveredLink()
        if readerDocument != nil { exitReader() }
        restoreCapturedCursor()
        if store?.pointerLockOffer?.tabID == id { store?.cancelPointerLock() }
        mediaFramesSeen.removeAll()
        finder.reset(clearQuery: true)
        finder.webView = existingWebView
        if store?.selectedTab?.id == id || store?.passwordFillOffer?.tabID == id { store?.cancelPasswordFill() }
        navigationID = UUID()
        navigationError = nil
        readerArticle = nil
        readerDocument = nil
        media = []
        dismissedMedia = []
        faviconLinks = []
        if let url { prepareFavicon(for: url, fetch: true) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard existingWebView === webView, page == .web else { return }
        if let activeNavigation, let navigation, activeNavigation !== navigation { return }
        requestedURL = nil
        url = webView.url
        let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = pageTitle.isEmpty ? BrowserAddress.display(url) : pageTitle
        store?.tabChanged(self)
        if !restoringFromSleep { store?.visited(self) }
        if !restoringFromSleep, defaultUserAgent == nil, webView.customUserAgent == nil {
            Task { [weak self, weak webView] in
                guard let webView else { return }
                let value = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
                guard let self, self.existingWebView === webView else { return }
                self.defaultUserAgent = value
            }
        }
        loadFavicon()
        webViewHost?.prepareResizeSnapshot()
        if sleepScrollPosition == nil { restoringFromSleep = false }
        if let point = sleepScrollPosition, webView.url == sleepRestoreURL {
            sleepScrollPosition = nil
            sleepRestoreURL = nil
            restoringFromSleep = false

            let token = navigationID
            Task { [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let webView, self.existingWebView === webView, self.navigationID == token else {
                    return
                }
                _ = try? await webView.callAsyncJavaScript(
                    "window.scrollTo(x, y)", arguments: ["x": Double(point.x), "y": Double(point.y)], in: nil,
                    contentWorld: .defaultClient)
            }
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard existingWebView === webView, page == .web else { return }
        if let activeNavigation, let navigation, activeNavigation !== navigation { return }
        requestedURL = nil
        if let committed = webView.url {
            url = committed
            if faviconOrigin != BrowserAddress.websiteOrigin(committed) { prepareFavicon(for: committed, fetch: true) }
            store?.tabChanged(self)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard existingWebView === webView, page == .web else { return }
        if let activeNavigation, let navigation, activeNavigation !== navigation { return }
        handle(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard existingWebView === webView, page == .web else { return }
        loading = false
        navigationError = "This page’s web process stopped. Reload to try again."
    }
    static func isNavigationCancellation(_ error: Error) -> Bool {
        let error = error as NSError

        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code))
    }
    private func handle(_ error: Error) {
        guard !Self.isNavigationCancellation(error) else { return }
        loading = false
        navigationError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {

        guard challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "sign in to \(challenge.protectionSpace.host)"
        alert.addButton(withTitle: "sign in")
        alert.addButton(withTitle: "cancel")
        let container = NSStackView()
        container.orientation = .vertical
        let username = NSTextField()
        username.placeholderString = "Username"
        let password = NSSecureTextField()
        password.placeholderString = "Password"
        container.addArrangedSubview(username)
        container.addArrangedSubview(password)
        container.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        alert.accessoryView = container
        let token = navigationID
        presentDialog(alert) { [weak self] result in
            if result == .alertFirstButtonReturn && self?.navigationID == token {
                completionHandler(
                    .useCredential,
                    URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard action.targetFrame == nil, let store else { return nil }

        let tab = store.newTab(profileID: profileID, showOmnibar: false, configuration: configuration)
        store.joinBrowsingTrail(tab, source: self)
        tab.loaded = true
        return tab.webView
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard existingWebView === webView, page == .web else { return }
        if let store, store.isPopupWindow, store.tabs.count == 1 {
            store.nativeWindow?.performClose(nil)
        } else {
            store?.close(self)
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let dialog = SiteJavaScriptDialog(
            kind: .alert, message: message, frame: frame, privateMode: store?.profileFor(profileID).privateMode == true)
        presentSiteDialog(dialog, from: webView) { _ in completionHandler() }
    }
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let dialog = SiteJavaScriptDialog(
            kind: .confirm, message: message, frame: frame,
            privateMode: store?.profileFor(profileID).privateMode == true)
        presentSiteDialog(dialog, from: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        let dialog = SiteJavaScriptDialog(
            kind: .prompt, message: prompt, frame: frame, defaultText: defaultText,
            privateMode: store?.profileFor(profileID).privateMode == true)
        presentSiteDialog(dialog, from: webView) {
            completionHandler($0 == .alertFirstButtonReturn ? dialog.field?.stringValue : nil)
        }
    }
    private func presentSiteDialog(
        _ dialog: SiteJavaScriptDialog, from webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard let store, let coordinator = store.application.coordinator else {
            completion(.abort)
            return
        }
        let token = navigationID
        let valid = { [weak self, weak store, weak webView] in
            guard let self, let store, let webView else { return false }
            return !self.isDisposed && self.navigationID == token && self.existingWebView === webView
                && store.selectedProfileID == self.profileID && store.selectedTab?.id == self.id
        }
        coordinator.enqueueSheet(for: store, cancel: { completion(.abort) }) { done in
            guard valid(), let window = store.nativeWindow else {
                completion(.abort)
                done()
                return
            }
            var observation: AnyCancellable?
            observation = self.objectWillChange.merge(with: store.objectWillChange).sink { _ in
                DispatchQueue.main.async {
                    if !valid(), dialog.alert.window.sheetParent === window {
                        window.endSheet(dialog.alert.window, returnCode: .abort)
                    }
                }
            }
            dialog.alert.beginSheetModal(for: window) { response in
                observation?.cancel()
                observation = nil
                completion(valid() ? response : .abort)
                done()
            }
            if let field = dialog.field { dialog.alert.window.makeFirstResponder(field) }
        }
    }
    private func presentDialog(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let store, let coordinator = store.application.coordinator else {
            completion(.abort)
            return
        }
        coordinator.alert(alert, for: store, completion: completion)
    }
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let store, let coordinator = store.application.coordinator else {
            completionHandler(nil)
            return
        }
        coordinator.enqueueSheet(for: store, cancel: { completionHandler(nil) }) { done in
            guard let window = store.nativeWindow else {
                completionHandler(nil)
                done()
                return
            }
            panel.beginSheetModal(for: window) { result in
                completionHandler(result == .OK ? panel.urls : nil)
                done()
            }
        }
    }
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        let url = components.url
        let settings =
            url.flatMap(BrowserAddress.websiteOrigin).flatMap { store?.profileFor(profileID).siteSettings?[$0] }
            ?? SiteSettings()
        let decisions =
            type == .camera
            ? [settings.camera] : type == .microphone ? [settings.microphone] : [settings.camera, settings.microphone]
        decisionHandler(decisions.contains("deny") ? .deny : decisions.allSatisfy { $0 == "allow" } ? .grant : .prompt)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let liveView = existingWebView, message.webView === liveView, page == .web else { return }
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "loafLinkPreview" {
            guard let frame = body["frame"] as? String, frame.count <= 64,
                let address = body["address"] as? String, address.count <= 8192
            else { return }
            updateHoveredLink(address, frame: frame)
            return
        }
        if message.name == "loafFavicon" {
            guard message.frameInfo.isMainFrame, let address = body["url"] as? String,
                address.count <= 8192, let source = URL(string: address), source == liveView.url, source == url,
                let links = body["links"] as? [String], links.count <= 16
            else { return }
            updateFavicon(
                for: source,
                declared: links.compactMap {
                    guard $0.count <= 4096, let link = URL(string: $0), link.scheme == "https",
                        link.user == nil, link.password == nil
                    else { return nil }
                    return link
                })
            return
        }
        if message.name == "loafShortcut", let key = body["key"] as? String {
            (store?.nativeWindow as? LoafBrowserWindow)?.siteClaimedShortcut(
                key, tabID: id, claimed: body["claimed"] as? Bool ?? true)
            return
        }
        if message.name == "loafStore" {
            receiveStoreAction(message, body: body)
            return
        }
        if message.name == "loafMedia", let locked = body["pointer"] as? Bool {
            if locked {
                pointerCapturePosition.didCapture()
                pointerCaptureFrame = message.frameInfo
            } else {
                restoreCapturedCursor()
            }
            if store?.selectedTab?.id == id, let store {
                store.feedback.show(
                    .pointer, icon: .pointer,
                    text: locked ? "your cursor is hidden. press escape twice to show it" : "mouse released")
            }
        }
        if message.name == "loafMedia", let frameID = body["frame"] as? String, frameID.count <= 64,
            let sources = body["sources"] as? [[String: Any]]
        {
            var updated: [MediaSource] = []
            for item in sources.prefix(12) {
                guard let id = item["id"] as? String, id.count <= 20, let title = item["title"] as? String else {
                    continue
                }
                func number(_ key: String) -> Double {
                    let value = item[key] as? Double ?? 0
                    return value.isFinite ? value : 0
                }
                let sourceID = frameID + ":" + id
                var source = MediaSource(
                    id: sourceID, elementID: id, frameID: frameID, frame: message.frameInfo,
                    title: String(title.prefix(200)), artist: String((item["artist"] as? String ?? "").prefix(120)),
                    paused: item["paused"] as? Bool ?? true, muted: item["muted"] as? Bool ?? false,
                    volume: min(1, max(0, number("volume"))), position: max(0, number("position")),
                    duration: max(0, number("duration")))
                source.supportsAirPlay = item["airplay"] as? Bool ?? false
                source.pictureInPicture = item["pip"] as? Bool ?? false
                source.firstSeen = media.first { $0.id == sourceID }?.firstSeen ?? Date()
                updated.append(source)
            }
            mediaFramesSeen[frameID] = Date()
            let combined =
                (media.filter {
                    $0.frameID != frameID && Date().timeIntervalSince(mediaFramesSeen[$0.frameID] ?? $0.updated) < 8
                } + updated).sorted { $0.firstSeen < $1.firstSeen }

            if combined.count != media.count || !zip(combined, media).allSatisfy({ $0.samePresentation(as: $1) }) {
                media = combined
            }
            mediaFramesSeen = mediaFramesSeen.filter { Date().timeIntervalSince($0.value) < 8 }
        }
        if message.name == "loafPassword", message.frameInfo.isMainFrame, let store,
            webView.hasOnlySecureContent, !store.profileFor(profileID).privateMode,
            store.selectedProfileID == profileID, store.selectedTab?.id == id,
            let current = webView.url, let origin = BrowserAddress.origin(current),
            let frameURL = message.frameInfo.request.url,
            BrowserAddress.origin(frameURL) == origin
        {
            if body["action"] as? String == "remember-username", let username = body["username"] as? String,
                !username.isEmpty, username.count <= 256
            {
                pendingLoginUsername = PendingLoginUsername(origin: origin, username: username, date: Date())
            } else if body["action"] as? String == "offer-fill", store.preferences.autofillPasswords != false,
                let stage = body["stage"] as? String, ["username", "password", "login"].contains(stage),
                let targetID = body["targetID"] as? String, targetID.count == 32,
                targetID.allSatisfy({ $0.isHexDigit }),
                let anchor = PasswordFieldAnchor(body["anchor"]),
                PasswordVault.canFill(tab: self, origin: origin, navigationID: navigationID),
                store.passwordAuthentication == nil
            {
                var users = PasswordVault.usernames(profileID: profileID, origin: origin)
                if body["passwordOnly"] as? Bool == true, let remembered = loginUsername(for: origin),
                    users.contains(remembered)
                {
                    users = [remembered]
                }
                if body["passwordOnly"] as? Bool == true, let remembered = loginUsername(for: origin),
                    hasPasswordApproval(origin: origin, username: remembered), users.contains(remembered),
                    automaticPasswordTarget != navigationID.uuidString + targetID
                {
                    automaticPasswordTarget = navigationID.uuidString + targetID
                    PasswordVault.fill(
                        tab: self, username: remembered, origin: origin, navigationID: navigationID, targetID: targetID)
                    return
                }
                if !users.isEmpty {
                    passwordSuggestions.anchor = anchor
                    passwordSuggestions.query = body["query"] as? String ?? ""
                    passwordSuggestions.selection = -1
                    store.passwordFillOffer = PasswordFillOffer(
                        tabID: id, navigationID: navigationID, origin: origin, usernames: users, targetID: targetID,
                        anchor: anchor)
                }
            } else if let action = body["action"] as? String,
                ["position-fill", "dismiss-fill", "key-fill"].contains(action),
                let offer = store.passwordFillOffer, offer.tabID == id, offer.navigationID == navigationID,
                offer.origin == origin, body["targetID"] as? String == offer.targetID
            {
                if action == "dismiss-fill" {
                    store.passwordFillOffer = nil
                } else if action == "position-fill" {
                    let anchor = PasswordFieldAnchor(body["anchor"])
                    if passwordSuggestions.anchor != anchor { passwordSuggestions.anchor = anchor }
                    let query = body["query"] as? String ?? ""
                    if passwordSuggestions.query != query {
                        passwordSuggestions.query = query
                        passwordSuggestions.selection = -1
                    }
                } else if let key = body["key"] as? String {
                    let users = PasswordSuggestionState.filtered(offer.usernames, query: passwordSuggestions.query)
                    switch key {
                    case "Escape": store.passwordFillOffer = nil
                    case "ArrowDown":
                        passwordSuggestions.selection =
                            users.isEmpty ? -1 : (passwordSuggestions.selection + 1) % users.count
                    case "ArrowUp":
                        passwordSuggestions.selection =
                            users.isEmpty
                            ? -1
                            : (passwordSuggestions.selection > 0 ? passwordSuggestions.selection - 1 : users.count - 1)
                    case "Enter":
                        if users.indices.contains(passwordSuggestions.selection) {
                            PasswordVault.fill(
                                tab: self, username: users[passwordSuggestions.selection], origin: origin,
                                navigationID: navigationID, targetID: offer.targetID)
                        }
                    default: break
                    }
                    let arguments: [String: Any] = [
                        "targetID": offer.targetID ?? "",
                        "selected": passwordSuggestions.selection >= 0 && store.passwordFillOffer != nil,
                    ]
                    self.webView.callAsyncJavaScript(
                        "globalThis.__loafPasswordSuggestions?.selection(targetID, selected)", arguments: arguments,
                        in: nil, in: PageScripts.passwordWorld, completionHandler: { _ in })
                }
            } else if store.preferences.savePasswords,
                store.profileFor(profileID).siteSettings?[origin]?.savePasswords != false,
                let supplied = body["username"] as? String,
                let password = body["password"] as? String, PasswordImport.validPassword(password),
                let username = supplied.isEmpty ? loginUsername(for: origin) : supplied,
                PasswordImport.validUsername(username)
            {

                if (try? PasswordVault.read(profileID: profileID, origin: origin, username: username)) != password {
                    store.passwordOffer = PasswordOffer(
                        profileID: profileID, origin: origin, username: username, password: password)
                }
            }
        }
    }

    func control(_ source: MediaSource, action: String, value: Double = 0) {
        guard value.isFinite, media.contains(where: { $0.id == source.id }) else { return }
        webView.callAsyncJavaScript(
            "globalThis.loafMediaControl?.(id, action, value)",
            arguments: ["id": source.elementID, "action": action, "value": value], in: source.frame, in: .defaultClient
        ) { _ in }
    }

    func exitReader() {
        readerWebView?.stopLoading()
        readerWebView?.navigationDelegate = nil
        readerWebView = nil
        finder.reset(clearQuery: true)
        finder.webView = existingWebView
        readerArticle = nil
        readerDocument = nil
    }
    func toggleReader() async {
        if readerArticle != nil {
            exitReader()
            return
        }
        guard let originalURL = url, page == .web, let view = existingWebView else { return }
        let token = navigationID
        do {
            let value =
                try await view.callAsyncJavaScript(
                    ReaderDocument.extraction, arguments: [:], in: nil, contentWorld: .defaultClient)
                as? [String: String]
            guard navigationID == token, url == originalURL, existingWebView === view else { return }
            guard let value, let text = value["text"], let body = value["body"] else {
                store?.error = "No readable article was found on this page."
                return
            }
            readerDocument = ReaderDocument(
                originalURL: originalURL, title: value["title"].flatMap { $0.isEmpty ? nil : $0 } ?? title, text: text,
                body: body)
            readerArticle = text
        } catch {
            if navigationID == token { store?.error = error.localizedDescription }
        }
    }

    func clearHoveredLink() {
        hoveredLinkFrame = nil
        if hoveredLink != nil { hoveredLink = nil }
    }
    func updateHoveredLink(_ address: String, frame: String) {
        guard !isDisposed, page == .web, store?.preferences.showLinkPreview != false else {
            clearHoveredLink()
            return
        }
        if address.isEmpty {
            if hoveredLinkFrame == frame { clearHoveredLink() }
            return
        }
        guard let display = Self.linkPreviewAddress(address) else {
            clearHoveredLink()
            return
        }
        hoveredLinkFrame = frame
        if hoveredLink != display { hoveredLink = display }
    }
    nonisolated static func linkPreviewAddress(_ address: String) -> String? {
        guard !address.isEmpty, address.count <= 8192,
            !address.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
            }),
            var components = URLComponents(string: address), let scheme = components.scheme,
            ["http", "https", "mailto", "tel", "ftp"].contains(scheme.lowercased())
        else { return nil }
        components.user = nil
        components.password = nil
        return components.string
    }

    private func prepareFavicon(for destination: URL, fetch: Bool = false) {
        faviconTask?.cancel()
        guard let store, let origin = BrowserAddress.websiteOrigin(destination) else {
            favicon = nil
            faviconOrigin = nil
            faviconLinks = []
            return
        }
        let privateID = store.profileFor(profileID).privateMode ? profileID : nil
        let sameOrigin = faviconOrigin == origin && url.flatMap(BrowserAddress.websiteOrigin) == origin
        favicon =
            store.application.favicons.cachedImage(for: destination, privateID: privateID)
            ?? (sameOrigin ? favicon : nil)
        faviconOrigin = origin
        if !sameOrigin { faviconLinks = [] }
        faviconTask = Task { [weak self] in
            let cached = await store.application.favicons.storedImage(for: destination, privateID: privateID)
            guard let self, !Task.isCancelled, !isDisposed,
                url.flatMap(BrowserAddress.websiteOrigin) == origin
            else { return }
            if let cached { favicon = cached }
            guard fetch, favicon == nil else { return }
            let image = await store.application.favicons.image(
                for: destination, privateID: privateID,
                quick: true, discoverPage: false)
            guard !Task.isCancelled, !isDisposed, url.flatMap(BrowserAddress.websiteOrigin) == origin else { return }
            if let image { favicon = image }
        }
    }
    private func updateFavicon(for source: URL, declared: [URL]) {
        guard let store, !declared.isEmpty, declared != faviconLinks else { return }
        faviconLinks = declared
        faviconTask?.cancel()
        let token = navigationID
        let view = existingWebView
        let privateID = store.profileFor(profileID).privateMode ? profileID : nil
        faviconTask = Task { [weak self] in
            let image = await store.application.favicons.image(
                for: source, privateID: privateID,
                declared: declared, refresh: true, discoverPage: false)
            guard let self, !Task.isCancelled, !isDisposed, navigationID == token,
                url == source, existingWebView === view, view?.url == source
            else { return }
            if let image { favicon = image }
        }
    }
    private func loadFavicon() {
        guard let source = url, let view = existingWebView else { return }
        let token = navigationID

        Task { [weak self, weak view] in
            guard let view else { return }

            let result = try? await view.evaluateJavaScript(
                PageScripts.faviconLinks
            )

            let links = result as? [String] ?? []

            guard let self,
                !isDisposed,
                navigationID == token,
                url == source,
                existingWebView === view
            else {
                return
            }

            updateFavicon(
                for: source,
                declared: links.compactMap {
                    guard $0.count <= 4096,
                        let link = URL(string: $0),
                        link.scheme == "https",
                        link.user == nil,
                        link.password == nil
                    else {
                        return nil
                    }
                    return link
                })
        }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store?.extensionWindow(for: profileID)
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { existingWebView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { pinned }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.profileFor(profileID).selectedTab == id }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { media.contains { !$0.paused && !$0.muted } }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        store?.switchProfile(profileID)
        store?.select(self)
        store?.nativeWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        self.pinned = pinned
        store?.tabChanged(self)
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        load(url)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        store?.close(self)
        completionHandler(nil)
    }
    func duplicate(
        using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let tab = store?.newTab(
            url: url, profileID: profileID, showOmnibar: false, activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

@MainActor private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

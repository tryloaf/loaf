import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

struct PointerEscapeGesture {
    private var firstPress: TimeInterval?
    mutating func press(at time: TimeInterval, repeatKey: Bool) -> Bool {
        guard !repeatKey else { return false }
        if let firstPress, time >= firstPress, time - firstPress <= 0.6 {
            self.firstPress = nil
            return true
        }
        firstPress = time
        return false
    }
    mutating func reset() { firstPress = nil }
}

struct PointerCapturePosition {
    private(set) var origin: CGPoint?
    private(set) var captured = false
    mutating func prepare(_ point: CGPoint?) {
        guard !captured, let point, point.x.isFinite, point.y.isFinite else { return }
        origin = point
    }
    mutating func didCapture() { captured = origin != nil }
    mutating func release(confirmed: Bool = false) -> CGPoint? {
        let result = captured || confirmed ? origin : nil
        origin = nil
        captured = false
        return result
    }
}

@MainActor final class ChromeColorObservation: NSObject {
    private weak var webView: WKWebView?
    private let changed: () -> Void
    private var observing = false
    private let key = "_sampledTopFixedPositionContentColor"
    init(webView: WKWebView, changed: @escaping () -> Void) {
        self.webView = webView
        self.changed = changed
        super.init()
        if webView.responds(to: NSSelectorFromString(key)) {
            observing = true
            webView.addObserver(self, forKeyPath: key, options: [.initial, .new], context: nil)
        }
    }
    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == key else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }
    func invalidate() {
        if observing {
            webView?.removeObserver(self, forKeyPath: key)
            observing = false
        }
    }
    deinit { if observing { webView?.removeObserver(self, forKeyPath: key) } }
}

@MainActor final class PointerLockOffer: Identifiable {
    let id = UUID()
    let tabID: UUID
    let host: String
    private weak var tab: BrowserTab?
    private let origin: String
    private let navigationID: UUID
    private var completion: ((Bool) -> Void)?
    private let capturePoint = CGEvent(source: nil)?.location
    init(tab: BrowserTab, origin: String, host: String, completion: @escaping (Bool) -> Void) {
        self.tab = tab
        tabID = tab.id
        self.origin = origin
        self.host = host
        navigationID = tab.navigationID
        self.completion = completion
    }
    func finish(_ allow: Bool) {
        guard let callback = completion else { return }
        completion = nil
        let valid =
            tab.map { tab in
                guard let store = tab.store else { return false }
                return WebKitAdapter.pointerLockEligible(tab) && tab.navigationID == navigationID
                    && tab.webView.url.flatMap(BrowserAddress.websiteOrigin) == origin
                    && WebKitAdapter.pointerLockPolicy(
                        preferences: store.preferences, settings: store.profileFor(tab.profileID).siteSettings?[origin])
                        != "deny"
            } ?? false
        if allow && valid { tab?.pointerCapturePosition.prepare(capturePoint) }
        callback(allow && valid)
    }
}

@MainActor enum WebKitAdapter {
    static func enablePictureInPicture(_ preferences: WKPreferences) {
        let selector = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        guard preferences.responds(to: selector), let implementation = preferences.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Setter.self)(preferences, selector, true)
    }
    static func capturedEscape(
        _ tab: BrowserTab, type: String, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []
    ) {
        guard !tab.isDisposed, tab.pointerCapturePosition.captured, let view = tab.existingWebView else { return }

        view.callAsyncJavaScript(
            """
            if (!document.pointerLockElement) return false;
            const target = document.activeElement || document.pointerLockElement;
            target.dispatchEvent(new KeyboardEvent(type, {key:'Escape', code:'Escape', keyCode:27, which:27,
                bubbles:true, cancelable:true, composed:true, repeat:repeatKey, shiftKey:shift, altKey:alt, ctrlKey:ctrl, metaKey:meta}));
            return true;
            """,
            arguments: [
                "type": type, "repeatKey": repeatKey, "shift": modifiers.contains(.shift),
                "alt": modifiers.contains(.option), "ctrl": modifiers.contains(.control),
                "meta": modifiers.contains(.command),
            ], in: tab.pointerCaptureFrame, in: .defaultClient, completionHandler: { _ in })
    }
    @discardableResult static func setWindowTitlebarOpacity(_ window: NSWindow, value: CGFloat) -> Bool {

        let selector = NSSelectorFromString("setTitlebarAlphaValue:")
        guard window.responds(to: selector) else { return false }
        typealias SetAlpha = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(window.method(for: selector), to: SetAlpha.self)(window, selector, value)
        return true
    }
    static func windowTitlebarOpacity(_ window: NSWindow) -> CGFloat? {
        let selector = NSSelectorFromString("titlebarAlphaValue")
        guard window.responds(to: selector) else { return nil }
        typealias Alpha = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(window.method(for: selector), to: Alpha.self)(window, selector)
    }
    @MainActor static func pointerLockEligible(_ tab: BrowserTab) -> Bool {
        guard let store = tab.store, let owner = store.nativeWindow, let window = tab.webView.window,
            window === owner || tab.webView.fullscreenState == .inFullscreen
        else { return false }
        return NSApp.isActive && window.isKeyWindow && window.isVisible && window.attachedSheet == nil
            && !store.omnibarVisible && !store.findVisible && !store.siteSettingsVisible
            && store.selectedProfileID == tab.profileID && store.selectedTab?.id == tab.id && tab.page == .web
            && tab.webView.url.flatMap(BrowserAddress.websiteOrigin) != nil
    }
    static func pointerLockPolicy(preferences: BrowserPreferences, settings: SiteSettings?) -> String {
        guard preferences.allowsPointerCapture != false else { return "deny" }
        switch settings?.pointerLock {
        case "deny": return "deny"
        case "ask": return "ask"
        default: return "allow"
        }
    }
    static func applyPointerLockPolicy(_ tab: BrowserTab) {
        guard let store = tab.store, let origin = tab.webView.url.flatMap(BrowserAddress.websiteOrigin),
            pointerLockPolicy(
                preferences: store.preferences, settings: store.profileFor(tab.profileID).siteSettings?[origin])
                != "allow"
        else { return }
        if store.pointerLockOffer?.tabID == tab.id { store.cancelPointerLock() }
        tab.webView.evaluateJavaScript("document.exitPointerLock()", in: nil, in: .defaultClient) { _ in }
    }
    static func requestPointerLock(_ tab: BrowserTab, completion: @escaping (Bool) -> Void) {
        guard pointerLockEligible(tab), let store = tab.store, let url = tab.webView.url,
            let origin = BrowserAddress.websiteOrigin(url)
        else {
            completion(false)
            return
        }
        let policy = pointerLockPolicy(
            preferences: store.preferences, settings: store.profileFor(tab.profileID).siteSettings?[origin])
        if policy == "deny" {
            completion(false)
            return
        }
        if policy == "allow" {
            tab.pointerCapturePosition.prepare(CGEvent(source: nil)?.location)
            completion(true)
            return
        }

        store.cancelPointerLock()
        store.pointerLockOffer = PointerLockOffer(
            tab: tab, origin: origin, host: url.host ?? "this site", completion: completion)
    }

    final class FindController: NSObject, ObservableObject {
        @Published var query = ""
        @Published var caseSensitive = false
        @Published var count: Int?
        @Published var index = 0
        @Published var searching = false
        @Published var found = true
        @Published private(set) var unavailable = false
        weak var webView: WKWebView? {
            didSet {
                guard oldValue !== webView else { return }

                if let oldValue {
                    let setter = NSSelectorFromString("_setFindDelegate:")
                    if oldValue.responds(to: setter) {
                        typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                        unsafeBitCast(oldValue.method(for: setter), to: SetDelegate.self)(oldValue, setter, nil)
                    }
                    if oldValue.responds(to: NSSelectorFromString("_hideFindUI")) {
                        oldValue.perform(NSSelectorFromString("_hideFindUI"))
                    }
                }
                timeout?.cancel()
                timeout = nil
                active = nil
                pending.removeAll()
                lastCriteria = nil
                generation = UUID()
                nativeUnavailable = false
                if count != nil { count = nil }
                if index != 0 { index = 0 }
                if searching { searching = false }
                if !found { found = true }
                if unavailable { unavailable = false }
            }
        }
        private struct Request {
            let id = UUID()
            let text: String
            let caseSensitive: Bool
            let backwards: Bool
            let generation: UUID
            func sameCriteria(as other: Request) -> Bool { text == other.text && caseSensitive == other.caseSensitive }
        }
        private var active: Request?
        private var pending: [Request] = []
        private var lastCriteria: Request?
        private var generation = UUID()
        private var timeout: Task<Void, Never>?
        private var nativeUnavailable = false
        var status: String {
            query.isEmpty
                ? ""
                : searching
                    ? "…"
                    : unavailable
                        ? "find unavailable"
                        : count.map { "\(index) of \($0)" } ?? (found ? "match found" : "no matches")
        }
        var supportsCounts: Bool {
            !nativeUnavailable && webView?.responds(to: NSSelectorFromString("_setFindDelegate:")) == true
                && webView?.responds(to: NSSelectorFromString("_findString:options:maxCount:")) == true
        }
        func search(backwards: Bool = false) {
            guard webView != nil else { return }
            guard !query.isEmpty else {
                reset()
                return
            }
            let request = Request(
                text: query, caseSensitive: caseSensitive, backwards: backwards, generation: generation)
            if lastCriteria.map({ !request.sameCriteria(as: $0) }) ?? true {
                hide()
                count = nil
                index = 0

                pending.removeAll()
                lastCriteria = request
            }
            searching = true
            unavailable = false
            if active != nil {
                pending.append(request)
                return
            }
            start(request)
        }
        private func start(_ request: Request) {
            guard let webView else { return }
            active = request
            timeout?.cancel()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, !Task.isCancelled, self.active?.id == request.id else { return }
                self.expired(request)
            }
            if supportsCounts {
                let setter = NSSelectorFromString("_setFindDelegate:")
                let find = NSSelectorFromString("_findString:options:maxCount:")
                typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject) -> Void
                typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
                unsafeBitCast(webView.method(for: setter), to: SetDelegate.self)(webView, setter, self)

                let options: UInt = (request.caseSensitive ? 0 : 1) | 16 | 64 | 128 | 512 | (request.backwards ? 8 : 0)
                unsafeBitCast(webView.method(for: find), to: Find.self)(
                    webView, find, request.text as NSString, options, UInt.max)
            } else {
                let configuration = WKFindConfiguration()
                configuration.backwards = request.backwards
                configuration.wraps = true
                configuration.caseSensitive = request.caseSensitive
                webView.find(request.text, configuration: configuration) { [weak self, weak webView] result in
                    guard let self, let webView, self.active?.id == request.id else { return }
                    self.complete(
                        webView, string: request.text, matches: result.matchFound ? nil : 0, matchIndex: 0,
                        found: result.matchFound)
                }
            }
        }
        private func complete(_ view: WKWebView, string: String, matches: Int?, matchIndex: Int, found result: Bool) {
            guard view === webView, let request = active, request.text == string else { return }
            timeout?.cancel()
            timeout = nil
            active = nil

            if request.generation == generation, string == query, request.caseSensitive == caseSensitive {
                count = matches
                index = matches.map { $0 == 0 ? 0 : max(1, min($0, matchIndex + 1)) } ?? 0
                found = result
            }
            if !pending.isEmpty { start(pending.removeFirst()) } else { searching = false }
        }
        private func expired(_ request: Request) {
            active = nil
            timeout = nil
            if supportsCounts, let webView {

                nativeUnavailable = true
                let setter = NSSelectorFromString("_setFindDelegate:")
                typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                unsafeBitCast(webView.method(for: setter), to: SetDelegate.self)(webView, setter, nil)
                hide()
                count = nil
                index = 0
                let next =
                    pending.last
                    ?? Request(
                        text: query, caseSensitive: caseSensitive, backwards: request.backwards, generation: generation)
                pending.removeAll()
                if !query.isEmpty && next.generation == generation { start(next) } else { searching = false }
            } else {
                pending.removeAll()
                count = nil
                index = 0
                searching = false
                unavailable = !query.isEmpty
            }
        }
        func reset(clearQuery: Bool = false) {
            generation = UUID()
            pending.removeAll()
            lastCriteria = nil
            count = nil
            index = 0
            found = true
            searching = false
            unavailable = false
            hide()
            if clearQuery { query = "" }

        }
        private func hide() {
            if let webView, webView.responds(to: NSSelectorFromString("_hideFindUI")) {
                webView.perform(NSSelectorFromString("_hideFindUI"))
            }
        }
        @objc(_webView:didFindMatches:forString:withMatchIndex:)
        func didFind(_ view: WKWebView, matches: UInt, string: String, matchIndex: Int) {
            guard !nativeUnavailable else { return }
            complete(view, string: string, matches: Int(clamping: matches), matchIndex: matchIndex, found: matches > 0)
        }
        @objc(_webView:didFailToFindString:)
        func didFail(_ view: WKWebView, string: String) {
            guard !nativeUnavailable else { return }
            complete(view, string: string, matches: 0, matchIndex: 0, found: false)
        }
        deinit { timeout?.cancel() }
    }
    private static var inspectorDelegateKey: UInt8 = 0
    static var supportsSiteAutoplay: Bool {
        WKWebpagePreferences().responds(to: NSSelectorFromString("_setAutoplayPolicy:"))
    }
    static var supportsSitePopups: Bool {
        WKWebpagePreferences().responds(to: NSSelectorFromString("_setPopUpPolicy:"))
    }
    @discardableResult static func setSitePopups(_ preferences: WKWebpagePreferences, allowed: Bool) -> Bool {

        let selector = NSSelectorFromString("_setPopUpPolicy:")
        guard preferences.responds(to: selector), let implementation = preferences.method(for: selector) else {
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Setter.self)(preferences, selector, allowed ? 1 : 0)
        return true
    }
    @discardableResult static func setSiteAutoplay(_ preferences: WKWebpagePreferences, allowed: Bool) -> Bool {

        let selector = NSSelectorFromString("_setAutoplayPolicy:")
        guard preferences.responds(to: selector), let implementation = preferences.method(for: selector) else {
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Setter.self)(preferences, selector, allowed ? 1 : 3)
        return true
    }
    @discardableResult static func setChromeInset(_ webView: WKWebView, height: CGFloat) -> Bool {
        let height = height.isFinite ? max(0, height) : 0
        let automatic = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if webView.responds(to: automatic), let automaticIMP = webView.method(for: automatic) {
            typealias AutomaticSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(automaticIMP, to: AutomaticSetter.self)(webView, automatic, false)
        }
        if #available(macOS 26.0, *) {

            var insets = webView.obscuredContentInsets
            if insets.top != height {
                insets.top = height
                webView.obscuredContentInsets = insets
            }
            return true
        }
        let inset = NSSelectorFromString("_setTopContentInset:immediate:")
        guard webView.responds(to: automatic), webView.responds(to: inset),
            let insetIMP = webView.method(for: inset)
        else { return false }
        typealias InsetSetter = @convention(c) (AnyObject, Selector, CGFloat, Bool) -> Void
        unsafeBitCast(insetIMP, to: InsetSetter.self)(webView, inset, height, true)
        return true
    }
    static func chromeInset(_ webView: WKWebView) -> CGFloat? {
        if #available(macOS 26.0, *) { return webView.obscuredContentInsets.top }
        let selector = NSSelectorFromString("_topContentInset")
        guard webView.responds(to: selector), let implementation = webView.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(implementation, to: Getter.self)(webView, selector)
    }
    static func topChromeColor(_ webView: WKWebView) -> NSColor? {
        object(webView, "_sampledTopFixedPositionContentColor") as? NSColor ?? webView.underPageBackgroundColor
    }
    static func object(_ object: NSObject?, _ getter: String) -> AnyObject? {
        guard let object, object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return object.perform(NSSelectorFromString(getter))?.takeUnretainedValue()
    }
    static func setInspectionEnabled(_ webView: WKWebView, _ enabled: Bool) {
        if !enabled { closeInspector(webView) }
        webView.isInspectable = enabled
        let preferences = webView.configuration.preferences
        let selector = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: selector), let implementation = preferences.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(preferences, selector, enabled)
    }
    static func inspectorView(_ webView: WKWebView) -> WKWebView? {
        guard let inspector = object(webView, "_inspector") as? NSObject else { return nil }
        return object(inspector, "inspectorWebView") as? WKWebView
    }
    static func inspectorIsDocked(_ webView: WKWebView) -> Bool {
        guard let host = webView.superview, host.subviews.count > 1,
            let frontend = inspectorView(webView), frontend !== webView
        else { return false }
        return frontend.superview === host && frontend.window === webView.window
    }
    static func handleInspectorChromeKey(_ event: NSEvent, store: BrowserStore) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "s",
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
            event.window === store.nativeWindow, store.nativeWindow?.attachedSheet == nil,
            let page = store.selectedTab?.existingWebView, inspectorIsDocked(page),
            let frontend = inspectorView(page), let responder = frontend.window?.firstResponder as? NSView,
            responder === frontend || responder.isDescendant(of: frontend)
        else { return false }

        store.sidebarVisible.toggle()
        return true
    }
    static func canDockInspector(_ webView: WKWebView) -> Bool {
        guard webView.fullscreenState == .notInFullscreen, let host = webView.superview as? WebViewHost.HostView,
            host.window != nil, host.fallbackInset == 0, let inspector = object(webView, "_inspector") as? NSObject,
            ["attach", "detach", "inspectorWebView"].allSatisfy({ inspector.responds(to: NSSelectorFromString($0)) })
        else { return false }

        return host.bounds.width >= 500 && host.bounds.height * 0.75 >= 250
    }
    static func closeInspector(_ webView: WKWebView) {
        guard let inspector = object(webView, "_inspector") as? NSObject,
            inspector.responds(to: NSSelectorFromString("close"))
        else { return }
        inspector.perform(NSSelectorFromString("close"))
        webView.superview?.needsLayout = true
    }
    fileprivate static func applyInspectorMode(_ inspector: NSObject, webView: WKWebView, mode: InspectorMode) {
        guard webView.isInspectable else {
            closeInspector(webView)
            return
        }
        let selector = NSSelectorFromString(mode == .inline && canDockInspector(webView) ? "attach" : "detach")
        if inspector.responds(to: selector) { inspector.perform(selector) }
    }
    static func inspect(_ webView: WKWebView, mode: InspectorMode = .inline) -> Bool {
        guard webView.isInspectable, let inspector = object(webView, "_inspector") as? NSObject,
            inspector.responds(to: NSSelectorFromString("show"))
        else { return false }
        let delegateSelector = NSSelectorFromString("setDelegate:")
        if inspector.responds(to: delegateSelector), let implementation = inspector.method(for: delegateSelector) {
            let delegate = InspectorWindowDelegate(webView: webView, mode: mode)
            objc_setAssociatedObject(inspector, &inspectorDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(implementation, to: Setter.self)(inspector, delegateSelector, delegate)
        }
        inspector.perform(NSSelectorFromString("show"))

        applyInspectorMode(inspector, webView: webView, mode: mode)
        return true
    }
    static func menu(_ proposed: NSMenu, element: NSObject, tab: BrowserTab, selectedText: String? = nil) -> NSMenu {
        let menu = proposed.copy() as? NSMenu ?? NSMenu()
        LowercaseMenus.normalizeWebContext(menu)
        let hit = object(element, "hitTestResult") as? NSObject
        let link = object(hit, "absoluteLinkURL") as? URL
        let image = object(hit, "absoluteImageURL") as? URL
        let media = object(hit, "absoluteMediaURL") as? URL
        let text = selectedText ?? (object(hit, "lookupText") as? String ?? "")
        let selected =
            hit?.responds(to: NSSelectorFromString("isSelected")) == true
            && (hit?.value(forKey: "selected") as? Bool == true)
        let replacements = ["search", "openlinkinnewwindow", "openlinkinnewtab", "reload", "goback", "goforward"]
        let replacedIdentifiers: Set<String> = [
            "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenLinkInNewTab",
            "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierReload",
            "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierInspectElement",
        ]

        menu.allowsContextMenuPlugIns = false
        for item in menu.items {
            let action = item.action.map(NSStringFromSelector)?.lowercased() ?? ""
            if replacedIdentifiers.contains(item.identifier?.rawValue ?? "")
                || replacements.contains(where: { action.contains($0) })
                || item.title.lowercased().contains("search with") || item.title.lowercased().contains("search the web")
            {
                menu.removeItem(item)
            }
        }
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let handler = MenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if let link, ["https", "http"].contains(link.scheme) {
            add("open link in new tab") { _ = tab.store?.newTab(url: link, showOmnibar: false) }
            add("open link in new window") {
                _ = tab.store?.application.coordinator?.newWindow(profileID: tab.profileID, url: link)
            }
            add("copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
            add("download linked file") {
                tab.webView.startDownload(using: URLRequest(url: link)) { download in
                    if let owner = tab.store {
                        owner.downloads.add(download, owner: owner, profileID: tab.profileID, source: tab.webView)
                    }
                }
            }
        }
        if selected && !text.isEmpty {
            add("search with Google") { _ = tab.store?.newTab(url: BrowserAddress.search(text), showOmnibar: false) }
            add("translate selection…") { tab.store?.translationText = text }

        }
        if let image, ["https", "http"].contains(image.scheme) {
            add("open image in new tab") { _ = tab.store?.newTab(url: image, showOmnibar: false) }
            add("download image") {
                tab.webView.startDownload(using: URLRequest(url: image)) { download in
                    if let owner = tab.store {
                        owner.downloads.add(download, owner: owner, profileID: tab.profileID, source: tab.webView)
                    }
                }
            }
        }
        if let media, ["https", "http"].contains(media.scheme) {
            add("open media in new tab") { _ = tab.store?.newTab(url: media, showOmnibar: false) }
        }
        if let media,
            !menu.items.contains(where: {
                $0.title.lowercased().contains("picture in picture")
                    || $0.title.lowercased().contains("picture-in-picture")
            })
        {
            let frame = object(hit, "frameInfo") as? WKFrameInfo
            add("picture in picture") {
                tab.webView.callAsyncJavaScript(
                    """
                    const video = [...document.querySelectorAll('video')].find(el => el.currentSrc === address || el.src === address);
                    if (!video) return false;
                    if (video.webkitPresentationMode === 'picture-in-picture') {
                        video.webkitSetPresentationMode('inline');
                        return true;
                    }
                    if (document.pictureInPictureElement === video && typeof document.exitPictureInPicture === 'function') {
                        await document.exitPictureInPicture();
                        return true;
                    }
                    if (video.webkitSupportsPresentationMode?.('picture-in-picture') && typeof video.webkitSetPresentationMode === 'function') {
                        video.webkitSetPresentationMode('picture-in-picture');
                        return true;
                    }
                    if (document.pictureInPictureEnabled && !video.disablePictureInPicture && typeof video.requestPictureInPicture === 'function') {
                        await video.requestPictureInPicture();
                        return true;
                    }
                    return false;
                    """, arguments: ["address": media.absoluteString], in: frame, in: .defaultClient
                ) { result in
                    if (try? result.get()) as? Bool != true {
                        tab.store?.feedback.show(
                            .info, icon: .play, text: "couldn’t open picture in picture")
                    }
                }
            }
        }
        if link == nil && !selected {
            if !menu.items.contains(where: {
                $0.title.lowercased().contains("full screen") || $0.title.lowercased().contains("fullscreen")
            }) {
                add(
                    tab.webView.window?.styleMask.contains(.fullScreen) == true
                        ? "exit full screen" : "enter full screen"
                ) { tab.webView.window?.toggleFullScreen(nil) }
            }
            add("back", enabled: tab.canGoBack) { tab.webView.goBack() }
            add("forward", enabled: tab.canGoForward) { tab.webView.goForward() }
            add("reload") { tab.reload() }
            add("save as…", enabled: !tab.loading && tab.url != nil) { tab.savePage() }
            add("print…") { tab.printPage() }
            add("view page source") { tab.showSource() }
        }
        if tab.webView.isInspectable { add("inspect") { tab.inspect() } }
        ContextMenuStyle.apply(menu)
        return menu
    }
}
@MainActor private final class InspectorWindowDelegate: NSObject {
    private weak var webView: WKWebView?
    private let mode: InspectorMode
    init(webView: WKWebView, mode: InspectorMode) {
        self.webView = webView
        self.mode = mode
    }
    @objc(inspectorFrontendLoaded:)
    func frontendLoaded(_ inspector: NSObject) {
        if let webView { WebKitAdapter.applyInspectorMode(inspector, webView: webView, mode: mode) }
    }
}
@MainActor private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

@MainActor enum PageSaveCommand {
    private static var trackingMenus = Set<ObjectIdentifier>()
    static func track(_ menu: NSMenu, active: Bool) {
        if active { trackingMenus.insert(ObjectIdentifier(menu)) } else { trackingMenus.remove(ObjectIdentifier(menu)) }
    }
    static func userInitiated(
        _ event: NSEvent?, assistive: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let event else { return assistive }
        guard (0...1).contains(now - event.timestamp) else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: return true
        case .keyDown:
            guard !event.isARepeat else { return false }
            return !trackingMenus.isEmpty || assistive
                || (event.charactersIgnoringModifiers?.lowercased() == "s"
                    && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift])
        default: return false
        }
    }
}

extension BrowserTab {
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func requestedPointerLock(_ view: WKWebView, completionHandler: @escaping (Bool) -> Void) {
        guard view === existingWebView, !isDisposed else {
            completionHandler(false)
            return
        }
        WebKitAdapter.requestPointerLock(self, completion: completionHandler)
    }

    @objc(_webViewDidLosePointerLock:)
    func lostPointerLock(_ view: WKWebView) {
        if view === existingWebView { restoreCapturedCursor(confirmed: true) }
        if view === existingWebView, store?.pointerLockOffer?.tabID == id { store?.cancelPointerLock() }
    }

    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func contextMenu(
        _ webView: WKWebView, proposed: NSMenu, element: NSObject, userInfo: Any?,
        completion: @escaping (NSMenu) -> Void
    ) {
        let hit = WebKitAdapter.object(element, "hitTestResult") as? NSObject
        guard hit?.responds(to: NSSelectorFromString("isSelected")) == true,
            hit?.value(forKey: "selected") as? Bool == true
        else {
            completion(WebKitAdapter.menu(proposed, element: element, tab: self))
            return
        }
        let frame = WebKitAdapter.object(hit, "frameInfo") as? WKFrameInfo
        let selection = """
            (() => {
                const field = document.activeElement;
                if (field?.tagName === 'INPUT' && field.type === 'password') return '';
                if ((field?.tagName === 'INPUT' || field?.tagName === 'TEXTAREA') && typeof field.selectionStart === 'number')
                    return field.value.slice(field.selectionStart, field.selectionEnd).slice(0, 4000);
                return (window.getSelection()?.toString() || '').slice(0, 4000);
            })()
            """
        let token = navigationID
        webView.evaluateJavaScript(selection, in: frame, in: .defaultClient) { [weak self] result in
            guard let self, self.navigationID == token else {
                completion(proposed)
                return
            }
            let text = (try? result.get()) as? String
            completion(WebKitAdapter.menu(proposed, element: element, tab: self, selectedText: text))
        }
    }
    func inspect(mode: InspectorMode? = nil) {
        let chosen = mode ?? store?.preferences.inspectorMode ?? .inline
        if let mode, let store {
            store.preferences.inspectorMode = mode
            store.persistSoon()
        }
        guard WebKitAdapter.inspect(webView, mode: chosen) else {
            store?.error = "Web Inspector isn’t available. Enable the developer menu in advanced settings."
            return
        }
    }
    func showSource() {
        Task {
            let token = navigationID
            guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
                token == navigationID, let store
            else { return }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 640), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "source · " + title
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 640))
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.string = html
            view.textContainerInset = NSSize(width: 16, height: 16)
            scroll.documentView = view
            window.contentView = scroll
            store.application.coordinator?.showAuxiliary(window)
        }
    }
    func printPage() {
        guard let owner = store, let window = owner.nativeWindow else { return }
        owner.application.coordinator?.enqueueSheet(for: owner, cancel: {}) { done in
            let operation = self.webView.printOperation(with: .shared)
            let delegate = PrintCompletion(done)
            PrintCompletion.pending[ObjectIdentifier(operation)] = delegate
            operation.runModal(
                for: window, delegate: delegate, didRun: #selector(PrintCompletion.finished(_:success:context:)),
                contextInfo: nil)
        }
    }
    func savePage(event: NSEvent? = nil) {
        let event = event ?? NSApp.currentEvent
        guard !isDisposed, !loading, page == .web, let owner = store, owner.selectedTab === self,
            owner.application.ready, !owner.application.onboardingVisible,
            let window = owner.nativeWindow, window.isKeyWindow, window.attachedSheet == nil, url != nil,
            PageSaveCommand.userInitiated(
                event, assistive: NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled)
        else { return }
        let panel = NSSavePanel()
        panel.title = "save page"
        panel.nameFieldStringValue = title + ".webarchive"
        panel.allowedContentTypes = [UTType(filenameExtension: "webarchive") ?? .data, .html]
        owner.application.coordinator?.enqueueSheet(for: owner, cancel: {}) { done in
            panel.beginSheetModal(for: window) { result in
                defer { done() }
                guard result == .OK, let destination = panel.url else { return }
                Task {
                    do {
                        let data: Data
                        if destination.pathExtension == "html" {
                            data = Data(
                                ((try await self.webView.evaluateJavaScript("document.documentElement.outerHTML"))
                                    as? String ?? "").utf8)
                        } else {
                            data = try await withCheckedThrowingContinuation { continuation in
                                self.webView.createWebArchiveData { result in continuation.resume(with: result) }
                            }
                        }
                        try data.write(to: destination, options: .atomic)
                    } catch { owner.error = error.localizedDescription }
                }
            }
        }
    }
}

extension BrowserWindowState {
    var currentUserAgentMode: UserAgentMode {
        guard let url = selectedTab?.url, let origin = BrowserAddress.websiteOrigin(url) else {
            return preferences.userAgentMode ?? .automatic
        }
        return profile.siteSettings?[origin]?.userAgent ?? preferences.userAgentMode ?? .automatic
    }
    func setUserAgent(_ mode: UserAgentMode, custom: String? = nil) {
        guard !application.onboardingVisible, let tab = selectedTab, let url = tab.url,
            let origin = BrowserAddress.websiteOrigin(url)
        else { return }
        if mode == .custom, !DesktopIdentity.validCustom(custom) { return }
        updateCurrent {
            var settings = $0.siteSettings?[origin] ?? SiteSettings()
            settings.userAgent = mode
            settings.customUserAgent = custom
            $0.siteSettings = $0.siteSettings ?? [:]
            $0.siteSettings?[origin] = settings
        }
        tab.applySiteSettings(url)
        tab.reload()
    }
    func editCustomUserAgent() {
        guard let tab = selectedTab, let url = tab.url, let origin = BrowserAddress.websiteOrigin(url),
            let coordinator = application.coordinator
        else { return }
        let profileID = selectedProfileID
        let field = NSTextField(
            string: profile.siteSettings?[origin]?.customUserAgent ?? tab.webView.customUserAgent ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        field.placeholderString = "user agent"
        let alert = NSAlert()
        alert.messageText = "custom user agent"
        alert.informativeText = "applies to this website until you choose another user agent."
        alert.accessoryView = field
        alert.addButton(withTitle: "apply")
        alert.addButton(withTitle: "cancel")
        coordinator.alert(alert, for: self) { [weak self, weak tab] response in
            guard response == .alertFirstButtonReturn, let self, self.selectedProfileID == profileID,
                self.selectedTab === tab, tab?.url == url
            else { return }
            guard DesktopIdentity.validCustom(field.stringValue) else {
                self.error = "use 1–1024 characters without line breaks or control characters"
                return
            }
            self.setUserAgent(.custom, custom: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }
}

@MainActor enum DesktopIdentity {
    static func validCustom(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.utf8.count <= 1024 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.controlCharacters.contains($0) }
    }
    static func userAgent(mode: UserAgentMode, defaultUA: String, custom: String?) -> String? {
        if mode == .automatic || mode == .desktop { return userAgent(defaultUA: defaultUA) }
        if mode == .custom { return validCustom(custom) ? custom?.trimmingCharacters(in: .whitespaces) : nil }
        let windows = [UserAgentMode.chromeWindows, .edgeWindows, .firefoxWindows].contains(mode)
        let android = [UserAgentMode.chromeAndroid, .edgeAndroid, .firefoxAndroid].contains(mode)
        if mode == .safariIPhone || mode == .safariIPad {
            let device =
                mode == .safariIPhone ? "iPhone; CPU iPhone OS 18_0 like Mac OS X" : "iPad; CPU OS 18_0 like Mac OS X"
            return "Mozilla/5.0 (" + device
                + ") AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
        let platform =
            windows
            ? "Windows NT 10.0; Win64; x64"
            : android
                ? "Linux; Android 15; Pixel 9"
                : mode == .chromeOS ? "X11; CrOS x86_64 16093.0.0" : "Macintosh; Intel Mac OS X 10_15_7"
        if [.firefoxMac, .firefoxWindows, .firefoxAndroid].contains(mode) {
            return "Mozilla/5.0 (" + platform + "; rv:140.0) Gecko/20100101 Firefox/140.0"
        }
        let edge = [UserAgentMode.edgeMac, .edgeWindows, .edgeAndroid].contains(mode)
        return "Mozilla/5.0 (" + platform + ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0"
            + (android ? " Mobile" : "") + " Safari/537.36"
            + (edge ? android ? " EdgA/140.0.0.0" : " Edg/140.0.0.0" : "")
    }
    static var safariVersion: String {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        return (NSDictionary(contentsOf: safari)?["CFBundleShortVersionString"] as? String) ?? ProcessInfo.processInfo
            .operatingSystemVersion.majorVersion.description + ".0"
    }
    static func userAgent(defaultUA: String) -> String {
        if defaultUA.contains("Safari/") { return defaultUA }
        let engine =
            defaultUA.range(of: "AppleWebKit/[0-9.]+", options: .regularExpression).map {
                String(defaultUA[$0]).replacingOccurrences(of: "AppleWebKit/", with: "")
            } ?? "605.1.15"
        return defaultUA + " Version/" + safariVersion + " Safari/" + engine
    }
}

@MainActor private final class PrintCompletion: NSObject {
    static var pending: [ObjectIdentifier: PrintCompletion] = [:]
    let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    @objc func finished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        Self.pending.removeValue(forKey: ObjectIdentifier(operation))
        completion()
    }
}

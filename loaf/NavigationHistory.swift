import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class OpenerNavigationTrail {
    let state: Any
    let entries: [WKBackForwardListItem]
    let previous: OpenerNavigationTrail?
    let returning: OpenerNavigationTrail?
    let returnBoundaryOffset: Int?
    private weak var source: BrowserTab?
    private weak var sourceView: WKWebView?
    private let sourceNavigationID: UUID?
    private let sourcePageRevision: UUID?
    private let sourceURL: URL
    private let sourceForwardItems: [WKBackForwardListItem]
    init?(view: WKWebView, previous: OpenerNavigationTrail?, returning: OpenerNavigationTrail? = nil,
        boundary: WKBackForwardListItem? = nil, source: BrowserTab? = nil) {
        guard let state = view.interactionState, let current = view.backForwardList.currentItem else { return nil }
        self.state = state
        entries = [current] + view.backForwardList.backList.reversed()
        self.previous = previous
        self.returning = returning
        self.source = source
        sourceView = source == nil ? nil : view
        sourceNavigationID = source?.navigationID
        sourcePageRevision = source?.pageRevision
        sourceURL = current.url
        sourceForwardItems = view.backForwardList.forwardList
        if current === boundary { returnBoundaryOffset = 0 }
        else if let index = view.backForwardList.forwardList.firstIndex(where: { $0 === boundary }) {
            returnBoundaryOffset = -index - 1
        } else if let index = Array(view.backForwardList.backList.reversed()).firstIndex(where: { $0 === boundary }) {
            returnBoundaryOffset = index + 1
        } else { returnBoundaryOffset = nil }
    }
    func returnTarget(for child: BrowserTab) -> BrowserTab? {
        guard let source, source !== child, !source.isDisposed, !source.closeRequested,
            source.profileID == child.profileID, source.page == .web,
            source.navigationID == sourceNavigationID, source.pageRevision == sourcePageRevision,
            let owner = source.store, owner.application === child.store?.application, owner.isOpenTab(source),
            owner.selectedProfileID == source.profileID,
            let view = source.existingWebView, view === sourceView, !view.isLoading,
            source.url == sourceURL, view.url == sourceURL, view.backForwardList.currentItem === entries.first,
            Array(view.backForwardList.backList.reversed()).map(ObjectIdentifier.init)
                == entries.dropFirst().map(ObjectIdentifier.init),
            view.backForwardList.forwardList.map(ObjectIdentifier.init) == sourceForwardItems.map(ObjectIdentifier.init)
        else { return nil }
        return source
    }
    func items(limit: Int) -> [WKBackForwardListItem] {
        guard limit > 0 else { return [] }
        var result = Array(entries.prefix(limit))
        if result.count < limit, let previous { result += previous.items(limit: limit - result.count) }
        return result
    }
    func destination(_ item: WKBackForwardListItem) -> (OpenerNavigationTrail, Int)? {
        if let index = entries.firstIndex(where: { $0 === item }) { return (self, index) }
        return previous?.destination(item)
    }
}

@MainActor enum NavigationHistory {
    static func items(_ tab: BrowserTab, backward: Bool) -> [WKBackForwardListItem] {
        guard !tab.isDisposed, tab.page == .web, tab.url != nil, let view = tab.existingWebView else { return [] }
        if backward {
            let native = Array(view.backForwardList.backList.reversed().prefix(30))
            return native + (tab.openerTrail?.items(limit: 30 - native.count) ?? [])
        }
        var entries = view.backForwardList.forwardList
        if let boundary = tab.openerBoundaryItem, let returning = tab.openerReturnItem {
            if view.backForwardList.currentItem === boundary { entries = [returning] }
            else if let index = entries.firstIndex(where: { $0 === boundary }) {
                entries = Array(entries.prefix(index + 1)) + [returning]
            }
        }
        return Array(entries.prefix(30))
    }
    @discardableResult static func go(_ tab: BrowserTab, to item: WKBackForwardListItem) -> WKNavigation? {
        guard !tab.isDisposed, !tab.closeRequested, tab.page == .web, tab.url != nil, let store = tab.store, store.isOpenTab(tab),
            let view = tab.existingWebView else { return nil }
        if item === tab.openerReturnItem, let trail = tab.openerReturnTrail {

            tab.openerTrail = OpenerNavigationTrail(view: view, previous: tab.openerTrail)
            tab.openerReturnTrail = trail.returning
            tab.openerReturnItem = trail.returning?.entries.first
            tab.openerBoundaryItem = nil
            return restore(tab, view: view, state: trail.state, offset: 0,
                boundaryOffset: trail.returnBoundaryOffset ?? 0)
        }
        if let (trail, index) = tab.openerTrail?.destination(item) {
            if index == 0, trail.returnTarget(for: tab) != nil {
                tab.pendingOpenerReturn = trail
                store.close(tab)
                return nil
            }
            return restoreOpenerHistory(tab, trail: trail, index: index)
        }
        guard (view.backForwardList.backList + view.backForwardList.forwardList).contains(where: { $0 === item })
        else { return nil }
        return view.go(to: item)
    }
    @discardableResult static func restoreOpenerHistory(_ tab: BrowserTab, trail: OpenerNavigationTrail,
        index: Int = 0) -> WKNavigation? {
        guard !tab.isDisposed, let view = tab.existingWebView else { return nil }
        tab.openerReturnTrail = OpenerNavigationTrail(view: view, previous: nil,
            returning: tab.openerReturnTrail, boundary: tab.openerBoundaryItem)
        tab.openerReturnItem = view.backForwardList.currentItem
        tab.openerTrail = trail.previous
        return restore(tab, view: view, state: trail.state, offset: index)
    }
    private static func restore(_ tab: BrowserTab, view: WKWebView, state: Any, offset: Int,
        boundaryOffset: Int = 0) -> WKNavigation? {
        tab.restoringOpenerHistory = true
        view.interactionState = state
        let entries = (view.backForwardList.currentItem.map { [$0] } ?? []) + view.backForwardList.backList.reversed()
        if tab.openerReturnTrail != nil {
            if boundaryOffset >= 0, entries.indices.contains(boundaryOffset) {
                tab.openerBoundaryItem = entries[boundaryOffset]
            } else {
                let forward = view.backForwardList.forwardList
                let index = -boundaryOffset - 1
                tab.openerBoundaryItem = forward.indices.contains(index) ? forward[index] : nil
            }
        }
        guard entries.indices.contains(offset) else {
            tab.restoringOpenerHistory = false
            tab.refreshNavigationAvailability()
            return nil
        }
        let navigation = view.go(to: entries[offset])

        DispatchQueue.main.async { [weak tab] in
            tab?.restoringOpenerHistory = false
            tab?.refreshNavigationAvailability()
        }
        return navigation
    }
    @discardableResult static func step(_ tab: BrowserTab, backward: Bool) -> WKNavigation? {
        guard let item = items(tab, backward: backward).first else { return nil }
        return go(tab, to: item)
    }
    private static var activePicker: NavigationHistoryPresenter?
    @discardableResult static func show(_ tab: BrowserTab, backward: Bool, anchor: NSView, rect: NSRect? = nil,
        preview: NavigationHistoryPresenter? = nil) -> NavigationHistoryPresenter? {
        let entries = items(tab, backward: backward)
        guard !entries.isEmpty, anchor.window != nil, tab.store?.selectedTab === tab else { return nil }
        activePicker?.close()
        let picker = preview ?? NavigationHistoryPresenter(tab: tab, entries: entries, backward: backward)
        activePicker = picker
        picker.onClose = { [weak picker] in
            if activePicker === picker { activePicker = nil }
        }
        picker.show(anchor: anchor, rect: rect)
        return picker
    }

}

struct NavigationHistoryButton: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    let backward: Bool
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> HistoryButton { HistoryButton() }
    func updateNSView(_ view: HistoryButton, context: Context) {
        view.store = store
        view.backward = backward
        view.isEnabled = store.selectedTab.map { !NavigationHistory.items($0, backward: backward).isEmpty } ?? false
        let icon: LoafIcon = backward ? .back : .forward
        view.image = (Golzheim.image(icon.rawValue, size: 16, weight: 220, fitInk: true)?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: icon.fallback, accessibilityDescription: nil)
        view.image?.isTemplate = true
        view.glyph.image = view.image
        view.contentTintColor = .labelColor
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.toolTip = backward ? "back (⌘[) · hold for history" : "forward (⌘]) · hold for history"
        view.setAccessibilityLabel(backward ? "back" : "forward")
        view.setAccessibilityHelp("Hold or right-click to choose a page from this tab's history.")
        view.refreshHover()
    }
    final class HistoryButton: NSButton {
        private final class Destination {
            weak var tab: BrowserTab?
            let entry: WKBackForwardListItem
            init(tab: BrowserTab, entry: WKBackForwardListItem) { self.tab = tab; self.entry = entry }
        }
        final class GlyphView: NSImageView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        let glyph = GlyphView()
        private(set) var hovered = false
        private var hoverTracking: NSTrackingArea?
        weak var store: BrowserStore?
        var backward = true
        private var openedHistory = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            isBordered = false
            imagePosition = .imageOnly
            setButtonType(.momentaryChange)
            target = self
            action = #selector(navigate)
            glyph.imageScaling = .scaleProportionallyUpOrDown
            glyph.contentTintColor = .labelColor
            glyph.setAccessibilityElement(false)
            addSubview(glyph)
        }
        required init?(coder: NSCoder) { fatalError("Not decoded") }
        override func layout() {
            super.layout()
            glyph.frame = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area); hoverTracking = area
            refreshHover()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshHover()
        }
        func refreshHover() {
            let inside: Bool
            if let window, NSApp.isActive, window.isVisible, !isHiddenOrHasHiddenAncestor {
                inside = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            } else {
                inside = false
            }
            guard hovered != inside else { return }
            hovered = inside
            needsDisplay = true
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {

            refreshHover()
            if hovered && isEnabled {
                NSColor.labelColor.withAlphaComponent(0.055).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            glyph.alphaValue = isEnabled ? (isHighlighted ? 0.65 : 1) : 0.5
        }
        @objc private func navigate() {
            guard !openedHistory, let tab = store?.selectedTab else { return }
            NavigationHistory.step(tab, backward: backward)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard isEnabled, let tab = store?.selectedTab else { return nil }
            let entries = NavigationHistory.items(tab, backward: backward)
            guard !entries.isEmpty else { return nil }
            let menu = NSMenu(title: backward ? "back history" : "forward history")
            menu.autoenablesItems = false
            for entry in entries {
                let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let item = NSMenuItem(title: title.isEmpty ? BrowserAddress.display(entry.url) : title,
                    action: #selector(chooseHistory(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Destination(tab: tab, entry: entry)
                item.toolTip = entry.url.absoluteString
                if let image = store?.application.favicons.cachedImage(for: entry.url,
                    privateID: store?.profile.privateMode == true ? tab.profileID : nil)?.copy() as? NSImage {
                    image.size = NSSize(width: 16, height: 16)
                    item.image = image
                }
                menu.addItem(item)
            }
            return menu
        }
        @objc private func chooseHistory(_ item: NSMenuItem) {
            guard let destination = item.representedObject as? Destination, let tab = destination.tab,
                store?.selectedTab === tab else { return }
            NavigationHistory.go(tab, to: destination.entry)
        }
        private func showHistory(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            openedHistory = true
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func mouseDown(with event: NSEvent) {
            openedHistory = false
            if event.modifierFlags.contains(.control) {
                showHistory(with: event)
                openedHistory = false
                return
            }
            let timer = Timer(timeInterval: 0.38, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                    self?.showHistory(with: event)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate(); openedHistory = false }
            super.mouseDown(with: event)
        }
        override func rightMouseDown(with event: NSEvent) { showHistory(with: event); openedHistory = false }
    }
}

nonisolated struct NavigationPullIntent {
    private var direction: Bool?
    private var retreat: CGFloat = 0
    private var advance: CGFloat = 0
    private(set) var cancelled = false
    mutating func update(delta: CGFloat, backward: Bool) {
        if direction == nil { direction = backward }
        guard direction == backward else { cancelled = true; advance = 0; return }
        let outward = backward ? delta : -delta
        if outward < 0 {
            advance = 0
            retreat -= outward
            if retreat >= 10 { cancelled = true }
        } else {
            advance += outward
            if advance >= 18 { retreat = 0; cancelled = false }
        }
    }
}

nonisolated struct NavigationPickerDismissIntent {
    private var retreat: CGFloat = 0
    mutating func update(x: CGFloat, y: CGFloat, backward: Bool) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        let reverse = backward ? -x : x
        if reverse > 0, abs(x) > abs(y) * 1.5 {
            retreat += reverse
        } else {
            retreat = max(0, retreat - max(abs(y), max(0, -reverse)))
        }
        return retreat >= 96
    }
}

nonisolated enum PageNavigationScrollEligibility {
    static let script = """
        const scrollable = value => /^(auto|scroll|overlay)$/.test(value);
        const clipped = value => value === 'hidden' || value === 'clip';
        const hasHorizontalScroll = (doc, x, y, depth = 0) => {
            if (depth > 8) return true;
            const root = doc.documentElement;
            if (!root) return false;
            const body = doc.body;
            const scrolling = doc.scrollingElement || root;
            const style = el => doc.defaultView.getComputedStyle(el);
            let el = doc.elementFromPoint(x, y);
            const hits = new Set();
            while (el?.shadowRoot && !hits.has(el)) {
                hits.add(el);
                const inner = el.shadowRoot.elementFromPoint?.(x, y);
                if (!inner || inner === el) break;
                el = inner;
            }
            const seen = new Set();
            while (el && !seen.has(el)) {
                seen.add(el);
                if (el.tagName === 'IFRAME') {
                    let child = null;
                    try { child = el.contentDocument; } catch (_) {}
                    if (child?.documentElement) {
                        const rect = el.getBoundingClientRect();
                        const scaleX = rect.width > 0 ? el.offsetWidth / rect.width : 1;
                        const scaleY = rect.height > 0 ? el.offsetHeight / rect.height : 1;
                        if (hasHorizontalScroll(child, (x - rect.left) * scaleX - el.clientLeft,
                            (y - rect.top) * scaleY - el.clientTop, depth + 1)) return true;
                    } else if (!clipped(style(el).overflowX)
                        && el.getAttribute('scrolling')?.toLowerCase() !== 'no') {
                        return true;
                    }
                }
                if (el !== root && el !== scrolling && scrollable(style(el).overflowX)
                    && el.scrollWidth > el.clientWidth + 2) return true;
                el = el.parentElement || el.getRootNode()?.host;
            }
            const rootOverflow = style(root).overflowX;
            const viewportOverflow = rootOverflow === 'visible' && body ? style(body).overflowX : rootOverflow;
            if (clipped(viewportOverflow)) return false;
            return scrolling.scrollWidth > (root.clientWidth || doc.defaultView.innerWidth) + 2;
        };
        return hasHorizontalScroll(document, x, y);
        """
}

@MainActor final class PageNavigationSwipe: ObservableObject {
    private weak var view: LoafWebView?
    private var monitor: Any?
    private var gesture = SidebarProfileGesture()
    private var intent = NavigationPullIntent()
    private var active = false
    private var mayNavigate = false
    private var token = UUID()
    private var openedHistory = false
    private(set) var historyPicker: NavigationHistoryPresenter?
    private(set) var preview: NavigationHistoryPresenter?
    private var verticalPull: CGFloat = 0
    private var hintStartedAt: TimeInterval?
    private var hintExpansion: Task<Void, Never>?
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var backward = true
    var destinationStore: BrowserStore? { view?.browserTab?.store }
    var destination: WKBackForwardListItem? {
        guard let tab = view?.browserTab else { return nil }
        if backward { return view?.backForwardList.backItem ?? tab.openerTrail?.entries.first }
        return NavigationHistory.items(tab, backward: false).first
    }
    init(view: LoafWebView) { self.view = view }
    func attach() {
        stop()
        guard view?.window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == true }
            return consumed ? nil : event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        historyPicker?.close()
        historyPicker = nil
        finish()
        gesture.reset()
    }
    private func finish() {
        active = false
        openedHistory = false
        token = UUID()
        dismissPreview()
        progress = 0
        verticalPull = 0
    }
    private func dismissPreview() {
        hintExpansion?.cancel()
        hintExpansion = nil
        hintStartedAt = nil
        preview?.close(restoreFocus: false)
        preview = nil
    }
    private func beginHistory(_ tab: BrowserTab, in view: LoafWebView) -> Bool {
        guard let preview, let content = preview.contentView else { return false }
        let rect = content.convert(content.bounds, to: view)
        historyPicker = NavigationHistory.show(tab, backward: backward, anchor: view, rect: rect, preview: preview)
        guard historyPicker != nil else { return false }
        openedHistory = true
        self.preview = nil
        hintExpansion?.cancel()
        hintExpansion = nil
        hintStartedAt = nil
        return true
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, let view,
            event.window === view.window || historyPicker?.owns(event) == true,
            let tab = view.browserTab, !tab.isDisposed, tab.store?.selectedTab === tab,
            view.fullscreenState == .notInFullscreen, !tab.pointerCapturePosition.captured
        else { return false }
        if view.magnification > 1.0001 {
            finish()
            gesture.reset()
            return false
        }
        if openedHistory || historyPicker?.isShown == true {
            guard let historyPicker, historyPicker.isShown else {
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { finish() }
                return true
            }
            if !event.momentumPhase.isEmpty { return true }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                active = true
                historyPicker.settleScroll()
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if event.phase.contains(.cancelled) { historyPicker.close() }
                else { historyPicker.chooseSelection() }
                finish()
                return true
            }
            historyPicker.scrub(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY)
            return true
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            guard WebCursorOwnership.webView(for: event, in: view.window) === view,
                view.canGoBack || view.canGoForward else { return false }
            finish()
            historyPicker?.close()
            historyPicker = nil
            gesture.reset()
            intent = NavigationPullIntent()
            active = true
            openedHistory = false
            mayNavigate = false
            let current = token
            let point = view.convert(event.locationInWindow, from: nil)
            let y = view.isFlipped ? point.y : view.bounds.height - point.y
            view.callAsyncJavaScript(PageNavigationScrollEligibility.script,
                arguments: ["x": point.x / view.pageZoom, "y": y / view.pageZoom], in: nil, in: .defaultClient
            ) { [weak self] result in
                guard let self, self.token == current else { return }
                if case .success(let scrollable) = result { self.mayNavigate = scrollable as? Bool == false }
            }
        }
        guard active || !event.momentumPhase.isEmpty else { return false }
        let result = gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            phase: event.phase, momentum: event.momentumPhase, startsInside: active,
            index: view.canGoBack ? 1 : 0, count: 1 + (view.canGoBack ? 1 : 0) + (view.canGoForward ? 1 : 0), stride: 136)
        if !event.momentumPhase.isEmpty { return result.consumed && mayNavigate }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if event.phase.contains(.cancelled) { historyPicker?.close() }
            else { historyPicker?.chooseSelection() }
            let commit = mayNavigate && !openedHistory && !intent.cancelled ? result.direction : nil
            let consumed = result.consumed && mayNavigate
            finish()
            if let commit { NavigationHistory.step(tab, backward: commit < 0) }
            return consumed
        }
        guard mayNavigate, result.consumed else { return false }


        if preview != nil, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            verticalPull += event.scrollingDeltaY
            if abs(verticalPull) >= 12, beginHistory(tab, in: view) {
                historyPicker?.scrub(horizontal: 0, vertical: verticalPull)
                verticalPull = 0
            }
            return true
        }
        verticalPull = 0
        if preview == nil, result.translation != 0 { backward = result.translation < 0 }
        intent.update(delta: event.scrollingDeltaX, backward: backward)
        if intent.cancelled {
            historyPicker?.close(); historyPicker = nil
            openedHistory = false
            dismissPreview()
            progress = 0
            return true
        }
        guard result.translation != 0 else { progress = 0; return true }
        progress = min(1, abs(result.translation) / 136)
        let frame = view.frame
        let width = min(NavigationHistoryLayout.width, max(92, frame.width - 36))
        let hintFrame = NSRect(x: backward ? frame.minX + 6 : frame.maxX - width - 6,
            y: frame.midY - 40, width: width, height: 80)
        if preview == nil, view.superview != nil {
            let entries = NavigationHistory.items(tab, backward: backward)
            guard !entries.isEmpty else { return true }
            let preview = NavigationHistoryPresenter(tab: tab, entries: entries, backward: backward, preview: true)
            self.preview = preview
            hintStartedAt = ProcessInfo.processInfo.systemUptime
            preview.showPreview(over: view, frame: hintFrame)
            let motion = preview.selection.motion
            let current = token
            hintExpansion = Task { @MainActor [weak self, weak motion] in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let self, let motion,
                    self.active, self.token == current, self.preview?.selection.motion === motion,
                    !self.intent.cancelled, self.progress > 0 else { return }
                motion.expand()
            }
        }
        if let hintStartedAt, ProcessInfo.processInfo.systemUptime - hintStartedAt >= 0.16,
            progress > 0 { preview?.selection.motion.expand() }
        preview?.selection.motion.float(horizontal: event.scrollingDeltaX)
        preview?.positionPreview(hintFrame)
        return true
    }
}

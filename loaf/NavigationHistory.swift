import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor enum NavigationHistory {
    static func items(_ tab: BrowserTab, backward: Bool) -> [WKBackForwardListItem] {
        guard !tab.isDisposed, let view = tab.existingWebView else { return [] }
        return Array((backward ? Array(view.backForwardList.backList.reversed()) : view.backForwardList.forwardList).prefix(30))
    }
    static func go(_ tab: BrowserTab, to item: WKBackForwardListItem) {
        guard !tab.isDisposed, let store = tab.store, store.selectedTab === tab,
            let view = tab.existingWebView,
            (view.backForwardList.backList + view.backForwardList.forwardList).contains(where: { $0 === item })
        else { return }
        view.go(to: item)
    }
    static func step(_ tab: BrowserTab, backward: Bool) {
        guard let item = items(tab, backward: backward).first else { return }
        go(tab, to: item)
    }
    private static var activePicker: NavigationHistoryPresenter?
    @discardableResult static func show(_ tab: BrowserTab, backward: Bool, anchor: NSView, rect: NSRect? = nil) -> NavigationHistoryPresenter? {
        let entries = items(tab, backward: backward)
        guard !entries.isEmpty, anchor.window != nil, tab.store?.selectedTab === tab else { return nil }
        activePicker?.close()
        let picker = NavigationHistoryPresenter(tab: tab, entries: entries, backward: backward)
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
        view.image = Golzheim.image(icon.rawValue, size: 16, weight: 220, fitInk: true)?.copy() as? NSImage
        view.image?.isTemplate = true
        view.contentTintColor = .labelColor
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.toolTip = backward ? "back (⌘[) · hold for history" : "forward (⌘]) · hold for history"
        view.setAccessibilityLabel(backward ? "back" : "forward")
        view.setAccessibilityHelp("Hold or right-click to choose a page from this tab's history.")
    }
    final class HistoryButton: NSButton {
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
        }
        required init?(coder: NSCoder) { fatalError("Not decoded") }
        @objc private func navigate() {
            guard !openedHistory, let tab = store?.selectedTab else { return }
            NavigationHistory.step(tab, backward: backward)
        }
        func showHistory() {
            guard isEnabled, let tab = store?.selectedTab else { return }
            openedHistory = true
            NavigationHistory.show(tab, backward: backward, anchor: self)
        }
        override func mouseDown(with event: NSEvent) {
            openedHistory = false
            let timer = Timer(timeInterval: 0.38, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                    self?.showHistory()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate(); openedHistory = false }
            super.mouseDown(with: event)
        }
        override func rightMouseDown(with event: NSEvent) { showHistory(); openedHistory = false }
    }
}

@MainActor final class PageNavigationSwipe: ObservableObject {
    private weak var view: LoafWebView?
    private var monitor: Any?
    private var gesture = SidebarProfileGesture()
    private var active = false
    private var mayNavigate = false
    private var token = UUID()
    private var hold: Task<Void, Never>?
    private var openedHistory = false
    private(set) var historyPicker: NavigationHistoryPresenter?
    private var historyVertical: CGFloat = 0
    private var historyWasScrubbed = false
    private var overlay: NSHostingView<NavigationSwipeHint>?
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var backward = true
    init(view: LoafWebView) { self.view = view }
    func attach() {
        stop()
        guard view?.window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true ? nil : event }
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
        token = UUID()
        hold?.cancel()
        hold = nil
        overlay?.removeFromSuperview()
        overlay = nil
        progress = 0
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, let view, event.window === view.window,
            let tab = view.browserTab, !tab.isDisposed, tab.store?.selectedTab === tab,
            view.fullscreenState == .notInFullscreen, !tab.pointerCapturePosition.captured
        else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            guard WebCursorOwnership.webView(for: event, in: view.window) === view,
                view.canGoBack || view.canGoForward else { return false }
            finish()
            historyPicker?.close()
            historyPicker = nil
            gesture.reset()
            active = true
            openedHistory = false
            historyVertical = 0
            historyWasScrubbed = false
            mayNavigate = false
            let current = token
            let point = view.convert(event.locationInWindow, from: nil)
            let y = view.isFlipped ? point.y : view.bounds.height - point.y
            view.callAsyncJavaScript("""
                let el = document.elementFromPoint(x, y);
                while (el) {
                    if (el.tagName === 'IFRAME') return true;
                    const style = getComputedStyle(el);
                    if (/auto|scroll/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 2) return true;
                    el = el.parentElement;
                }
                return document.documentElement.scrollWidth > innerWidth + 2;
                """, arguments: ["x": point.x, "y": y], in: nil, in: .defaultClient) { [weak self] result in
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
            else if historyWasScrubbed { historyPicker?.chooseSelection() }
            let commit = mayNavigate && !openedHistory ? result.direction : nil
            let consumed = result.consumed && mayNavigate
            finish()
            if let commit { NavigationHistory.step(tab, backward: commit < 0) }
            return consumed
        }
        if openedHistory, let historyPicker {
            historyVertical += event.scrollingDeltaY
            if abs(historyVertical) >= 18 {
                historyPicker.move(by: historyVertical > 0 ? -1 : 1)
                historyWasScrubbed = true
                historyVertical = 0
            }
            return true
        }
        guard mayNavigate, result.consumed, result.translation != 0 else { return false }
        backward = result.translation < 0
        progress = min(1, abs(result.translation) / 136)
        if overlay == nil, let parent = view.superview {
            let hint = NavigationHintHost(rootView: NavigationSwipeHint(swipe: self))
            hint.sizingOptions = []
            parent.addSubview(hint, positioned: .above, relativeTo: view)
            overlay = hint
        }
        if let overlay {
            let frame = view.frame
            overlay.frame = .init(x: backward ? frame.minX + 12 : frame.maxX - 64,
                y: frame.midY - 26, width: 52, height: 52)
        }
        if progress <= 0.2 { hold?.cancel(); hold = nil }
        if hold == nil, progress > 0.2 {
            let current = token
            hold = Task { @MainActor [weak self, weak tab] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, let tab, self.token == current,
                    self.active, let anchor = self.overlay, let view = self.view,
                    self.progress > 0.2 else { return }
                self.historyPicker = NavigationHistory.show(tab, backward: self.backward,
                    anchor: view, rect: anchor.convert(anchor.bounds, to: view))
                self.openedHistory = self.historyPicker != nil
            }
        }
        return true
    }
}

private final class NavigationHintHost: NSHostingView<NavigationSwipeHint> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct NavigationSwipeHint: View {
    @ObservedObject var swipe: PageNavigationSwipe
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GolzheimIcon(icon: swipe.backward ? .back : .forward, size: 22, weight: 260)
            .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            .scaleEffect(reduceMotion ? 1 : 0.76 + swipe.progress * 0.28)
            .offset(x: reduceMotion ? 0 : (swipe.backward ? 1 : -1) * swipe.progress * 6)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7), value: swipe.progress)
            .opacity(min(1, swipe.progress * 3)).frame(width: 52, height: 52)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

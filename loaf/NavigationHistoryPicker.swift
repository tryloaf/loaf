import AppKit
import Combine
import SwiftUI
import WebKit

nonisolated enum NavigationHistoryLayout {
    static let width: CGFloat = 300
    static let height: CGFloat = 80
}

@MainActor final class NavigationBubbleMotion: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var drift: CGFloat = 0
    @Published private(set) var expanded = false
    private var horizontal: CGFloat = 0
    private var dismissed = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func appear() {
        guard !dismissed, !visible else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.22)) { visible = true }
    }
    func disappear() {
        dismissed = true
        withAnimation(.easeIn(duration: 0.16)) { visible = false; drift = 0 }
    }
    func expand() {
        guard !dismissed, !expanded else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
            expanded = true
        }
    }
    func float(horizontal delta: CGFloat) {
        guard !dismissed, !reduceMotion, delta.isFinite else { return }
        horizontal = min(160, max(-160, horizontal + delta))
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.94, blendDuration: 0.04)) {
            drift = 8 * tanh(horizontal / 65)
        }
    }
    func settle() {
        horizontal = 0
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.94)) { drift = 0 }
    }
}

struct NavigationBubbleTransition: ViewModifier {
    @ObservedObject var motion: NavigationBubbleMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(motion.visible ? 1 : 0)
            .blur(radius: reduceMotion || motion.visible ? 0 : 4)
            .scaleEffect(reduceMotion || motion.visible ? 1 : 0.97)
            .offset(x: reduceMotion ? 0 : motion.drift)
            .allowsHitTesting(motion.visible)
            .onAppear { motion.appear() }
    }
}

nonisolated enum NavigationHistoryDetents {
    static let pointsPerItem: CGFloat = 72
    static let captureRadius: CGFloat = 0.22
    static func position(_ raw: CGFloat) -> CGFloat {
        let center = raw.rounded()
        let offset = raw - center
        let travel = max(0, abs(offset) - captureRadius) / (0.5 - captureRadius)

        let eased = travel * travel * (2 - travel)
        return center + (offset < 0 ? -0.5 : 0.5) * eased
    }
}

@MainActor final class NavigationHistorySelection: ObservableObject {
    let motion = NavigationBubbleMotion()
    @Published var browsing: Bool
    weak var tab: BrowserTab?
    let entries: [WKBackForwardListItem]
    let backward: Bool
    @Published var index = 0
    @Published private(set) var pull: CGFloat = 0
    var position: CGFloat { NavigationHistoryDetents.position(CGFloat(index) + pull) }
    var centered: Bool { abs(position - CGFloat(index)) < 0.025 }
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool, preview: Bool = false) {
        self.tab = tab; self.entries = entries; self.backward = backward
        browsing = !preview
        if !preview { motion.expand() }
    }
    func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        let next = min(entries.count - 1, max(0, index + delta))
        guard next != index else { return }
        index = next
        pull = 0
        LoafHaptics.perform(enabled: tab?.store?.preferences.haptics != false)
    }
    @discardableResult func scrub(_ delta: CGFloat, ended: Bool = false) -> Bool {
        if ended { pull = 0; return false }
        guard delta.isFinite, !entries.isEmpty else { return false }
        let previous = index
        let nextPosition = min(CGFloat(entries.count - 1), max(0, CGFloat(index) + pull - delta / NavigationHistoryDetents.pointsPerItem))
        let nextIndex = Int(nextPosition.rounded())
        if nextIndex != index {
            index = nextIndex
            LoafHaptics.perform(enabled: tab?.store?.preferences.haptics != false)
        }
        pull = nextPosition - CGFloat(index)
        return previous != index
    }
    var tint: Color {
        guard let tab, let store = tab.store else { return .accentColor }
        return profileTint(store.profileFor(tab.profileID))
    }
}

@MainActor final class NavigationHistoryPresenter: NSObject {
    enum ScrubResult { case changed, unchanged, dismissed }
    private final class HistoryHost<Content: View>: NSHostingView<Content> {
        var interactive = true
        var scrolled: ((NSEvent) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
        override func scrollWheel(with event: NSEvent) { scrolled?(event) }
    }
    private final class HistoryPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    let selection: NavigationHistorySelection
    private let panel = HistoryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var observations = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var scrollEnd: Task<Void, Never>?
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var closed = false
    private var host: HistoryHost<NavigationHistoryPicker>?
    private var dismissIntent = NavigationPickerDismissIntent()
    var onClose: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool, preview: Bool = false) {
        selection = NavigationHistorySelection(tab: tab, entries: entries, backward: backward, preview: preview)
        super.init()
        selection.choose = { [weak self] in self?.chooseSelection() }
        selection.dismiss = { [weak self] in self?.close() }
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        tab.$isDisposed.dropFirst().sink { [weak self] disposed in if disposed { self?.close(restoreFocus: false) } }.store(in: &observations)
        tab.store?.objectWillChange.sink { [weak self, weak tab] in
            DispatchQueue.main.async {
                guard let self else { return }
                if tab?.store?.selectedTab !== tab { self.close(restoreFocus: false) }
            }
        }.store(in: &observations)
    }
    var isShown: Bool { !closed && panel.isVisible }
    var contentView: NSView? { host }
    var contentSize: NSSize { panel.frame.size }
    private func makeHost(appearance: NSAppearance) -> HistoryHost<NavigationHistoryPicker> {
        let host = HistoryHost(rootView: NavigationHistoryPicker(selection: selection))
        host.appearance = appearance
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        self.host = host
        return host
    }
    func showPreview(over view: NSView, frame: NSRect) {
        guard !closed, let parent = view.superview, let window = view.window else { return }
        self.parent = window
        let host = host ?? makeHost(appearance: view.effectiveAppearance)
        host.interactive = false
        host.frame = frame
        parent.addSubview(host, positioned: .above, relativeTo: view)
    }
    func positionPreview(_ frame: NSRect) { host?.frame = frame }
    func show(anchor: NSView, rect: NSRect? = nil) {
        guard !closed, let window = anchor.window else { return }
        parent = window
        previousResponder = window.firstResponder
        panel.appearance = anchor.effectiveAppearance
        let size = host?.frame.size ?? NSSize(width: NavigationHistoryLayout.width, height: NavigationHistoryLayout.height)
        let host = host ?? makeHost(appearance: anchor.effectiveAppearance)
        host.interactive = true
        selection.browsing = true
        selection.motion.expand()
        host.scrolled = { [weak self] event in
            guard let self, event.momentumPhase.isEmpty else { return }
            self.scrollEnd?.cancel()
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.settleScroll(); return }
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 4
            if self.scrub(horizontal: event.scrollingDeltaX * factor,
                vertical: event.scrollingDeltaY * factor) == .dismissed { return }
            if event.phase.isEmpty {
                self.scrollEnd = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    self?.settleScroll()
                }
            }
        }
        host.removeFromSuperview()
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let point = window.convertToScreen(anchor.convert(rect ?? anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? point
        var y = rect == nil ? point.minY - 6 - size.height : point.midY - size.height / 2
        if y < screen.minY + 8, point.maxY + 6 + size.height <= screen.maxY - 8 { y = point.maxY + 6 }
        let frame = NSRect(x: max(screen.minX + 8, min(point.midX - size.width / 2, screen.maxX - size.width - 8)),
            y: max(screen.minY + 8, min(y, screen.maxY - size.height - 8)), width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                self?.close(restoreFocus: false)
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification).sink { [weak self] _ in
            self?.close(restoreFocus: false)
        }.store(in: &observations)
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close(restoreFocus: false) }
            }
            return event
        }
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
    }
    func close(restoreFocus: Bool = true) {
        guard !closed else { return }
        closed = true
        scrollEnd?.cancel()
        scrollEnd = nil
        let wasKey = panel.isKeyWindow
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        observations.removeAll()
        panel.ignoresMouseEvents = true
        selection.choose = nil
        selection.dismiss = nil
        selection.motion.disappear()
        if !restoreFocus, wasKey { panel.resignKey() }
        if restoreFocus, wasKey, let parent, parent.isVisible {
            parent.makeKey()
            if let view = previousResponder as? NSView, view.window === parent { parent.makeFirstResponder(view) }
        }
        onClose?()

        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(180))
            parent?.removeChildWindow(panel)
            panel.close()
            panel.contentView = nil
            host?.removeFromSuperview()
            host = nil
        }
    }
    func move(by delta: Int) { selection.move(by: delta) }
    func settleScroll() {
        guard !closed else { return }
        dismissIntent = NavigationPickerDismissIntent()
        selection.motion.settle()
        let motion: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .spring(response: 0.24, dampingFraction: 0.94)
        withAnimation(motion) { selection.scrub(0, ended: true) }
    }
    @discardableResult func scrub(_ delta: CGFloat) -> Bool { selection.scrub(delta) }
    func owns(_ event: NSEvent) -> Bool { !closed && event.window === panel }
    @discardableResult func scrub(horizontal: CGFloat, vertical: CGFloat) -> ScrubResult {
        guard !closed else { return .dismissed }
        selection.motion.float(horizontal: horizontal)
        if dismissIntent.update(x: horizontal, y: vertical, backward: selection.backward) {
            close()
            return .dismissed
        }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .interactiveSpring(response: 0.16, dampingFraction: 1, blendDuration: 0.04)
        let changed = withAnimation(animation) { selection.scrub(vertical) }
        return changed ? .changed : .unchanged
    }
    func chooseSelection() {
        guard !closed else { return }
        guard let tab = selection.tab, selection.entries.indices.contains(selection.index) else { close(); return }
        NavigationHistory.go(tab, to: selection.entries[selection.index])
        close()
    }
}

struct NavigationDestinationPill: View, Animatable {
    let entry: WKBackForwardListItem?
    let backward: Bool
    var store: BrowserStore?
    var positionLabel: String? = nil
    var historyEntries: [WKBackForwardListItem] = []
    var historyPosition: CGFloat? = nil
    var expansion: CGFloat = 1
    var selected = false
    var animatableData: CGFloat {
        get { historyPosition ?? 0 }
        set { if historyPosition != nil { historyPosition = newValue } }
    }
    private var highlighted: Bool {
        selected && (reduceMotion || historyPosition.map { abs($0 - $0.rounded()) < 0.025 } != false)
    }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { store.map { profileTint($0.profile) } ?? .accentColor }
    var body: some View {
        GeometryReader { geometry in
            let width = max(56, geometry.size.width)
            let revealedWidth = 56 + (width - 56) * expansion
            let edge: Alignment = backward ? .leading : .trailing
            HStack(spacing: 10) {
                if backward { arrow }
                destinationWheel
                    .offset(x: backward ? 0 : width - revealedWidth)
                    .clipped()
                    .opacity(expansion)
                    .blur(radius: reduceMotion ? 0 : (1 - expansion) * 4)
                if !backward { arrow }
            }
            .padding(.horizontal, 13)
            .frame(width: width, height: 56)
            .frame(width: revealedWidth, alignment: edge)
            .background {
                ZStack {
                    if reduceTransparency { Capsule().fill(Color(nsColor: .windowBackgroundColor)) }
                    else { Capsule().fill(.regularMaterial) }
                    Capsule().fill(Color.primary.opacity(0.12))
                        .padding(4)
                        .opacity(highlighted ? 1 : 0)
                        .animation(nil, value: highlighted)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.18)))
            .contentShape(Capsule())
            .frame(maxWidth: .infinity, alignment: edge)
        }.frame(height: 56)
    }
    private var arrow: some View {
        GolzheimIcon(icon: backward ? .back : .forward, size: 18, weight: 260)
            .frame(width: 30, height: 30)
    }
    private var destinationWheel: some View {
        ZStack {
            if let position = historyPosition, !historyEntries.isEmpty, !reduceMotion {
                let center = min(historyEntries.count - 1, max(0, Int(position.rounded())))
                ForEach(max(0, center - 1)...min(historyEntries.count - 1, center + 1), id: \.self) { index in
                    let distance = CGFloat(index) - position
                    let angle = Double(distance) * 14
                    let radians = angle * .pi / 180
                    NavigationDestinationContent(entry: historyEntries[index], backward: backward, store: store,
                        positionLabel: "\(index + 1) / \(historyEntries.count)")
                        .rotationEffect(.degrees(backward ? angle : -angle))
                        .offset(x: (backward ? -1 : 1) * (1 - cos(radians)) * 300,
                            y: sin(radians) * 300)
                        .opacity(max(0, 1 - abs(distance)))
                }
            } else {
                NavigationDestinationContent(entry: entry, backward: backward, store: store,
                    positionLabel: positionLabel)
            }
        }.frame(maxWidth: .infinity).frame(height: 56).clipped()
    }
}

private struct NavigationDestinationContent: View {
    let entry: WKBackForwardListItem?
    let backward: Bool
    var store: BrowserStore?
    var positionLabel: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            if let entry, let store {
                if let image = store.application.favicons.cachedImage(for: entry.url,
                    privateID: store.profile.privateMode ? store.selectedProfileID : nil) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else { GolzheimIcon(icon: .globe, size: 20).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry?.url.host ?? "page")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry?.url.host ?? (backward ? "back" : "forward"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let positionLabel {
                        Spacer(minLength: 0)
                        Text(positionLabel).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 56)
    }
}

struct NavigationHistoryPicker: View {
    @ObservedObject var selection: NavigationHistorySelection
    @ObservedObject private var bubbleMotion: NavigationBubbleMotion
    init(selection: NavigationHistorySelection) {
        self.selection = selection
        bubbleMotion = selection.motion
    }
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.94) }
    var body: some View {
        VStack(spacing: 8) {
            if selection.entries.indices.contains(selection.index) {
                Button { selection.choose?() } label: {
                    NavigationDestinationPill(entry: selection.entries[selection.index], backward: selection.backward,
                        store: selection.tab?.store,
                        positionLabel: selection.browsing ? "\(selection.index + 1) / \(selection.entries.count)" : nil,
                        historyEntries: selection.browsing ? selection.entries : [],
                        historyPosition: selection.browsing ? selection.position : nil,
                        expansion: bubbleMotion.expanded ? 1 : 0,
                        selected: selection.browsing && bubbleMotion.visible)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .modifier(NavigationBubbleTransition(motion: selection.motion))
                }.buttonStyle(.plain)
                    .accessibilityLabel((selection.backward ? "back to " : "forward to ")
                        + (selection.entries[selection.index].title ?? selection.entries[selection.index].url.absoluteString))
            }

        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .focusable(selection.browsing).focused($focused).focusEffectDisabled()
        .onAppear { focused = selection.browsing }
        .onChange(of: selection.browsing) { _, browsing in focused = browsing }
        .accessibilityHidden(!selection.browsing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selection.backward ? "back history" : "forward history")
        .accessibilityValue("\(selection.index + 1) of \(selection.entries.count)")
        .help("scroll or use the arrow keys to choose a page; click or press return to open it")
        .accessibilityAdjustableAction { direction in
            withAnimation(motion) { selection.move(by: direction == .increment ? 1 : -1) }
        }
        .onKeyPress(.upArrow) { withAnimation(motion) { selection.move(by: -1) }; return .handled }
        .onKeyPress(.downArrow) { withAnimation(motion) { selection.move(by: 1) }; return .handled }
        .onKeyPress(.return) { selection.choose?(); return .handled }
        .onKeyPress(.escape) { selection.dismiss?(); return .handled }
    }
}

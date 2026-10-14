import AppKit
import Combine
import SwiftUI
import WebKit

nonisolated enum NavigationHistoryLayout {
    static let width: CGFloat = 260
    static let inset: CGFloat = 8
    static let corner: CGFloat = 16
    static let selectionCorner = corner - inset
    static let maximumHeight: CGFloat = 360
}

@MainActor final class NavigationHistorySelection: ObservableObject {
    weak var tab: BrowserTab?
    let entries: [WKBackForwardListItem]
    let backward: Bool
    @Published var index = 0
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool) {
        self.tab = tab; self.entries = entries; self.backward = backward
    }
    func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        index = min(entries.count - 1, max(0, index + delta))
    }
    var tint: Color {
        guard let tab, let store = tab.store else { return .accentColor }
        return profileTint(store.profileFor(tab.profileID))
    }
}

@MainActor final class NavigationHistoryPresenter: NSObject {
    private final class HistoryPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    let selection: NavigationHistorySelection
    private let panel = HistoryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var observations = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var closed = false
    var onClose: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool) {
        selection = NavigationHistorySelection(tab: tab, entries: entries, backward: backward)
        super.init()
        selection.choose = { [weak self] in self?.chooseSelection() }
        selection.dismiss = { [weak self] in self?.close() }
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
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
    var isShown: Bool { panel.isVisible }
    var contentView: NSView? { panel.contentView }
    var contentSize: NSSize { panel.frame.size }
    func show(anchor: NSView, rect: NSRect? = nil) {
        guard !closed, let window = anchor.window else { return }
        parent = window
        previousResponder = window.firstResponder
        panel.appearance = anchor.effectiveAppearance
        let scheme: ColorScheme = anchor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        // Measure the same rows, at the same width and appearance, that the user will see.
        let measure = NSHostingView(rootView: NavigationHistoryRows(selection: selection)
            .frame(width: NavigationHistoryLayout.width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme))
        measure.appearance = panel.appearance
        let size = NSSize(width: NavigationHistoryLayout.width,
            height: min(NavigationHistoryLayout.maximumHeight, ceil(measure.fittingSize.height)))
        let host = NSHostingView(rootView: NavigationHistoryPicker(selection: selection).environment(\.colorScheme, scheme))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let surface = NSVisualEffectView(frame: host.frame)
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = NavigationHistoryLayout.corner
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        surface.addSubview(host)
        panel.contentView = surface
        let point = window.convertToScreen(anchor.convert(rect ?? anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? point
        var y = point.minY - 6 - size.height
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
        let wasKey = panel.isKeyWindow
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        observations.removeAll()
        parent?.removeChildWindow(panel)
        panel.close()
        panel.contentView = nil
        if restoreFocus, wasKey, let parent, parent.isVisible {
            parent.makeKey()
            if let view = previousResponder as? NSView, view.window === parent { parent.makeFirstResponder(view) }
        }
        onClose?()
    }
    func move(by delta: Int) { selection.move(by: delta) }
    func chooseSelection() {
        guard let tab = selection.tab, selection.entries.indices.contains(selection.index) else { close(); return }
        NavigationHistory.go(tab, to: selection.entries[selection.index])
        close()
    }
}

struct NavigationHistoryRows: View {
    @ObservedObject var selection: NavigationHistorySelection
    @Namespace private var bubble
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.73) }
    var body: some View {
        VStack(spacing: 4) {
            ForEach(selection.entries.indices, id: \.self) { index in
                let entry = selection.entries[index]
                Button { selection.index = index; selection.choose?() } label: {
                    HStack(alignment: .center, spacing: 8) {
                        historyIcon(entry).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url.host ?? "page")
                                .font(.system(size: 12, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Text(entry.url.host ?? entry.url.scheme ?? "page")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal, 8).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if selection.index == index {
                                RoundedRectangle(cornerRadius: NavigationHistoryLayout.selectionCorner)
                                    .fill(selection.tint.opacity(0.16))
                                    .overlay(RoundedRectangle(cornerRadius: NavigationHistoryLayout.selectionCorner)
                                        .strokeBorder(selection.tint.opacity(0.28)))
                                    .matchedGeometryEffect(id: "selection", in: bubble)
                            }
                        }.contentShape(RoundedRectangle(cornerRadius: NavigationHistoryLayout.selectionCorner))
                }.buttonStyle(LoafButtonStyle()).id(index)
                    .onHover { inside in if inside { withAnimation(motion) { selection.index = index } } }
                    .accessibilityValue(selection.index == index ? "selected" : "")
            }
        }.padding(NavigationHistoryLayout.inset).animation(motion, value: selection.index)
    }
    @ViewBuilder private func historyIcon(_ entry: WKBackForwardListItem) -> some View {
        if let tab = selection.tab, let store = tab.store,
            let image = store.application.favicons.cachedImage(for: entry.url,
                privateID: store.profileFor(tab.profileID).privateMode ? tab.profileID : nil) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else { GolzheimIcon(icon: .globe, size: 16).foregroundStyle(.secondary) }
    }
}

struct NavigationHistoryPicker: View {
    @ObservedObject var selection: NavigationHistorySelection
    @State private var appeared = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.73) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { NavigationHistoryRows(selection: selection) }.scrollIndicators(.hidden)
                .onChange(of: selection.index) { _, index in withAnimation(motion) { proxy.scrollTo(index) } }
        }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; withAnimation(motion) { appeared = true } }
        .onKeyPress(.upArrow) { withAnimation(motion) { selection.move(by: -1) }; return .handled }
        .onKeyPress(.downArrow) { withAnimation(motion) { selection.move(by: 1) }; return .handled }
        .onKeyPress(.return) { selection.choose?(); return .handled }
        .onKeyPress(.escape) { selection.dismiss?(); return .handled }
    }
}

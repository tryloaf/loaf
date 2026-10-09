import SwiftUI
import WebKit

nonisolated struct BrowserSplit: Equatable {
    let left: UUID
    let right: UUID
    static let dividerWidth: CGFloat = 8
    var fraction = 0.5
    func contains(_ id: UUID) -> Bool { left == id || right == id }
    static func bounded(_ fraction: Double, width: CGFloat) -> Double {
        let minimum = min(0.5, 240 / max(1, width - dividerWidth))
        return min(1 - minimum, max(minimum, fraction.isFinite ? fraction : 0.5))
    }
}

extension BrowserWindowState {


    func markVisibleTabsActive(at now: Date = .now) {
        selectedTab?.lastActivated = now
        if let split = visibleSplit {
            for tab in tabs where split.contains(tab.id) { tab.lastActivated = now }
        }
    }
    var visibleSplit: BrowserSplit? {
        guard let split = browserSplit, let selected = selectedTab, split.contains(selected.id),
            tabs.contains(where: { $0.id == split.left && $0.page == .web }),
            tabs.contains(where: { $0.id == split.right && $0.page == .web })
        else { return nil }
        return split
    }
    var splittableTabs: [BrowserTab] {
        tabs.filter { !$0.isDisposed && !$0.pinned && $0.page == .web && $0.url != nil }
    }
    func splitSelection(including tab: BrowserTab) -> [BrowserTab] {
        let selection = groupingTabs(including: tab)
        guard selection.count <= 2, selection.allSatisfy({ candidate in splittableTabs.contains { $0 === candidate } })
        else { return [] }
        return selection
    }
    func splitSelectedTabs(including tab: BrowserTab) {
        let selected = splitSelection(including: tab)
        guard selected.count == 2 else { return }
        split(selected[0], with: selected[1])
        selectedSidebarTabIDs = []
    }
    func split(_ left: BrowserTab, with right: BrowserTab) {
        guard left !== right, left.store === self, right.store === self,
            !left.isDisposed, !right.isDisposed, tabs.contains(where: { $0 === left }),
            tabs.contains(where: { $0 === right }),
            left.profileID == selectedProfileID, right.profileID == selectedProfileID,
            left.page == .web, right.page == .web, left.url != nil, right.url != nil,
            !left.pinned, !right.pinned
        else { return }
        assignTab(right, to: left.groupID)
        browserSplit = .init(left: left.id, right: right.id)
        left.ensureLoaded()
        right.ensureLoaded()
        select(left)
        if let window = nativeWindow {
            if splitOriginalMinimum == nil { splitOriginalMinimum = window.minSize }
            window.minSize.width = max(window.minSize.width, 500 + (sidebarPresented ? preferences.sidebarWidth : 0))
            if window.frame.width < window.minSize.width {
                var frame = window.frame
                frame.size.width = window.minSize.width
                window.setFrame(frame, display: true)
            }
        }
        sidebarEntryCache = nil
    }
    func endSplit() {
        markVisibleTabsActive()
        browserSplit = nil
        sidebarEntryCache = nil
        if let size = splitOriginalMinimum {
            nativeWindow?.minSize = size
            splitOriginalMinimum = nil
        }
    }
}

@MainActor final class LoafWebView: WKWebView {
    weak var browserTab: BrowserTab?
    private var linkPreviewTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkPreviewTracking { removeTrackingArea(linkPreviewTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        linkPreviewTracking = area
    }
    override func mouseExited(with event: NSEvent) {
        browserTab?.clearHoveredLink()
        super.mouseExited(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let host = superview as? WebViewHost.HostView {
            let local = convert(point, from: superview)
            let inset = host.configuredInset ?? host.requestedInset
            let fromTop = isFlipped ? local.y - bounds.minY : bounds.maxY - local.y
            if inset > 0, bounds.contains(local), fromTop < inset { return nil }
        }
        return super.hitTest(point)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let tab = browserTab, let store = tab.store,
            store.visibleSplit?.contains(tab.id) == true, store.selectedTab?.id != tab.id
        {
            store.select(tab)
        }
        return accepted
    }
}

struct BrowserWebSurface: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let topInset: CGFloat
    let viewport: CGSize
    var body: some View {
        if let split = store.visibleSplit,
            let left = store.tabs.first(where: { $0.id == split.left }),
            let right = store.tabs.first(where: { $0.id == split.right })
        {
            GeometryReader { geometry in
                let available = max(1, geometry.size.width - BrowserSplit.dividerWidth)
                let fraction = BrowserSplit.bounded(split.fraction, width: geometry.size.width)
                HStack(spacing: 0) {
                    pane(left, viewport: CGSize(width: available * fraction, height: viewport.height)).frame(
                        width: available * fraction)
                    SplitDivider(store: store, split: split, width: geometry.size.width)
                        .frame(width: BrowserSplit.dividerWidth)
                        .accessibilityElement().accessibilityLabel("resize split view")
                        .accessibilityValue("left pane \(Int(fraction * 100)) percent")
                        .accessibilityAdjustableAction { direction in
                            store.browserSplit?.fraction = BrowserSplit.bounded(
                                fraction + (direction == .increment ? 0.05 : -0.05), width: geometry.size.width)
                        }
                    pane(right, viewport: CGSize(width: available * (1 - fraction), height: viewport.height)).frame(
                        width: available * (1 - fraction))
                }
            }
        } else {
            pane(tab, viewport: viewport)
        }
    }
    private func pane(_ page: BrowserTab, viewport: CGSize) -> some View {
        WebViewHost(tab: page, topInset: topInset, sidebarVisible: store.sidebarPresented, viewportSize: viewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                PasswordSuggestionOverlay(
                    store: store, tab: page,
                    offer: store.selectedTab?.id == page.id && store.passwordOffer == nil && !store.omnibarVisible
                        && !store.findVisible ? store.passwordFillOffer : nil)
            }
            .overlay {
                if store.visibleSplit != nil {
                    Rectangle().strokeBorder(
                        store.selectedTab?.id == page.id ? profileTint(store.profile).opacity(0.35) : .clear,
                        lineWidth: 1
                    ).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                LinkPreviewToast(store: store, tab: page, maximumWidth: max(0, min(420, viewport.width - 16)))
                    .padding(8)
            }
            .accessibilityElement(children: .contain).accessibilityLabel(page.sidebarTitle)
            .id(page.id)
    }
}

struct LinkPreviewToast: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let maximumWidth: CGFloat
    var body: some View {
        Group {
            if store.preferences.showLinkPreview != false, !store.omnibarVisible,
                tab.fullscreenState == .notInFullscreen, let address = tab.hoveredLink {
                Text(address).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                    .frame(maxWidth: maximumWidth, alignment: .leading)
                    .accessibilityLabel("link destination: " + address)
            }
        }.allowsHitTesting(false)
            .onChange(of: store.preferences.showLinkPreview) { _, enabled in
                if enabled == false { tab.clearHoveredLink() }
            }
    }
}

struct SplitDivider: NSViewRepresentable {
    let store: BrowserStore
    let split: BrowserSplit
    let width: CGFloat
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.store = store
        view.split = split
        view.availableWidth = width
    }
    static func dismantleNSView(_ view: DividerView, coordinator: ()) {
        view.store = nil
        view.dragStart = nil
    }
    final class DividerView: NSView {
        weak var store: BrowserStore?
        var split: BrowserSplit?
        var availableWidth: CGFloat = 0
        var dragStart: (x: CGFloat, fraction: Double, left: UUID, right: UUID)?
        private var hovered = false
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) {
            hovered = true
            NSCursor.resizeLeftRight.set()
            needsDisplay = true
        }
        override func mouseExited(with event: NSEvent) {
            hovered = false
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.labelColor.withAlphaComponent(hovered || dragStart != nil ? 0.12 : 0.05).setFill()
            bounds.fill()
            NSColor.labelColor.withAlphaComponent(hovered || dragStart != nil ? 0.55 : 0.28).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 18, width: 2, height: 36), xRadius: 1,
                yRadius: 1
            ).fill()
        }
        override func mouseDown(with event: NSEvent) {
            guard let store, let split, store.visibleSplit?.left == split.left, store.visibleSplit?.right == split.right
            else { return }
            if event.clickCount == 2 {
                store.browserSplit?.fraction = 0.5
                return
            }
            dragStart = (
                event.locationInWindow.x, BrowserSplit.bounded(split.fraction, width: availableWidth), split.left,
                split.right
            )
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
            guard let store, let start = dragStart, store.visibleSplit?.left == start.left,
                store.visibleSplit?.right == start.right
            else {
                dragStart = nil
                return
            }
            store.browserSplit?.fraction = BrowserSplit.bounded(
                start.fraction + (event.locationInWindow.x - start.x)
                    / max(1, availableWidth - BrowserSplit.dividerWidth),
                width: availableWidth)
        }
        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            needsDisplay = true
        }
    }
}

struct SplitTabRow: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var left: BrowserTab
    @ObservedObject var right: BrowserTab
    var body: some View {
        HStack(spacing: 3) {
            SplitTabSegment(tab: left, store: store)
            SplitTabSegment(tab: right, store: store)
        }.frame(height: 32)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityLabel("split tabs")
    }
}

private struct SplitTabSegment: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: Bool { store.selectedTab?.id == tab.id || store.selectedSidebarTabIDs.contains(tab.id) }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.selectSidebarTab(tab, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                store.focusPage()
            } label: {
                HStack(spacing: 5) {
                    EditableTabIcon(tab: tab, store: store, size: 14)
                    Text(tab.sidebarTitle).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.leading, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tab.sidebarTitle).accessibilityAddTraits(
                selected ? .isSelected : [])
            Button {
                store.closeFromPointer(tab)
            } label: {
                GolzheimIcon(icon: .close, size: 12).foregroundStyle(.secondary).frame(width: 20, height: 24)
            }.buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel("close " + tab.sidebarTitle)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }.padding(.trailing, 3).frame(maxWidth: .infinity).frame(height: 28)
            .background(selected ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .contextMenu {
                TabActions(tab: tab, store: store)
                Button("end split") { store.endSplit() }
            }
    }
}

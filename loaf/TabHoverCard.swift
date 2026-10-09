import AppKit
import SwiftUI
import WebKit

enum TabHoverMetrics {
    static let width: CGFloat = 220
}

struct HoverActionLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        .init(width: proposal.width ?? 196, height: 28)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, view) in subviews.enumerated() {
            view.place(
                at: .init(x: bounds.minX + (CGFloat(index) + 0.5) * width, y: bounds.midY), anchor: .center,
                proposal: .init(width: 26, height: 26))
        }
    }
}
@MainActor final class TabHoverController {
    private(set) var panel: NSPanel?

    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private weak var anchor: NSView?
    private weak var tab: BrowserTab?
    private var groupID: UUID?
    private var hoverWatch: Task<Void, Never>?
    private weak var store: BrowserStore?
    private var pending: DispatchWorkItem?
    private var hiding: DispatchWorkItem?
    private weak var trackingMenu: NSMenu?
    private var observers: [NSObjectProtocol] = []
    init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu,
                        self.panel?.frame.contains(self.pointerLocation()) == true
                    else { return }
                    self.trackingMenu = menu
                    self.keepOpen()
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu, self.trackingMenu === menu else {
                        return
                    }
                    self.trackingMenu = nil
                    self.deferHide()
                }
            })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func enter(_ view: NSView, tab: BrowserTab, store: BrowserStore) {

        guard !view.isHiddenOrHasHiddenAncestor, view.window?.isKeyWindow == true,
            screenRect(for: view).contains(pointerLocation())
        else { return }
        hiding?.cancel()
        hiding = nil
        if self.anchor === view, panel != nil { return }
        dismiss()
        self.anchor = view
        self.tab = tab
        self.store = store
        scheduleShow()
    }
    func enter(_ view: NSView, groupID: UUID, store: BrowserStore) {

        guard !view.isHiddenOrHasHiddenAncestor, view.window?.isKeyWindow == true,
            screenRect(for: view).contains(pointerLocation())
        else { return }
        hiding?.cancel()
        hiding = nil
        if self.anchor === view, panel != nil { return }
        dismiss()
        self.anchor = view
        self.groupID = groupID
        self.store = store
        scheduleShow()
    }
    private func scheduleShow() {
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func deferHide(ifAnchoredTo view: NSView? = nil) {
        if let view, anchor !== view { return }
        if isHoveringTargetOrCard {
            keepOpen()
            return
        }
        pending?.cancel()
        pending = nil

        guard hiding == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hiding = nil
            guard self.trackingMenu == nil else { return }
            if !self.isHoveringTargetOrCard { self.dismiss() }
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private var anchorScreenRect: NSRect { anchor.map { screenRect(for: $0) } ?? .zero }
    private func screenRect(for anchor: NSView) -> NSRect {
        guard let window = anchor.window else { return .zero }

        let visible = anchor.visibleRect.intersection(anchor.bounds)
        guard !visible.isEmpty else { return .zero }
        return window.convertToScreen(anchor.convert(visible, to: nil)).intersection(window.frame)
    }
    private var targetIsValid: Bool {
        guard let anchor, let window = anchor.window, let store,
            window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
            !anchor.isHiddenOrHasHiddenAncestor, !anchorScreenRect.isEmpty,
            !store.omnibarVisible, store.editingGroupID == nil
        else { return false }
        if let tab { return !tab.isDisposed && store.selectedProfileID == tab.profileID }
        return groupID.map { id in store.tabGroups.contains { $0.id == id } } ?? false
    }
    private var anchorHovered: Bool {
        targetIsValid && anchorScreenRect.contains(pointerLocation())
    }
    private var isHoveringTargetOrCard: Bool {
        guard targetIsValid else { return false }
        return anchorHovered || panel?.frame.contains(pointerLocation()) == true
    }
    func keepOpen() {
        hiding?.cancel()
        hiding = nil
    }
    private func watchHover() {
        hoverWatch?.cancel()
        hoverWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, self.panel != nil else { return }
                if !self.targetIsValid {
                    self.dismiss()
                    return
                }
                self.fitPanelToContent()
                if self.isHoveringTargetOrCard { self.keepOpen() } else if self.hiding == nil { self.deferHide() }
            }
        }
    }
    func dismiss(ifAnchoredTo view: NSView? = nil) {
        if let view, anchor !== view { return }
        pending?.cancel()
        pending = nil
        hiding?.cancel()
        hiding = nil
        hoverWatch?.cancel()
        hoverWatch = nil
        let outgoing = panel
        panel = nil
        if let outgoing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.06 : 0.14
                outgoing.animator().alphaValue = 0
            } completionHandler: {
                outgoing.parent?.removeChildWindow(outgoing)
                outgoing.close()
            }
        }
        trackingMenu = nil
        anchor = nil
        tab = nil
        groupID = nil
        store = nil
    }
    private func show() {
        guard anchorHovered, let anchor, let window = anchor.window, let store,
            !store.omnibarVisible, store.editingGroupID == nil
        else { return }
        let card: AnyView
        if let tab, !tab.isDisposed, store.selectedProfileID == tab.profileID {
            card = AnyView(TabHoverCard(tab: tab, store: store))
        } else if let groupID, store.tabGroups.contains(where: { $0.id == groupID }) {
            card = AnyView(GroupHoverCard(groupID: groupID, store: store))
        } else {
            return
        }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? rect
        let hosting = NSHostingView(
            rootView: AnyView(
                card
                    .onHover { [weak self] inside in if inside { self?.keepOpen() } else { self?.deferHide() } }
                    .preferredColorScheme(store.profile.privateMode ? .dark : nil).tint(
                        store.profile.privateMode ? PrivateChrome.accent : Color.accentColor)))
        let size = NSSize(width: TabHoverMetrics.width, height: ceil(hosting.fittingSize.height))
        let frame = NSRect(
            x: max(screen.minX, min(rect.maxX + 6, screen.maxX - size.width)),
            y: max(screen.minY, min(rect.maxY - size.height, screen.maxY - size.height)), width: size.width,
            height: size.height)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(
            named: store.profile.privateMode
                ? .darkAqua : window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        watchHover()
    }
    private func fitPanelToContent() {
        guard let panel, let content = panel.contentView else { return }
        let height = ceil(content.fittingSize.height)
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = max(panel.screen?.visibleFrame.minY ?? frame.minY, frame.maxY - height)
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

}
struct TabHoverAnchor: NSViewRepresentable {
    let tab: BrowserTab?
    let groupID: UUID?
    let store: BrowserStore
    init(tab: BrowserTab, store: BrowserStore) {
        self.tab = tab
        groupID = nil
        self.store = store
    }
    init(group: TabGroup, store: BrowserStore) {
        tab = nil
        groupID = group.id
        self.store = store
    }
    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ view: HoverView, context: Context) {
        view.tab = tab
        view.groupID = groupID
        view.store = store
        if let tab, tab.isDisposed || store.selectedProfileID != tab.profileID {
            store.tabHover.dismiss(ifAnchoredTo: view)
        }
    }
    static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.store?.tabHover.dismiss(ifAnchoredTo: view) }
    final class HoverView: NSView {
        weak var tab: BrowserTab?
        var groupID: UUID?
        weak var store: BrowserStore?
        private var tracking: NSTrackingArea?
        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            clipsToBounds = true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard tracking == nil else { return }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) {
            guard let store else { return }
            if let tab {
                store.tabHover.enter(self, tab: tab, store: store)
            } else if let groupID {
                store.tabHover.enter(self, groupID: groupID, store: store)
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { store?.tabHover.dismiss(ifAnchoredTo: self) }
        }
        override func mouseExited(with event: NSEvent) { store?.tabHover.deferHide(ifAnchoredTo: self) }
    }
}
struct TabHoverCard: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(BrowserAddress.visible(tab.sidebarTitle)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                .truncationMode(.tail)
            Text(tab.url?.host ?? tab.page.address).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            HoverActionLayout {
                IconButton(icon: .back, label: store.isPersistentTab(tab) ? "return to pinned page" : "back") {
                    if store.isPersistentTab(tab) { store.returnToPin(tab) } else { tab.webView.goBack() }
                }.disabled(store.isPersistentTab(tab) ? tab.pinnedAddress == nil && tab.url == nil : !tab.canGoBack)
                IconButton(icon: .favorite, label: "toggle favorite") { store.favorite(tab) }.disabled(tab.url == nil)
                IconButton(icon: .pinned, label: store.isPersistentTab(tab) ? "unpin tab" : "pin tab") {
                    if store.isPersistentTab(tab) { store.removePersistentTab(tab) } else { store.togglePin(tab) }
                }
                IconButton(icon: tab.media.contains { !$0.muted } ? .volume : .muted, label: "toggle tab sound") {
                    store.toggleMute(tab)
                }.disabled(tab.media.isEmpty)
                Menu {
                    TabActions(tab: tab, store: store)
                } label: {
                    ChromeMoreIcon().frame(width: 26, height: 26)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("tab actions")
            }.frame(height: 28).padding(.top, 2)
        }.padding(10).frame(width: TabHoverMetrics.width, alignment: .leading).fixedSize(
            horizontal: false, vertical: true
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain).accessibilityLabel("tab actions for " + tab.sidebarTitle)
    }
}

struct GroupHoverCard: View {
    let groupID: UUID
    @ObservedObject var store: BrowserStore
    var body: some View {
        if let group = store.tabGroups.first(where: { $0.id == groupID }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.tail)
                Text("\(store.groupTabs(group).count) tabs" + (group.isPinned ? " · pinned group" : "")).font(
                    .system(size: 11)
                ).foregroundStyle(.secondary)
                HoverActionLayout {
                    IconButton(icon: .disclosureDown, label: group.collapsed ? "expand group" : "collapse group") {
                        store.updateGroup(groupID) { $0.collapsed.toggle() }
                    }
                    IconButton(icon: .plus, label: "new tab in group") {
                        let tab = store.newTab()
                        store.assignTab(tab, to: groupID)
                    }
                    IconButton(icon: .pinned, label: group.isPinned ? "unpin group" : "pin group") {
                        store.toggleGroupPin(groupID)
                    }
                    IconButton(icon: .settings, label: "rename group") {
                        store.editTabGroup(groupID)
                        store.tabHover.dismiss()
                    }
                    IconButton(icon: .close, label: "close group pages") { store.closeTabGroup(groupID) }
                }.frame(height: 28).padding(.top, 2)
            }.padding(10).frame(width: TabHoverMetrics.width, alignment: .leading).fixedSize(
                horizontal: false, vertical: true
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .contain).accessibilityLabel("group actions for " + group.name)
        }
    }
}

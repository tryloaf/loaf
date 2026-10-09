import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BrowserDragTypes {
    static func accepted(_ type: UTType) -> [UTType] {
        [type]
    }
    static func pasteboardTypes(_ type: UTType) -> [NSPasteboard.PasteboardType] {
        accepted(type).map { .init($0.identifier) }
    }
    static func data(_ pasteboard: NSPasteboard, type: UTType) -> Data? {
        for name in pasteboardTypes(type) {
            if let data = pasteboard.data(forType: name) { return data }
        }
        return nil
    }
}

struct TabDragArea: NSViewRepresentable {
    let tab: BrowserTab
    let store: BrowserStore
    let title: String
    let selected: Bool
    @Binding var pressed: Bool
    func makeNSView(context: Context) -> DragView {
        DragView()
    }
    func updateNSView(_ view: DragView, context: Context) {
        view.tab = tab
        view.store = store
        view.setPressed = { pressed = $0 }
        if tab.pinned {
            view.registerForDraggedTypes(BrowserDragTypes.pasteboardTypes(.loafTab))
        } else {
            view.unregisterDraggedTypes()
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp(tab.url?.absoluteString)
        view.setAccessibilityValue(selected ? "selected" : "")
    }
    final class DragView: NSView, NSDraggingSource {
        weak var tab: BrowserTab?
        weak var store: BrowserStore?
        var setPressed: ((Bool) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        private var mouseOrigin: NSPoint?
        private var dragging = false
        override func hitTest(_ point: NSPoint) -> NSView? {

            if let event = NSApp.currentEvent,
                event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            {
                return nil
            }
            return super.hitTest(point)
        }
        override func accessibilityPerformPress() -> Bool {
            guard let tab, let store else { return false }
            store.select(tab)
            return true
        }
        override func mouseDown(with event: NSEvent) {
            mouseOrigin = event.locationInWindow
            dragging = false
            setPressed?(true)
        }
        override func mouseUp(with event: NSEvent) {
            defer {
                mouseOrigin = nil
                setPressed?(false)
            }
            guard !dragging, bounds.contains(convert(event.locationInWindow, from: nil)), let tab, let store else {
                return
            }
            if event.clickCount == 2, store.isPersistentTab(tab),
                event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
            {
                store.returnToPin(tab)
            } else {
                store.selectSidebarTab(tab, modifiers: event.modifierFlags)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let origin = mouseOrigin, let tab, let store,
                hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4,
                tab.windowID == store.id, tab.profileID == store.selectedProfileID,
                let data = try? JSONEncoder().encode(
                    TabDrag(window: store.id, profile: store.selectedProfileID, tab: tab.id))
            else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.loafTab.identifier))
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                tab.favicon?.draw(in: NSRect(x: 8, y: 8, width: 16, height: 16))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (tab.sidebarTitle as NSString).draw(
                    in: NSRect(x: 28, y: 8, width: max(0, rect.width - 36), height: 20),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraph,
                    ])
                return true
            }
            draggingItem.setDraggingFrame(bounds, contents: image)
            dragging = true
            setPressed?(false)
            store.draggedTabID = tab.id
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }
        func validatedPinDrag(_ sender: any NSDraggingInfo) -> BrowserTab? {
            guard let store, let target = tab, target.pinned, let source = sender.draggingSource as? DragView,
                source.store === store, source.window === window, sender.draggingDestinationWindow === window,
                sender.draggingSourceOperationMask.contains(.move), let origin = source.tab, origin.pinned,
                let data = BrowserDragTypes.data(sender.draggingPasteboard, type: .loafTab), data.count <= 1024,
                let drag = try? JSONDecoder().decode(TabDrag.self, from: data), drag.window == store.id,
                drag.profile == store.selectedProfileID, origin.profileID == drag.profile,
                target.profileID == drag.profile,
                drag.tab == origin.id, store.draggedTabID == origin.id,
                store.pinnedTabs.contains(where: { $0.pinnedShortcutID == origin.pinnedShortcutID }),
                store.pinnedTabs.contains(where: { $0.pinnedShortcutID == target.pinnedShortcutID })
            else { return nil }
            return origin
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            validatedPinDrag(sender) == nil ? [] : .move
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { validatedPinDrag(sender) != nil }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let origin = validatedPinDrag(sender), let tab, let store else { return false }
            let point = convert(sender.draggingLocation, from: nil)
            let after =
                store.preferences.pinnedLayout == "list"
                ? (isFlipped ? point.y > bounds.midY : point.y < bounds.midY) : point.x > bounds.midX
            store.movePin(origin, before: tab, after: after)
            store.draggedTabID = nil
            return true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            context == .withinApplication ? .move : []
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseOrigin = nil
            dragging = false
            setPressed?(false)
            guard let store, let source = tab?.id else { return }
            if store.draggedTabID == source { store.draggedTabID = nil }
            store.draggedGroupTargetID = nil
        }
    }
}

enum SidebarTabMetrics {
    static let rowHeight: CGFloat = 32
    static let spacing: CGFloat = 4
    static let insertionGap: CGFloat = 8
    static let bottomPadding: CGFloat = 16
    static let stride = rowHeight + spacing
}

struct TabInsertionLayout {
    struct Row {
        let id: UUID
        let pinned: Bool
        var height: CGFloat = SidebarTabMetrics.rowHeight
    }
    private let offsets: [CGFloat]
    init(rows: [Row]) {
        self.rows = rows
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(rows.count + 1)
        for row in rows { offsets.append(offsets.last! + row.height + SidebarTabMetrics.spacing) }
        self.offsets = offsets
    }
    func offset(at index: Int) -> CGFloat { offsets[min(rows.count, max(0, index))] }
    var height: CGFloat { max(0, offset(at: rows.count) - SidebarTabMetrics.spacing) }
    func index(at y: CGFloat) -> Int {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if y < offsets[middle + 1] { upper = middle } else { lower = middle + 1 }
        }
        return min(lower, max(0, rows.count - 1))
    }
    let rows: [Row]
    func slot(for position: TabDropPosition?) -> Int? {
        guard let position, let index = rows.firstIndex(where: { $0.id == position.target }) else { return nil }
        return index + (position.after ? 1 : 0)
    }

    func position(at y: CGFloat, pinned: Bool, previous: TabDropPosition?, excluding source: UUID? = nil)
        -> TabDropPosition?
    {
        let eligible = rows.indices.filter { rows[$0].pinned == pinned && rows[$0].id != source }
        guard let last = eligible.last else { return nil }
        let boundary = eligible.first { y <= offset(at: $0) + rows[$0].height / 2 }
        let proposed =
            boundary.map { TabDropPosition(target: rows[$0].id, after: false) }
            ?? TabDropPosition(target: rows[last].id, after: true)
        func rank(_ position: TabDropPosition?) -> Int? {
            guard let position, let index = eligible.firstIndex(where: { rows[$0].id == position.target }) else {
                return nil
            }
            return index + (position.after ? 1 : 0)
        }
        if let prior = rank(previous), let next = rank(proposed), prior != next {
            let boundaryIndex = eligible[next > prior ? prior : prior - 1]
            let midpoint = offset(at: boundaryIndex) + rows[boundaryIndex].height / 2
            if next > prior && y < midpoint + 4 || next < prior && y > midpoint - 4 { return previous }
        }
        return proposed
    }
    func isNoOp(_ position: TabDropPosition?, source: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == source }), let slot = slot(for: position) else {
            return true
        }
        return slot == index || slot == index + 1
    }
}

struct TabListView: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    @Binding var position: TabDropPosition?
    func makeNSView(context: Context) -> TabScrollView {
        let view = TabScrollView()
        view.hasVerticalScroller = false
        view.hasHorizontalScroller = false
        view.drawsBackground = false
        view.contentView.drawsBackground = false
        let layout = TabInsertionLayout(
            rows: store.sidebarEntries.map { .init(id: $0.id, pinned: $0.tab == nil, height: $0.height) })
        view.documentView = NSHostingView(
            rootView: TabListContent(store: store, position: $position, visibleRange: view.visibleRange(in: layout)))
        view.registerForDraggedTypes(
            BrowserDragTypes.pasteboardTypes(.loafTab) + BrowserDragTypes.pasteboardTypes(.loafGroup))
        return view
    }
    func updateNSView(_ view: TabScrollView, context: Context) {
        let appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        view.store = store
        view.getPosition = { position }
        view.setPosition = { position = $0 }
        view.refreshVisibleRows(force: true)
        view.revealChangedSelection()
        view.needsLayout = true
    }
    final class TabScrollView: NSScrollView {
        weak var store: BrowserStore?
        var getPosition: (() -> TabDropPosition?)?
        var setPosition: ((TabDropPosition?) -> Void)?
        private var lastScroll = Date.distantPast
        private var dragSequence: Int?
        private var candidate: TabDropPosition?
        private var groupTarget: UUID?
        private var viewportObserver: NSObjectProtocol?
        private var viewportRefreshPending = false
        private var renderedRange: Range<Int>?
        private var lastSelectedID: UUID?
        override init(frame: NSRect) {
            super.init(frame: frame)
            contentView.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleViewportRefresh() }
            }
        }
        required init?(coder: NSCoder) { super.init(coder: coder) }
        deinit { if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
        func visibleRange(in layout: TabInsertionLayout) -> Range<Int>? {
            guard layout.rows.count > 64 else { return nil }
            let viewport = contentView.bounds
            let height = viewport.height > 0 ? viewport.height : 650
            let first = max(0, layout.index(at: max(0, viewport.minY)) - 6)
            let last = min(layout.rows.count, layout.index(at: max(0, viewport.minY) + height) + 7)
            return first..<max(first, last)
        }
        private func scheduleViewportRefresh() {
            guard !viewportRefreshPending else { return }
            viewportRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewportRefreshPending = false
                guard self.window?.isVisible == true else { return }
                self.refreshVisibleRows()
            }
        }
        func refreshVisibleRows(force: Bool = false) {
            guard let store, let host = documentView as? NSHostingView<TabListContent> else { return }
            let range = visibleRange(in: insertionLayout)
            guard force || range != renderedRange else { return }
            renderedRange = range
            host.rootView = TabListContent(
                store: store,
                position: Binding(
                    get: { [weak self] in self?.getPosition?() }, set: { [weak self] in self?.setPosition?($0) }),
                visibleRange: range)
        }
        func revealChangedSelection() {
            guard let store else { return }
            let selected = store.workspaces[store.selectedProfileID]?.selectedTab
            guard selected != lastSelectedID else { return }
            lastSelectedID = selected
            guard let selected else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastSelectedID == selected, let store = self.store,
                    store.workspaces[store.selectedProfileID]?.selectedTab == selected
                else { return }
                self.layoutSubtreeIfNeeded()
                let layout = self.insertionLayout
                guard let index = layout.rows.firstIndex(where: { $0.id == selected }) else { return }
                let viewport = self.contentView.bounds
                guard viewport.height > 0 else { return }
                let top = layout.offset(at: index)
                let bottom = top + layout.rows[index].height
                let destination =
                    top < viewport.minY ? top : bottom > viewport.maxY ? bottom - viewport.height : viewport.minY
                guard abs(destination - viewport.minY) > 0.5 else { return }
                self.contentView.scroll(to: NSPoint(x: viewport.minX, y: max(0, destination)))
                self.reflectScrolledClipView(self.contentView)
                self.scheduleViewportRefresh()
            }
        }
        var insertionLayout: TabInsertionLayout {
            TabInsertionLayout(
                rows: (store?.sidebarEntries ?? []).map { .init(id: $0.id, pinned: $0.tab == nil, height: $0.height) })
        }
        override func layout() {
            super.layout()
            guard let documentView else { return }
            let height = max(contentSize.height, insertionLayout.height + SidebarTabMetrics.bottomPadding)
            let size = NSSize(width: contentSize.width, height: height)
            if documentView.frame.size != size { documentView.setFrameSize(size) }
            scheduleViewportRefresh()
        }
        func validatedDrag(_ sender: any NSDraggingInfo) -> TabDrag? {
            guard let store, let source = sender.draggingSource as? TabDragArea.DragView,
                source.window === window, sender.draggingDestinationWindow === window,
                source.store === store, sender.draggingSourceOperationMask.contains(.move),
                let data = BrowserDragTypes.data(sender.draggingPasteboard, type: .loafTab),
                data.count <= 1024, let drag = try? JSONDecoder().decode(TabDrag.self, from: data),
                drag.window == store.id, drag.profile == store.selectedProfileID,
                drag.tab == store.draggedTabID, drag.tab == source.tab?.id,
                let origin = source.tab, !origin.isDisposed, origin.windowID == store.id,
                origin.profileID == store.selectedProfileID
            else { return nil }

            guard
                origin.pinned
                    ? store.pinnedTabs.contains(where: { $0 === origin })
                    : store.tabs.contains(where: { $0 === origin })
            else { return nil }
            return drag
        }
        func validatedFolderDrag(_ sender: any NSDraggingInfo) -> FolderDrag? {
            guard let store, let source = sender.draggingSource as? GroupDragArea.DragView,
                source.store === store, source.window === window, sender.draggingDestinationWindow === window,
                sender.draggingSourceOperationMask.contains(.move),
                let data = BrowserDragTypes.data(sender.draggingPasteboard, type: .loafGroup), data.count <= 1024,
                let drag = try? JSONDecoder().decode(FolderDrag.self, from: data), drag.window == store.id,
                drag.profile == store.selectedProfileID, drag.group == source.groupID,
                drag.group == store.draggedFolderID,
                store.tabGroups.contains(where: { $0.id == drag.group })
            else { return nil }
            return drag
        }
        private func folderPosition(_ sender: any NSDraggingInfo, drag: FolderDrag) -> TabDropPosition? {
            guard let store, let documentView, let group = store.tabGroups.first(where: { $0.id == drag.group }) else {
                return nil
            }
            let point = documentView.convert(sender.draggingLocation, from: nil)
            let y = documentView.isFlipped ? point.y : documentView.bounds.height - point.y
            let layout = TabInsertionLayout(
                rows: store.sidebarEntries.map { entry in
                    let eligible: Bool
                    switch entry {
                    case .group(let target): eligible = target.isPinned == group.isPinned
                    case .tab(let tab): eligible = !group.isPinned && tab.groupID == nil
                    case .newTab: eligible = false
                    }
                    return .init(id: entry.id, pinned: eligible, height: entry.height)
                })
            return layout.position(at: y, pinned: true, previous: nil, excluding: drag.group)
        }
        private func insertionPosition(_ sender: any NSDraggingInfo) -> TabDropPosition? {
            guard validatedDrag(sender) != nil, let source = sender.draggingSource as? TabDragArea.DragView,
                let origin = source.tab, let documentView
            else { return nil }
            let point = documentView.convert(sender.draggingLocation, from: nil)
            let y = documentView.isFlipped ? point.y : documentView.bounds.height - point.y
            groupTarget = nil
            let row = insertionLayout.index(at: max(0, y))
            if let store, store.sidebarEntries.indices.contains(row), case .newTab = store.sidebarEntries[row],
                y < insertionLayout.offset(at: row) + 8
            {
                groupTarget = nil
                candidate = nil
                return nil
            }
            if let store, store.sidebarEntries.indices.contains(row), case .group(let group) = store.sidebarEntries[row]
            {
                groupTarget = group.id
                candidate = nil
                return nil
            }
            if dragSequence != sender.draggingSequenceNumber {
                dragSequence = sender.draggingSequenceNumber
                candidate = nil
            }
            candidate = insertionLayout.position(at: y, pinned: false, previous: candidate, excluding: origin.id)
            if let target = candidate.flatMap({ candidate in
                store?.sidebarEntries.first { $0.id == candidate.target }?.tab
            }) {
                groupTarget = target.groupID
            }
            return candidate
        }
        private func pinsAboveDivider(_ sender: any NSDraggingInfo) -> Bool {
            guard let documentView,
                let divider = store?.sidebarEntries.firstIndex(where: { $0.id == SidebarEntry.newTabID })
            else { return false }
            let point = documentView.convert(sender.draggingLocation, from: nil)
            let y = documentView.isFlipped ? point.y : documentView.bounds.height - point.y
            return y >= insertionLayout.offset(at: divider) && y < insertionLayout.offset(at: divider) + 8
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if let folder = validatedFolderDrag(sender) {
                setPosition?(folderPosition(sender, drag: folder))
                autoscrollDrag(at: sender.draggingLocation)
                return .move
            }
            guard let drag = validatedDrag(sender) else {
                candidate = nil
                setPosition?(nil)
                return []
            }
            let position = insertionPosition(sender)
            if store?.draggedGroupTargetID != groupTarget { store?.draggedGroupTargetID = groupTarget }
            let unpinning = (sender.draggingSource as? TabDragArea.DragView)?.tab?.pinned == true
            setPosition?(!unpinning && insertionLayout.isNoOp(position, source: drag.tab) ? nil : position)
            if unpinning && pinsAboveDivider(sender) { return [] }
            autoscrollDrag(at: sender.draggingLocation)
            return .move
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            candidate = nil
            store?.draggedGroupTargetID = nil
            setPosition?(nil)
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if validatedFolderDrag(sender) != nil { return true }
            guard validatedDrag(sender) != nil else { return false }
            return (sender.draggingSource as? TabDragArea.DragView)?.tab?.pinned != true || !pinsAboveDivider(sender)
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if let folder = validatedFolderDrag(sender), let store {
                if let position = folderPosition(sender, drag: folder) {
                    store.moveTabGroup(folder.group, relativeTo: position.target, after: position.after)
                }
                candidate = nil
                setPosition?(nil)
                store.draggedFolderID = nil
                return true
            }
            guard validatedDrag(sender) != nil, let store else {
                candidate = nil
                setPosition?(nil)
                return false
            }
            let position = insertionPosition(sender)
            guard let source = sender.draggingSource as? TabDragArea.DragView, let origin = source.tab else {
                return false
            }
            if pinsAboveDivider(sender) {
                guard !origin.pinned else { return false }
                store.togglePin(origin)
            } else {
                let tab: BrowserTab
                if origin.pinned {

                    tab = store.openPinned(origin)
                    store.togglePin(tab)
                } else {
                    tab = origin
                }
                if let groupTarget {
                    let target = position.flatMap { position in
                        store.sidebarEntries.first { $0.id == position.target }?.tab
                    }
                    store.insertTab(tab, in: groupTarget, relativeTo: target, after: position?.after ?? true)
                } else if let position, !insertionLayout.isNoOp(position, source: tab.id) {
                    store.moveTab(tab.id, relativeTo: position.target, after: position.after)
                }
            }
            candidate = nil
            setPosition?(nil)
            store.draggedTabID = nil
            store.draggedGroupTargetID = nil
            return true
        }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
        private func autoscrollDrag(at point: NSPoint) {
            let now = Date()
            guard now.timeIntervalSince(lastScroll) >= 0.04, let documentView else { return }
            lastScroll = now
            let clip = contentView
            let location = clip.convert(point, from: nil)
            let top = clip.isFlipped ? location.y - clip.bounds.minY : clip.bounds.maxY - location.y
            let bottom = clip.bounds.height - top
            let amount: CGFloat =
                top < 28 ? -12 * (1 - max(0, top) / 28) : bottom < 28 ? 12 * (1 - max(0, bottom) / 28) : 0
            guard amount != 0 else { return }
            var next = clip.bounds
            next.origin.y += documentView.isFlipped ? amount : -amount
            clip.scroll(to: clip.constrainBoundsRect(next).origin)
            reflectScrolledClipView(clip)
        }
    }
}

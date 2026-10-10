import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BrowserDragTypes {
    static let links: [NSPasteboard.PasteboardType] = [.URL, .string, .init("public.url-name")]
    static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        guard data(pasteboard, type: .loafTab) == nil, data(pasteboard, type: .loafGroup) == nil else { return [] }
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        if urls.isEmpty, let text = pasteboard.string(forType: .string), text.utf8.count <= 64_000 {
            urls = text.split(whereSeparator: \.isNewline).compactMap {
                let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else {
                    return nil
                }
                return URL(string: text)
            }
        }
        var seen = Set<String>()
        return urls.filter {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false
                && $0.user == nil && $0.password == nil && seen.insert($0.absoluteString).inserted
        }.prefix(16).map { $0 }
    }

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
        view.unregisterDraggedTypes()
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
        private weak var session: NSDraggingSession?
        private weak var sourceWindow: NSWindow?
        var draggingWindow: NSWindow? { sourceWindow ?? window }
        private(set) var dragPreviewGrid = false
        private(set) var previewSize = NSSize.zero
        private(set) var previewImage: NSImage?
        private var previewStartSize = NSSize.zero
        private var previewStartImage: NSImage?
        private var previewTargetSize = NSSize.zero
        private var previewTargetImage: NSImage?
        private var previewStarted: CFTimeInterval = 0
        private var previewAnchor: CGFloat = 0.5
        private var previewLink: CADisplayLink?
        private final class PreviewTick: NSObject {
            weak var view: DragView?
            init(_ view: DragView) { self.view = view }
            @objc func update(_ link: CADisplayLink) {
                if let view { view.tickPreview() } else { link.invalidate() }
            }
        }
        func previewSize(grid: Bool) -> NSSize {
            guard let store else { return .zero }
            let count = store.gridPinnedTabs.count + (store.gridPinnedTabs.contains { $0.id == tab?.id } ? 0 : 1)
            let columns = grid && store.preferences.pinnedLayout != "list" ? PinGridLayout.columns(for: count) : 1
            return NSSize(
                width: (store.preferences.sidebarWidth - 16 - CGFloat(columns - 1) * 6) / CGFloat(columns),
                height: SidebarTabMetrics.rowHeight)
        }
        private func image(size: NSSize, grid: Bool) -> NSImage {
            guard let tab, let store else { return NSImage(size: size) }
            let preview = NSHostingView(
                rootView: TabDragPreview(tab: tab, store: store, grid: grid)
                    .frame(width: size.width, height: size.height))
            preview.appearance = effectiveAppearance
            preview.frame = NSRect(origin: .zero, size: size)
            preview.layoutSubtreeIfNeeded()
            let image = NSImage(size: size)
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                image.addRepresentation(bitmap)
            }
            return image
        }
        func updateDraggingPreview(grid: Bool) {
            let grid = grid && store?.preferences.pinnedLayout != "list"
            guard grid != dragPreviewGrid else { return }
            dragPreviewGrid = grid
            previewLink?.invalidate()
            previewLink = nil
            guard session != nil else { return }
            previewStartSize = previewSize
            previewStartImage = previewImage
            previewTargetSize = previewSize(grid: grid)
            previewTargetImage = image(size: previewTargetSize, grid: grid)
            previewStarted = CACurrentMediaTime()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                tickPreview(finish: true)
            } else if let draggingWindow {
                let link = draggingWindow.contentView!.displayLink(
                    target: PreviewTick(self), selector: #selector(PreviewTick.update(_:)))
                previewLink = link
                link.add(to: .main, forMode: .common)
            }
        }
        private func tickPreview(finish: Bool = false) {
            guard let session, let view = draggingWindow?.contentView,
                let from = previewStartImage, let to = previewTargetImage
            else { return }
            let progress = finish ? 1 : min(1, (CACurrentMediaTime() - previewStarted) / 0.14)
            let phase = progress * progress * (3 - 2 * progress)
            let size = NSSize(
                width: previewStartSize.width + (previewTargetSize.width - previewStartSize.width) * phase,
                height: previewStartSize.height + (previewTargetSize.height - previewStartSize.height) * phase)
            let image = NSImage(size: size, flipped: false) { rect in
                from.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - phase)
                to.draw(in: rect, from: .zero, operation: .sourceOver, fraction: phase)
                return true
            }
            previewSize = size
            previewImage = image
            let pointer = view.convert(view.window!.convertPoint(fromScreen: session.draggingLocation), from: nil)
            session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:])
            {
                item, _, _ in
                item.setDraggingFrame(
                    NSRect(
                        x: pointer.x - size.width * self.previewAnchor,
                        y: pointer.y - size.height / 2, width: size.width, height: size.height), contents: image)
            }
            if progress >= 1 {
                previewLink?.invalidate()
                previewLink = nil
            }
        }
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
            dragPreviewGrid = tab.pinned && tab.pinPresentation != "row" && store.preferences.pinnedLayout != "list"
            let size = previewSize(grid: dragPreviewGrid)
            let image = image(size: size, grid: dragPreviewGrid)
            previewSize = size
            previewImage = image
            sourceWindow = window
            let pointer = convert(event.locationInWindow, from: nil)
            let fraction = max(0, min(1, pointer.x / max(1, bounds.width)))
            previewAnchor = fraction
            draggingItem.setDraggingFrame(
                NSRect(
                    x: pointer.x - size.width * fraction, y: bounds.midY - size.height / 2, width: size.width,
                    height: size.height),
                contents: image)
            dragging = true
            setPressed?(false)
            store.draggedTabID = tab.id
            session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        }
        func validatedPinDrag(_ sender: any NSDraggingInfo) -> BrowserTab? {
            guard let store, let target = tab, target.pinned, let source = sender.draggingSource as? DragView,
                source.store === store, source.draggingWindow === window, sender.draggingDestinationWindow === window,
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
                (tab.pinPresentation == "row" || store.preferences.pinnedLayout == "list")
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
            previewLink?.invalidate()
            previewLink = nil
            self.session = nil
            sourceWindow = nil
            previewImage = nil
            previewStartImage = nil
            previewTargetImage = nil
            mouseOrigin = nil
            dragging = false
            setPressed?(false)
            guard let store, let source = tab?.id else { return }
            if store.draggedTabID == source { store.draggedTabID = nil }
            store.draggedGroupTargetID = nil
        }
        deinit { previewLink?.invalidate() }
    }
}

enum SidebarTabMetrics {
    static let rowHeight: CGFloat = 32
    static let spacing: CGFloat = 4
    static let insertionGap: CGFloat = 12
    static let bottomPadding: CGFloat = 16
    static let stride = rowHeight + spacing
}

struct TabInsertionLayout {
    struct Row {
        let id: UUID
        let pinned: Bool
        var height: CGFloat = SidebarTabMetrics.rowHeight
        var containerID: UUID?
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
        guard position.after else { return index }
        var end = index + 1
        while end < rows.count, rows[end].containerID == position.target { end += 1 }
        return end
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
            rows: store.sidebarEntries.map {
                .init(id: $0.id, pinned: $0.tab == nil, height: $0.height, containerID: $0.tab?.groupID)
            })
        view.documentView = NSHostingView(
            rootView: TabListContent(store: store, position: $position, visibleRange: view.visibleRange(in: layout)))
        view.registerForDraggedTypes(
            BrowserDragTypes.pasteboardTypes(.loafTab) + BrowserDragTypes.pasteboardTypes(.loafGroup)
                + BrowserDragTypes.links)
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
        private var candidate: TabDropPosition?
        private var groupTarget: UUID?
        private var outsideGroup = false
        private var pinRow = false
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
                rows: (store?.sidebarEntries ?? []).map {
                    .init(id: $0.id, pinned: $0.tab == nil, height: $0.height, containerID: $0.tab?.groupID)
                })
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
                source.draggingWindow === window, sender.draggingDestinationWindow === window,
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
                    : store.sidebarSelectableTabs.contains(where: { $0 === origin })
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
                    case .tab(let tab): eligible = !group.isPinned && !tab.pinned && tab.groupID == nil
                    case .newTab: eligible = false
                    }
                    return .init(id: entry.id, pinned: eligible, height: entry.height)
                })
            return layout.position(at: y, pinned: true, previous: nil, excluding: drag.group)
        }
        private func insertionPosition(_ sender: any NSDraggingInfo) -> TabDropPosition? {
            guard let documentView, store != nil else { return nil }
            let point = documentView.convert(sender.draggingLocation, from: nil)
            let y = documentView.isFlipped ? point.y : documentView.bounds.height - point.y
            return insertionPosition(at: y, source: (sender.draggingSource as? TabDragArea.DragView)?.tab)
        }
        func insertionPosition(at y: CGFloat, source: BrowserTab?) -> TabDropPosition? {
            guard let store else { return nil }
            let entries = store.sidebarEntries
            let layout = insertionLayout
            groupTarget = nil
            outsideGroup = false
            let divider = entries.firstIndex { $0.id == SidebarEntry.newTabID } ?? 0
            pinRow = y < layout.offset(at: divider) + 8
            let row = layout.index(at: max(0, y))
            guard entries.indices.contains(row) else { return nil }
            if case .newTab = entries[row] {
                candidate = nil
                outsideGroup = !pinRow
                return nil
            }
            if case .group(let group) = entries[row] {
                let localY = y - layout.offset(at: row)
                if !group.isPinned && (localY < 7 || (group.collapsed && localY > SidebarTabMetrics.rowHeight - 7)) {
                    outsideGroup = true
                    candidate = TabDropPosition(target: group.id, after: localY >= 7)
                    return candidate
                }
                groupTarget = group.id
                candidate = nil
                return nil
            }
            if let tab = entries[row].tab, let groupID = tab.groupID,
                let group = store.tabGroups.first(where: { $0.id == groupID }), !group.isPinned,
                (row + 1 == entries.count || entries[row + 1].tab?.groupID != groupID),
                y >= layout.offset(at: row) + entries[row].height - 7
            {
                outsideGroup = true
                candidate = TabDropPosition(target: groupID, after: true)
                return candidate
            }
            let eligible = TabInsertionLayout(
                rows: entries.map {
                    .init(
                        id: $0.id, pinned: $0.tab == nil || ($0.tab?.pinned == true) != pinRow,
                        height: $0.height, containerID: $0.tab?.groupID)
                })
            candidate = eligible.position(at: y, pinned: false, previous: candidate, excluding: source?.id)
            if let position = candidate, let target = entries.first(where: { $0.id == position.target })?.tab {
                groupTarget = target.groupID
            }
            return candidate
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if let folder = validatedFolderDrag(sender) {
                setPosition?(folderPosition(sender, drag: folder))
                autoscrollDrag(at: sender.draggingLocation)
                return .move
            }
            if !BrowserDragTypes.urls(sender.draggingPasteboard).isEmpty {
                setPosition?(insertionPosition(sender))
                if store?.draggedGroupTargetID != groupTarget { store?.draggedGroupTargetID = groupTarget }
                autoscrollDrag(at: sender.draggingLocation)
                return .copy
            }
            guard let drag = validatedDrag(sender) else {
                candidate = nil
                setPosition?(nil)
                return []
            }
            let position = insertionPosition(sender)
            store?.pinDropPreview = nil
            (sender.draggingSource as? TabDragArea.DragView)?.updateDraggingPreview(grid: false)
            if store?.draggedGroupTargetID != groupTarget { store?.draggedGroupTargetID = groupTarget }
            let unpinning = (sender.draggingSource as? TabDragArea.DragView)?.tab?.pinned == true
            let sameGroup = (sender.draggingSource as? TabDragArea.DragView)?.tab?.groupID == groupTarget
            setPosition?(
                !unpinning && !outsideGroup && !pinRow && sameGroup
                    && insertionLayout.isNoOp(position, source: drag.tab) ? nil : position)

            autoscrollDrag(at: sender.draggingLocation)
            return .move
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            candidate = nil
            store?.draggedGroupTargetID = nil
            setPosition?(nil)
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if validatedFolderDrag(sender) != nil || !BrowserDragTypes.urls(sender.draggingPasteboard).isEmpty {
                return true
            }
            guard validatedDrag(sender) != nil else { return false }
            return true
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
            guard let store else { return false }
            let urls = BrowserDragTypes.urls(sender.draggingPasteboard)
            let origin = (sender.draggingSource as? TabDragArea.DragView)?.tab
            guard !urls.isEmpty || validatedDrag(sender) != nil else { return false }
            let position = insertionPosition(sender)
            var destination = position
            let targets =
                urls.isEmpty ? origin.map { [$0] } ?? [] : urls.map { store.newTab(url: $0, showOmnibar: false) }
            for preview in targets {
                let tab = preview.pinned ? store.openPinned(preview) : store.openGroupMember(preview)
                if pinRow && groupTarget == nil && !outsideGroup {
                    store.setPinPresentation(tab, row: true)
                    if let target = destination.flatMap({ p in store.rowPinnedTabs.first { $0.id == p.target } }) {
                        store.movePin(tab, before: target, after: destination?.after ?? false)
                    }
                } else {
                    if tab.pinned { store.removePin(tab) }
                    if let groupTarget {
                        let target = destination.flatMap { p in store.sidebarEntries.first { $0.id == p.target }?.tab }
                        store.insertTab(tab, in: groupTarget, relativeTo: target, after: destination?.after ?? true)
                    } else if outsideGroup {
                        store.moveTabOutsideGroup(
                            tab, relativeTo: destination?.target ?? SidebarEntry.newTabID,
                            after: destination?.after ?? false)
                    } else if let destination {
                        store.moveTab(tab.id, relativeTo: destination.target, after: destination.after)
                    } else if tab.groupID != nil {
                        store.assignTab(tab, to: nil)
                    }
                }
                destination = TabDropPosition(target: tab.id, after: true)
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

private struct TabDragPreview: View {
    @ObservedObject var tab: BrowserTab
    let store: BrowserStore
    var grid = false
    var body: some View {
        HStack(spacing: 8) {
            EditableTabIcon(tab: tab, store: store, size: 16)
            if !grid {
                Text(tab.sidebarTitle).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GolzheimIcon(icon: .close, size: 12).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 8).frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

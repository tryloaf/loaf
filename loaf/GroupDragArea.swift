import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let loafGroup = UTType(exportedAs: "app.tryloaf.loaf.group", conformingTo: .data) }
nonisolated struct FolderDrag: Codable {
    let window: UUID
    let profile: UUID
    let group: UUID
}

struct GroupDragArea: NSViewRepresentable {
    let group: TabGroup
    let store: BrowserStore
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.groupID = group.id
        view.store = store
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(group.name)
        view.setAccessibilityValue(group.collapsed ? "collapsed" : "expanded")
    }
    final class DragView: NSView, NSDraggingSource {
        var groupID: UUID?
        weak var store: BrowserStore?
        private var origin: NSPoint?
        private var dragging = false
        override var mouseDownCanMoveWindow: Bool { false }
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
            guard let store, let groupID else { return false }
            store.updateGroup(groupID) { $0.collapsed.toggle() }
            return true
        }
        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
            dragging = false
        }
        override func mouseUp(with event: NSEvent) {
            defer { origin = nil }
            guard !dragging, bounds.contains(convert(event.locationInWindow, from: nil)), let store, let groupID else {
                return
            }
            if event.clickCount == 2 {
                store.editTabGroup(groupID)
            } else {
                withAnimation(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)
                ) { store.updateGroup(groupID) { $0.collapsed.toggle() } }
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let origin, let store, let groupID,
                let group = store.tabGroups.first(where: { $0.id == groupID }),
                hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4,
                let data = try? JSONEncoder().encode(
                    FolderDrag(window: store.id, profile: store.selectedProfileID, group: groupID))
            else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: .init(UTType.loafGroup.identifier))
            let image = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                (group.name as NSString).draw(
                    in: rect.insetBy(dx: 8, dy: 6),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
                    ])
                return true
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: image)
            dragging = true
            store.draggedFolderID = groupID
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        { context == .withinApplication ? .move : [] }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            origin = nil
            dragging = false
            store?.draggedFolderID = nil
        }
    }
}

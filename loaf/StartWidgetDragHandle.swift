import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct StartWidgetDropCleanup: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var startWidgetDropCleanup: () -> Void {
        get { self[StartWidgetDropCleanup.self] }
        set { self[StartWidgetDropCleanup.self] = newValue }
    }
}

struct StartWidgetDragHandle: NSViewRepresentable {
    let payload: StartWidgetDrag
    let title: String
    @Binding var dragged: String?
    let ended: () -> Void
    let removed: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.payload = payload
        view.title = title
        view.started = { dragged = payload.widget }
        view.ended = {
            dragged = nil
            ended()
        }
        view.removed = removed
    }
    final class DragView: NSView, NSDraggingSource {
        static var grids: [UUID: WeakGrid] = [:]
        var payload: StartWidgetDrag?
        var title = ""
        var started: (() -> Void)?
        var ended: (() -> Void)?
        var removed: (() -> Void)?
        private var cancellationMonitor: Any?
        private var cancelled = false
        private var sourcePayload: StartWidgetDrag?
        private var sourceRemoved: (() -> Void)?
        private var origin: NSPoint?
        private var dragging = false
        private var hiding = false
        private var sourceTitle = ""
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
            dragging = false
        }
        override func mouseUp(with event: NSEvent) { origin = nil }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let origin,
                hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4,
                let payload, let data = try? JSONEncoder().encode(payload)
            else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.loafWidget.identifier))
            let drag = NSDraggingItem(pasteboardWriter: item)
            sourceTitle = title
            hiding = false
            let image = dragImage(hiding: false)
            drag.setDraggingFrame(
                NSRect(x: bounds.midX - 16, y: bounds.midY - image.size.height / 2,
                       width: image.size.width, height: image.size.height), contents: image)
            dragging = true
            cancelled = false
            sourcePayload = payload
            sourceRemoved = removed
            started?()
            cancellationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { MainActor.assumeIsolated { self?.cancelled = true } }
                return event
            }
            let session = beginDraggingSession(with: [drag], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            session.draggingFormation = .none
            NSCursor.closedHand.set()
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        { context == .withinApplication ? .move : [] }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        private func isOutsideGrid(_ point: NSPoint) -> Bool {
            guard let payload = sourcePayload, let grid = Self.grids[payload.window]?.view,
                let window = grid.window else { return false }

            let visible = grid.visibleRect
            guard !visible.isEmpty else { return false }
            return !window.convertToScreen(grid.convert(visible, to: nil)).insetBy(dx: -16, dy: -16).contains(point)
        }
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            let next = isOutsideGrid(screenPoint)
            if hiding != next {
                hiding = next
                session.animatesToStartingPositionsOnCancelOrFail =
                    !next && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let image = dragImage(hiding: next)
                session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) {
                    item, _, _ in
                    item.setDraggingFrame(item.draggingFrame, contents: image)
                }
            }
            (next ? NSCursor.disappearingItem : NSCursor.closedHand).set()
        }
        private func dragImage(hiding: Bool) -> NSImage {
            let size = NSSize(width: 244, height: 52)
            let title = sourceTitle
            return NSImage(size: size, flipped: false) { rect in
                let background = NSColor.windowBackgroundColor
                background.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
                (hiding ? NSColor.systemRed : NSColor.separatorColor).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
                outline.lineWidth = hiding ? 2 : 1
                outline.stroke()
                let symbol = NSImage(systemSymbolName: hiding ? "minus.circle.fill" : "hand.draw", accessibilityDescription: nil)
                symbol?.draw(in: NSRect(x: 12, y: 18, width: 16, height: 16))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in: NSRect(x: 38, y: 27, width: 194, height: 16), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ])
                let instruction = hiding ? "release to hide · esc to cancel" : "drag to move · esc to cancel"
                (instruction as NSString).draw(in: NSRect(x: 38, y: 10, width: 194, height: 14), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: hiding ? NSColor.systemRed : NSColor.secondaryLabelColor,
                ])
                return true
            }
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let cancellationMonitor {
                NSEvent.removeMonitor(cancellationMonitor)
                self.cancellationMonitor = nil
            }
            if !cancelled, operation.isEmpty, isOutsideGrid(screenPoint) {
                sourceRemoved?()
            }
            NSCursor.arrow.set()
            hiding = false
            sourceTitle = ""
            origin = nil
            dragging = false
            sourcePayload = nil
            sourceRemoved = nil
            ended?()
        }
        deinit { if let cancellationMonitor { NSEvent.removeMonitor(cancellationMonitor) } }
    }
}

struct StartWidgetGridBounds: NSViewRepresentable {
    let windowID: UUID
    func makeNSView(context: Context) -> BoundsView { BoundsView() }
    func updateNSView(_ view: BoundsView, context: Context) {
        view.windowID = windowID
        StartWidgetDragHandle.DragView.grids[windowID] = WeakGrid(view)
    }
    static func dismantleNSView(_ view: BoundsView, coordinator: ()) {
        if let id = view.windowID, StartWidgetDragHandle.DragView.grids[id]?.view === view {
            StartWidgetDragHandle.DragView.grids[id] = nil
        }
    }
    final class BoundsView: NSView {
        var windowID: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
@MainActor final class WeakGrid {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

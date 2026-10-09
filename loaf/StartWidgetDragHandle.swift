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
            let image = NSImage(size: NSSize(width: 1, height: 1))
            drag.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
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
            session.animatesToStartingPositionsOnCancelOrFail = false

        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        { context == .withinApplication ? .move : [] }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let cancellationMonitor {
                NSEvent.removeMonitor(cancellationMonitor)
                self.cancellationMonitor = nil
            }
            if !cancelled, operation.isEmpty, let payload = sourcePayload, let grid = Self.grids[payload.window]?.view,
                let window = grid.window
            {
                let frame = window.convertToScreen(grid.convert(grid.bounds, to: nil))
                if !frame.insetBy(dx: -16, dy: -16).contains(screenPoint) {
                    sourceRemoved?()
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        NSAnimationEffect.poof.show(centeredAt: screenPoint, size: .zero) {}
                    }
                }
            }
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

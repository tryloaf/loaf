import AppKit
import SwiftUI

struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    var changed: ((CGPoint, Bool) -> Void)?
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.cursor = cursor
        view.changed = context.environment.isEnabled ? changed : nil
        view.window?.invalidateCursorRects(for: view)
        view.refreshCursor()
    }
    final class Region: NSView {
        var cursor = NSCursor.arrow
        var changed: ((CGPoint, Bool) -> Void)?
        private var dragging = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { changed == nil ? nil : super.hitTest(point) }
        override func resetCursorRects() {
            if changed != nil { addCursorRect(bounds, cursor: dragging ? .closedHand : cursor) }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        func refreshCursor() {
            guard changed != nil, let window else { return }
            if dragging || bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                (dragging ? NSCursor.closedHand : cursor).set()
            }
        }
        override func cursorUpdate(with event: NSEvent) { refreshCursor() }
        override func mouseEntered(with event: NSEvent) { refreshCursor() }
        override func mouseExited(with event: NSEvent) { if !dragging { NSCursor.arrow.set() } }
        override func mouseDown(with event: NSEvent) {
            dragging = true
            changed?(convert(event.locationInWindow, from: nil), true)
            NSCursor.closedHand.set()
        }
        override func mouseDragged(with event: NSEvent) {
            changed?(convert(event.locationInWindow, from: nil), true)
            NSCursor.closedHand.set()
        }
        override func mouseUp(with event: NSEvent) {
            dragging = false
            changed?(convert(event.locationInWindow, from: nil), false)
            window?.invalidateCursorRects(for: self)
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

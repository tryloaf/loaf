import AppKit
import SwiftUI

struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    var hoverCircle: CGRect
    var changed: ((CGPoint, Bool) -> Void)?
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        let enabled = context.environment.isEnabled && changed != nil
        let geometryChanged = view.cursor !== cursor || view.hoverCircle != hoverCircle
        view.cursor = cursor
        view.hoverCircle = hoverCircle
        view.changed = enabled ? changed : nil
        if geometryChanged { view.refreshCursor() }
    }
    final class Region: NSView {
        var cursor = NSCursor.arrow
        var hoverCircle = CGRect.zero
        var changed: ((CGPoint, Bool) -> Void)?
        private var dragging = false
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { changed == nil ? nil : super.hitTest(point) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking, trackingAreas.contains(tracking) { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            tracking = area
        }
        func cursor(at point: CGPoint) -> NSCursor {
            guard changed != nil else { return .arrow }
            if dragging { return .closedHand }
            return NSBezierPath(ovalIn: hoverCircle).contains(point) ? cursor : .arrow
        }
        func refreshCursor() {
            guard let window, window.isKeyWindow, let content = window.contentView,
                content.hitTest(
                    content.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                        ?? window.mouseLocationOutsideOfEventStream) === self
            else { return }
            cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)).set()
        }
        private func refreshCursor(with event: NSEvent) {
            guard changed != nil, dragging || bounds.contains(convert(event.locationInWindow, from: nil)) else {
                return
            }
            cursor(at: convert(event.locationInWindow, from: nil)).set()
        }
        override func cursorUpdate(with event: NSEvent) {
            if changed == nil { super.cursorUpdate(with: event) } else { refreshCursor(with: event) }
        }
        override func mouseEntered(with event: NSEvent) { refreshCursor(with: event) }
        override func mouseMoved(with event: NSEvent) { refreshCursor(with: event) }
        override func mouseDown(with event: NSEvent) {
            guard changed != nil else { return }
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
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                cursor(at: convert(event.locationInWindow, from: nil)).set()
            } else {
                super.cursorUpdate(with: event)
            }
        }
    }
}

import AppKit
import SwiftUI


struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
        if let window = view.window, view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            cursor.set()
        }
    }
    final class Region: NSView {
        var cursor = NSCursor.arrow
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
    }
}

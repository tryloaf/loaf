import AppKit
import SwiftUI

struct StartWidgetResizeHandle: NSViewRepresentable {
    let size: StartWidgetSize
    let columnWidth: CGFloat
    let columns: Int
    let preview: (StartWidgetSize) -> Void
    let ended: (StartWidgetSize?) -> Void
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.size = size
        view.columnWidth = columnWidth
        view.columns = columns
        view.preview = preview
        view.ended = ended
    }
    static func dismantleNSView(_ view: ResizeView, coordinator: ()) { view.cancel() }
    final class ResizeView: NSView {
        var size: StartWidgetSize = .small
        var columnWidth: CGFloat = 300
        var columns = 2
        var preview: ((StartWidgetSize) -> Void)?
        var ended: ((StartWidgetSize?) -> Void)?
        private var origin: NSPoint?
        private var session: StartWidgetResizeSession?
        private var moved = false
        private weak var previousResponder: NSResponder?
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }
        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
            session = StartWidgetResizeSession(size: size, columnWidth: columnWidth, columns: columns)
            moved = false
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(self)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, var session else { return }
            let translation = CGSize(
                width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard hypot(translation.width, translation.height) >= 2 else { return }
            moved = true
            let last = session.preview
            let value = session.update(translation: translation)
            self.session = session
            if value != last { preview?(value) }
        }
        override func mouseUp(with event: NSEvent) { finish(commit: true) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel() } else { super.keyDown(with: event) }
        }
        func cancel() { finish(commit: false) }
        private func finish(commit: Bool) {
            guard let session else { return }
            let result = commit && moved ? session.preview : nil
            self.session = nil
            origin = nil
            moved = false
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            ended?(result)
        }
    }
}

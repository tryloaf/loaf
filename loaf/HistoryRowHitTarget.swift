import AppKit
import SwiftUI

struct HistoryRowHitTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.select = select
        view.open = open
        view.isEnabled = isEnabled
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: ClickView, context: Context) {
        view.select = select
        view.open = open
        view.isEnabled = isEnabled
    }
    final class ClickView: NSView {
        var select: ((NSEvent.ModifierFlags) -> Void)?
        var open: (() -> Void)?
        var isEnabled = true
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent,
                event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            {
                return nil
            }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.clickCount > 1 { open?() } else { select?(event.modifierFlags) }
        }
    }
}

struct LibraryDeleteKey: NSViewRepresentable {
    let enabled: Bool
    let delete: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.enabled = enabled
        view.delete = delete
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    final class KeyView: NSView {
        var enabled = false
        var delete: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }
        func handle(_ event: NSEvent) -> Bool {
            guard enabled, event.type == .keyDown, [51, 117].contains(event.keyCode),
                event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty
            else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
            if window.firstResponder is NSTextField { return false }
            delete?()
            return true
        }
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

import AppKit
import SwiftUI

struct SettingsPreviewScrollRelay: NSViewRepresentable {
    func makeNSView(context: Context) -> Relay { Relay() }
    func updateNSView(_ view: Relay, context: Context) {}
    static func dismantleNSView(_ view: Relay, coordinator: ()) { view.stop() }
    final class Relay: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) == true }
                return consumed ? nil : event
            }
        }
        func consume(_ event: NSEvent) -> Bool {
            guard event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)),
                let root = window?.contentView
            else { return false }
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            guard
                let scroll = scrollViews(root).filter({ !$0.isHidden && $0.bounds.width > 280 }).max(by: {
                    $0.bounds.width < $1.bounds.width
                })
            else { return false }
            scroll.scrollWheel(with: event)
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

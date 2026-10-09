import AppKit
import SwiftUI

struct WidgetTaskRow<Content: View>: View {
    let complete: Bool
    let toggle: () -> Void
    let remove: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var translation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            HStack {
                Button(action: {
                    toggle()
                    translation = 0
                }) { Image(systemName: complete ? "arrow.uturn.backward" : "checkmark").frame(width: 36, height: 26) }
                .tint(.accentColor)
                Spacer()
                Button(
                    role: .destructive,
                    action: {
                        remove()
                        translation = 0
                    }
                ) { Image(systemName: "trash").frame(width: 36, height: 26) }
            }.buttonStyle(.borderless).opacity(abs(translation) > 4 ? 1 : 0)
            content().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3).background(Color(nsColor: .textBackgroundColor))
                .offset(x: translation)
                .background(
                    WidgetTaskSwipeTarget(
                        translation: translation, changed: { translation = $0 },
                        settled: { value in
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0)) {
                                if value < -80 {
                                    remove()
                                    translation = 0
                                } else if value > 80 {
                                    toggle()
                                    translation = 0
                                } else {
                                    translation = abs(value) > 24 ? (value < 0 ? -44 : 44) : 0
                                }
                            }
                        }))
        }.clipped().accessibilityAction(named: Text(complete ? "mark incomplete" : "complete"), toggle)
            .accessibilityAction(named: Text("delete task"), remove)
    }
}

struct WidgetTaskSwipeTarget: NSViewRepresentable {
    let translation: CGFloat
    let changed: (CGFloat) -> Void
    let settled: (CGFloat) -> Void
    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) {
        view.restingOffset = translation
        view.changed = changed
        view.settled = settled
    }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }
    final class SwipeView: NSView {
        var restingOffset: CGFloat = 0
        private var startOffset: CGFloat = 0
        var changed: ((CGFloat) -> Void)?
        var settled: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var active = false
        private var captured = false
        private var rejected = false
        private var x: CGFloat = 0
        private var y: CGFloat = 0
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
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
        func consume(_ event: NSEvent) -> Bool {
            guard event.window === window, window?.isKeyWindow == true, event.hasPreciseScrollingDeltas else {
                return false
            }
            if !event.momentumPhase.isEmpty { return captured }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                startOffset = restingOffset
                active = bounds.contains(convert(event.locationInWindow, from: nil))
                captured = false
                rejected = false
                x = 0
                y = 0
            }
            guard active, !rejected else { return false }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                active = false
                if captured { settled?(event.phase.contains(.cancelled) ? 0 : startOffset - x) }
                return captured
            }
            x += event.scrollingDeltaX
            y += event.scrollingDeltaY
            if !captured {
                if abs(y) > 8, abs(y) >= abs(x) {
                    rejected = true
                    return false
                }
                guard abs(x) > 10, abs(x) > abs(y) * 1.5 else { return false }
                captured = true
            }
            changed?(min(100, max(-100, startOffset - x)))
            return true
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

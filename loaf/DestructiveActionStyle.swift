import AppKit
import ObjectiveC
import SwiftUI

@MainActor enum DestructiveActionStyle {
    private static var shortcutKey: UInt8 = 0
    static func configure(_ alert: NSAlert, destructive button: NSButton) {
        button.hasDestructiveAction = true
        configure(alert.window)
    }

    static func configure(_ window: NSWindow) {
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let buttons = window.contentView.map(buttons) ?? []
        guard let destructive = buttons.first(where: \.hasDestructiveAction) else { return }
        window.defaultButtonCell = nil
        for button in buttons {
            if button.keyEquivalent == "\r" { button.keyEquivalent = "" }
            button.bezelColor = nil
            button.contentTintColor = nil
        }
        destructive.toolTip = "confirm (⌘Return)"
        destructive.setAccessibilityHelp("confirm with Command-Return; Escape cancels")


        objc_setAssociatedObject(window, &shortcutKey, Shortcut(window: window, button: destructive),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private final class Shortcut {
        private var monitor: Any?
        init(window: NSWindow, button: NSButton) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak button] event in
                MainActor.assumeIsolated {
                    guard let window, window.isKeyWindow, window.isVisible, event.window === window,
                        event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command,
                        [36, 76].contains(event.keyCode), !event.isARepeat, let button, button.isEnabled
                    else { return event }
                    button.performClick(nil)
                    return nil
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    func destructiveConfirmationDialog<Actions: View, Message: View>(
        _ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> Actions, @ViewBuilder message: () -> Message
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
            actions: actions, message: message)
            .background {
                DestructiveConfirmationAppearance(presented: isPresented.wrappedValue)
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
    }
}

private struct DestructiveConfirmationAppearance: NSViewRepresentable {
    let presented: Bool
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.presented = presented
        view.styleSheetLater()
    }
    final class Anchor: NSView {
        var presented = false
        private var observations: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations = []
            guard let window else { return }
            for name in [NSWindow.willBeginSheetNotification, NSWindow.didBecomeKeyNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name,
                    object: name == NSWindow.willBeginSheetNotification ? window : nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.styleSheetLater() }
                })
            }
            styleSheetLater()
        }
        func styleSheetLater() {
            guard presented else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presented, let sheet = self.window?.attachedSheet else { return }
                DestructiveActionStyle.configure(sheet)
            }
        }
        deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }
    }
}

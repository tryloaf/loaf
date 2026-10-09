import AppKit
import WebKit

@MainActor final class CapturedPageKeyboard {
    private weak var view: WKWebView?
    private var pressed: [UInt16: NSEvent] = [:]
    func observe(_ event: NSEvent, webView: WKWebView?) {
        if view !== webView {
            release()
            view = webView
        }
        guard webView != nil else { return }
        if event.modifierFlags.contains(.command) { release() }
        switch event.type {
        case .keyDown where event.keyCode != 53 && !event.modifierFlags.contains(.command):
            pressed[event.keyCode] = event
        case .keyUp: pressed.removeValue(forKey: event.keyCode)
        default: break
        }
    }
    func release() {
        let events = pressed.values.sorted { $0.keyCode < $1.keyCode }
        pressed.removeAll()
        guard let view else { return }
        for down in events {
            guard let up = Self.keyUp(down) else { continue }
            view.keyUp(with: up)
        }
    }
    static func keyUp(_ down: NSEvent) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyUp, location: down.locationInWindow,
            modifierFlags: down.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: down.windowNumber, context: nil, characters: down.characters ?? "",
            charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: down.keyCode
        )
    }
}

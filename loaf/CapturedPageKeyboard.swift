import AppKit
import WebKit

@MainActor final class CapturedPageKeyboard {
    private weak var view: WKWebView?
    private var pressed: [UInt16: NSEvent] = [:]
    private var recoveredKeys = Set<UInt16>()
    private var releasedSamples: [UInt16: Int] = [:]
    private var recoveryTimer: Timer?
    private let keyIsDown: (UInt16) -> Bool
    init(keyIsDown: @escaping (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }) {
        self.keyIsDown = keyIsDown
    }
    func updateFocus(_ webView: WKWebView?) {
        if view !== webView {
            release()
            recoveredKeys = []
            view = webView
        }
    }
    @discardableResult func observe(_ event: NSEvent, webView: WKWebView?) -> Bool {
        updateFocus(webView)
        guard webView != nil else { return false }
        if event.modifierFlags.contains(.command) { release() }
        switch event.type {
        case .keyDown where event.keyCode != 53 && !event.modifierFlags.contains(.command):
            // Queued repeats can arrive after a recovered release. Do not restart that key.
            if event.isARepeat, pressed[event.keyCode] == nil, !keyIsDown(event.keyCode) { return true }
            recoveredKeys.remove(event.keyCode)
            pressed[event.keyCode] = event
            releasedSamples[event.keyCode] = nil
            startRecovery()
        case .keyUp:
            if recoveredKeys.remove(event.keyCode) != nil { return true }
            pressed[event.keyCode] = nil
            releasedSamples[event.keyCode] = nil
            if pressed.isEmpty { stopRecovery() }
        default: break
        }
        return false
    }
    private func startRecovery() {
        guard recoveryTimer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverReleasedKeys() }
        }
        timer.tolerance = 0.005
        recoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func recoverReleasedKeys() {
        guard let view, view.window != nil else {
            release()
            return
        }
        for (code, down) in pressed {
            if keyIsDown(code) {
                releasedSamples[code] = nil
                continue
            }
            releasedSamples[code, default: 0] += 1
            guard releasedSamples[code, default: 0] >= 2 else { continue }
            pressed[code] = nil
            recoveredKeys.insert(code)
            releasedSamples[code] = nil
            if let up = Self.keyUp(down) { view.keyUp(with: up) }
        }
        if pressed.isEmpty { stopRecovery() }
    }
    private func stopRecovery() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        releasedSamples = [:]
    }
    func release() {
        let events = pressed.values.sorted { $0.keyCode < $1.keyCode }
        pressed.removeAll()
        stopRecovery()
        guard let view else { return }
        for down in events {
            guard let up = Self.keyUp(down) else { continue }
            view.keyUp(with: up)
        }
    }
    deinit { recoveryTimer?.invalidate() }
    static func keyUp(_ down: NSEvent) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyUp, location: down.locationInWindow,
            modifierFlags: down.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: down.windowNumber, context: nil, characters: down.characters ?? "",
            charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: down.keyCode
        )
    }
}

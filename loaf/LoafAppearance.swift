import AppKit
import Combine
import SwiftUI

@MainActor final class LoafAppearance: ObservableObject {
    static let shared = LoafAppearance()
    @Published private(set) var systemScheme: ColorScheme
    private var observation: NSKeyValueObservation?

    init(application: NSApplication? = nil) {
        let application = application ?? .shared
        systemScheme = Self.scheme(application.effectiveAppearance)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next = Self.scheme(app.effectiveAppearance)
                if next != self.systemScheme { self.systemScheme = next }
            }
        }
    }

    func colorScheme(for preference: String, privateMode: Bool = false) -> ColorScheme {
        if privateMode || preference == "dark" { return .dark }
        if preference == "light" { return .light }
        return systemScheme
    }

    private static func scheme(_ appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

struct NativeWindowAppearance: NSViewRepresentable {
    let scheme: ColorScheme
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.name = scheme == .dark ? .darkAqua : .aqua
        view.apply()
    }
    final class Anchor: NSView {
        var name: NSAppearance.Name = .aqua
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window, window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }
}

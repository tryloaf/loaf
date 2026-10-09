import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor enum ExtensionTheme {
    static var appearance: NSAppearance? {
        NSAppearance(named: LoafAppearance.shared.systemScheme == .dark ? .darkAqua : .aqua)
    }
    static var colors: [String: String] {
        var result: [String: String] = [:]
        appearance?.performAsCurrentDrawingAppearance {
            for (name, color) in [
                "popup": NSColor.windowBackgroundColor, "popup_text": .labelColor, "popup_border": .separatorColor,
                "toolbar": .controlBackgroundColor, "toolbar_text": .labelColor, "frame": .windowBackgroundColor,
                "tab_background_text": .labelColor, "popup_highlight": .selectedContentBackgroundColor,
                "popup_highlight_text": .alternateSelectedControlTextColor,
            ] {
                guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                result[name] = String(
                    format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                    Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }
        }
        return result
    }
    static func bind(_ view: WKWebView) -> AnyCancellable {
        LoafAppearance.shared.$systemScheme.sink { [weak view] scheme in
            view?.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
    }
}

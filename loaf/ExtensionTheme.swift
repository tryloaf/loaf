import AppKit
import Combine
import SwiftUI
import WebKit

nonisolated struct ExtensionColorTheme: Codable, Equatable, Sendable {
    var colors: [String: ProfileColor]

    @MainActor static func parse(_ value: [String: Any]) throws -> Self {
        var colors: [String: ProfileColor] = [:]
        for (key, value) in value["colors"] as? [String: Any] ?? [:] {
            guard let color = parseColor(value) else { continue }
            colors[key] = color
        }
        guard ["frame", "toolbar", "popup"].contains(where: { colors[$0] != nil }) else {
            throw PackageError(reason: "This theme has no supported interface colors. loaf supports solid theme colors; theme images and image tints are not supported.")
        }
        return Self(colors: colors)
    }

    @MainActor private static func parseColor(_ value: Any) -> ProfileColor? {
        if let values = value as? [NSNumber], (3...4).contains(values.count) {
            let channels = values.prefix(3).map(\.doubleValue)
            guard channels.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                values.count == 3 || values[3].doubleValue == 1 else { return nil }
            return ProfileColor(hue: 0, red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255)
        }
        guard let text = value as? String else { return nil }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
        return ProfileColor(hue: 0, red: Double(number >> 16) / 255,
            green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }

    var frame: ProfileColor { colors["frame"] ?? colors["toolbar"] ?? colors["popup"] ?? ProfileColor(hue: 0) }
    var toolbar: ProfileColor { colors["toolbar"] ?? frame }
    @MainActor var scheme: ColorScheme { ChromePalette.prefersDark(on: NSColor(frame.color)) == true ? .dark : .light }
    var apiColors: [String: String] {
        colors.mapValues { color in
            let rgb = color.rgb
            return String(format: "#%02x%02x%02x", Int((rgb.red * 255).rounded()),
                Int((rgb.green * 255).rounded()), Int((rgb.blue * 255).rounded()))
        }
    }
}

extension Profile {
    var extensionColorTheme: ExtensionColorTheme? {
        guard !privateMode, let activeThemeID else { return nil }
        return extensions.first { $0.id == activeThemeID && $0.enabled }?.colorTheme
    }
    @MainActor func interfaceScheme(fallback: ColorScheme) -> ColorScheme {
        privateMode ? .dark : extensionColorTheme?.scheme ?? fallback
    }
}

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

import AppKit
import SwiftUI

struct ChromePalette {
    let dark: Bool
    var sample: NSColor? = nil
    var privateMode = false
    var primary: Color { Color(white: dark ? 0.94 : 0.08) }
    var secondary: Color { Color(white: dark ? 0.72 : 0.32) }
    var barSurface: Color {
        privateMode
            ? PrivateChrome.base
            : Color(nsColor: Self.meaningfulColor(sample) ?? NSColor(white: dark ? 0.15 : 0.88, alpha: 1))
    }
    var surface: Color {
        if privateMode { return PrivateChrome.surface }
        let behind = Self.meaningfulColor(sample) ?? NSColor(white: dark ? 0.15 : 0.88, alpha: 1)
        var fraction = dark ? 0.12 : 0.6
        var lighter = behind.blended(withFraction: fraction, of: .white) ?? behind
        while dark, Self.prefersDark(on: lighter) == false, fraction > 0.01 {
            fraction *= 0.5
            lighter = behind.blended(withFraction: fraction, of: .white) ?? behind
        }
        return Color(nsColor: lighter)
    }
    static func meaningfulColor(_ color: NSColor?) -> NSColor? {
        guard let rgb = color?.usingColorSpace(.sRGB), rgb.alphaComponent >= 0.85 else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let lightness = (values.max()! + values.min()!) / 2
        if values.max()! - values.min()! < 0.04 && lightness > 0.12 && lightness < 0.88 { return nil }
        return rgb
    }
    static func prefersDark(on color: NSColor?) -> Bool? {
        guard let rgb = color?.usingColorSpace(.sRGB), rgb.alphaComponent >= 0.85 else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard channels.allSatisfy(\.isFinite) else { return nil }
        let linear = channels.map { value in value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 < 0.179
    }
}

enum PrivateChrome {
    static let base = Color(white: 0.065)
    static let surface = Color(white: 0.115)
    static let accent = Color(white: 0.72)
}

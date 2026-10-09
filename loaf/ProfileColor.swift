import SwiftUI

nonisolated struct ProfileColor: Codable, Equatable, Sendable {
    var hue: Double
    var richness: Double = 0.5
    var red: Double?
    var green: Double?
    var blue: Double?
    static func surfaceStrength(_ value: Double) -> Double { value.isFinite ? min(0.16, max(0, value)) : 0.06 }

    static func surfaceOpacity(_ strength: Double) -> Double {
        let amount = surfaceStrength(strength) / 0.16
        return 0.92 * pow(amount, 2.8)
    }
    @MainActor static func surfaceColor(_ color: Color, strength: Double, dark: Bool) -> Color {
        let rgb = (picked(color) ?? ProfileColor(hue: 0)).rgb
        let amount = surfaceOpacity(strength)
        let base = dark ? 0.15 : 0.88
        var channels = [rgb.red, rgb.green, rgb.blue].map { base + ($0 - base) * amount }
        if dark {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            func encoded(_ value: Double) -> Double {
                value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
            }
            let values = channels.map(linear)
            let luminance = values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
            if luminance > 0.065 { channels = values.map { encoded($0 * 0.065 / luminance) } }
        }
        return Color(red: channels[0], green: channels[1], blue: channels[2])
    }
    @MainActor static func addressSurface(_ color: Color, strength: Double, dark: Bool) -> Color {
        let behind = NSColor(surfaceColor(color, strength: strength, dark: dark))
        return Color(nsColor: behind.blended(withFraction: dark ? 0.12 : 0.6, of: .white) ?? behind)
    }
    @MainActor static func surfaceScheme(_ color: Color, strength: Double, dark: Bool) -> ColorScheme {
        dark ? .dark : .light
    }
    var normalizedHue: Double {
        hue.isFinite ? (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) : 0
    }
    var normalizedRichness: Double { richness.isFinite ? min(1, max(0, richness)) : 0.5 }
    var rgb: (red: Double, green: Double, blue: Double) {
        if let red, let green, let blue, red.isFinite, green.isFinite, blue.isFinite {
            return (min(1, max(0, red)), min(1, max(0, green)), min(1, max(0, blue)))
        }
        let saturation = 0.28 + normalizedRichness * 0.3
        let value = 0.86
        let h = normalizedHue * 6
        let sector = Int(h)
        let fraction = h - Double(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    var pickerHue: Double {
        guard red != nil, green != nil, blue != nil else { return hue == 1 ? 1 : normalizedHue }
        let rgb = rgb
        let high = max(rgb.red, rgb.green, rgb.blue)
        let low = min(rgb.red, rgb.green, rgb.blue)
        let delta = high - low
        guard delta > 0 else { return normalizedHue }
        let sector: Double
        if high == rgb.red {
            sector = (rgb.green - rgb.blue) / delta
        } else if high == rgb.green {
            sector = (rgb.blue - rgb.red) / delta + 2
        } else {
            sector = (rgb.red - rgb.green) / delta + 4
        }
        return (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
    }
    var color: Color {
        let rgb = rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    @MainActor static func picked(_ color: Color) -> ProfileColor? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return ProfileColor(
            hue: 0, red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }
}
func profileTint(_ profile: Profile) -> Color {
    profile.privateMode ? PrivateChrome.accent : profile.personalization?.customTint?.color ?? profileTint(profile.tint)
}

struct ProfileColorPicker: View {
    @Binding var selection: ProfileColor?
    var fallback: Color = profileTint(0)
    var body: some View {
        ColorPicker(
            "custom color",
            selection: Binding(get: { selection?.color ?? fallback }, set: { selection = ProfileColor.picked($0) }),
            supportsOpacity: false)
    }
}

struct ProfileThemeControls: View {
    @Binding var tint: Int
    @Binding var customTint: ProfileColor?
    @Binding var strength: Double
    @Binding var transparency: Double
    var showsPreviews: Bool
    var compact: Bool
    var previewHeight: CGFloat
    var previewSettings: AppearancePreviewSettings
    var demonstration: AppearancePreviewOption?
    @State private var hex = ""
    @State private var invalidHex = false
    @FocusState private var editingHex: Bool
    init(
        tint: Binding<Int>, customTint: Binding<ProfileColor?>, strength: Binding<Double>,
        transparency: Binding<Double> = .constant(0), showsPreviews: Bool = true, compact: Bool = false,
        previewHeight: CGFloat = 186, previewSettings: AppearancePreviewSettings = .init(),
        demonstration: AppearancePreviewOption? = nil
    ) {
        _tint = tint
        _customTint = customTint
        _strength = strength
        _transparency = transparency
        self.showsPreviews = showsPreviews
        self.compact = compact
        self.previewHeight = previewHeight
        self.previewSettings = previewSettings
        self.demonstration = demonstration
    }
    private let names = ["loaf", "amber", "blue", "rose", "mint", "violet"]
    private var color: Color { customTint?.color ?? profileTint(tint) }
    private var colorHex: String {
        let rgb = (ProfileColor.picked(color) ?? ProfileColor(hue: 0)).rgb
        return String(
            format: "%02X%02X%02X", Int((rgb.red * 255).rounded()), Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded()))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            if showsPreviews {
                HStack(spacing: 12) {
                    ProfileThemePreview(
                        height: previewHeight, color: color, strength: strength, dark: false,
                        transparency: transparency, settings: previewSettings, demonstration: demonstration)
                    ProfileThemePreview(
                        height: previewHeight, color: color, strength: strength, dark: true, transparency: transparency,
                        settings: previewSettings, demonstration: demonstration)
                }
            }
            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                HStack {
                    Text("profile color").fontWeight(.medium)
                    Spacer()
                    Text("\(Int((ProfileColor.surfaceStrength(strength) / 0.16 * 100).rounded()))% intensity")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                ProfileColorPad(
                    selection: $customTint, strength: $strength, fallback: profileTint(tint),
                    height: compact ? 130 : 208)
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(0..<6) { index in
                            Button {
                                tint = index
                                customTint = nil
                            } label: {
                                Circle().fill(profileTint(index)).frame(width: 20, height: 20)
                                    .padding(4)
                                    .overlay {
                                        if tint == index && customTint == nil {
                                            Circle().strokeBorder(Color.primary.opacity(0.65), lineWidth: 1).padding(1)
                                        }
                                    }
                                    .contentShape(Circle())
                            }.buttonStyle(.plain).help(names[index]).accessibilityLabel(names[index])
                                .accessibilityAddTraits(tint == index && customTint == nil ? .isSelected : [])
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        Text("#").foregroundStyle(.secondary)
                        TextField("hex", text: $hex, axis: .horizontal).labelsHidden().textFieldStyle(.plain)
                            .lineLimit(1).fixedSize(horizontal: false, vertical: true).frame(width: 64)
                            .focused($editingHex).onSubmit { applyHex() }
                            .onChange(of: editingHex) { _, focused in if !focused { applyHex() } }
                            .accessibilityLabel("hex color")
                    }.font(.system(size: 12, design: .monospaced)).padding(7)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                    Button("reset") {
                        tint = 0
                        customTint = nil
                        strength = 0.06
                        transparency = 0
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if invalidHex {
                    Text("enter a six-digit hex color, such as 96B0E8").font(.caption).foregroundStyle(.red)
                }
                Text("drag left or right for color, up or down for intensity")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ProfileTransparencyControl(value: $transparency, height: 88)
        }.padding(.vertical, 4)
            .onAppear { hex = colorHex }
            .onChange(of: colorHex) { _, value in
                hex = value
                invalidHex = false
            }
    }
    private func applyHex() {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }), let number = UInt32(value, radix: 16) else {
            invalidHex = true
            return
        }
        customTint = ProfileColor(
            hue: 0, red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255,
            blue: Double(number & 255) / 255)
        hex = value.uppercased()
        invalidHex = false
    }
}

nonisolated struct ProfileColorPadPosition {
    var hue: Double
    var strength: Double
    static let inset: CGFloat = 22
    func point(in size: CGSize) -> CGPoint {
        let width = max(1, size.width - Self.inset * 2)
        let height = max(1, size.height - Self.inset * 2)
        return CGPoint(
            x: Self.inset + min(1, max(0, hue.isFinite ? hue : 0)) * width,
            y: Self.inset + (1 - ProfileColor.surfaceStrength(strength) / 0.16) * height)
    }
    func color(preserving current: ProfileColor?, fallbackHue: Double, in size: CGSize) -> ProfileColor? {
        let currentHue = current?.pickerHue ?? fallbackHue
        guard abs(hue - currentHue) * max(1, size.width - Self.inset * 2) > 1 else { return current }
        return ProfileColor(hue: hue, richness: 1)
    }
    static func at(_ point: CGPoint, in size: CGSize) -> Self {
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        let x = point.x.isFinite ? point.x : inset
        let y = point.y.isFinite ? point.y : inset + height
        return Self(
            hue: min(1, max(0, (x - inset) / width)),
            strength: min(1, max(0, 1 - (y - inset) / height)) * 0.16)
    }
}

struct ProfileColorPadDots: View, Animatable {
    var marker: CGPoint
    var ink: Color
    var expansion: Double
    var rowCount: Int? = nil
    var animatableData: Double {
        get { expansion }
        set { expansion = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let inset = ProfileColorPadPosition.inset
            let columns = max(2, Int((size.width - inset * 2) / 24) + 1)
            let rows = rowCount ?? max(2, Int((size.height - inset * 2) / 24) + 1)
            let dx = (size.width - inset * 2) / CGFloat(columns - 1)
            let dy = (size.height - inset * 2) / CGFloat(rows - 1)
            for row in 0..<rows {
                for column in 0..<columns {
                    let point = CGPoint(x: inset + CGFloat(column) * dx, y: inset + CGFloat(row) * dy)
                    let influence = max(0, 1 - hypot(point.x - marker.x, point.y - marker.y) / 68)
                    let aligned = abs(point.x - marker.x) < dx * 0.22 || abs(point.y - marker.y) < dy * 0.22
                    let diameter = 3.5 + 12 * influence * influence * expansion
                    let opacity = 0.2 + (aligned ? 0.22 : 0) + influence * (0.08 + expansion * 0.22)
                    let rect = CGRect(
                        x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: rect), with: .color(ink.opacity(opacity)))
                }
            }
        }
    }
}

struct ProfileColorPad: View {
    @Binding var selection: ProfileColor?
    @Binding var strength: Double
    var fallback: Color
    var height: CGFloat = 208
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    @FocusState private var focused: Bool
    private var hue: Double { (selection ?? ProfileColor.picked(fallback))?.pickerHue ?? 0 }
    private var color: Color { selection?.color ?? fallback }
    private var spectrum: [Color] { (0...12).map { ProfileColor(hue: Double($0) / 12, richness: 1).color } }
    var body: some View {
        GeometryReader { geometry in
            let marker = ProfileColorPadPosition(hue: hue, strength: strength).point(in: geometry.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(Color(white: scheme == .dark ? 0.16 : 0.84))
                LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
                    .opacity(0.92)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                Circle().fill(
                    RadialGradient(
                        colors: [color.opacity(dragging ? 0.3 : 0.12), color.opacity(0)], center: .center,
                        startRadius: 0, endRadius: dragging ? 52 : 32)
                )
                .frame(width: dragging ? 104 : 64, height: dragging ? 104 : 64).position(marker)
                ProfileColorPadDots(marker: marker, ink: scheme == .dark ? .white : .black, expansion: dragging ? 1 : 0)
                Circle().fill(.white)
                    .frame(width: dragging ? 34 : 18, height: dragging ? 34 : 18)
                    .shadow(color: .black.opacity(0.18), radius: dragging ? 10 : 3, y: 2)
                    .position(marker)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    Color.primary.opacity(focused ? 0.35 : 0.1), lineWidth: focused ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        focused = true
                        let position = ProfileColorPadPosition.at(value.location, in: geometry.size)

                        let updated = position.color(preserving: selection, fallbackHue: hue, in: geometry.size)
                        if updated != selection { selection = updated }
                        strength = position.strength
                    }
            )
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: dragging)
        }.frame(height: height)
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                shiftHue(-1 / 120)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                shiftHue(1 / 120)
                return .handled
            }
            .onKeyPress(.upArrow) {
                strength = ProfileColor.surfaceStrength(strength + 0.004)
                return .handled
            }
            .onKeyPress(.downArrow) {
                strength = ProfileColor.surfaceStrength(strength - 0.004)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("profile color and intensity")
            .accessibilityValue(
                "hue \(Int((hue * 360).rounded())) degrees, \(Int((ProfileColor.surfaceStrength(strength) / 0.16 * 100).rounded())) percent intensity"
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: strength = ProfileColor.surfaceStrength(strength + 0.004)
                case .decrement: strength = ProfileColor.surfaceStrength(strength - 0.004)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "previous color") { shiftHue(-1 / 120) }
            .accessibilityAction(named: "next color") { shiftHue(1 / 120) }
            .help("drag to change color and intensity; use arrow keys for fine adjustments")
    }
    private func shiftHue(_ amount: Double) {
        selection = ProfileColor(hue: min(1, max(0, hue + amount)), richness: 1)
    }
}

enum AppearancePreviewOption: String, CaseIterable {
    case titlebar, pageMargins, resizing, wonderbarTint
    var title: String {
        switch self {
        case .titlebar: "sidebar-only titlebar"
        case .pageMargins: "page margins"
        case .resizing: "soft resizing"
        case .wonderbarTint: "wonderbar tint"
        }
    }
}

struct AppearancePreviewSettings: Equatable {
    var sidebarOnlyTitlebar = true
    var pageMargins = true
    var softenResizing = true
    var tintWonderbar = false
    init() {}
    init(_ preferences: BrowserPreferences) {
        sidebarOnlyTitlebar = preferences.sidebarOnlyChrome != false
        pageMargins = preferences.insetCollapsedPage != false
        softenResizing = preferences.resizeTransition != false
        tintWonderbar = preferences.tintWonderbar == true
    }
    func demonstrating(_ option: AppearancePreviewOption?, enabled: Bool) -> Self {
        var value = self
        switch option {
        case .titlebar: value.sidebarOnlyTitlebar = enabled
        case .pageMargins:
            value.sidebarOnlyTitlebar = true
            value.pageMargins = enabled
        case .resizing: value.softenResizing = enabled
        case .wonderbarTint: value.tintWonderbar = enabled
        case nil: break
        }
        return value
    }
}

struct AppearancePreviewHover: ViewModifier {
    let option: AppearancePreviewOption
    @Binding var selection: AppearancePreviewOption?
    var enabled = true
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onHover { inside in
            if inside && enabled { selection = option } else if selection == option { selection = nil }
        }.onDisappear { if selection == option { selection = nil } }
            .onChange(of: enabled) { _, allowed in if !allowed && selection == option { selection = nil } }
            .accessibilityAction(named: Text("preview \(option.title)")) {
                guard enabled else { return }
                selection = selection == option ? nil : option
            }
    }
}

struct ProfileThemePreview: View {
    var height: CGFloat = 186
    let color: Color
    let strength: Double
    let dark: Bool
    var transparency: Double = 0
    var settings = AppearancePreviewSettings()
    var demonstration: AppearancePreviewOption? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoEnabled = true
    @State private var sidebarCollapsed = false
    @State private var pageBlurred = false
    private struct Playback: Equatable {
        let option: AppearancePreviewOption?
        let reduced: Bool
    }
    private var resolved: AppearancePreviewSettings { settings.demonstrating(demonstration, enabled: demoEnabled) }
    private var base: Color { Color(white: dark ? 0.15 : 0.92) }
    private var sidebarScheme: ColorScheme { ProfileColor.surfaceScheme(color, strength: strength, dark: dark) }
    private var sidebarControl: Color {
        ProfileColor.addressSurface(color, strength: strength, dark: sidebarScheme == .dark)
    }
    private var page: Color { Color(white: dark ? 0.09 : 1) }
    private var showsToolbar: Bool { !resolved.sidebarOnlyTitlebar }
    private var pageInset: CGFloat {
        !sidebarCollapsed || (resolved.sidebarOnlyTitlebar && resolved.pageMargins) ? 4 : 0
    }
    private var caption: String {
        guard let demonstration else { return dark ? "dark" : "light" }
        if demonstration == .resizing && reduceMotion { return "soft resizing · Reduce Motion" }
        return demonstration.title + " · " + (demoEnabled ? "on" : "off")
    }
    private var windowControls: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle().fill(
                    resolved.sidebarOnlyTitlebar
                        ? Color.primary.opacity(0.28) : [Color.red, .yellow, .green][index].opacity(0.7)
                ).frame(width: 5, height: 5)
            }
        }.accessibilityHidden(true)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: height < 160 ? 3 : 6) {
            HStack(spacing: 3) {
                if resolved.sidebarOnlyTitlebar { windowControls }
                Spacer(minLength: 2)
                GolzheimIcon(icon: .back, size: 7)
                GolzheimIcon(icon: .reload, size: 7)
            }.frame(height: 12)
            HStack(spacing: 3) {
                GolzheimIcon(icon: .globe, size: 7)
                Text("search or surf…").lineLimit(1)
            }
            .padding(4).frame(maxWidth: .infinity, alignment: .leading).background(
                Color.white.opacity(sidebarScheme == .dark ? 0.08 : 0.18), in: RoundedRectangle(cornerRadius: 4))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach([LoafIcon.sparkle, .favorite, .book, .globe, .folder, .music], id: \.rawValue) { icon in
                    GolzheimIcon(icon: icon, size: 9).frame(maxWidth: .infinity).frame(height: 16).background(
                        Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Label {
                Text("new tab")
            } icon: {
                GolzheimIcon(icon: .plus, size: 8)
            }.padding(.top, 3).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                GolzheimIcon(icon: .globe, size: 8)
                Text("loaf")
                Spacer(minLength: 0)
            }
            .padding(4).background(sidebarControl.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                GolzheimIcon(icon: .tray, size: 8, weight: 100)
                Spacer(minLength: 0)
                Text("personal")
                Capsule().fill(color).frame(width: 10, height: 2)
                Spacer(minLength: 0)
                GolzheimIcon(icon: .extensionPuzzle, size: 8)
            }
        }.font(.system(size: 7)).padding(height < 160 ? 5 : 6).frame(
            width: 96, height: height - (showsToolbar ? 20 : 0), alignment: .top
        )
        .environment(\.colorScheme, sidebarScheme).foregroundStyle(sidebarScheme == .dark ? Color.white : Color.black)
    }
    private var wonderbar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                GolzheimIcon(icon: .search, size: 9)
                Text("search or surf…")
                Spacer()
                Text("esc").foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 5) {
                GolzheimIcon(icon: .globe, size: 9)
                Text("loaf")
                Spacer()
                Text("↵").foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                GolzheimIcon(icon: .search, size: 9)
                Text("search the web").foregroundStyle(.secondary)
            }
        }.font(.system(size: 8)).padding(10).frame(maxWidth: 200)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(resolved.tintWonderbar ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3).padding(12)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(spacing: 0) {
                if showsToolbar {
                    HStack(spacing: 5) {
                        windowControls
                        HStack(spacing: 3) {
                            GolzheimIcon(icon: .back, size: 7)
                            GolzheimIcon(icon: .forward, size: 7)
                            GolzheimIcon(icon: .reload, size: 7)
                        }
                        Text("search or surf…").font(.system(size: 7)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).frame(maxWidth: .infinity).frame(height: 12).background(
                                Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        GolzheimIcon(icon: .plus, size: 7)
                    }.padding(.horizontal, 6).frame(height: 20)
                }
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: sidebarCollapsed ? 0 : 96)
                        ZStack {
                            page
                            VStack(spacing: 9) {
                                GolzheimIcon(icon: .sparkle, size: 20).foregroundStyle(color)
                                Text("search or surf…").font(.system(size: 8)).foregroundStyle(.secondary).padding(7)
                                    .frame(maxWidth: .infinity).background(
                                        base.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                                HStack(spacing: 5) {
                                    ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 4).fill(base).frame(height: 22)
                                    }
                                }
                            }.padding(12).blur(radius: pageBlurred ? 3 : 0).opacity(pageBlurred ? 0.45 : 1)
                        }.clipShape(RoundedRectangle(cornerRadius: pageInset == 0 ? 0 : 6)).padding(
                            [.top, .trailing, .bottom], pageInset
                        )
                        .padding(.leading, sidebarCollapsed ? pageInset : 0)
                    }
                    sidebar.offset(x: sidebarCollapsed ? -112 : 0)

                }.clipped().frame(maxHeight: .infinity)
            }.frame(height: height).background(
                ProfileWindowSurface(
                    color: ProfileColor.surfaceColor(color, strength: strength, dark: dark), transparency: transparency)
            )
            .overlay { if demonstration == .wonderbarTint { wonderbar } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .environment(\.colorScheme, dark ? .dark : .light).foregroundStyle(dark ? Color.white : Color.black)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(dark ? "dark" : "light") appearance preview").accessibilityValue(caption)
            .animation(reduceMotion || demonstration == .resizing ? nil : .smooth(duration: 0.4), value: resolved)
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: demonstration)
            .task(id: Playback(option: demonstration, reduced: reduceMotion)) { await playDemonstration() }
    }
    private func playDemonstration() async {
        demoEnabled = true
        pageBlurred = false
        sidebarCollapsed =
            demonstration == .pageMargins || demonstration == .titlebar || (reduceMotion && demonstration == .resizing)
        guard let demonstration, !reduceMotion else { return }
        do {
            while !Task.isCancelled {
                if demonstration == .resizing {
                    for enabled in [true, false] {
                        demoEnabled = enabled
                        for collapsed in [true, false] {
                            withAnimation(.easeInOut(duration: 0.26)) {
                                sidebarCollapsed = collapsed
                                pageBlurred = enabled
                            }
                            try await Task.sleep(for: .milliseconds(300))
                            withAnimation(.easeOut(duration: 0.16)) { pageBlurred = false }
                            try await Task.sleep(for: .milliseconds(1400))
                        }
                    }
                } else {
                    try await Task.sleep(for: .milliseconds(1800))
                    demoEnabled.toggle()
                }
            }
        } catch {}
    }
}

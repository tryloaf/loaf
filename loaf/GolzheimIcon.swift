import AppKit
import CoreText
import SwiftUI

enum LoafIcon: String, CaseIterable {
    case back = "←"
    case forward = "→"
    case reload = "↻"
    case close = "✗"
    case plus = "+"
    case globe = "🌐"
    case history = "🕐"
    case folder = "📁"
    case favorite = "☆"
    case pinned = "📌"
    case favoriteFilled = "★"
    case profiles = "👥"
    case advanced = "🔧"
    case pointer = "\u{E504}"
    case zoomIn = "\u{EA00}"
    case zoomOut = "\u{EA01}"
    case search = "🔍"
    case settings = "⚙"
    case shield = "🛡"
    case lock = "🔒"
    case key = "🔑"
    case download = "\u{E508}"
    case music = "🎶"
    case play = "\u{EC03}"
    case pause = "\u{EC07}"
    case volume = "🔉"
    case muted = "🔇"
    case sun = "☀"
    case cloud = "☁"
    case partlyCloudy = "⛅"
    case rain = "🌧"
    case snow = "❄"
    case storm = "⛈"
    case fog = "🌫"
    case sleep = "💤"
    case sparkle = "✨"
    case profile = "👤"
    case privateMode = "\u{E104}"
    case leaf = "🌱"
    case check = "✓"
    case more = "…"
    case book = "📖"
    case trash = "🗑"
    case external = "↗"
    case extensionPuzzle = "🧩"
    case cookie = "🙉"

    case expand = "⤢"
    case collapse = "⤡"
    case rewind = "\u{EC00}"
    case fastForward = "\u{EC04}"
    case disclosureDown = "›"
    case disclosureUp = "‹"
    case tray = ""
    case edit = "✏"
    case copy = "📓"
    case dice = "🎲"
    case eye = "👁"
    case insecure = "🔓"
    case info = "ⓘ"
    case sidebar = "◧"
    case image = "🏞"
    case language = "🗣"
    case share = "\u{E509}"
    case list = "\u{E700}"

    var fallback: String {
        switch self {
        case .back: "arrow.left"
        case .forward: "arrow.right"
        case .reload: "arrow.clockwise"
        case .close: "xmark"
        case .plus: "plus"
        case .globe: "globe"
        case .history: "clock"
        case .folder: "folder"
        case .favorite: "star"
        case .pinned: "pin"
        case .search: "magnifyingglass"
        case .favoriteFilled: "star.fill"
        case .profiles: "person.2"
        case .advanced: "wrench"
        case .pointer: "cursorarrow"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .settings: "gearshape"
        case .shield: "shield"
        case .lock: "lock"
        case .key: "key"
        case .download: "tray.and.arrow.down"
        case .music: "music.note"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .volume: "speaker.wave.2"
        case .muted: "speaker.slash"
        case .sun: "sun.max"
        case .cloud: "cloud"
        case .partlyCloudy: "cloud.sun"
        case .rain: "cloud.rain"
        case .snow: "snowflake"
        case .storm: "cloud.bolt.rain"
        case .fog: "cloud.fog"
        case .sleep: "zzz"
        case .sparkle: "sparkles"
        case .profile: "person"
        case .privateMode: "eye.slash"
        case .leaf: "leaf"
        case .check: "checkmark"
        case .more: "ellipsis"
        case .book: "book"
        case .trash: "trash"
        case .external: "arrow.up.right"
        case .extensionPuzzle: "puzzlepiece.extension"
        case .cookie: "circle.dotted"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .collapse: "arrow.down.right.and.arrow.up.left"
        case .rewind: "gobackward.15"
        case .fastForward: "goforward.15"
        case .disclosureDown: "chevron.down"
        case .disclosureUp: "chevron.up"
        case .tray: "rectangle.split.2x1"
        case .edit: "pencil"
        case .copy: "document.on.clipboard"
        case .dice: "dice"
        case .eye: "eye"
        case .insecure: "lock.open"
        case .info: "info.circle"
        case .sidebar: "sidebar.left"
        case .image: "photo"
        case .language: "character.bubble"
        case .share: "square.and.arrow.up"
        case .list: "list.bullet"
        }
    }
}
extension BrowserPage {
    var icon: LoafIcon {
        switch self {
        case .web: .globe
        case .ask: .search
        case .history: .history
        case .downloads: .download
        case .favorites: .favorite
        case .cookies: .cookie
        case .settings: .settings
        case .extensions: .extensionPuzzle
        case .profiles: .profile
        case .about: .info
        }
    }
}

@MainActor enum Golzheim {
    static let name = "GolzheimSansVAR-Regular"
    static let font: NSFont? = {

        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
        if let fonts = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in fonts
            where url.lastPathComponent.lowercased().contains("golzheimsans")
                && !url.lastPathComponent.lowercased().contains("trial")
            {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return NSFont(name: name, size: 20)
    }()
    static var available: Bool { font != nil }
    private static var cache: [String: NSImage] = [:]
    private static var fonts: [String: CTFont] = [:]
    static func weight(for size: CGFloat) -> CGFloat {

        min(300, 100 + max(0, size - 16) * 16)
    }
    static func iconFont(size: CGFloat, weight override: CGFloat? = nil, arrows: Bool = false) -> CTFont? {
        guard size.isFinite, size > 0, size <= 512, let font else { return nil }
        let key = "\(size)-\(override ?? weight(for: size))-\(arrows)"
        if let cached = fonts[key] { return cached }
        let base = CTFontCreateWithName(font.fontName as CFString, size, nil)

        let descriptor = CTFontDescriptorCreateCopyWithVariation(
            CTFontCopyFontDescriptor(base), NSNumber(value: 0x77676874), override ?? weight(for: size))
        let styled =
            arrows
            ? CTFontDescriptorCreateCopyWithAttributes(
                descriptor,
                [
                    kCTFontFeatureSettingsAttribute: [
                        [kCTFontOpenTypeFeatureTag: "ss11", kCTFontOpenTypeFeatureValue: 1]
                    ]
                ] as CFDictionary) : descriptor
        let result = CTFontCreateWithFontDescriptor(styled, size, nil)
        if fonts.count >= 64 { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = result
        return result
    }

    private static func silhouette(_ path: CGPath) -> CGPath {
        var contours: [(path: CGMutablePath, points: [CGPoint])] = []
        var current = CGMutablePath()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = CGMutablePath()
                current.move(to: element.points[0])
                contours.append((current, [element.points[0]]))
            case .addLineToPoint:
                current.addLine(to: element.points[0])
                contours[contours.count - 1].points.append(element.points[0])
            case .addQuadCurveToPoint:
                current.addQuadCurve(to: element.points[1], control: element.points[0])
                contours[contours.count - 1].points.append(contentsOf: [element.points[0], element.points[1]])
            case .addCurveToPoint:
                current.addCurve(to: element.points[2], control1: element.points[0], control2: element.points[1])
                contours[contours.count - 1].points.append(contentsOf: [
                    element.points[0], element.points[1], element.points[2],
                ])
            case .closeSubpath: current.closeSubpath()
            @unknown default: break
            }
        }
        func signedArea(_ points: [CGPoint]) -> CGFloat {
            guard let first = points.first else { return 0 }
            return zip(points, Array(points.dropFirst()) + [first]).reduce(0) { sum, pair in
                sum + pair.0.x * pair.1.y - pair.1.x * pair.0.y
            }
        }
        let areas = contours.map { signedArea($0.points) }
        let outerArea = areas.max(by: { abs($0) < abs($1) }) ?? 0
        let result = CGMutablePath()
        for (contour, area) in zip(contours, areas) {

            if area * outerArea >= 0 { result.addPath(contour.path) }
        }
        return result
    }

    static func image(
        _ glyph: String, size: CGFloat, weight: CGFloat? = nil, filled: Bool = false, fitInk: Bool = false
    ) -> NSImage? {
        let key = "\(glyph)-\(size)-\(weight ?? self.weight(for: size))-\(filled)-\(fitInk)"
        if let image = cache[key] { return image }
        let arrows = [LoafIcon.back, .forward, .external, .expand, .collapse, .reload].contains { $0.rawValue == glyph }
        guard let face = iconFont(size: size, weight: weight, arrows: arrows) else { return nil }
        let chars = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(face, chars, &glyphs, chars.count) else { return nil }
        if arrows {

            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: glyph, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face]))
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
            glyphs = runs.flatMap { run in
                var shaped = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &shaped)
                return shaped
            }
        }
        glyphs = glyphs.filter { $0 != 0 }
        guard !glyphs.isEmpty else { return nil }

        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(face, .default, glyphs, &advances, glyphs.count)
        CTFontGetBoundingRectsForGlyphs(face, .default, glyphs, &bounds, glyphs.count)
        var ink = CGRect.null
        var cursor: CGFloat = 0
        for index in glyphs.indices {
            if !bounds[index].isEmpty { ink = ink.union(bounds[index].offsetBy(dx: cursor, dy: 0)) }
            cursor += advances[index].width
        }
        guard !ink.isNull else { return nil }

        let silhouettes =
            filled
            ? glyphs.map { glyph in
                CTFontCreatePathForGlyph(face, glyph, nil).map(silhouette)
            } : []

        let image = NSImage(
            size: NSSize(
                width: fitInk ? ink.width + 4 : max(size + 4, ink.width + 4),
                height: fitInk ? ink.height + 4 : max(size + 4, ink.height + 4)), flipped: false
        ) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            var x = rect.midX - ink.midX
            let y = rect.midY - ink.midY
            var points: [CGPoint] = []
            for advance in advances {
                points.append(CGPoint(x: x, y: y))
                x += advance.width
            }
            if filled {
                for (path, point) in zip(silhouettes, points) {
                    guard let path else { continue }
                    ctx.saveGState()
                    ctx.translateBy(x: point.x, y: point.y)
                    ctx.addPath(path)
                    ctx.fillPath()
                    ctx.restoreGState()
                }
            } else {
                CTFontDrawGlyphs(face, glyphs, points, glyphs.count, ctx)
            }
            return true
        }
        image.isTemplate = true
        if cache.count >= 1024 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}

struct GolzheimIcon: View {
    var icon: LoafIcon
    var size: CGFloat = 16
    var weight: CGFloat? = nil
    var filled = false
    var body: some View {
        Group {
            if let image = Golzheim.image(
                icon.rawValue, size: size, weight: weight, filled: filled,
                fitInk: [.plus, .tray, .disclosureDown, .disclosureUp].contains(icon)
                    || [.back, .forward, .reload].contains(icon))
            {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: icon.fallback).font(.system(size: size - 2, weight: weight == nil ? .thin : .light))
            }
        }.frame(width: size + 2, height: size + 2)
            .rotationEffect(.degrees([.disclosureDown, .disclosureUp].contains(icon) ? 90 : 0)).accessibilityHidden(
                true)
    }
}

struct EmojiIcon: View {
    var glyph: String
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let image = Golzheim.image(glyph, size: size) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text(glyph).font(.system(size: size))
            }
        }.frame(width: size + 2, height: size + 2).accessibilityHidden(true)
    }
}

struct LoafButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed && enabled ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var icon: LoafIcon
    var label: String
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            GolzheimIcon(icon: icon, size: 16, weight: 220)
                .frame(width: 26, height: 26)
                .background(
                    hovered && enabled ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6)
                )
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(LoafButtonStyle()).opacity(enabled ? 1 : 0.25).animation(
            reduceMotion ? nil : .easeOut(duration: 0.12), value: enabled
        ).onHover { hovered = enabled && $0 }.help(label).accessibilityLabel(label)
    }
}

struct ChromeMoreIcon: View {
    var color: Color = .primary
    private var dots: NSImage {
        let ink = NSColor(color)
        let image = NSImage(size: .init(width: 16, height: 16), flipped: false) { _ in
            ink.setFill()
            for x in [2.0, 6.5, 11.0] { NSBezierPath(ovalIn: .init(x: x, y: 6.5, width: 3, height: 3)).fill() }
            return true
        }
        image.isTemplate = false
        return image
    }
    var body: some View {
        Image(nsImage: dots).renderingMode(.original).accessibilityHidden(true)
    }
}

struct ChromeMenuIcon: View {
    let icon: LoafIcon
    var size: CGFloat = 20
    let color: Color
    private var image: NSImage? {
        guard let source = Golzheim.image(icon.rawValue, size: size) else { return nil }
        let ink = NSColor(color)
        let result = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            ink.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
    var body: some View {
        if let image {
            Image(nsImage: image).renderingMode(.original).resizable().scaledToFit().frame(
                width: size + 2, height: size + 2
            ).accessibilityHidden(true)
        } else {
            GolzheimIcon(icon: icon, size: size).foregroundStyle(color)
        }
    }
}

struct AddressSecurityButton: View {
    let icon: LoafIcon
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            GolzheimIcon(icon: icon, size: 12, weight: 220).frame(width: 20, height: 18)
                .background(hovered ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.help("website settings").accessibilityLabel("website settings")
    }
}

struct ChromeLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            Circle().trim(from: 0.06, to: 0.78)
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .foregroundStyle(.primary).opacity(0.8)
                .rotationEffect(
                    .degrees(
                        reduceMotion
                            ? -90
                            : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85) / 0.85
                                * 360 - 90)
                )
                .frame(width: 11, height: 11)
        }.accessibilityLabel("loading")
    }
}

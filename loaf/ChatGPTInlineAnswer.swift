import AppKit
import SwiftUI
import CoreImage

private extension NSAttributedString.Key {
    static let loafCitationLabel = NSAttributedString.Key("loaf.citation.label")
}

struct ChatGPTInlineAnswer: NSViewRepresentable {
    let block: ChatGPTAnswerContent.Block
    var icons: [String: NSImage] = [:]
    var streaming = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CitationTextView {
        let storage = NSTextStorage()
        let manager = StreamingAnswerLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = CitationTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor, .cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: CitationTextView, context: Context) {
        context.coordinator.open = { url in openURL(url) }
        let signature =
            block.raw + "|\(block.style)|\(scheme)|\(compact)|\(block.streaming)|" + block.citations.map(\.id).joined(separator: "|")
            + icons.keys.sorted().joined(separator: "|")
        let manager = view.layoutManager as? StreamingAnswerLayoutManager
        manager?.reduceMotion = reduceMotion
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        let selected = view.selectedRange()
        let text = Self.render(block: block, icons: icons, dark: scheme == .dark, compact: compact)
        let previous = view.string
        view.textStorage?.setAttributedString(text)
        context.coordinator.measurementStorage.setAttributedString(text)
        view.needsLayout = true
        manager?.receive(previous: previous, current: text.string, animate: streaming && !reduceMotion)
        if selected.length > 0, NSMaxRange(selected) <= text.length { view.setSelectedRange(selected) }
        view.setAccessibilityLabel(Self.copyText(text))
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CitationTextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? 760
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 760
        let container = context.coordinator.measurementContainer
        let manager = context.coordinator.measurementManager
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height))
    }

    static func render(block: ChatGPTAnswerContent.Block, icons: [String: NSImage], dark: Bool, compact: Bool = false) -> NSAttributedString {
        let size: CGFloat
        let weight: NSFont.Weight
        if case .heading(let level) = block.style {
            size = compact ? (level <= 2 ? 17 : 15) : (level <= 2 ? 20 : 17)
            weight = .semibold
        } else {
            size = compact ? 14 : 16
            weight = .regular
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let foreground = NSColor(white: dark ? 0.88 : 0.13, alpha: 1)
        let attributed = block.text
        let result = NSMutableAttributedString(attributed)
        var offset = 0
        for run in attributed.runs {
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular) }
                if intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
            }
            let length = String(attributed[run.range].characters).utf16.count
            result.addAttributes(
                [.font: font, .foregroundColor: foreground], range: NSRange(location: offset, length: length))
            offset += length
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = compact ? 5 : 6
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        let sources = Set(block.citations.map(\.url))
        var replacements: [(NSRange, URL)] = []
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, sources.contains(url),
                result.attributedSubstring(from: range).string == ChatGPTAnswerContent.siteName(url),
                block.citations.contains(where: { $0.url == url && $0.valid })
            else { return }
            replacements.append((range, url))
        }
        for (range, url) in replacements.reversed() {
            let label = ChatGPTAnswerContent.siteName(url)
            let attachment = NSTextAttachment()
            let image = pill(label: label, favicon: icons[BrowserAddress.websiteOrigin(url) ?? ""], dark: dark)
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
            let pill = NSMutableAttributedString(attachment: attachment)
            pill.addAttributes(
                [
                    .link: url, .loafCitationLabel: label, .toolTip: url.absoluteString, .font: base,
                    .paragraphStyle: paragraph,
                ], range: NSRange(location: 0, length: pill.length))
            result.replaceCharacters(in: range, with: pill)
        }
        return result
    }

    private static func pill(label: String, favicon: NSImage?, dark: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let width = min(180, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 34)
        return NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor(white: dark ? 0.17 : 0.94, alpha: 1).setFill()
            path.fill()
            NSColor(white: dark ? 0.25 : 0.86, alpha: 0.65).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 4.5, width: 13, height: 13), xRadius: 3, yRadius: 3).addClip()
            if let favicon {
                favicon.draw(in: NSRect(x: 6, y: 4.5, width: 13, height: 13))
            } else {
                let color = NSColor(white: dark ? 0.62 : 0.48, alpha: 1)
                if let globe = Golzheim.image(LoafIcon.globe.rawValue, size: 12)
                    ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
                    let tinted = NSImage(size: globe.size, flipped: false) { rect in
                        globe.draw(in: rect)
                        color.setFill()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 6, y: 4.5, width: 13, height: 13))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            (label as NSString).draw(
                in: NSRect(x: 24, y: 4, width: width - 30, height: 14),
                withAttributes: [
                    .font: font, .foregroundColor: NSColor(white: dark ? 0.78 : 0.37, alpha: 1),
                    .paragraphStyle: paragraph,
                ])
            return true
        }
    }

    static func copyText(_ attributed: NSAttributedString) -> String {
        let result = NSMutableAttributedString(attributedString: attributed)
        var replacements: [(NSRange, String)] = []
        attributed.enumerateAttribute(.loafCitationLabel, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            if let label = value as? String { replacements.append((range, label)) }
        }
        for (range, label) in replacements.reversed() { result.replaceCharacters(in: range, with: label) }
        return result.string
    }

    final class CitationTextView: NSTextView {
        override func layout() {
            super.layout()
            guard let container = textContainer, let manager = layoutManager, bounds.width > 0 else { return }
            container.containerSize = .init(width: bounds.width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { (layoutManager as? StreamingAnswerLayoutManager)?.settle() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func copy(_ sender: Any?) {
            guard let storage = textStorage, selectedRange().length > 0 else { return }
            let text = ChatGPTInlineAnswer.copyText(storage.attributedSubstring(from: selectedRange()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measurementStorage = NSTextStorage()
        let measurementManager = NSLayoutManager()
        let measurementContainer = NSTextContainer()
        override init() {
            super.init()
            measurementContainer.lineFragmentPadding = 0
            measurementStorage.addLayoutManager(measurementManager)
            measurementManager.addTextContainer(measurementContainer)
        }
        var signature: String?
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil || ChatGPTCitation.contextID(url) != nil { open?(url) }
            return true
        }
    }
}

final class StreamingAnswerLayoutManager: NSLayoutManager {
    private struct Reveal {
        let range: NSRange
        let started: TimeInterval
        var image: NSImage?
        var bounds: NSRect = .zero
    }
    private var reveals: [Reveal] = []
    private var timer: Timer?
    var pendingRevealCount: Int { reveals.count }
    private var cachedWidth: CGFloat = 0
    private let duration: TimeInterval = 0.34
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    var reduceMotion = false {
        didSet { if reduceMotion { settle() } }
    }

    func receive(previous: String, current: String, animate: Bool) {
        guard animate, !current.isEmpty else { settle(); return }

        let old = Array(previous.utf16), new = Array(current.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        reveals.removeAll { NSMaxRange($0.range) > prefix }
        for index in reveals.indices { reveals[index].image = nil }
        let range = NSRange(location: prefix, length: new.count - prefix)
        let regex = try! NSRegularExpression(pattern: #"\S+\s*"#)
        let words = regex.matches(in: current, range: range)
        let now = ProcessInfo.processInfo.systemUptime

        if words.count > 24 {
            reveals.append(Reveal(range: range, started: now))
        } else {
            for (index, word) in words.enumerated() {
                reveals.append(Reveal(range: word.range, started: now + min(0.12, Double(index) * 0.012)))
            }
        }
        if !reveals.isEmpty && timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if let self { self.tick() } else { timer.invalidate() }
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        textContainers.first?.textView?.needsDisplay = true
    }

    func settle() {
        reveals.removeAll()
        timer?.invalidate()
        timer = nil
        textContainers.first?.textView?.needsDisplay = true
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        reveals.removeAll { now - $0.started >= duration }
        textContainers.first?.textView?.needsDisplay = true
        if reveals.isEmpty { timer?.invalidate(); timer = nil }
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard !reveals.isEmpty, let container = textContainers.first else {
            super.drawGlyphs(forGlyphRange: glyphs, at: origin)
            return
        }
        if cachedWidth != container.containerSize.width {
            cachedWidth = container.containerSize.width
            for index in reveals.indices { reveals[index].image = nil }
        }
        let now = ProcessInfo.processInfo.systemUptime
        var cursor = glyphs.location
        for index in reveals.indices {
            let reveal = reveals[index]
            let animated = glyphRange(forCharacterRange: reveal.range, actualCharacterRange: nil)
            let intersection = NSIntersectionRange(animated, glyphs)
            guard intersection.length > 0 else { continue }
            if cursor < intersection.location {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: intersection.location - cursor), at: origin)
            }
            let progress = min(1, max(0, (now - reveal.started) / duration))
            let eased = 1 - pow(1 - progress, 3)
            if progress >= 1 {
                super.drawGlyphs(forGlyphRange: intersection, at: origin)
            } else if eased > 0 {
                if reveals[index].image == nil {
                    let bounds = boundingRect(forGlyphRange: animated, in: container).insetBy(dx: -5, dy: -5).integral
                    reveals[index].bounds = bounds
                    reveals[index].image = glyphImage(animated, bounds: bounds)
                }
                if let image = reveals[index].image {
                    var displayed = image
                    let blur = 3 * (1 - eased)
                    if blur > 0.05, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let input = CIImage(cgImage: cg)
                        let filtered = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * 2])
                        if let output = imageContext.createCGImage(filtered, from: input.extent) {
                            displayed = NSImage(cgImage: output, size: image.size)
                        }
                    }
                    var rect = reveals[index].bounds
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    displayed.draw(in: rect, from: .zero, operation: .sourceOver, fraction: eased, respectFlipped: true, hints: nil)
                }
            }
            cursor = NSMaxRange(intersection)
        }
        if cursor < NSMaxRange(glyphs) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphs) - cursor), at: origin)
        }
    }

    private func glyphImage(_ range: NSRange, bounds: NSRect) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                        pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
        super.drawGlyphs(forGlyphRange: range, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

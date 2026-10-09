import AppKit
import SwiftUI

private extension NSAttributedString.Key {
    static let loafCitationLabel = NSAttributedString.Key("loaf.citation.label")
}

struct ChatGPTInlineAnswer: NSViewRepresentable {
    let block: ChatGPTAnswerContent.Block
    var icons: [String: NSImage] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CitationTextView {
        let view = CitationTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
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
            block.raw + "|\(block.style)|\(scheme)|" + block.citations.map(\.id).joined(separator: "|")
            + icons.keys.sorted().joined(separator: "|")
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        let selected = view.selectedRange()
        let text = Self.render(block: block, icons: icons, dark: scheme == .dark)
        view.textStorage?.setAttributedString(text)
        if selected.length > 0, NSMaxRange(selected) <= text.length { view.setSelectedRange(selected) }
        view.setAccessibilityLabel(Self.copyText(text))
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CitationTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 760)
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height))
    }

    static func render(block: ChatGPTAnswerContent.Block, icons: [String: NSImage], dark: Bool) -> NSAttributedString {
        let size: CGFloat
        let weight: NSFont.Weight
        if case .heading(let level) = block.style {
            size = level <= 2 ? 20 : 17
            weight = .semibold
        } else {
            size = 16
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
        paragraph.lineSpacing = 6
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        let sources = Set(block.citations.map(\.url))
        var replacements: [(NSRange, URL)] = []
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, sources.contains(url),
                result.attributedSubstring(from: range).string == ChatGPTAnswerContent.siteName(url),
                ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil
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
                color.setStroke()
                let circle = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 6, width: 10, height: 10))
                circle.lineWidth = 0.8
                circle.stroke()
                let meridian = NSBezierPath(ovalIn: NSRect(x: 10.5, y: 6, width: 4, height: 10))
                meridian.lineWidth = 0.8
                meridian.stroke()
                let equator = NSBezierPath()
                equator.move(to: NSPoint(x: 7.5, y: 11))
                equator.line(to: NSPoint(x: 17.5, y: 11))
                equator.lineWidth = 0.8
                equator.stroke()
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
        override func copy(_ sender: Any?) {
            guard let storage = textStorage, selectedRange().length > 0 else { return }
            let text = ChatGPTInlineAnswer.copyText(storage.attributedSubstring(from: selectedRange()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var signature: String?
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil { open?(url) }
            return true
        }
    }
}

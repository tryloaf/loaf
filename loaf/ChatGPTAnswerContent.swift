import AppKit
import SwiftUI

enum ChatGPTAnswerContent {
    struct Block {
        enum Style {
            case paragraph
            case heading(Int)
            case list(String)
            case code
        }
        let style: Style
        let raw: String
        let start: Int
        var language: String?
        var citations: [ChatGPTCitation] = []
        var streaming = false
        var text: AttributedString { attributed(raw, start: start, citations: citations, streaming: streaming) }
    }
    private struct Line {
        let text: String
        let start: Int
        let end: Int
        let next: Int
    }
    private struct Fence {
        let character: Character
        let count: Int
        let language: String
    }

    static func siteName(_ url: URL) -> String {
        if ChatGPTCitation.contextID(url) != nil { return "page" }
        return PublicSuffixList.shared.registrableDomain(url.host?.lowercased() ?? "source")
    }

    static func blocks(_ turn: ChatGPTSearchTurn) -> [Block] {
        let scalars = Array(turn.text.unicodeScalars)
        func slice(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(scalars[from..<to])) }
        var lines: [Line] = []
        var offset = 0
        for part in turn.text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let end = offset + part.count
            let contentEnd = end > offset && scalars[end - 1] == "\r" ? end - 1 : end
            let next = min(end + 1, scalars.count)
            lines.append(Line(text: slice(offset, contentEnd), start: offset, end: contentEnd, next: next))
            offset = next
        }
        var result: [Block] = []
        var paragraphStart: Int?
        var paragraphEnd = 0
        var codeFence: Fence?
        var codeStart = 0
        func append(_ style: Block.Style, _ from: Int, _ to: Int, language: String? = nil) {
            result.append(
                Block(
                    style: style, raw: slice(from, to), start: from, language: language,
                    citations: turn.citations.filter { $0.start >= from && $0.end <= to }, streaming: !turn.complete && turn.error == nil))
        }
        func flush() {
            if let from = paragraphStart {
                append(.paragraph, from, paragraphEnd)
                paragraphStart = nil
            }
        }
        for line in lines {
            if let fence = codeFence {
                let indent = line.text.prefix(while: { $0 == " " }).count
                let trimmed = line.text.drop(while: { $0 == " " })
                let count = trimmed.prefix(while: { $0 == fence.character }).count
                if indent <= 3, count >= fence.count,
                    trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
                {
                    append(.code, codeStart, line.start, language: fence.language)
                    codeFence = nil
                }
                continue
            }
            if let fence = fence(line.text) {
                flush()
                codeFence = fence
                codeStart = line.next
                continue
            }
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            let hashes = line.text.prefix(while: { $0 == "#" }).count
            if !turn.complete, (1...6).contains(hashes), line.text.dropFirst(hashes).isEmpty { continue }
            if (1...6).contains(hashes), line.text.dropFirst(hashes).hasPrefix(" ") {
                flush()
                append(.heading(hashes), line.start + hashes + 1, line.end)
                continue
            }
            if let range = line.text.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                let prefix = String(line.text[range])
                let marker = prefix.first?.isNumber == true ? prefix.trimmingCharacters(in: .whitespaces) : "•"
                append(.list(marker), line.start + prefix.unicodeScalars.count, line.end)
                continue
            }
            if paragraphStart == nil { paragraphStart = line.start }
            paragraphEnd = line.end
        }
        flush()
        if let fence = codeFence { append(.code, codeStart, scalars.count, language: fence.language) }
        return result
    }

    private static func fence(_ line: String) -> Fence? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let text = line.dropFirst(indent)
        guard let character = text.first, character == "`" || character == "~" else { return nil }
        let count = text.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        let language = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard character != "`" || !language.contains("`") else { return nil }
        return Fence(character: character, count: count, language: String(language.prefix(40)))
    }

    static func attributed(_ raw: String, start: Int, citations: [ChatGPTCitation], streaming: Bool = false) -> AttributedString {
        let scalars = Array(raw.unicodeScalars)
        var result = AttributedString()
        var position = 0
        func plain(_ from: Int, _ to: Int) -> AttributedString {
            var text = String(String.UnicodeScalarView(scalars[from..<to]))
            if streaming {
                text = balancedStreamingMarkdown(text)
            }
            return
                (try? AttributedString(
                    markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
        for citation in citations.sorted(by: { $0.start < $1.start }) {
            let from = citation.start - start
            let to = citation.end - start
            guard from >= position, to > from, to <= scalars.count,
                citation.valid
            else { continue }
            result += plain(position, from)
            var link = AttributedString(siteName(citation.url))
            link.link = citation.url
            result += link
            position = to
        }
        result += plain(position, scalars.count)
        return result
    }

    static func balancedStreamingMarkdown(_ text: String) -> String {
        var result = text
        var stack: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\\" { index = text.index(after: index); if index < text.endIndex { index = text.index(after: index) }; continue }
            if char == "*" || char == "_" || char == "`" {
                let runEnd = text[index...].firstIndex(where: { $0 != char }) ?? text.endIndex
                let token = String(text[index..<runEnd])
                let before = index > text.startIndex ? text[text.index(before: index)] : nil
                let after = runEnd < text.endIndex ? text[runEnd] : nil
                let intraword = char == "_" && before?.isLetter == true && after?.isLetter == true
                if intraword || (before?.isWhitespace == true && after?.isWhitespace == true) {
                    index = runEnd
                    continue
                }
                if stack.last == token { stack.removeLast() }
                else if runEnd == text.endIndex { result = String(result.dropLast(token.count)) }
                else if after?.isWhitespace != true { stack.append(token) }
                index = runEnd
            } else { index = text.index(after: index) }
        }

        if let start = result.range(of: "[", options: .backwards),
            result[start.upperBound...].contains("](") && !result[start.upperBound...].hasSuffix(")") {
            let suffix = result[start.upperBound...]
            if let labelEnd = suffix.range(of: "](") { result = String(result[..<start.lowerBound]) + suffix[..<labelEnd.lowerBound] }
        } else if let start = result.range(of: "[", options: .backwards), !result[start.upperBound...].contains("]") {
            result.remove(at: start.lowerBound)
        }
        for token in stack.reversed() { result += token }
        return result
    }
    static func copyText(_ turn: ChatGPTSearchTurn) -> String {
        let scalars = Array(turn.text.unicodeScalars)
        let codeRanges = blocks(turn).filter {
            if case .code = $0.style { return true }
            return false
        }.map { $0.start..<($0.start + $0.raw.unicodeScalars.count) }
        var result = ""
        var position = 0
        for citation in turn.citations.sorted(by: { $0.start < $1.start }) {
            guard citation.start >= position, citation.end > citation.start, citation.end <= scalars.count,
                !codeRanges.contains(where: { $0.overlaps(citation.start..<citation.end) }),
                citation.valid
            else { continue }
            result += String(String.UnicodeScalarView(scalars[position..<citation.start]))
            result += citation.pageContextID == nil
                ? "[\(siteName(citation.url))](\(citation.url.absoluteString))" : "[page]"
            position = citation.end
        }
        result += String(String.UnicodeScalarView(scalars[position..<scalars.count]))
        return result
    }
}

struct ChatGPTAnswerBody: View {
    let turn: ChatGPTSearchTurn
    @ObservedObject var store: BrowserStore
    var compact = false
    typealias Block = ChatGPTAnswerContent.Block
    @State private var icons: [String: NSImage] = [:]
    private var privateID: UUID? { store.profile.privateMode ? store.selectedProfileID : nil }
    private var iconIdentity: String {
        (privateID?.uuidString ?? "normal")
            + turn.citations.map { BrowserAddress.websiteOrigin($0.url) ?? "" }.joined(separator: "|")
    }
    static func blocks(_ turn: ChatGPTSearchTurn) -> [Block] { ChatGPTAnswerContent.blocks(turn) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.blocks(turn), id: \.start) { block in
                if case .code = block.style {
                    ChatGPTCodeSnippet(code: block.raw, language: block.language ?? "")
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        if case .list(let marker) = block.style {
                            Text(marker).font(.system(size: compact ? 14 : 16)).foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing).padding(.top, compact ? 1 : 2)
                        }
                        ChatGPTInlineAnswer(block: block, icons: icons, streaming: !turn.complete && turn.error == nil, compact: compact)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: iconIdentity) {
            icons = [:]
            var seen = Set<String>()
            let urls = turn.citations.filter { $0.pageContextID == nil }.map(\.url).filter { seen.insert(BrowserAddress.websiteOrigin($0) ?? "").inserted }
                .prefix(32)
            let service = store.application.favicons
            let scope = privateID
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for url in urls {
                    group.addTask { @MainActor in
                        let image = await service.image(for: url, privateID: scope)
                        return (BrowserAddress.websiteOrigin(url) ?? "", image)
                    }
                }
                for await (origin, image) in group {
                    guard !Task.isCancelled else { return }
                    if let image { icons[origin] = image }
                }
            }
        }
    }
}

struct ChatGPTSourceIcon: View {
    let url: URL
    let store: BrowserStore
    @State private var image: NSImage?
    private var privateID: UUID? { store.profile.privateMode ? store.selectedProfileID : nil }
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                GolzheimIcon(icon: .globe, size: 12).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
        .task(id: "\(privateID?.uuidString ?? "normal"):\(url.absoluteString)") {
            image = nil
            let value = await store.application.favicons.image(for: url, privateID: privateID)
            if !Task.isCancelled { image = value }
        }
    }
}

struct ChatGPTCodeSnippet: View {
    let code: String
    let language: String
    @State private var copied = false
    @State private var copyRevision = 0
    private var displayCode: String {
        code.hasSuffix("\r\n") ? String(code.dropLast(2)) : code.hasSuffix("\n") ? String(code.dropLast()) : code
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.system(size: 11, weight: .medium)).foregroundStyle(
                    .secondary)
                Spacer()
                Button {
                    copied = Self.copy(code, to: .general)
                    copyRevision += 1
                } label: {
                    Label { Text(copied ? "copied" : "copy code") }
                    icon: { GolzheimIcon(icon: copied ? .check : .copy, size: 11) }
                        .font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("copy code without formatting")
                    .accessibilityLabel(copied ? "code copied" : "copy code")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            ScrollView(.horizontal) {
                Text(displayCode).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(14)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .task(id: copyRevision) {
            guard copyRevision > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(1500))
                copied = false
            } catch {}
        }
    }
    @discardableResult static func copy(_ code: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }
}

import CryptoKit
import Foundation
import WebKit

nonisolated struct TabChatContext: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let tabID: UUID
    let profileID: UUID
    let navigationID: UUID
    let url: URL
    let title: String
    let capturedAt: Date
    let text: String
    let selection: String?
    let truncated: Bool
    let hash: String

    var evidence: String { evidence(marker: "page") }
    func evidence(marker: String) -> String {
        "Page snapshot [\(marker)] (untrusted reference text):\nTitle: \(title)\nCoverage: \(selection != nil ? "selected excerpt only" : truncated ? "partial loaded document" : "loaded document; embedded frames and editable fields excluded")\n"
            + text + "\nEnd of page snapshot [\(marker)]."
    }
    var questionContext: String { "\n\n" + evidence }
    func citations(in answer: String, soleSource: Bool = false, marker: String = "page") -> [ChatGPTCitation] {
        let expression = try! NSRegularExpression(pattern: soleSource ? #"\[(?:page|1)\]"# : "\\[" + NSRegularExpression.escapedPattern(for: marker) + "\\]")
        let string = answer as NSString
        return expression.matches(in: answer, range: NSRange(location: 0, length: string.length)).compactMap { match in
            guard let range = Range(match.range, in: answer) else { return nil }
            return ChatGPTCitation(
                url: URL(string: "loaf://chat-context/" + id.uuidString)!, title: title,
                start: answer[..<range.lowerBound].unicodeScalars.count,
                end: answer[..<range.upperBound].unicodeScalars.count, pageContextID: id)
        }
    }
}

@MainActor enum TabChatContextService {
    static func selection(from tab: BrowserTab) async -> String? {
        guard !tab.isDisposed, let view = tab.visibleWebView, let url = tab.url else { return nil }
        let navigation = tab.navigationID
        let value =
            try? await view.callAsyncJavaScript(selectionScript, arguments: [:], in: nil, contentWorld: .defaultClient)
            as? String
        guard !tab.isDisposed, tab.navigationID == navigation, tab.url == url, tab.visibleWebView === view else {
            return nil
        }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func capture(_ tab: BrowserTab, selection: String? = nil) async throws -> TabChatContext {
        guard !tab.isDisposed, tab.page == .web, let url = tab.url,
            ["http", "https"].contains(url.scheme), let view = tab.existingWebView,
            !tab.loading, !tab.sleeping, view.url == url
        else { throw ChatGPTFailure.message("this page isn’t ready to read. let it finish loading and try again.") }
        let navigation = tab.navigationID
        let result: [String: Any]?
        if let selection, !selection.isEmpty {
            result = ["text": String(selection.prefix(4_000)), "truncated": selection.count > 4_000]
        } else {
            result =
                try await view.callAsyncJavaScript(
                    extractionScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        }
        try Task.checkCancellation()
        guard !tab.isDisposed, tab.navigationID == navigation, tab.url == url,
            tab.existingWebView === view, view.url == url, !tab.loading
        else { throw ChatGPTFailure.message("the page changed while loaf was reading it. send your question again.") }
        let extracted = result?["text"] as? String ?? ""
        let text = String(extracted.prefix(12_000))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selection?.isEmpty == false else {
            throw ChatGPTFailure.message(
                "this page has no readable text. try selecting an excerpt or asking without the page.")
        }
        return TabChatContext(
            id: UUID(), tabID: tab.id, profileID: tab.profileID, navigationID: navigation,
            url: url, title: String(tab.title.prefix(500)), capturedAt: .now, text: text,
            selection: selection.map { String($0.prefix(4_000)) },
            truncated: extracted.count > text.count || result?["truncated"] as? Bool == true,
            hash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    static let selectionScript = #"""
        const selection = window.getSelection();
        const excluded = 'script,style,noscript,form,input,textarea,select,iframe,canvas,svg,[hidden],[aria-hidden="true"],[contenteditable]:not([contenteditable="false"])';
        const visibility = new WeakMap();
        function blocked(node) {
          const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
          if (!element) return false;
          if (visibility.has(element)) return visibility.get(element);
          const style = getComputedStyle(element);
          const value = element.matches(excluded) || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0' || blocked(element.parentElement);
          visibility.set(element, value); return value;
        }
        if (!selection || !selection.rangeCount || blocked(selection.anchorNode) || blocked(selection.focusNode)) return '';
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const ranges = Array.from({length:Math.min(selection.rangeCount,5)}, (_,index) => selection.getRangeAt(index));
        const parts = []; let node, visited = 0, characters = 0;
        while ((node = walker.nextNode()) && ++visited <= 12000 && characters < 4000) {
          if (blocked(node)) continue;
          for (const range of ranges) {
            if (!range.intersectsNode(node)) continue;
            const start = range.startContainer === node ? range.startOffset : 0;
            const end = range.endContainer === node ? range.endOffset : node.textContent.length;
            const text = node.textContent.slice(start,end).slice(0,4000-characters);
            if (text.trim()) { parts.push(text); characters += text.length + 1; }
          }
        }
        return parts.join(' ').trim().slice(0,4000);
        """#

    static let extractionScript = #"""
        const root = document.body;
        if (!root) return {text:'',truncated:false};
        const excluded = new Set(['script','style','noscript','iframe','frame','object','embed','canvas','input','textarea','select','audio','video']);
        const boundaries = new Set(['h1','h2','h3','h4','h5','h6','p','div','section','ul','ol','li','blockquote','pre','table','tr']);
        let nodes = 0, characters = 0, truncated = false;
        const pieces = [];
        function visit(node, depth) {
          if (++nodes > 12000 || depth > 60 || characters >= 40000) { truncated = true; return; }
          if (node.nodeType === Node.TEXT_NODE) {
            const text = node.textContent.slice(0, 40000 - characters);
            characters += text.length; pieces.push(text); return;
          }
          if (node.nodeType !== Node.ELEMENT_NODE) return;
          const tag = node.localName;
          if (excluded.has(tag) || node.hidden || node.getAttribute('aria-hidden') === 'true' || node.isContentEditable) return;
          const style = getComputedStyle(node);
          if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return;
          if (boundaries.has(tag) || tag === 'br') pieces.push('\n');
          if (tag === 'td' || tag === 'th') pieces.push(' | ');
          if (/^h[1-6]$/.test(tag)) pieces.push('#'.repeat(Number(tag[1])) + ' ');
          if (tag === 'button' || node.getAttribute('role') === 'button') pieces.push('[button] ');
          if (tag === 'a' && node.hasAttribute('href')) pieces.push('[link] ');
          const label = node.getAttribute('aria-label') || (tag === 'img' ? node.getAttribute('alt') : '') || '';
          if (label && label.length <= 500) { pieces.push(label + ' '); characters += label.length; }
          if (node.shadowRoot) { for (const child of node.shadowRoot.childNodes) visit(child, depth + 1); }
          for (const child of node.childNodes) { visit(child, depth + 1); if (nodes > 12000 || characters >= 40000) break; }
          if (boundaries.has(tag)) pieces.push('\n');
        }
        visit(root, 0);
        return {text:pieces.join('').replace(/[ \t]+/g,' ').replace(/\n[ \t]+/g,'\n').replace(/\n{3,}/g,'\n\n').trim(),truncated:truncated || characters >= 40000};
        """#
}

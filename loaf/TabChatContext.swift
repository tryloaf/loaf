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
        let expression = try! NSRegularExpression(
            pattern: soleSource ? #"\[(?:page|1)\]"# : "\\[" + NSRegularExpression.escapedPattern(for: marker) + "\\]")
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

    nonisolated static let selectionScript = #"""
        const selection = window.getSelection();
        const excluded = 'script,style,noscript,form,input,textarea,select,iframe,canvas,svg,[hidden],[inert],[aria-hidden="true"],[contenteditable]:not([contenteditable="false"])';
        const visibility = new WeakMap();
        function blocked(node) {
          const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
          if (!element) return false;
          if (visibility.has(element)) return visibility.get(element);
          const style = getComputedStyle(element);
          const value = element.matches(excluded) || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0' || blocked(element.parentElement);
          visibility.set(element, value); return value;
        }
        if (!selection || !selection.rangeCount || blocked(selection.anchorNode) || blocked(selection.focusNode)) return '';
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const ranges = Array.from({length:Math.min(selection.rangeCount,5)}, (_,index) => selection.getRangeAt(index));
        const parts = []; let node, visited = 0, characters = 0, previousBlock = null;
        while ((node = walker.nextNode()) && ++visited <= 12000 && characters < 4000) {
          if (blocked(node)) continue;
          for (const range of ranges) {
            if (!range.intersectsNode(node)) continue;
            const start = range.startContainer === node ? range.startOffset : 0;
            const end = range.endContainer === node ? range.endOffset : node.textContent.length;
            const block = node.parentElement.closest('p,div,li,pre,blockquote,h1,h2,h3,h4,h5,h6,tr');
            if (parts.length && block !== previousBlock) { parts.push('\n'); characters++; }
            previousBlock = block;
            const value = node.textContent.slice(start,end).replace(/[\u00ad\u200b\ufeff]/g,'').replace(/\u00a0/g,' ');
            const text = (node.parentElement.closest('pre') ? value : value.replace(/\s+/g,' ')).slice(0,Math.max(0,4000-characters));
            parts.push(text); characters += text.length;
          }
        }
        return parts.join('').replace(/ *\n/g,'\n').trim().slice(0,4000);
        """#

    nonisolated static let extractionScript = #"""
        const preferMain = typeof mainContentOnly !== 'undefined' && mainContentOnly;
        const limit = typeof characterLimit === 'number' ? Math.min(50000, Math.max(1, characterLimit)) : 40000;
        const root = (preferMain && (document.querySelector('main, [role="main"]') || document.querySelector('article'))) || document.body;
        if (!root) return {text:'',truncated:false};
        const excluded = new Set(['script','style','noscript','iframe','frame','object','embed','canvas','input','textarea','select','audio','video']);
        const boundaries = new Set(['h1','h2','h3','h4','h5','h6','p','div','section','article','main','header','footer','nav','aside','ul','ol','li','blockquote','pre','table','tr','dl','dt','dd','figure','figcaption']);
        const noise = new Set(['nav','aside','footer','form','dialog']);
        const pieces = [], seen = new WeakSet(), visibility = new WeakMap(), listCounts = new WeakMap();
        let nodes = 0, labelNodes = 0, characters = 0, truncated = false;
        const clean = text => text.replace(/[\u00ad\u200b\ufeff]/g, '').replace(/\u00a0/g, ' ');
        function emit(text) {
          const value = text.slice(0, Math.max(0, limit - characters));
          pieces.push(value); characters += value.length;
          if (value.length < text.length) truncated = true;
        }
        function blocked(element, depth = 0) {
          if (!element) return false;
          if (depth > 60) return true;
          if (visibility.has(element)) return visibility.get(element);
          const style = getComputedStyle(element);
          const parent = element.parentElement || element.getRootNode()?.host;
          const value = excluded.has(element.localName) || element.hidden || element.inert ||
            element.getAttribute('aria-hidden')?.toLowerCase() === 'true' || element.isContentEditable ||
            style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' ||
            style.opacity === '0' || blocked(parent, depth + 1);
          visibility.set(element, value); return value;
        }
        function labelText(element) {
          if (blocked(element)) return '';
          const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
          const parts = []; let node, count = 0, length = 0;
          while ((node = walker.nextNode()) && ++count <= 300 && length < 500) {
            if (++labelNodes > 12000) { truncated = true; break; }
            if (blocked(node.parentElement)) continue;
            const text = clean(node.textContent).slice(0, 500 - length);
            parts.push(text); length += text.length;
          }
          return parts.join('').replace(/\s+/g, ' ').trim();
        }
        function accessibleName(element) {
          const scope = element.getRootNode();
          const ids = (element.getAttribute('aria-labelledby') || '').trim().split(/\s+/).slice(0, 8);
          const referenced = ids.map(id => scope.getElementById?.(id)).filter(Boolean).map(labelText).filter(Boolean).join(' ');
          return clean(referenced || element.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().slice(0, 500);
        }
        function children(element, depth, pre) {
          const assigned = element.localName === 'slot' ? element.assignedNodes({flatten:true}) : [];
          const childNodes = assigned.length ? assigned : element.shadowRoot?.childNodes || element.childNodes;
          for (const child of childNodes) {
            if (nodes >= 12000 || characters >= limit) { truncated = true; break; }
            visit(child, depth + 1, pre);
          }
        }
        function visit(node, depth, pre = false) {
          if (seen.has(node)) return;
          seen.add(node);
          if (++nodes > 12000 || depth > 60 || characters >= limit) { truncated = true; return; }
          if (node.nodeType === Node.TEXT_NODE) {
            const text = clean(node.textContent);
            emit(pre ? text : text.replace(/\s+/g, ' ')); return;
          }
          if (node.nodeType !== Node.ELEMENT_NODE || blocked(node)) return;
          const tag = node.localName, role = (node.getAttribute('role') || '').toLowerCase();
          if (preferMain && (noise.has(tag) || ['navigation','banner','contentinfo','complementary'].includes(role) ||
              tag === 'header' && !node.closest('main, article, [role="main"]'))) return;
          const heading = /^h[1-6]$/.test(tag) ? Number(tag[1]) : role === 'heading' ? Math.min(6, Math.max(1, Number(node.getAttribute('aria-level')) || 2)) : 0;
          const button = tag === 'button' || role === 'button';
          const link = tag === 'a' && node.hasAttribute('href') || role === 'link';
          const image = tag === 'img' || role === 'img';
          const boundary = boundaries.has(tag) || ['heading','row','listitem','main','navigation'].includes(role);
          const name = accessibleName(node);
          if (boundary || tag === 'br') emit('\n');
          if (tag === 'td' || tag === 'th' || role === 'cell' || role === 'columnheader' || role === 'rowheader') {
            if (node.previousElementSibling) emit(' | ');
          }
          if (heading) emit('#'.repeat(heading) + ' ');
          if (tag === 'li' || role === 'listitem') {
            const parent = node.parentElement;
            const start = Number(parent?.getAttribute('start') ?? 1);
            const count = (listCounts.get(parent) ?? ((Number.isFinite(start) ? start : 1) - 1)) + 1;
            if (parent) listCounts.set(parent, count);
            emit(parent?.localName === 'ol' ? count + '. ' : '- ');
          }
          if (!preferMain && ['main','nav','aside'].includes(tag)) emit('[' + (tag === 'nav' ? 'navigation' : tag) + (name ? ': ' + name : '') + ']\n');
          if (button || link) emit(button ? ' [button] ' : ' [link] ');
          if (image) {
            const alt = name || clean(node.getAttribute('alt') || '').replace(/\s+/g, ' ').trim().slice(0, 500);
            if (alt) emit(' [image: ' + alt + '] ');
          } else if (name && (button || link || heading)) {
            emit(name);
          } else {
            children(node, depth, pre || tag === 'pre');
          }
          if (button || link) emit(' ');
          if (boundary) emit('\n');
        }
        visit(root, 0);
        return {text:pieces.join('').replace(/ *\n/g,'\n').replace(/\n{3,}/g,'\n\n').trim(),truncated};
        """#
}

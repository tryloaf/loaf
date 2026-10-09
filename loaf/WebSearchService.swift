import Foundation
import WebKit

nonisolated struct WebSearchResult: Sendable, Equatable {
    let url: URL
    let title: String
    let excerpt: String
}

@MainActor enum WebSearchService {
    static func search(_ query: String) async throws -> [WebSearchResult] {
        guard let url = SearchEngine.google.url(for: query) else { throw URLError(.badURL) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView.load(URLRequest(url: url, timeoutInterval: 12))
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard !webView.isLoading else { continue }
            let values =
                try await webView.callAsyncJavaScript(
                    #"""
                    const seen = new Set(), results = [];
                    for (const heading of document.querySelectorAll('h3')) {
                      const anchor = heading.closest('a');
                      if (!anchor) continue;
                      let url;
                      try {
                        url = new URL(anchor.href);
                        if (url.pathname === '/url') url = new URL(url.searchParams.get('q') || url.searchParams.get('url'));
                      } catch { continue; }
                      if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password ||
                          /(^|\.)google\.com$/.test(url.hostname) || seen.has(url.href)) continue;
                      seen.add(url.href);
                      let container = anchor.parentElement;
                      for (let depth = 0; depth < 5 && container?.parentElement; depth++) {
                        if (container.innerText.length > heading.innerText.length + 120) break;
                        container = container.parentElement;
                      }
                      const excerpt = (container?.innerText || heading.innerText).replace(/\s+/g, ' ').slice(0, 600);
                      results.push({url: url.href, title: heading.innerText.slice(0, 160), excerpt});
                      if (results.length === 4) break;
                    }
                    return results;
                    """#, arguments: [:], in: nil, contentWorld: .defaultClient) as? [[String: String]] ?? []
            let results = parse(values)
            if !results.isEmpty { return results }
        }
        throw ChatGPTFailure.message("web search couldn’t load results. try again or open this question in Google.")
    }

    nonisolated static func parse(_ values: [[String: String]]) -> [WebSearchResult] {
        var seen = Set<URL>()
        return values.prefix(4).compactMap { value in
            guard let address = value["url"], let url = ChatGPTProtocol.safeSourceURL(address),
                seen.insert(url).inserted, let title = value["title"], !title.isEmpty,
                let excerpt = value["excerpt"], !excerpt.isEmpty
            else { return nil }
            return WebSearchResult(url: url, title: String(title.prefix(160)), excerpt: String(excerpt.prefix(600)))
        }
    }

    nonisolated static func citations(in text: String, results: [WebSearchResult]) -> [ChatGPTCitation] {
        let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            guard let number = Int(string.substring(with: match.range(at: 1))), results.indices.contains(number - 1),
                let range = Range(match.range, in: text)
            else { return nil }
            let result = results[number - 1]
            return ChatGPTCitation(
                url: result.url, title: result.title,
                start: text[..<range.lowerBound].unicodeScalars.count,
                end: text[..<range.upperBound].unicodeScalars.count)
        }
    }
}

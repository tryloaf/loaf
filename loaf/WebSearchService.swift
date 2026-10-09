import Foundation
import WebKit

nonisolated struct WebSearchResult: Sendable, Equatable {
    let url: URL
    let title: String
    var excerpt: String
    var contentFetched = false
}

@MainActor enum WebSearchService {
    nonisolated static func isAssistantQuestion(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of:
                #"^(?:(?:what (?:is|are)|show|tell|explain|describe|repeat)(?: me)? your (?:system |developer |initial )?(?:prompt|instructions|rules|role|capabilities)|who are you|what can you do|(?:hi|hello|hey|thanks|thank you)[!.?]*$)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func isLoafQuestion(_ query: String) -> Bool {
        let text = query.lowercased()
        return text.contains("owen van vooren")
            || (text.range(of: #"\bloaf\b"#, options: .regularExpression) != nil
                && !["bread", "recipe", "bake", "calories"].contains(where: text.contains))
    }

    nonisolated static func searchQuery(_ query: String, preceding: [String]) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let followUp =
            text.range(
                of: #"\b(it|its|that|they|their|them|he|his|she|her)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        let subject = followUp ? preceding.suffix(2).joined(separator: " ") : ""
        let combined = subject.isEmpty ? text : String(subject.suffix(300)) + " " + text
        if isLoafQuestion(combined) {
            return "loaf macOS browser Owen Van Vooren " + text
                + " (site:tryloaf.app OR site:owen.uno OR site:github.com/tryloaf/loaf)"
        }
        return combined
    }

    static func search(_ query: String, reading: (([WebSearchResult]) -> Void)? = nil) async throws -> [WebSearchResult]
    {
        let official = isLoafQuestion(query)
        let seeds: [WebSearchResult] =
            official
            ? [
                .init(url: URL(string: "https://tryloaf.app/about")!, title: "about loaf", excerpt: ""),
                .init(url: URL(string: "https://tryloaf.app/")!, title: "loaf — a native browser for Mac", excerpt: ""),
                .init(url: URL(string: "https://owen.uno/")!, title: "Owen Van Vooren", excerpt: ""),
            ] : []
        var results = seeds
        if !official {
            async let primary = try? searchResults(query)
            let technical =
                query.range(
                    of: #"\b(api|sdk|swiftui|webkit|javascript|python|typescript|programming|framework|library)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            async let focused = try? searchResults(query + (technical ? " official documentation" : " official"))
            let (main, additional) = await (primary ?? [], focused ?? [])
            results =
                Array(main.prefix(3)) + Array(additional.prefix(3)) + Array(main.dropFirst(3))
                + Array(additional.dropFirst(3))
            results = results.enumerated().sorted {
                let left = relevance($0.element, query: query)
                let right = relevance($1.element, query: query)
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
        }
        var seen = Set<URL>()
        var hosts: [String: Int] = [:]
        results = results.filter { result in
            let host = result.url.host?.lowercased() ?? ""
            if official
                && !(host == "tryloaf.app" || host == "owen.uno"
                    || host == "github.com" && result.url.path.hasPrefix("/tryloaf/loaf"))
            {
                return false
            }
            guard seen.insert(result.url).inserted, hosts[host, default: 0] < 2 else { return false }
            hosts[host, default: 0] += 1
            return true
        }
        results = Array(results.prefix(6))
        reading?(results)
        let enriched = await withTaskGroup(of: (Int, WebSearchResult).self) { group in
            for (index, result) in results.enumerated() {
                group.addTask { @MainActor in
                    var source = result
                    if let text = try? await pageText(source.url), text.count >= 100 {
                        source.excerpt = relevantExcerpt(text, query: query, limit: 4_800)
                        source.contentFetched = true
                    }
                    return (index, source)
                }
            }
            var values: [(Int, WebSearchResult)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.excerpt.isEmpty }
        }
        try Task.checkCancellation()
        guard !enriched.isEmpty else {
            throw ChatGPTFailure.message(
                "web search couldn’t load useful sources. try again or open this question in your search engine.")
        }
        return enriched
    }

    nonisolated static func relevance(_ result: WebSearchResult, query: String) -> Int {
        let ignored: Set<String> = ["what", "which", "who", "does", "the", "and", "for", "are", "how", "official"]
        let terms = Set(
            query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count > 2 && !ignored.contains($0) })
        let title = result.title.lowercased()
        let excerpt = result.excerpt.lowercased()
        return terms.reduce(0) { $0 + (title.contains($1) ? 4 : excerpt.contains($1) ? 1 : 0) }
            + sourcePriority(result.url)
    }

    nonisolated static func sourcePriority(_ url: URL) -> Int {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.hasPrefix("developer.") || host.hasPrefix("developers.") || host.hasPrefix("docs.")
            || host.hasSuffix(".gov") || path.hasPrefix("/documentation/")
        {
            return 2
        }
        if ["reddit.com", "youtube.com", "facebook.com", "tiktok.com"].contains(where: {
            host == $0 || host.hasSuffix("." + $0)
        }) {
            return -1
        }
        return 0
    }

    private static func searchResults(_ query: String) async throws -> [WebSearchResult] {
        var fallback = URLComponents(string: "https://html.duckduckgo.com/html/")!
        fallback.queryItems = [URLQueryItem(name: "q", value: query)]
        let urls = [SearchEngine.google.url(for: query), fallback.url].compactMap { $0 }
        let webView = makeWebView()
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        for url in urls {
            try Task.checkCancellation()
            webView.load(URLRequest(url: url, timeoutInterval: 6))
            for attempt in 0..<60 {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                guard !webView.isLoading else { continue }
                let values =
                    try? await webView.callAsyncJavaScript(
                        Self.resultsScript, arguments: [:], in: nil, contentWorld: .defaultClient)
                    as? [[String: String]]
                let results = parse(values ?? [])
                if !results.isEmpty { return results }
                if attempt >= 20,
                    let blank = try? await webView.evaluateJavaScript("!document.body?.innerText.trim()") as? Bool,
                    blank == true
                {
                    break
                }
            }
            webView.stopLoading()
        }
        throw ChatGPTFailure.message(
            "web search couldn’t load results. try again or open this question in your search engine.")
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.customUserAgent = DesktopIdentity.userAgent(
            defaultUA:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)")
        return view
    }

    static func pageText(_ url: URL) async throws -> String {
        let data = try await AssetRequest.data(url, limit: 2_000_000)
        try Task.checkCancellation()
        guard let html = String(data: data, encoding: .utf8),
            html.range(of: "<(html|head|body|article|main|p)[ >]", options: [.regularExpression, .caseInsensitive])
                != nil
        else { return "" }
        return try await extractHTML(html, queryURL: url)
    }

    static func extractHTML(_ html: String, queryURL: URL) async throws -> String {
        let webView = makeWebView()
        defer { webView.stopLoading() }

        webView.loadHTMLString(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'\">" + html,
            baseURL: queryURL)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            try Task.checkCancellation()
            guard !webView.isLoading else { continue }
            return try await webView.callAsyncJavaScript(
                Self.pageScript, arguments: [:], in: nil,
                contentWorld: .defaultClient) as? String ?? ""
        }
        throw URLError(.timedOut)
    }

    nonisolated static let resultsScript = #"""
        const seen = new Set(), results = [];
        for (const heading of document.querySelectorAll('h3, a.result__a')) {
          const anchor = heading.matches('a') ? heading : heading.closest('a');
          if (!anchor || anchor.closest('[data-text-ad], [data-ad-client], .result--ad')) continue;
          let url;
          try {
            url = new URL(anchor.href);
            if (url.pathname === '/url' && /(^|\.)google\.com$/.test(url.hostname))
              url = new URL(url.searchParams.get('q') || url.searchParams.get('url'));
            if (/(^|\.)duckduckgo\.com$/.test(url.hostname) && url.searchParams.has('uddg'))
              url = new URL(url.searchParams.get('uddg'));
          } catch { continue; }
          if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password ||
              /(^|\.)(google|duckduckgo)\.com$/.test(url.hostname) || seen.has(url.href)) continue;
          seen.add(url.href);
          let container = anchor.parentElement;
          for (let depth = 0; depth < 7 && container?.parentElement; depth++) {
            const parent = container.parentElement;
            if (parent.querySelectorAll('h3, a.result__a').length > 1) break;
            container = parent;
            if (container.innerText.length > heading.innerText.length + 180) break;
          }
          const excerpt = (container?.innerText || heading.innerText).replace(/\s+/g, ' ').slice(0, 1200);
          results.push({url: url.href, title: heading.innerText.slice(0, 160), excerpt});
          if (results.length === 8) break;
        }
        return results;
        """#

    nonisolated static let pageScript = #"""
        const title = document.title, description = document.querySelector('meta[name="description"]')?.content || '';
        const date = document.querySelector('meta[property="article:published_time"], time[datetime]');
        const published = date?.content || date?.getAttribute('datetime') || '';
        for (const node of document.querySelectorAll('script, style, nav, header, footer, aside, form, dialog, [hidden], [aria-hidden="true"]')) node.remove();
        const root = document.querySelector('article') || document.querySelector('main, [role="main"]') || document.body;
        const blocks = Array.from(root.querySelectorAll('h1,h2,h3,h4,p,li,pre,td')).map(node =>
          node.innerText.replace(/\s+/g,' ').trim()).filter(text => text.length >= 20);
        return [title, description, published && 'Published: ' + published,
          ...(blocks.length ? blocks : [root.innerText])].filter(Boolean).join('\n').slice(0, 50000);
        """#

    nonisolated static func relevantExcerpt(_ text: String, query: String, limit: Int) -> String {
        let ignored: Set<String> = [
            "the", "a", "an", "is", "are", "what", "who", "how", "why", "of", "for", "to", "in", "on", "and", "or",
            "it", "this", "that", "with", "site", "com", "https",
        ]
        let terms = Set(
            query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count > 2 && !ignored.contains($0) })
        let paragraphs = text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if paragraphs.count <= 3 { return String(text.prefix(limit)) }
        var ranked: [(Int, Int)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let lower = paragraph.lowercased()
            ranked.append((index, terms.filter { lower.contains($0) }.count))
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var pieces = paragraphs.prefix(3).map { String($0.prefix(max(0, min(200, limit / 6)))) }
        var used = Set(paragraphs.indices.prefix(3))
        var remaining = max(0, limit - pieces.reduce(0) { $0 + $1.count + 1 })
        for (index, _) in ranked where !used.contains(index) {
            guard remaining > 0 else { break }
            let piece = String(paragraphs[index].prefix(remaining))
            pieces.append(piece)
            used.insert(index)
            remaining -= piece.count + 1
        }
        return String(pieces.joined(separator: "\n").prefix(limit))
    }

    nonisolated static func parse(_ values: [[String: String]]) -> [WebSearchResult] {
        var seen = Set<URL>()
        return values.compactMap { value in
            guard let address = value["url"], let url = ChatGPTProtocol.safeSourceURL(address),
                seen.insert(url).inserted, let title = value["title"], !title.isEmpty,
                let excerpt = value["excerpt"], !excerpt.isEmpty
            else { return nil }
            return WebSearchResult(url: url, title: String(title.prefix(160)), excerpt: String(excerpt.prefix(1200)))
        }.prefix(8).map { $0 }
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

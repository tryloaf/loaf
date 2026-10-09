import Foundation

nonisolated enum SuggestionProvider: String, Codable, CaseIterable, Sendable {
    case google, duckduckgo, wikipedia
    var title: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .wikipedia: "Wikipedia"
        }
    }
    func url(for query: String) -> URL {
        var url: URLComponents
        switch self {
        case .google:
            url = URLComponents(string: "https://www.google.com/complete/search")!
            url.queryItems = [.init(name: "client", value: "chrome"), .init(name: "q", value: query)]
        case .duckduckgo:
            url = URLComponents(string: "https://duckduckgo.com/ac/")!
            url.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        case .wikipedia:
            url = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
            url.queryItems = [
                .init(name: "action", value: "opensearch"), .init(name: "search", value: query),
                .init(name: "limit", value: "5"), .init(name: "format", value: "json"),
            ]
        }
        return url.url!
    }
}

nonisolated enum AIProvider: String, Codable, CaseIterable, Sendable {
    case chatgpt, onDevice, privateCloud
    var title: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .onDevice: "Apple Intelligence · on device"
        case .privateCloud: "Apple Intelligence · Private Cloud Compute"
        }
    }
}

nonisolated enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, googleAIOverview, bing, duckduckgo, ecosia, yahoo, wikipedia, startpage, custom
    var title: String {
        switch self {
        case .google: "Google"
        case .googleAIOverview: "Google AI Overview"
        case .bing: "Bing"
        case .duckduckgo: "DuckDuckGo"
        case .ecosia: "Ecosia"
        case .yahoo: "Yahoo"
        case .wikipedia: "Wikipedia"
        case .startpage: "Startpage"
        case .custom: "custom"
        }
    }
    var template: String {
        switch self {
        case .google, .googleAIOverview: "https://www.google.com/search?q={query}"
        case .bing: "https://www.bing.com/search?q={query}"
        case .duckduckgo: "https://duckduckgo.com/?q={query}"
        case .ecosia: "https://www.ecosia.org/search?q={query}"
        case .yahoo: "https://search.yahoo.com/search?p={query}"
        case .wikipedia: "https://en.wikipedia.org/w/index.php?search={query}"
        case .startpage: "https://www.startpage.com/sp/search?query={query}"
        case .custom: ""
        }
    }
    func url(for query: String, customTemplate: String? = nil) -> URL? {
        var redirect = SearchRedirect()
        redirect.provider = .custom
        redirect.customTemplate = self == .custom ? customTemplate ?? "" : template
        return redirect.url(for: query)
    }
}

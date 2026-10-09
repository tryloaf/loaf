import AppKit

nonisolated struct SearchRedirect: Codable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case perplexity, chatgpt, appleIntelligence, duckduckgo, google, googleAIOverview, bing, ecosia, yahoo,
            startpage, kagi, wikipedia, custom
    }
    static var availableProviders: [Provider] { Provider.allCases.filter { $0 != .googleAIOverview } }
    enum Shortcut: String, Codable, CaseIterable, Sendable {
        case commandReturn = "⌘↵"
        case optionReturn = "⌥↵"
        case commandShiftReturn = "⌘⇧↵"
        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .commandReturn: [.command]
            case .optionReturn: [.option]
            case .commandShiftReturn: [.command, .shift]
            }
        }
        func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
            flags.intersection([.command, .option, .shift, .control]) == modifiers
        }
    }
    var enabled = true
    var provider: Provider = .perplexity
    var shortcut: Shortcut = .commandReturn
    var customTemplate = "https://www.google.com/search?q={query}"
    var template: String {
        switch provider {
        case .perplexity: "https://www.perplexity.ai/search?s=o&q={query}"
        case .chatgpt, .appleIntelligence: ""
        case .ecosia: SearchEngine.ecosia.template
        case .yahoo: SearchEngine.yahoo.template
        case .startpage: SearchEngine.startpage.template
        case .duckduckgo: "https://duckduckgo.com/?q={query}"
        case .google, .googleAIOverview: "https://www.google.com/search?q={query}"
        case .bing: "https://www.bing.com/search?q={query}"
        case .kagi: "https://kagi.com/search?q={query}"
        case .wikipedia: "https://en.wikipedia.org/w/index.php?search={query}"
        case .custom:
            customTemplate.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\.", with: ".")
        }
    }
    var title: String {
        provider == .appleIntelligence
            ? "Apple Intelligence"
            : provider == .chatgpt
                ? "ChatGPT"
                : provider == .custom
                    ? "custom…"
                    : [
                        Provider.perplexity: "Perplexity", .duckduckgo: "DuckDuckGo", .google: "Google",
                        .googleAIOverview: "Google AI Overview", .bing: "Bing", .kagi: "Kagi", .wikipedia: "Wikipedia",
                        .ecosia: "Ecosia", .yahoo: "Yahoo", .startpage: "Startpage",
                    ][provider] ?? provider.rawValue
    }
    var valid: Bool { provider == .chatgpt || provider == .appleIntelligence || url(for: "loaf") != nil }
    func url(for input: String) -> URL? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, template.components(separatedBy: "{query}").count == 2,
            let placeholder = URLComponents(string: template.replacingOccurrences(of: "{query}", with: "loaf")),
            let empty = URLComponents(string: template.replacingOccurrences(of: "{query}", with: "")),
            placeholder.scheme == "https", let host = placeholder.host, !host.isEmpty,
            empty.host == host, placeholder.user == nil, placeholder.password == nil,
            let encoded = query.addingPercentEncoding(
                withAllowedCharacters: CharacterSet(
                    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")),
            let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)), url.host == host
        else { return nil }
        return url
    }
}

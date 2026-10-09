import Darwin
import Foundation

nonisolated enum BrowserBrand {
    static let name = "loaf"
    static let scheme = "loaf"
    static let website = URL(string: "https://tryloaf.app")!
    static let reportBug = URL(string: "https://tryloaf.app/report")!
    static let authorWebsite = URL(string: "https://owen.uno")!
    static let github = URL(string: "https://github.com/owenvanvooren")!
    static let bundleIdentifier = "app.tryloaf.loaf"
    static let supportDirectory = "loaf"
    static let passwordServicePrefix = "app.tryloaf.loaf.passwords."
}

enum BrowserAddress {
    nonisolated static func isDNSLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    static func isSuggestedWebsite(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil, let host = url.host?.lowercased()
        else { return false }
        let value = host.hasSuffix(".") ? String(host.dropLast()) : host
        if isLocalHost(value) { return true }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let literal = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET, literal, &ipv4) == 1 || inet_pton(AF_INET6, literal, &ipv6) == 1 { return true }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return value.utf8.count <= 253 && labels.count >= 2 && labels.allSatisfy(isDNSLabel)
            && TopLevelDomains.shared.domains.contains(labels.last ?? "")
    }

    static func domainCompletionPrefix(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        guard value.contains("."), let url = URL(string: "https://" + value), let host = url.host?.lowercased(),
            url.user == nil, url.password == nil, url.port == nil, url.path.isEmpty,
            url.query == nil, url.fragment == nil, !value.contains(where: { $0.isWhitespace }),
            !value.contains(where: { "/?#@:%".contains($0) })
        else { return nil }
        let labels = (host.hasSuffix(".") ? String(host.dropLast()) : host)
            .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.allSatisfy(isDNSLabel) else { return nil }
        return host
    }

    nonisolated static func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") || value == "::1"
            || value == "0.0.0.0"
        {
            return true
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { Int($0) }
        return components.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1])))
    }
    static func resolve(_ input: String, engine: SearchEngine = .google, customTemplate: String? = nil) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), BrowserPage.from(url) != nil { return url }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host != nil
        {
            return url
        }
        if !text.contains(where: { $0.isWhitespace }), let local = URL(string: "http://" + text),
            isLocalHost(local.host), local.user == nil, local.password == nil
        {
            return local
        }

        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil,
            text.range(of: "^[^ /:]+\\.[^ /:]+:[0-9]+", options: .regularExpression) == nil
        {
            return search(text, engine: engine, customTemplate: customTemplate)
        }
        if !text.contains(where: { $0.isWhitespace }), let url = URL(string: "https://" + text),
            isSuggestedWebsite(url)
        {
            return url
        }
        return search(text, engine: engine, customTemplate: customTemplate)
    }

    static func search(_ query: String, engine: SearchEngine = .google, customTemplate: String? = nil) -> URL? {
        engine.url(for: query, customTemplate: customTemplate)
    }

    static func defaultSearchQuery(_ url: URL?) -> String? {
        guard let url, url.scheme == "https" || url.scheme == "http",
            ["www.google.com", "google.com"].contains(url.host?.lowercased() ?? ""),
            url.user == nil, url.password == nil, url.port == nil,
            url.path == "/search", let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let queries = components.percentEncodedQueryItems?.filter { $0.name.removingPercentEncoding == "q" } ?? []

        guard queries.count == 1, let encoded = queries.first?.value,
            let query = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return query
    }

    nonisolated static func origin(_ url: URL) -> String? {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else {
            return nil
        }
        return "https://" + host + (url.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
    }

    static func domain(_ cookieDomain: String, belongsTo host: String) -> Bool {
        let domain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    static func display(_ url: URL?) -> String {
        guard let url else { return "search or surf..." }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else {
            return url.absoluteString
        }
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (url.port.map { ":\($0)" } ?? "")
            + (url.path == "/" ? "" : url.path) + (url.query.map { "?" + $0 } ?? "")
            + (url.fragment.map { "#" + $0 } ?? "")
    }
    static func suggestionLabel(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return display(url)
        }
        components.query = nil
        components.fragment = nil
        return display(components.url)
    }

    static func visible(_ text: String) -> String {
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
    static func resolveEditing(
        _ input: String, original: URL?, engine: SearchEngine = .google, customTemplate: String? = nil
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original, ["http", "https"].contains(original.scheme) else {
            return resolve(trimmed, engine: engine, customTemplate: customTemplate)
        }
        if trimmed == visible(original.absoluteString)
            || trimmed == defaultSearchQuery(original)?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return original
        }
        guard !trimmed.contains("://"),
            var candidate = resolve(trimmed, engine: engine, customTemplate: customTemplate),
            candidate.host == original.host, candidate.port == original.port
        else { return resolve(trimmed, engine: engine, customTemplate: customTemplate) }
        if original.scheme == "http", var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) {
            components.scheme = "http"
            candidate = components.url ?? candidate
        }
        return candidate
    }
}

nonisolated struct SavedTab: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = "new tab"
    var address: String?
    var pinned = false
    var page: BrowserPage = .web
    var pinnedTitle: String?
    var pinnedIcon: String?
    var pinnedAddress: String?
    var pinnedShortcutID: UUID?
    var customTitle: String?
    var groupID: UUID?
    var groupMemberID: UUID?
    var customIcon: String?
}

nonisolated enum BrowserPage: String, Codable, CaseIterable, Sendable {
    case web, ask, history, downloads, favorites, cookies, settings, extensions, profiles, about
    var settingsSection: String? {
        switch self {
        case .settings: "general"
        case .extensions: "extensions"
        case .profiles: "profiles"
        case .cookies: "privacy"
        default: nil
        }
    }
    var address: String {
        BrowserBrand.scheme + "://" + (self == .web ? "new-tab" : self == .favorites ? "bookmarks" : rawValue)
    }
    var title: String {
        self == .web ? "new tab" : self == .ask ? "ask loaf" : self == .favorites ? "bookmarks" : rawValue
    }
    var detail: String {
        switch self {
        case .web: "your start page"
        case .ask: "web answers with sources"
        case .history: "visits and browsing data"
        case .downloads: "saved and interrupted transfers"
        case .favorites: "saved websites"
        case .cookies: "cookies in this profile"
        case .settings: "browser preferences"
        case .extensions: "installed extensions"
        case .profiles: "names, icons and workspaces"
        case .about: "loaf and system information"
        }
    }
    static func from(_ url: URL) -> BrowserPage? {
        guard let scheme = url.scheme?.lowercased(), scheme == BrowserBrand.scheme,
            url.user == nil, url.password == nil, url.port == nil,
            url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return nil }
        let host = url.host?.lowercased()
        if host == "new-tab" { return .web }
        if host == "bookmarks" { return .favorites }
        return allCases.first { $0 != .web && $0.rawValue == host }
    }
}

nonisolated struct Visit: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var address: String
    var date = Date()
    var count = 1
}

nonisolated struct Favorite: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var address: String
    var folderID: UUID?
}

nonisolated enum BookmarkImport {
    static func html(_ source: String) throws -> [Favorite] {
        let regex = try NSRegularExpression(
            pattern: #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive])
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).prefix(20_000).compactMap {
            match in
            let address = decode(text.substring(with: match.range(at: 1)))
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil,
                url.user == nil, url.password == nil
            else { return nil }
            let title = decode(
                text.substring(with: match.range(at: 2)).replacingOccurrences(
                    of: "<[^>]+>", with: "", options: .regularExpression)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return Favorite(title: title.isEmpty ? url.host! : String(title.prefix(500)), address: url.absoluteString)
        }
    }
    private static func decode(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                let raw = (result as NSString).substring(with: match.range(at: 1))
                let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: result) {
                    result.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        for (entity, value) in [
            ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&"),
        ] { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}

nonisolated struct InstalledExtension: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var enabled = true
    var permissions: [String]
    var hosts: [String]
    var storeID: String?
    var version: String?
    var diagnostics: [String]?
    var status: String?
}

nonisolated struct Profile: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var emoji = "🌱"
    var tint = 0
    var tabs: [SavedTab] = []
    var pinShortcuts: [SavedTab]?
    var pinnedGroups: [TabGroup]?
    var selectedTab: UUID?
    var history: [Visit] = []
    var favorites: [Favorite] = []
    var bookmarkFolders: [BookmarkFolder]?
    var extensions: [InstalledExtension] = []
    var blockerEnabled = true
    var allowedSites: [String] = []
    var privateMode = false
    var personalization: Personalization?
    var siteSettings: [String: SiteSettings]?
    var blocksCookies: Bool?
}

nonisolated struct BrowserPreferences: Codable, Sendable {
    var googleSuggestions = false
    var savePasswords = true
    var haptics: Bool?
    var autofillPasswords: Bool?
    var allowsPointerCapture: Bool?
    var weatherCity = ""
    var fahrenheit = true
    var sidebarWidth = 220.0
    var remoteSites: Bool?
    var alternateSearch: SearchRedirect?
    var developerMenu: Bool?
    var inspectorMode: InspectorMode?
    var userAgentMode: UserAgentMode?
    var weatherProvider: String?
    var restoreSession: Bool?
    var warnBeforeQuitting: Bool?
    var sleepIdleTabs: Bool?
    var sidebarOnlyChrome: Bool?
    var insetCollapsedPage: Bool?
    var downloadFolder: String?
    var asksBeforeDownloading: Bool?
    var pinnedLayout: String?
    var resizeTransition: Bool?
    var tintWonderbar: Bool?
    var tabSleepMinutes: Int?
    var customNewTabURL: String?
    var searchEngine: SearchEngine?
    var customSearchTemplate: String?
    var suggestionProvider: SuggestionProvider?
    var aiProvider: AIProvider?
    mutating func configureOnboardingAlternateSearch() {
        var redirect = alternateSearch ?? SearchRedirect()
        redirect.enabled = aiFeaturesEnabled != false && aiProvider != nil
        redirect.provider = aiProvider == .chatgpt ? .chatgpt : .appleIntelligence
        alternateSearch = redirect
    }
    var aiFeaturesEnabled: Bool?
    var powerSaver: Bool?
    var powerSaverThreshold: Int?
    var tracksScreenTime: Bool?
    var linkTabGroups: Bool?
    var webNotifications: Bool?
    var onboardingCompleted: Bool?
    var allowsScriptJavaScript: Bool?
    var sleepInterval: TimeInterval {
        TimeInterval(([5, 10, 15, 30, 60, 120, 240].contains(tabSleepMinutes ?? 30) ? tabSleepMinutes ?? 30 : 30) * 60)
    }
}

nonisolated enum InspectorMode: String, Codable, CaseIterable, Sendable { case detached, inline }

nonisolated struct BrowserSnapshot: Codable, Sendable {
    var version = 1
    var profiles: [Profile]
    var selectedProfile: UUID
    var preferences: BrowserPreferences
    var windows: [SavedWindow]?
}

enum AdBlockDomains {

    static func parse(_ source: String) -> [String] {
        var blocked = Set<String>()
        var exceptions = Set<String>()
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let allowed = line.hasPrefix("@@||")
            guard line.hasPrefix("||") || allowed, line.hasSuffix("^") else { continue }
            let domain = String(line.dropFirst(allowed ? 4 : 2).dropLast()).lowercased()
            guard domain.range(of: "^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}$", options: .regularExpression) != nil,
                !domain.contains("..")
            else { continue }
            if allowed { exceptions.insert(domain) } else { blocked.insert(domain) }
        }
        return blocked.filter { domain in !exceptions.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) }
            .sorted()
    }

    static func rules(_ domains: [String]) throws -> String {

        let rules: [[String: Any]] = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?" + escaped + "[:/]",
                    "resource-type": [
                        "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup",
                    ],
                ], "action": ["type": "block"],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated enum UserAgentMode: String, Codable, CaseIterable, Sendable {
    case automatic, desktop, safariIPhone, safariIPad, edgeMac, edgeWindows, edgeAndroid, chromeMac, chromeWindows,
        chromeAndroid, chromeOS, firefoxMac, firefoxWindows, firefoxAndroid, custom
    var title: String {
        switch self {
        case .automatic: "automatic"
        case .desktop: "Safari · macOS"
        case .safariIPhone: "Safari · iPhone"
        case .safariIPad: "Safari · iPad"
        case .edgeMac: "Microsoft Edge · macOS"
        case .edgeWindows: "Microsoft Edge · Windows"
        case .edgeAndroid: "Microsoft Edge · Android"
        case .chromeMac: "Google Chrome · macOS"
        case .chromeWindows: "Google Chrome · Windows"
        case .chromeAndroid: "Google Chrome · Android"
        case .chromeOS: "Google Chrome · ChromeOS"
        case .firefoxMac: "Firefox · macOS"
        case .firefoxWindows: "Firefox · Windows"
        case .firefoxAndroid: "Firefox · Android"
        case .custom: "custom…"
        }
    }
}
nonisolated struct SiteSettings: Codable, Sendable {
    var savePasswords: Bool?
    var downloads: Bool?
    var pointerLock: String?
    var automaticPopups: Bool?
    var javascript = true
    var autoplay = false
    var zoom = 1.0
    var camera = "ask"
    var microphone = "ask"
    var location: String?
    var notifications: String?
    var userAgent: UserAgentMode = .desktop
    var customUserAgent: String?
}
nonisolated struct Personalization: Codable, Sendable {
    var customTint: ProfileColor?
    var sidebarWeather: Bool?
    var compactSidebarWeather: Bool?
    var tintStrength = 0.06
    var windowTransparency: Double?
    var background = "profile"
    var pinStyle = "tiles"
    var widgets = ["clock", "weather", "pins", "recent", "notes"]
    var hiddenWidgets: [String] = []
    var widgetSizes: [String: StartWidgetSize]? = ["clock": .square, "weather": .square]
    var widgetOptions: [String: StartWidgetOptions]?
    var widgetPositions: [String: StartWidgetPosition]?
    var notes = ""
    var checklistItems: [StartChecklistItem]?
}
nonisolated struct TabGroup: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "untitled group"
    var icon = "📁"
    var color = 2
    var collapsed = false
    var savedTabs: [SavedTab]?
    var isPinned: Bool { savedTabs != nil }
}

nonisolated struct WindowWorkspace: Codable, Sendable {
    var sidebarOrder: [UUID]?
    var groups: [TabGroup]?
    var tabs: [SavedTab] = []
    var selectedTab: UUID?
}
nonisolated struct SavedWindow: Codable, Identifiable, Sendable {
    var id = UUID()
    var selectedProfile: UUID
    var workspaces: [UUID: WindowWorkspace]
    var frame: String?
    var sidebarVisible = true
}
enum ClearingTimeframe: String, CaseIterable {
    case hour = "last hour"
    case day = "last 24 hours"
    case week = "last seven days"
    case month = "last four weeks"
    case all = "all time"
    func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(
            -([Self.hour: 3600.0, .day: 86400, .week: 604800, .month: 2419200][self] ?? now.timeIntervalSince1970))
    }
}
struct ClearingRequest {
    var timeframe: ClearingTimeframe = .hour
    var history = true
    var cookies = false
    var cache = false
    var downloads = false
}

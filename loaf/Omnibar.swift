import Combine
import SwiftUI

nonisolated enum OmnibarMetrics {
    static func layout(in height: Double) -> (top: Double, suggestions: Double) {
        let suggestions = min(228, max(36, height - 108))
        return (max(12, (height - (56 + 1 + suggestions + 28)) / 2), suggestions)
    }
    static func width(in available: Double) -> Double {
        guard available.isFinite else { return 520 }
        let room = max(0, available - 48)
        return min(room, 600, 440 + 160 * (1 - exp(-max(0, available - 480) / 480)))
    }
}

enum SuggestionKind { case tab, history, favorite, site, search, page }
struct Suggestion: Identifiable {
    let id: String
    let title: String
    var detail: String
    let icon: LoafIcon
    let destination: String
    var tabID: UUID?
    var kind: SuggestionKind = .search
    var siteURL: URL? { kind == .search || kind == .page ? nil : BrowserAddress.resolve(destination) }
    var defaultSearchQuery: String? { BrowserAddress.defaultSearchQuery(siteURL) }
    var displayIcon: LoafIcon { defaultSearchQuery != nil ? .search : icon }
    var visibleTitle: String { defaultSearchQuery ?? (kind == .search ? title : BrowserAddress.visible(title)) }
    var fieldText: String {
        defaultSearchQuery ?? (kind == .search ? title : kind == .page ? destination : BrowserAddress.display(siteURL))
    }
    var visibleDetail: String {
        guard defaultSearchQuery != nil else { return BrowserAddress.visible(detail) }
        if kind == .tab { return detail }
        return kind == .favorite ? "favorite · google search" : "google search"
    }
    var preview: String {
        if let query = defaultSearchQuery { return "google search · " + query }
        if kind == .search { return detail + " · " + title }
        let address = BrowserAddress.display(siteURL)
        return visibleTitle == address || id == "input" ? address : visibleTitle + " · " + address
    }
}

@MainActor enum SuggestionRanking {
    struct Accumulator {
        let transform: (Suggestion) -> Suggestion
        let key: (Suggestion) -> String
        private var entries: [(original: Suggestion, score: Double, result: Suggestion, key: String)] = []
        init(transform: @escaping (Suggestion) -> Suggestion, key: @escaping (Suggestion) -> String) {
            self.transform = transform
            self.key = key
        }
        private static func precedes(_ value: (Suggestion, Double), _ other: (Suggestion, Double)) -> Bool {
            value.1 == other.1 ? value.0.id < other.0.id : value.1 > other.1
        }
        mutating func offer(score: Double, make: () -> Suggestion) {

            if entries.count == 6, score < entries.last!.score { return }
            let original = make()
            let value = (original, score)
            if entries.count == 6, let last = entries.last, !Self.precedes(value, (last.original, last.score)) {
                return
            }
            let result = transform(original)
            let identity = key(result)
            if let index = entries.firstIndex(where: { $0.key == identity }) {
                guard Self.precedes(value, (entries[index].original, entries[index].score)) else { return }
                entries.remove(at: index)
            }
            entries.append((original, score, result, identity))
            entries.sort { Self.precedes(($0.original, $0.score), ($1.original, $1.score)) }
            if entries.count > 6 { entries.removeLast() }
        }
        var results: [Suggestion] { entries.map(\.result) }
    }
    static func best(
        _ entries: [(Suggestion, Double)], transform: @escaping (Suggestion) -> Suggestion,
        key: @escaping (Suggestion) -> String
    ) -> [Suggestion] {
        var ranking = Accumulator(transform: transform, key: key)
        for (value, score) in entries { ranking.offer(score: score) { value } }
        return ranking.results
    }
}

@MainActor final class SuggestionEngine: ObservableObject {
    @Published var suggestions: [Suggestion] = []
    @Published var selectedID: String?
    @Published var remoteLoading = false
    @Published var keyboardSelection = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var previousQuery = ""
    private var publishedQuery = ""
    private var profileID: UUID?
    private weak var currentStore: BrowserStore?
    private var tldObserver: AnyCancellable?
    private struct HistorySource: Equatable {
        let profile: UUID
        let visits: [Visit]
    }
    private final class PreparedVisit {
        let visit: Visit
        let title: String
        let address: String
        let host: String
        private let url: URL?

        lazy var label = BrowserAddress.suggestionLabel(url)
        let catalogHost: String?
        let titleSearch: NSString
        let addressSearch: NSString
        init(_ visit: Visit) {
            self.visit = visit
            let url = URL(string: visit.address)
            let title = visit.title.lowercased()
            let address = visit.address.lowercased()
            self.url = url
            self.title = title
            self.address = address
            let rawHost = url?.host?.lowercased() ?? ""
            let catalogHost = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            self.catalogHost =
                url.map {
                    ["https", "http"].contains($0.scheme) && $0.user == nil && $0.password == nil && $0.port == nil
                        && !catalogHost.isEmpty
                } == true ? catalogHost : nil
            host = url?.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
            titleSearch = title as NSString
            addressSearch = address as NSString
        }
        func score(for needle: String) -> Double? {
            if needle.isEmpty { return 0 }
            if host.hasPrefix(needle) || address.hasPrefix(needle) { return 120 }
            if title.hasPrefix(needle) { return 100 }

            if titleSearch.range(of: needle).location != NSNotFound
                || addressSearch.range(of: needle).location != NSNotFound
            {
                return 45
            }
            return nil
        }
    }
    private weak var historyOwner: BrowserStore?
    private var historyObserver: AnyCancellable?
    private var preparedHistory: [PreparedVisit] = []
    private var preparedHistoryByID: [UUID: PreparedVisit] = [:]
    private var hostVisits: [String: Int] = [:]
    private(set) var historyPreparations = 0
    private(set) var historyRowsPrepared = 0
    private var preparedProfileID: UUID?
    private struct PreparedOpenTab {
        let title: String
        let address: String
        let canonicalAddress: String
        let canonicalDisplayAddress: String
        let lowerTitle: String
        let lowerAddress: String
        let host: String
        let titleSearch: NSString
        let addressSearch: NSString
        func score(for needle: String) -> Double? {
            if needle.isEmpty { return 0 }
            if host.hasPrefix(needle) || lowerAddress.hasPrefix(needle) { return 120 }
            if lowerTitle.hasPrefix(needle) { return 100 }
            if titleSearch.range(of: needle).location != NSNotFound
                || addressSearch.range(of: needle).location != NSNotFound
            {
                return 45
            }
            return nil
        }
    }
    private var preparedOpenTabs: [UUID: PreparedOpenTab] = [:]
    private var openTabProfileID: UUID?
    private var openTabProfileIsPrivate = false
    func belongs(to profile: UUID) -> Bool { profileID == profile }
    func represents(_ query: String, profile: UUID) -> Bool { previousQuery == query && profileID == profile }
    func action(for chosen: Suggestion? = nil, query: String, profile: UUID) -> Suggestion? {
        if let chosen, belongs(to: profile) { return suggestions.first { $0.id == chosen.id } }
        guard represents(query, profile: profile) else { return nil }
        guard publishedQuery == query || explicitSelection else { return nil }
        return suggestions.indices.contains(selected) ? suggestions[selected] : nil
    }
    private let fetch: (URL) async throws -> Data
    private struct CacheKey: Hashable {
        let profile: UUID
        let query: String
        let searches: Bool
        let sites: Bool
        let provider: SuggestionProvider
    }
    private struct Cached {
        let date: Date
        let values: [Suggestion]
    }
    private var cache: [CacheKey: Cached] = [:]
    init(fetch: @escaping (URL) async throws -> Data = { try await AssetRequest.data($0, limit: 100_000) }) {
        self.fetch = fetch
        tldObserver = TopLevelDomains.shared.changes.sink { [weak self] in
            guard let self, let store = self.currentStore else { return }
            self.cache.removeAll()
            self.update(self.previousQuery, store: store)
        }
    }
    private var explicitSelection = false
    var selected: Int {
        get { suggestions.firstIndex { $0.id == selectedID } ?? 0 }
        set {
            selectedID = suggestions.indices.contains(newValue) ? suggestions[newValue].id : nil
            explicitSelection = true
        }
    }
    func update(_ query: String, store: BrowserStore) {
        currentStore = store
        let sameProfile = profileID == store.selectedProfileID
        if query != previousQuery || profileID != store.selectedProfileID {
            selectedID = nil
            previousQuery = query
            profileID = store.selectedProfileID
            explicitSelection = false
            keyboardSelection = false
        }
        task?.cancel()
        remoteLoading = false
        let token = UUID()
        generation = token
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainPrefix = BrowserAddress.domainCompletionPrefix(text)
        let needle = domainPrefix ?? text.lowercased()
        prepareHistory(for: store)
        func preparedScore(_ title: String, _ address: String, _ host: String) -> Double? {
            if needle.isEmpty { return 0 }
            if host.hasPrefix(needle) || address.hasPrefix(needle) { return 120 }
            if title.hasPrefix(needle) { return 100 }
            if title.contains(needle) || address.contains(needle) { return 45 }
            return nil
        }
        func score(_ title: String, _ address: String) -> Double? {
            if needle.isEmpty { return 0 }
            return preparedScore(
                title.lowercased(), address.lowercased(),
                URL(string: address)?.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? "")
        }
        let runtimeTabs = store.runtime.tabs
        let windows = store.application.windows
        let orderedWindows = windows.filter { $0 === store } + windows.filter { $0 !== store }
        let openTabs = orderedWindows.flatMap { window in
            window.workspaces[store.selectedProfileID]?.tabs.compactMap { runtimeTabs[$0.id] } ?? []
        }
        let previousTabs = openTabProfileID == store.selectedProfileID ? preparedOpenTabs : [:]
        var nextTabs: [UUID: PreparedOpenTab] = [:]
        nextTabs.reserveCapacity(openTabs.count)
        var tabsByAddress: [String: BrowserTab] = [:]
        func tabAction(_ suggestion: Suggestion) -> Suggestion {
            guard suggestion.kind != .search && suggestion.kind != .page,
                let tab = tabsByAddress[canonical(suggestion.destination, kind: suggestion.kind)]
            else { return suggestion }
            return Suggestion(
                id: "tab-\(tab.id)", title: tab.sidebarTitle,
                detail: tab.windowID == store.id ? "switch to tab" : "switch to tab · other window", icon: .globe,
                destination: tab.url!.absoluteString, tabID: tab.id, kind: .tab)
        }
        var ranking = SuggestionRanking.Accumulator(transform: tabAction) {
            self.canonical($0.destination, kind: $0.kind)
        }
        func consider(_ suggestion: @autoclosure () -> Suggestion, score: Double) {
            guard let domainPrefix else {
                ranking.offer(score: score, make: suggestion)
                return
            }
            let value = suggestion()
            let url = value.kind == .search || value.kind == .page ? nil : URL(string: value.destination)
            let host = url?.host?.lowercased() ?? ""
            let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let completion =
                BrowserAddress.isSuggestedWebsite(url) && key.hasPrefix(domainPrefix)
                && value.defaultSearchQuery == nil
            ranking.offer(score: score + (completion ? 160 : 0)) { value }
        }
        for page in BrowserPage.allCases {
            if page == .ask && store.preferences.aiFeaturesEnabled == false { continue }
            if let score = score(page.title, page.address) {
                consider(
                    Suggestion(
                        id: "page-" + page.rawValue, title: page.title, detail: page.address, icon: page.icon,
                        destination: page.address, kind: .page), score: needle.isEmpty ? -20 : score + 40)
            }
        }

        for tab in openTabs where tab.url != nil {
            let url = tab.url!
            let address = url.absoluteString
            let title = tab.sidebarTitle
            let row: PreparedOpenTab
            if let existing = previousTabs[tab.id], existing.title == title, existing.address == address {
                row = existing
            } else {
                let lowerTitle = title.lowercased()
                let lowerAddress = address.lowercased()
                row = PreparedOpenTab(
                    title: title, address: address, canonicalAddress: canonical(address, kind: .tab),
                    canonicalDisplayAddress: canonical("https://" + BrowserAddress.display(url), kind: .tab),
                    lowerTitle: lowerTitle, lowerAddress: lowerAddress,
                    host: url.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? "",
                    titleSearch: lowerTitle as NSString, addressSearch: lowerAddress as NSString)
            }
            nextTabs[tab.id] = row
            let key = row.canonicalAddress
            if tabsByAddress[key] == nil { tabsByAddress[key] = tab }
            if let score = row.score(for: needle) {
                consider(
                    Suggestion(
                        id: "tab-\(tab.id)", title: title,
                        detail: tab.windowID == store.id ? "switch to tab" : "switch to tab · other window",
                        icon: .globe, destination: address, tabID: tab.id, kind: .tab), score: score + 30)
            }
        }
        preparedOpenTabs = nextTabs
        openTabProfileID = store.selectedProfileID
        openTabProfileIsPrivate = store.profile.privateMode
        for favorite in store.profile.favorites {
            if let score = score(favorite.title, favorite.address) {
                consider(
                    Suggestion(
                        id: "favorite-\(favorite.id)", title: favorite.title,
                        detail: "favorite · " + BrowserAddress.suggestionLabel(URL(string: favorite.address)),
                        icon: .favorite, destination: favorite.address, kind: .favorite), score: score + 20)
            }
        }
        let now = Date()
        for row in preparedHistory {
            let visit = row.visit
            if let score = row.score(for: needle) {
                consider(
                    Suggestion(
                        id: "history-" + visit.address, title: visit.title, detail: row.label, icon: .history,
                        destination: visit.address, kind: .history),
                    score: score + max(0, 12 - now.timeIntervalSince(visit.date) / 86400))
            }
        }

        let siteNeedle = needle.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        let homepageIntent = !siteNeedle.contains(where: { "/?#@: ".contains($0) })
        if homepageIntent {
            for site in store.application.sites.entries {
                guard let url = URL(string: site.address), BrowserAddress.isSuggestedWebsite(url),
                    url.scheme == "https", url.user == nil, url.password == nil,
                    url.port == nil, url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
                    let host = url.host?.lowercased()
                else { continue }
                let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let count = hostVisits[key] ?? 0
                guard count >= 3,
                    siteNeedle.isEmpty || key.hasPrefix(siteNeedle) || site.title.lowercased().hasPrefix(siteNeedle)
                else { continue }
                let base: Double = siteNeedle.isEmpty ? 0 : key.hasPrefix(siteNeedle) ? 120 : 100
                consider(
                    Suggestion(
                        id: "frequent-site-" + site.address, title: site.title,
                        detail: BrowserAddress.suggestionLabel(url), icon: .globe, destination: site.address,
                        kind: .site), score: base + 25 + min(22, log2(Double(count)) * 5))
            }
        }
        if !needle.isEmpty {
            for site in store.application.sites.entries {
                guard BrowserAddress.isSuggestedWebsite(URL(string: site.address)) else { continue }
                if let score = score(site.title, site.address), score >= 100 {
                    consider(
                        Suggestion(
                            id: "site-" + site.address, title: site.title,
                            detail: BrowserAddress.suggestionLabel(URL(string: site.address)), icon: .globe,
                            destination: site.address, kind: .site), score: score - 12)
                }
            }
            if let domainPrefix, !store.profile.privateMode, store.preferences.remoteSites == true {


                for (key, cached) in cache where key.profile == store.selectedProfileID && key.sites
                    && key.provider == (store.preferences.suggestionProvider ?? .google)
                    && Date().timeIntervalSince(cached.date) < 300
                {
                    for site in cached.values where site.kind == .site {
                        guard let url = site.siteURL, BrowserAddress.isSuggestedWebsite(url),
                            let host = url.host?.lowercased()
                        else { continue }
                        let hostKey = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        guard hostKey.hasPrefix(domainPrefix) else { continue }
                        consider(site, score: 120)
                    }
                }
            }
            let displayKey =
                !text.contains("://") && !text.contains(where: { $0.isWhitespace })
                ? URL(string: "https://" + text).flatMap {
                    $0.host != nil && $0.user == nil && $0.password == nil
                        ? canonical($0.absoluteString, kind: .tab) : nil
                } : nil
            let displayedTab =
                displayKey != nil
                ? openTabs.first(where: {
                    nextTabs[$0.id]?.canonicalDisplayAddress == displayKey
                }) : nil
            let resolved = displayedTab?.url ?? store.resolveAddress(text, original: store.omnibarOriginalURL)
            let internalPage = resolved.flatMap(BrowserPage.from)
            let knownTab = displayedTab ?? resolved.flatMap { tabsByAddress[canonical($0.absoluteString, kind: .tab)] }
            let direct =
                resolved != store.searchAddress(text)
                && (knownTab != nil || BrowserAddress.isSuggestedWebsite(resolved))
            let searchDestination =
                resolved != store.searchAddress(text)
                ? store.searchAddress(text)?.absoluteString ?? text : text
            let addressIntent = text.contains(".") && !text.contains(where: { $0.isWhitespace })
            if internalPage == nil {
                consider(
                    Suggestion(
                        id: "input", title: direct ? BrowserAddress.display(resolved) : text,
                        detail: direct ? "go to site" : (store.preferences.searchEngine ?? .google).title + " search",
                        icon: direct ? .globe : .search,
                        destination: direct ? resolved?.absoluteString ?? text : searchDestination,
                        kind: direct ? .site : .search), score: direct || addressIntent ? 200 : 70)
            }
            if direct, internalPage == nil, let address = store.searchAddress(text) {
                consider(
                    Suggestion(
                        id: "search-input", title: text, detail: "search instead", icon: .search,
                        destination: address.absoluteString, kind: .search), score: 199)
            }
        }
        let local = ranking.results
        let keepPrevious = sameProfile && !suggestions.isEmpty
        guard text.count >= 2, text.count <= 200, !store.profile.privateMode,
            store.preferences.googleSuggestions || store.preferences.remoteSites == true,
            !text.contains("/"), !text.contains(":"), !text.contains("@"), !text.contains("."),
            BrowserAddress.resolve(text)?.host == "www.google.com"
        else {
            publish(Array(local.prefix(6)))
            return
        }
        if !keepPrevious { publish(Array(local.prefix(6))) }
        let searches = store.preferences.googleSuggestions
        let sites = store.preferences.remoteSites == true
        let provider = store.preferences.suggestionProvider ?? .google
        let key = CacheKey(
            profile: store.selectedProfileID, query: text, searches: searches, sites: sites, provider: provider)
        func combined(_ remote: [Suggestion]) -> [Suggestion] {
            var values = Array(local.prefix(3))
            var keys = Set(values.map { canonical($0.destination, kind: $0.kind) })
            for remoteSuggestion in remote.prefix(5) {
                var suggestion = tabAction(remoteSuggestion)
                if suggestion.kind == .search {
                    suggestion.detail = (store.preferences.searchEngine ?? .google).title + " search"
                }
                if keys.insert(canonical(suggestion.destination, kind: suggestion.kind)).inserted {
                    values.append(suggestion)
                }
            }
            for suggestion in local.dropFirst(3) {
                if keys.insert(canonical(suggestion.destination, kind: suggestion.kind)).inserted {
                    values.append(suggestion)
                }
            }
            return Array(values.prefix(6))
        }
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 300 {
            publish(combined(cached.values))
            if Date().timeIntervalSince(cached.date) < 15 { return }
        }
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                remoteLoading = true
                let data = try await fetch(provider.url(for: text))
                let remote = Self.parse(data, provider: provider, searches: searches, sites: sites)
                guard !Task.isCancelled, token == generation, store.selectedProfileID == key.profile,
                    !store.profile.privateMode
                else { return }
                cache = cache.filter { Date().timeIntervalSince($0.value.date) < 300 }
                if cache.count >= 100, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
                    cache.removeValue(forKey: oldest)
                }
                cache[key] = Cached(date: Date(), values: remote)
                publish(combined(remote))
                remoteLoading = false
            } catch {
                if token == generation, !Task.isCancelled {
                    publish(Array(local.prefix(6)))
                    remoteLoading = false
                }
            }
        }
    }
    private func prepareHistory(for store: BrowserStore) {
        guard historyOwner !== store else { return }
        historyOwner = store
        historyObserver = Publishers.CombineLatest(store.application.$profiles, store.$selectedProfileID)
            .map { profiles, id in
                HistorySource(profile: id, visits: Array((profiles.first { $0.id == id }?.history ?? []).prefix(5000)))
            }
            .removeDuplicates()
            .sink { [weak self] source in
                guard let self else { return }
                self.historyPreparations += 1
                let previous = self.preparedProfileID == source.profile ? self.preparedHistoryByID : [:]
                self.preparedProfileID = source.profile
                var rows: [PreparedVisit] = []
                var byID: [UUID: PreparedVisit] = [:]
                rows.reserveCapacity(source.visits.count)
                byID.reserveCapacity(source.visits.count)
                for visit in source.visits {
                    let row: PreparedVisit
                    if let cached = previous[visit.id], cached.visit == visit {
                        row = cached
                    } else {
                        row = PreparedVisit(visit)
                        self.historyRowsPrepared += 1
                    }
                    rows.append(row)
                    byID[visit.id] = row
                }
                self.preparedHistory = rows
                self.preparedHistoryByID = byID
                self.hostVisits = self.preparedHistory.reduce(into: [:]) { counts, row in
                    if let host = row.catalogHost { counts[host, default: 0] += 1 }
                }
            }
    }
    static func parse(_ data: Data, provider: SuggestionProvider, searches: Bool, sites: Bool) -> [Suggestion] {
        if provider == .google { return parseGoogle(data, searches: searches, sites: sites) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
            let phrases = json[1] as? [String]
        else { return [] }
        let urls = json.count > 3 ? json[3] as? [String] ?? [] : []
        return phrases.prefix(5).enumerated().compactMap { index, phrase in
            if provider == .wikipedia, sites, urls.indices.contains(index), let url = URL(string: urls[index]),
                url.scheme == "https", url.host == "en.wikipedia.org"
            {
                return Suggestion(
                    id: "wikipedia-" + url.absoluteString, title: String(phrase.prefix(200)), detail: "Wikipedia",
                    icon: .globe, destination: url.absoluteString, kind: .site)
            }
            guard searches else { return nil }
            return Suggestion(
                id: "search-" + phrase, title: String(phrase.prefix(200)), detail: "search", icon: .search,
                destination: phrase)
        }
    }
    static func parseGoogle(_ data: Data, searches: Bool, sites: Bool) -> [Suggestion] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 4,
            let phrases = json[1] as? [String], let metadata = json[4] as? [String: Any]
        else { return [] }
        let types = metadata["google:suggesttype"] as? [String] ?? []
        let descriptions = json[2] as? [String] ?? []
        return phrases.enumerated().compactMap { index, phrase in
            let navigation = types.indices.contains(index) && types[index] == "NAVIGATION"
            guard navigation ? sites : searches else { return nil }
            if navigation {
                guard let url = BrowserAddress.resolve(phrase), BrowserAddress.isSuggestedWebsite(url),
                    BrowserAddress.defaultSearchQuery(url) == nil
                else { return nil }
                return Suggestion(
                    id: "remote-site-" + url.absoluteString,
                    title: descriptions.indices.contains(index) && !descriptions[index].isEmpty
                        ? descriptions[index] : phrase, detail: BrowserAddress.suggestionLabel(url), icon: .globe,
                    destination: url.absoluteString, kind: .site)
            }
            return Suggestion(
                id: "search-" + phrase, title: String(phrase.prefix(200)), detail: "google search", icon: .search,
                destination: phrase)
        }
    }
    private func canonical(_ destination: String, kind: SuggestionKind) -> String {
        if kind == .page { return destination.lowercased() }
        guard kind != .search, let url = BrowserAddress.resolve(destination),
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host
        else { return "search:" + destination.lowercased() }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? destination
    }
    private func publish(_ values: [Suggestion]) {
        let old = selectedID
        suggestions = values
        publishedQuery = previousQuery
        selectedID = values.contains { $0.id == old } ? old : values.first?.id
    }
    func inline(for prefix: String) -> String? {
        guard prefix == publishedQuery, !prefix.isEmpty, suggestions.indices.contains(selected) else { return nil }
        var suggestion = suggestions[selected]
        if suggestion.kind == .page {
            return suggestion.destination.lowercased().hasPrefix(prefix.lowercased())
                && suggestion.destination.count > prefix.count
                ? prefix + suggestion.destination.dropFirst(prefix.count) : nil
        }
        if let query = suggestion.defaultSearchQuery {
            return query.lowercased().hasPrefix(prefix.lowercased()) && query.count > prefix.count
                ? prefix + query.dropFirst(prefix.count) : nil
        }
        if suggestion.kind == .search {
            if !explicitSelection, suggestion.id == "input",
                let proposed = suggestions.first(where: {
                    $0.kind == .search && $0.id != "input" && $0.title.lowercased().hasPrefix(prefix.lowercased())
                        && $0.title.count > prefix.count
                })
            {
                suggestion = proposed
            }
            return suggestion.title.lowercased().hasPrefix(prefix.lowercased()) && suggestion.title.count > prefix.count
                ? prefix + suggestion.title.dropFirst(prefix.count) : nil
        }
        guard !prefix.contains(" "), let url = BrowserAddress.resolve(suggestion.destination) else { return nil }
        let candidates = [
            url.absoluteString, BrowserAddress.display(url),
            BrowserAddress.display(url).replacingOccurrences(of: "www.", with: ""),
        ]
        if let candidate = candidates.first(where: {
            $0.lowercased().hasPrefix(prefix.lowercased()) && $0.count > prefix.count
        }) {
            return prefix + candidate.dropFirst(prefix.count)
        }
        if let hostPrefix = BrowserAddress.domainCompletionPrefix(prefix) {
            let display = BrowserAddress.display(url).replacingOccurrences(
                of: "^www\\.", with: "", options: .regularExpression)
            if display.lowercased().hasPrefix(hostPrefix), display.count > hostPrefix.count {
                return prefix + display.dropFirst(hostPrefix.count)
            }
        }
        return nil
    }
    func move(_ offset: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + offset + suggestions.count) % suggestions.count
        keyboardSelection = true
    }
    func fieldPreview(for prefix: String) -> String? {
        guard explicitSelection, suggestions.indices.contains(selected), inline(for: prefix) == nil else { return nil }
        return suggestions[selected].fieldText
    }
    func resetSelection() {
        selectedID = nil
        explicitSelection = false
        keyboardSelection = false
    }
    func cancel() {
        currentStore = nil
        task?.cancel()
        task = nil
        generation = UUID()
        remoteLoading = false
        if openTabProfileIsPrivate {
            preparedOpenTabs.removeAll()
            openTabProfileID = nil
        }
    }
}

struct SuggestionIcon: View {
    let suggestion: Suggestion
    let store: BrowserStore
    var size: CGFloat = 16
    var cachedOnly = false
    @State private var image: NSImage?
    @State private var imageIdentity: String?
    private var identity: String {
        "\(store.selectedProfileID):\(faviconURL.flatMap(BrowserAddress.websiteOrigin) ?? ""):\(cachedOnly)"
    }
    private var faviconURL: URL? { suggestion.defaultSearchQuery == nil ? suggestion.siteURL : nil }
    var body: some View {
        Group {
            if imageIdentity == identity, let image {
                Image(nsImage: image).resizable().scaledToFit().clipShape(
                    RoundedRectangle(cornerRadius: max(2, size * 0.2)))
            } else {
                GolzheimIcon(icon: suggestion.displayIcon, size: size).foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size)
            .task(id: identity) {
                image = nil
                imageIdentity = nil
                guard let url = faviconURL else { return }
                let requestedIdentity = identity
                if let cached = store.application.favicons.cachedImage(
                    for: url, privateID: store.profile.privateMode ? store.selectedProfileID : nil)
                {
                    image = cached
                    imageIdentity = requestedIdentity
                    return
                }
                guard !cachedOnly else { return }
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
                guard !Task.isCancelled else { return }
                let fetched = await store.application.favicons.image(
                    for: url, privateID: store.profile.privateMode ? store.selectedProfileID : nil, quick: true)
                guard !Task.isCancelled else { return }
                image = fetched
                imageIdentity = requestedIdentity
            }
    }
}
struct OmnibarView: View {
    @ObservedObject var store: BrowserStore
    @StateObject private var engine = SuggestionEngine()
    @State private var hoveredID: String?
    @State private var closeHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var suggestionHeight: CGFloat = 320
    var width: CGFloat = 520
    init(store: BrowserStore, suggestionHeight: CGFloat = 320, width: CGFloat = 520) {
        self.store = store
        self.suggestionHeight = suggestionHeight
        self.width = width
        _engine = StateObject(wrappedValue: store.suggestionEngine)
    }
    var body: some View {
        let focusID = store.omnibarFocusID
        let profileID = store.selectedProfileID
        let query = store.omnibarQuery
        let current = engine.represents(query, profile: profileID)
        let displayed = engine.belongs(to: profileID) ? engine.suggestions : []
        let selectedAction = engine.action(query: query, profile: profileID)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if let selectedAction {
                        SuggestionIcon(suggestion: selectedAction, store: store, size: 20)
                    } else {
                        GolzheimIcon(icon: .search, size: 20).foregroundStyle(.secondary)
                    }
                }.frame(width: 20, height: 20)
                OmnibarTextField(
                    windowID: store.id, text: $store.omnibarQuery,
                    submit: { commit(focusID: focusID, profileID: profileID) },
                    alternateSubmit: { modifiers in
                        guard ownsSession(focusID, profile: profileID) else { return false }
                        let redirect = store.preferences.alternateSearch ?? SearchRedirect()
                        let keys = modifiers.intersection([.command, .option, .shift, .control])
                        if !(redirect.enabled && redirect.shortcut.matches(modifiers)) {
                            guard keys == .shift || keys == .option || keys == .control else { return false }
                            refreshQuery()
                            let action = engine.action(query: store.omnibarQuery, profile: profileID)
                            guard let url = store.resolveAddress(action?.destination ?? store.omnibarQuery) else {
                                return true
                            }
                            if keys == .control {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                store.feedback.show(.copied, icon: .check, text: "address copied")
                            } else {
                                _ = store.newTab(url: url, showOmnibar: false, activate: keys == .shift)
                                store.omnibarVisible = false
                            }
                            return true
                        }
                        let action = engine.action(query: store.omnibarQuery, profile: profileID)
                        let query =
                            action?.kind == .search && action?.id != "input"
                            ? action?.title ?? store.omnibarQuery : store.omnibarQuery
                        store.performAlternateSearch(query)
                        return true
                    },
                    move: { offset in
                        guard ownsSession(focusID, profile: profileID) else { return }
                        refreshQuery()
                        engine.move(offset)
                    }, cancel: { if ownsSession(focusID, profile: profileID) { store.omnibarVisible = false } },
                    complete: {
                        guard ownsSession(focusID, profile: profileID) else { return }
                        refreshQuery()
                        if let action = engine.action(query: store.omnibarQuery, profile: profileID) {
                            store.omnibarQuery = action.fieldText
                        }
                    }, bufferedInput: store.omnibarBufferedInput,
                    inlineCompletion: current ? engine.inline(for: store.omnibarQuery) : nil,
                    actionPreview: current ? engine.fieldPreview(for: store.omnibarQuery) : nil,
                    actionPreviewID: engine.selectedID,
                    focusSnapshot: {
                        guard ownsSession(focusID, profile: profileID) else { return nil }
                        return (store.omnibarQuery, !store.omnibarBufferedInput)
                    }, fadesOverflow: true, reduceMotion: reduceMotion, monochromeSelection: store.profile.privateMode
                ).id(focusID).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).frame(height: 24)
                Button {
                    store.omnibarVisible = false
                } label: {
                    ZStack {
                        ShortcutKey(text: "esc").opacity(closeHovered ? 0 : 1)
                        GolzheimIcon(icon: .close, size: 12).opacity(closeHovered ? 1 : 0)
                    }.frame(width: 30, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { closeHovered = $0 }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: closeHovered)
                    .accessibilityLabel("close wonderbar")
            }.padding(16)
            if !engine.suggestions.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            commit(suggestion, focusID: focusID, profileID: profileID, queryAtRender: query)
                        } label: {
                            HStack(spacing: 8) {
                                SuggestionIcon(suggestion: suggestion, store: store)
                                Text(
                                    suggestion.title.isEmpty
                                        ? BrowserAddress.suggestionLabel(suggestion.siteURL) : suggestion.visibleTitle
                                ).lineLimit(1).truncationMode(.tail).frame(
                                    minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 8)
                                Text(suggestion.visibleDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                                if suggestion.siteURL?.scheme == "http" {
                                    GolzheimIcon(icon: .insecure, size: 12).foregroundStyle(.secondary).help(
                                        "unencrypted connection")
                                }
                                GolzheimIcon(icon: suggestion.kind == .tab ? .sidebar : .forward, size: 12)
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 13)).padding(.horizontal, 8).frame(height: 32)
                                .background {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(
                                            index == engine.selected
                                                ? profileTint(store.profile).opacity(0.25)
                                                : hoveredID == suggestion.id
                                                    ? Color.primary.opacity(0.07)
                                                    : index == 0 ? profileTint(store.profile).opacity(0.08) : .clear
                                        )
                                        .transaction { $0.animation = nil }
                                }
                        }.buttonStyle(.plain).id(suggestion.id).onHover {
                            hoveredID = $0 ? suggestion.id : hoveredID == suggestion.id ? nil : hoveredID
                        }.accessibilityLabel("\(suggestion.visibleTitle), \(suggestion.visibleDetail)")
                    }
                }.padding(8).frame(
                    height: min(suggestionHeight, CGFloat(engine.suggestions.count) * 36 + 12), alignment: .top
                ).clipped()

                    .transaction { $0.animation = nil }
            }
            HStack(spacing: 5) {
                EmojiIcon(glyph: store.profile.emoji, size: 12)
                Text(store.profile.name)
                Spacer(minLength: 8)
                ShortcutKey(text: "⇥")
                Text("complete")
                ShortcutKey(text: "⇧↵")
                Text("new tab")
                if (store.preferences.alternateSearch ?? SearchRedirect()).enabled
                    && (store.preferences.aiFeaturesEnabled != false
                        || ![SearchRedirect.Provider.chatgpt, .appleIntelligence].contains(
                            (store.preferences.alternateSearch ?? SearchRedirect()).provider))
                {
                    ShortcutKey(text: (store.preferences.alternateSearch ?? SearchRedirect()).shortcut.rawValue)
                    Text((store.preferences.alternateSearch ?? SearchRedirect()).title)
                }
            }.font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 16).padding(
                .vertical, 8)

        }.frame(width: width, alignment: .top).clipped().background {
            ProfileWindowSurface(
                color: store.profile.privateMode ? PrivateChrome.surface : Color(nsColor: .controlBackgroundColor),
                transparency: store.profile.personalization?.windowTransparency ?? 0, withinWindow: true
            ).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16).fill(
                profileTint(store.profile).opacity(
                    store.preferences.tintWonderbar == true && !store.profile.privateMode ? 0.08 : 0)
            ).allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
        .onAppear {
            engine.resetSelection()
            engine.update(store.omnibarQuery, store: store)
        }.onDisappear { engine.cancel() }
        .onChange(of: store.omnibarQuery) { _, query in
            hoveredID = nil
            engine.update(query, store: store)
        }
        .onChange(
            of: store.application.windows.flatMap {
                $0.workspaces[store.selectedProfileID]?.tabs.map { $0.id.uuidString + ($0.address ?? $0.page.address) }
                    ?? []
            }
        ) { _, _ in engine.update(store.omnibarQuery, store: store) }
    }
    private func ownsSession(_ focusID: UUID, profile: UUID) -> Bool {
        store.omnibarVisible && store.omnibarFocusID == focusID && store.selectedProfileID == profile
            && store.application.windows.contains { $0 === store }
    }
    private func refreshQuery() {
        if !engine.represents(store.omnibarQuery, profile: store.selectedProfileID) {
            engine.update(store.omnibarQuery, store: store)
        }
    }
    private func commit(_ chosen: Suggestion? = nil, focusID: UUID, profileID: UUID, queryAtRender: String? = nil) {
        guard ownsSession(focusID, profile: profileID), chosen == nil || queryAtRender == store.omnibarQuery else {
            return
        }
        if chosen == nil { refreshQuery() }
        let suggestion = engine.action(for: chosen, query: store.omnibarQuery, profile: profileID)
        guard chosen == nil || suggestion != nil else { return }
        if let id = suggestion?.tabID {
            guard let tab = store.application.runtimes[profileID]?.tabs[id], let owner = tab.store,
                !tab.isDisposed, store.application.windows.contains(where: { $0 === owner })
            else { return }
            if owner.selectedProfileID != tab.profileID { owner.switchProfile(tab.profileID) }
            owner.select(tab)
            store.omnibarVisible = false
            owner.omnibarVisible = false
            owner.nativeWindow?.makeKeyAndOrderFront(nil)
            owner.focusPage()
        } else {
            let destination: String
            if suggestion?.id == "input" {
                destination =
                    suggestion?.kind == .search
                    ? store.searchAddress(store.omnibarQuery)?.absoluteString ?? store.omnibarQuery
                    : store.omnibarQuery
            } else {
                destination = suggestion?.destination ?? store.omnibarQuery
            }
            store.navigate(destination)
        }
    }
}

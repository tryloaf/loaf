import Combine
import NaturalLanguage
import SwiftUI

nonisolated enum OmnibarMetrics {
    static func layout(in height: Double) -> (top: Double, suggestions: Double) {
        let suggestions = min(228, max(36, height - 108))
        return (max(12, (height - (56 + 1 + suggestions + 30)) / 2), suggestions)
    }
    static func suggestionsHeight(count: Int, maximum: Double) -> Double {
        guard count > 0 else { return 0 }
        return min(maximum, Double(count) * 32 + Double(count - 1) * 4 + 16)
    }
    static func width(in available: Double) -> Double {
        guard available.isFinite else { return 520 }
        let room = max(0, available - 48)
        return min(room, 600, 440 + 160 * (1 - exp(-max(0, available - 480) / 480)))
    }
}

nonisolated enum SuggestionKind: Hashable, Sendable { case tab, history, favorite, site, search, page }
struct Suggestion: Identifiable {
    let id: String
    let title: String
    var detail: String
    let icon: LoafIcon
    let destination: String
    var tabID: UUID?
    var pinnedShortcutID: UUID?
    var kind: SuggestionKind = .search
    var siteURL: URL? { kind == .search || kind == .page ? nil : BrowserAddress.resolve(destination) }
    var defaultSearchQuery: String? { BrowserAddress.defaultSearchQuery(siteURL) }
    var displayIcon: LoafIcon { defaultSearchQuery != nil ? .search : icon }
    var visibleTitle: String { defaultSearchQuery ?? (title.isEmpty ? BrowserAddress.suggestionLabel(siteURL) : title) }
    var fieldText: String {
        defaultSearchQuery ?? (kind == .search ? title : kind == .page ? destination : BrowserAddress.display(siteURL))
    }
    var visibleDetail: String {
        guard defaultSearchQuery != nil else { return BrowserAddress.visible(detail) }
        if kind == .tab { return detail }
        return kind == .favorite ? "favorite – Google search" : "Google search"
    }
    var preview: String {
        if let query = defaultSearchQuery { return "google search – " + query }
        if kind == .search { return detail + " – " + title }
        let address = BrowserAddress.display(siteURL)
        return visibleTitle == address || id == "input" ? address : visibleTitle + " – " + address
    }
}

@MainActor enum SuggestionRanking {
    struct Accumulator {
        let transform: (Suggestion) -> Suggestion
        let key: (Suggestion) -> String
        let limit: Int
        private var entries: [(original: Suggestion, score: Double, result: Suggestion, key: String)] = []
        init(limit: Int = 6, transform: @escaping (Suggestion) -> Suggestion, key: @escaping (Suggestion) -> String) {
            self.limit = limit
            self.transform = transform
            self.key = key
        }
        private static func precedes(_ value: (Suggestion, Double), _ other: (Suggestion, Double)) -> Bool {
            value.1 == other.1 ? value.0.id < other.0.id : value.1 > other.1
        }
        mutating func offer(score: Double, make: () -> Suggestion) {

            if entries.count == limit, score < entries.last!.score { return }
            let original = make()
            let value = (original, score)
            if entries.count == limit, let last = entries.last, !Self.precedes(value, (last.original, last.score)) {
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
            if entries.count > limit { entries.removeLast() }
        }
        var results: [Suggestion] { entries.map(\.result) }
        var scoredResults: [(Suggestion, Double)] { entries.map { ($0.result, $0.score) } }
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

nonisolated struct PreparedHistoryVisit: Sendable {
    let visit: Visit
    let title: String
    let address: String
    let host: String
    let label: String
    let catalogHost: String?
    let titleSearch: LocalPageSearch.Text
    let addressSearch: LocalPageSearch.Text
    let hostSearch: LocalPageSearch.Text
    let savedSearch: Bool
    let document: LocalPageSearch.Document

    init(_ visit: Visit) {
        self.visit = visit
        let url = URL(string: visit.address)
        let title = visit.title.lowercased()
        let address = visit.address.lowercased()
        self.title = title
        self.address = address
        label = BrowserAddress.suggestionLabel(url)
        let rawHost = url?.host?.lowercased() ?? ""
        let catalogHost = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        self.catalogHost =
            url.map {
                ["https", "http"].contains($0.scheme) && $0.user == nil && $0.password == nil && $0.port == nil
                    && !catalogHost.isEmpty
            } == true ? catalogHost : nil
        host = url?.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
        titleSearch = LocalPageSearch.Text(title)
        addressSearch = LocalPageSearch.Text(address)
        hostSearch = LocalPageSearch.Text(host)
        savedSearch = BrowserAddress.defaultSearchQuery(url) != nil
        document = LocalPageSearch.Document(title: visit.title, address: visit.address)
    }

    func score(query: LocalPageSearch.Query) -> Double? {
        let literal = query.literal
        if literal.isEmpty { return 0 }
        if hostSearch.hasPrefix(literal) || addressSearch.hasPrefix(literal) { return 120 }
        if titleSearch.hasPrefix(literal) { return 100 }
        if hostSearch.contains(literal) { return 95 }
        if titleSearch.contains(literal) { return 85 }
        if addressSearch.contains(literal) { return 75 }
        guard !query.patterns.isEmpty else { return nil }
        if query.patterns.allSatisfy({ titleSearch.contains($0[0]) || addressSearch.contains($0[0]) }) { return 65 }
        guard
            query.patterns.allSatisfy({ patterns in
                patterns.contains { titleSearch.contains($0) || addressSearch.contains($0) }
            })
        else { return nil }
        return document.score(query)
    }
}

nonisolated struct HistorySuggestionMatch: Sendable {
    let visit: Visit
    let label: String
    let score: Double
}

nonisolated struct PreparedHistorySnapshot: Sendable {
    let rows: [PreparedHistoryVisit]
    let byID: [UUID: PreparedHistoryVisit]
    let hostVisits: [String: Int]
    let addressVisits: [String: Int]
    let rowsPrepared: Int
}

nonisolated enum HistorySuggestionWork {
    static func prepare(_ visits: [Visit], previous: [UUID: PreparedHistoryVisit]) -> PreparedHistorySnapshot {
        var rows: [PreparedHistoryVisit] = []
        var byID: [UUID: PreparedHistoryVisit] = [:]
        var hostVisits: [String: Int] = [:]
        var addressVisits: [String: Int] = [:]
        var rowsPrepared = 0
        rows.reserveCapacity(visits.count)
        byID.reserveCapacity(visits.count)
        hostVisits.reserveCapacity(min(visits.count, 2_000))
        addressVisits.reserveCapacity(min(visits.count, 10_000))
        for (index, visit) in visits.enumerated() {
            if index & 255 == 0, Task.isCancelled { break }
            let row: PreparedHistoryVisit
            if let cached = previous[visit.id], cached.visit == visit {
                row = cached
            } else {
                row = PreparedHistoryVisit(visit)
                rowsPrepared += 1
            }
            rows.append(row)
            byID[visit.id] = row
            if let host = row.catalogHost { hostVisits[host, default: 0] += 1 }
            addressVisits[visit.address, default: 0] += 1
        }
        return PreparedHistorySnapshot(
            rows: rows, byID: byID, hostVisits: hostVisits, addressVisits: addressVisits,
            rowsPrepared: rowsPrepared)
    }

    static func matches(
        rows: [PreparedHistoryVisit], addressVisits: [String: Int], query: LocalPageSearch.Query,
        emptyQuery: Bool, now: Date, limit: Int = 128
    ) -> [HistorySuggestionMatch] {
        guard !rows.isEmpty, limit > 0 else { return [] }


        typealias Candidate = (match: HistorySuggestionMatch, id: String, slot: Int)
        var best: [Candidate] = []
        best.reserveCapacity(min(limit, rows.count))

        func outranks(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.slot > rhs.slot
        }
        func siftDown(_ start: Int) {
            var parent = start
            while parent * 2 + 1 < best.count {
                var child = parent * 2 + 1
                if child + 1 < best.count, outranks(best[child], best[child + 1]) { child += 1 }
                guard outranks(best[parent], best[child]) else { break }
                best.swapAt(parent, child)
                parent = child
            }
        }

        for (index, row) in rows.enumerated() {
            if index & 255 == 0, Task.isCancelled { return [] }
            guard let score = row.score(query: query) else { continue }
            let visit = row.visit
            let adjusted =
                score + (emptyQuery ? 35 : 20)
                + min(20, log2(Double((addressVisits[visit.address] ?? 1) + 1)) * 5)
                + max(0, 12 - now.timeIntervalSince(visit.date) / 86400)
                - (row.savedSearch ? 15 : 0)
            if best.count == limit, adjusted < best[0].match.score { continue }
            let match = HistorySuggestionMatch(visit: visit, label: row.label, score: adjusted)
            if best.count < limit {
                best.append((match, visit.id.uuidString, best.count))
                if best.count == limit {
                    for parent in (0..<(best.count / 2)).reversed() { siftDown(parent) }
                }
            } else {
                let candidate = (match: match, id: visit.id.uuidString, slot: best[0].slot)
                if outranks(candidate, best[0]) {
                    best[0] = candidate
                    siftDown(0)
                }
            }
        }
        return best.sorted {
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.slot < $1.slot
        }.map(\.match)
    }
}

@MainActor final class SuggestionEngine: ObservableObject {
    @Published var suggestions: [Suggestion] = []
    @Published var selectedID: String?
    @Published var remoteLoading = false
    @Published var keyboardSelection = false
    private lazy var embedding = NLEmbedding.wordEmbedding(for: .english)
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var previousQuery = ""
    private var publishedQuery = ""
    private var profileID: UUID?
    private weak var currentStore: BrowserStore?
    private var tldObserver: AnyCancellable?
    private struct HistorySignature: Equatable {
        let profile: UUID
        let count: Int
        let firstID: UUID?
        let firstDate: Date?
        let lastID: UUID?
    }
    private var historySignature: HistorySignature?
    private var historyPreparationTask: Task<Void, Never>?
    private var preparedHistory: [PreparedHistoryVisit] = []
    private var preparedHistoryByID: [UUID: PreparedHistoryVisit] = [:]
    private var hostVisits: [String: Int] = [:]
    private var addressVisits: [String: Int] = [:]
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
        let titleSearch: LocalPageSearch.Text
        let addressSearch: LocalPageSearch.Text
        let hostSearch: LocalPageSearch.Text
        let document: LocalPageSearch.Document
        func score(for needle: String, query: LocalPageSearch.Query) -> Double? {
            let literal = query.literal
            if literal.isEmpty { return 0 }
            if hostSearch.hasPrefix(literal) || addressSearch.hasPrefix(literal) { return 120 }
            if titleSearch.hasPrefix(literal) { return 100 }
            if hostSearch.contains(literal) { return 95 }
            if titleSearch.contains(literal) { return 85 }
            if addressSearch.contains(literal) { return 75 }
            guard !query.patterns.isEmpty else { return nil }
            if query.patterns.allSatisfy({ titleSearch.contains($0[0]) || addressSearch.contains($0[0]) }) { return 65 }
            guard
                query.patterns.allSatisfy({ patterns in
                    patterns.contains { titleSearch.contains($0) || addressSearch.contains($0) }
                })
            else { return nil }
            return document.score(query)
        }
    }
    private var preparedOpenTabs: [UUID: PreparedOpenTab] = [:]
    private var openTabProfileID: UUID?
    private var openTabProfileIsPrivate = false
    func belongs(to profile: UUID) -> Bool { profileID == profile }
    func represents(_ query: String, profile: UUID) -> Bool { previousQuery == query && profileID == profile }
    func action(for chosen: Suggestion? = nil, query: String, profile: UUID) -> Suggestion? {
        guard represents(query, profile: profile) else { return nil }
        if let chosen { return suggestions.first { $0.id == chosen.id } }
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
    private struct LearnedChoice: Codable {
        var profile: UUID
        var query: String
        var destination: String
        var count: Int
        var lastUsed: Date
    }
    private var learnedChoices: [LearnedChoice] = []
    private var learningFile: URL?
    init(fetch: @escaping (URL) async throws -> Data = { try await AssetRequest.data($0, limit: 100_000) }) {
        self.fetch = fetch
        tldObserver = TopLevelDomains.shared.changes.sink { [weak self] in
            guard let self, let store = self.currentStore else { return }
            self.cache.removeAll()
            self.update(self.previousQuery, store: store)
        }
    }
    private var explicitSelection = false
    private func loadLearning(from store: BrowserStore) {
        let file = store.application.directory.appendingPathComponent("WonderbarChoices.json")
        guard learningFile != file else { return }
        learningFile = file
        learnedChoices =
            (try? Data(contentsOf: file)).flatMap {
                try? JSONDecoder().decode([LearnedChoice].self, from: $0)
            } ?? []
    }
    func remember(_ suggestion: Suggestion, query: String, store: BrowserStore) {
        guard !store.profile.privateMode, suggestion.id != "input", suggestion.id != "search-input",
            !query.isEmpty, query.count <= 80, !query.contains("@"), !query.contains("://")
        else { return }
        loadLearning(from: store)
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count >= 2 else { return }
        let destination = canonical(suggestion.destination, kind: suggestion.kind)
        if let index = learnedChoices.firstIndex(where: {
            $0.profile == store.selectedProfileID && $0.query == value && $0.destination == destination
        }) {
            learnedChoices[index].count = min(100, learnedChoices[index].count + 1)
            learnedChoices[index].lastUsed = Date()
        } else {
            learnedChoices.append(
                LearnedChoice(
                    profile: store.selectedProfileID, query: value, destination: destination, count: 1, lastUsed: Date()
                ))
        }
        if learnedChoices.count > 500 {
            learnedChoices.sort { $0.lastUsed > $1.lastUsed }
            learnedChoices = Array(learnedChoices.prefix(500))
        }
        if let file = learningFile, let data = try? JSONEncoder().encode(learnedChoices) {
            try? data.write(to: file, options: .atomic)
        }
    }
    private func learnedBoost(for suggestion: Suggestion, query: String, profile: UUID) -> Double {
        guard !query.isEmpty else { return 0 }
        let destination = canonical(suggestion.destination, kind: suggestion.kind)
        guard
            let choice = learnedChoices.first(where: {
                $0.profile == profile && $0.query == query && $0.destination == destination
            })
        else { return 0 }
        return min(28, log2(Double(choice.count + 1)) * 10)
    }
    var selected: Int {
        get { suggestions.firstIndex { $0.id == selectedID } ?? 0 }
        set {
            selectedID = suggestions.indices.contains(newValue) ? suggestions[newValue].id : nil
            explicitSelection = true
        }
    }
    func update(_ query: String, store: BrowserStore) {
        currentStore = store
        if !store.profile.privateMode { loadLearning(from: store) }
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
        let localQuery = LocalPageSearch.Query(needle, embedding: domainPrefix == nil ? embedding : nil)
        prepareHistory(for: store)
        func preparedScore(_ title: String, _ address: String, _ host: String) -> Double? {
            if needle.isEmpty { return 0 }
            if host.hasPrefix(needle) || address.hasPrefix(needle) { return 120 }
            if title.hasPrefix(needle) { return 100 }
            if host.contains(needle) { return 95 }
            if title.contains(needle) { return 85 }
            if address.contains(needle) { return 75 }
            return LocalPageSearch.Document(title: title, address: address).score(localQuery)
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
        let pins = store.profile.pinShortcuts ?? []
        var pinsByAddress: [String: SavedTab] = [:]
        for pin in pins {
            if let address = pin.pinnedAddress ?? pin.address {
                let key = canonical(address, kind: .tab)
                if pinsByAddress[key] == nil { pinsByAddress[key] = pin }
            }
        }
        func tabAction(_ suggestion: Suggestion) -> Suggestion {
            if suggestion.kind != .search && suggestion.kind != .page,
                let pin = pinsByAddress[canonical(suggestion.destination, kind: suggestion.kind)],
                let address = pin.pinnedAddress ?? pin.address
            {
                return Suggestion(
                    id: "pin-\(pin.id)", title: pin.pinnedTitle ?? pin.title,
                    detail: "open pinned page in new tab", icon: .pinned, destination: address,
                    pinnedShortcutID: pin.id, kind: .tab)
            }
            guard suggestion.kind != .search && suggestion.kind != .page,
                let tab = tabsByAddress[canonical(suggestion.destination, kind: suggestion.kind)]
            else { return suggestion }
            return Suggestion(
                id: "tab-\(tab.id)", title: tab.sidebarTitle,
                detail: tab.windowID == store.id ? "switch to tab" : "switch to tab – other window", icon: .sidebar,
                destination: tab.url!.absoluteString, tabID: tab.id, kind: .tab)
        }
        var ranking = SuggestionRanking.Accumulator(limit: 40, transform: tabAction) {
            self.canonical($0.destination, kind: $0.kind)
        }
        func adjustedScore(_ value: Suggestion, score: Double) -> Double {
            var adjusted =
                score
                + (store.profile.privateMode
                    ? 0
                    : learnedBoost(
                        for: value, query: text.lowercased(), profile: store.selectedProfileID))
            guard let domainPrefix else { return adjusted }
            let url = value.kind == .search || value.kind == .page ? nil : URL(string: value.destination)
            let host = url?.host?.lowercased() ?? ""
            let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let completion =
                BrowserAddress.isSuggestedWebsite(url) && key.hasPrefix(domainPrefix)
                && value.defaultSearchQuery == nil
            if completion { adjusted += 160 }
            return adjusted
        }
        func consider(_ suggestion: @autoclosure () -> Suggestion, score: Double) {
            let value = suggestion()
            ranking.offer(score: adjustedScore(value, score: score)) { value }
        }
        var inputAction: Suggestion?
        var utilityCandidates: [(Suggestion, Double)] = []
        for page in BrowserPage.allCases {
            if page == .ask && store.preferences.aiFeaturesEnabled == false { continue }
            if let score = score(page.title, page.address) {
                let suggestion = Suggestion(
                        id: "page-" + page.rawValue, title: page.title, detail: page.address, icon: page.icon,
                        destination: page.address, kind: .page)
                let pageScore = needle.isEmpty
                    ? (page == .history ? 10.0 : page == .downloads ? 9.0 : -20.0)
                    : score + (needle.hasPrefix("loaf:") ? 40 : 0)
                consider(suggestion, score: pageScore)
                if !needle.isEmpty || page == .history || page == .downloads {
                    utilityCandidates.append((suggestion, pageScore))
                }
            }
        }

        for pin in pins {
            if let address = pin.pinnedAddress ?? pin.address,
                let score = score(pin.pinnedTitle ?? pin.title, address)
            {
                consider(
                    Suggestion(
                        id: "pin-\(pin.id)", title: pin.pinnedTitle ?? pin.title,
                        detail: "open pinned page in new tab", icon: .pinned, destination: address,
                        pinnedShortcutID: pin.id, kind: .tab), score: score + (needle.isEmpty ? 30 : 45))
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
                    titleSearch: LocalPageSearch.Text(lowerTitle), addressSearch: LocalPageSearch.Text(lowerAddress),
                    hostSearch: LocalPageSearch.Text(url.host?.replacingOccurrences(of: "www.", with: "") ?? ""),
                    document: LocalPageSearch.Document(title: title, address: address))
            }
            nextTabs[tab.id] = row
            let key = row.canonicalAddress
            if tabsByAddress[key] == nil { tabsByAddress[key] = tab }
            if let score = row.score(for: needle, query: localQuery) {
                consider(
                    Suggestion(
                        id: "tab-\(tab.id)", title: title,
                        detail: tab.windowID == store.id ? "switch to tab" : "switch to tab – other window",
                        icon: .sidebar, destination: address, tabID: tab.id, kind: .tab),
                    score: score + (needle.isEmpty ? 25 : 40))
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
                        detail: "favorite – " + BrowserAddress.suggestionLabel(URL(string: favorite.address)),
                        icon: .favorite, destination: favorite.address, kind: .favorite),
                    score: score + (needle.isEmpty ? 65 : 35))
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

                for (key, cached) in cache
                where key.profile == store.selectedProfileID && key.sites
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
                let typed = tabAction(
                    Suggestion(
                        id: "input", title: direct ? BrowserAddress.display(resolved) : text,
                        detail: direct ? "go to site" : (store.preferences.searchEngine ?? .google).title + " search",
                        icon: direct ? .globe : .search,
                        destination: direct ? resolved?.absoluteString ?? text : searchDestination,
                        kind: direct ? .site : .search))
                inputAction = typed
                consider(typed, score: direct || addressIntent ? 200 : 70)
            }
            if direct, internalPage == nil, let address = store.searchAddress(text) {
                consider(
                    Suggestion(
                        id: "search-input", title: text, detail: "search instead", icon: .search,
                        destination: address.absoluteString, kind: .search), score: 199)
            }
        }

        let baseLocal =
            ranking.scoredResults
            + utilityCandidates
            + (inputAction.map {
                [($0, $0.kind == .site ? 200.0 : 70.0)]
            } ?? [])
        let baseResults = ranked(baseLocal, query: text, domainPrefix: domainPrefix)
        publish(baseResults)

        let historyRows = preparedHistory
        let historyAddressVisits = addressVisits
        let historyNow = Date()
        let remoteEligible =
            text.count >= 2 && text.count <= 200 && !store.profile.privateMode
            && (store.preferences.googleSuggestions || store.preferences.remoteSites == true)
            && !text.contains("/") && !text.contains(":") && !text.contains("@") && !text.contains(".")
            && BrowserAddress.resolve(text)?.host == "www.google.com"
        let searches = store.preferences.googleSuggestions
        let sites = store.preferences.remoteSites == true
        let provider = store.preferences.suggestionProvider ?? .google
        let remoteKey =
            remoteEligible
            ? CacheKey(
                profile: store.selectedProfileID, query: text, searches: searches, sites: sites, provider: provider)
            : nil

        task = Task { @MainActor in
            let historyWork = Task.detached(priority: .userInitiated) {
                HistorySuggestionWork.matches(
                    rows: historyRows, addressVisits: historyAddressVisits, query: localQuery,
                    emptyQuery: needle.isEmpty, now: historyNow)
            }
            let historyMatches = await withTaskCancellationHandler {
                await historyWork.value
            } onCancel: {
                historyWork.cancel()
            }
            guard !Task.isCancelled, token == generation, store.selectedProfileID == profileID else { return }

            var local = baseLocal
            local.reserveCapacity(baseLocal.count + historyMatches.count)
            for match in historyMatches {
                let original = Suggestion(
                    id: "history-" + match.visit.address, title: match.visit.title, detail: match.label,
                    icon: .history, destination: match.visit.address, kind: .history)
                local.append((tabAction(original), adjustedScore(original, score: match.score)))
            }
            let localResults = ranked(local, query: text, domainPrefix: domainPrefix)
            publish(localResults, remoteUpdate: true)

            guard let key = remoteKey else { return }
            if let cached = cache[key], Date().timeIntervalSince(cached.date) < 300 {
                var candidates = local
                for (index, remoteSuggestion) in cached.values.prefix(8).enumerated() {
                    var suggestion = tabAction(remoteSuggestion)
                    if suggestion.kind == .search {
                        suggestion.detail = (store.preferences.searchEngine ?? .google).title + " search"
                    }
                    let score: Double
                    if remoteSuggestion.kind == .site {
                        let host = suggestion.siteURL?.host?.lowercased() ?? ""
                        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        score =
                            156 - Double(index * 4)
                            + (domainPrefix.map { shortHost.hasPrefix($0) } == true ? 160 : 0)
                    } else {
                        score = 125 - Double(index * 4)
                    }
                    candidates.append(
                        (
                            suggestion,
                            score
                                + learnedBoost(
                                    for: suggestion, query: text.lowercased(), profile: store.selectedProfileID)
                        ))
                }
                publish(ranked(candidates, query: text, domainPrefix: domainPrefix), remoteUpdate: true)
                if Date().timeIntervalSince(cached.date) < 15 { return }
            }
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
                var candidates = local
                for (index, remoteSuggestion) in remote.prefix(8).enumerated() {
                    var suggestion = tabAction(remoteSuggestion)
                    if suggestion.kind == .search {
                        suggestion.detail = (store.preferences.searchEngine ?? .google).title + " search"
                    }
                    let score: Double
                    if remoteSuggestion.kind == .site {
                        let host = suggestion.siteURL?.host?.lowercased() ?? ""
                        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        score =
                            156 - Double(index * 4)
                            + (domainPrefix.map { shortHost.hasPrefix($0) } == true ? 160 : 0)
                    } else {
                        score = 125 - Double(index * 4)
                    }
                    candidates.append(
                        (
                            suggestion,
                            score
                                + learnedBoost(
                                    for: suggestion, query: text.lowercased(), profile: store.selectedProfileID)
                        ))
                }
                publish(ranked(candidates, query: text, domainPrefix: domainPrefix), remoteUpdate: true)
                remoteLoading = false
            } catch {
                if token == generation, !Task.isCancelled {
                    publish(localResults, remoteUpdate: true)
                    remoteLoading = false
                }
            }
        }
    }

    private func ranked(
        _ candidates: [(Suggestion, Double)], query: String, domainPrefix: String?
    ) -> [Suggestion] {
        let literal = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = literal.lowercased()
        func addressKey(_ value: String) -> String {
            var key = value
            for prefix in ["https://", "http://", "www."] {
                if key.lowercased().hasPrefix(prefix) { key.removeFirst(prefix.count) }
            }
            let boundary = key.firstIndex(where: { "/?#".contains($0) }) ?? key.endIndex
            let suffix = key[boundary...]
            return key[..<boundary].lowercased() + (suffix == "/" ? "" : String(suffix))
        }
        func matchesAddress(_ suggestion: Suggestion) -> Bool {
            guard !needle.isEmpty, !needle.contains(where: { $0.isWhitespace }),
                suggestion.kind != .search, suggestion.kind != .page,
                let url = suggestion.kind == .tab ? URL(string: suggestion.destination) : suggestion.siteURL
            else { return false }
            let typed = addressKey(literal)
            return addressKey(url.absoluteString) == typed
                || (suggestion.defaultSearchQuery == nil && addressKey(url.host ?? "") == typed)
        }
        var sorted = candidates.sorted {
            $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
        }

        if !query.isEmpty && domainPrefix == nil {
            sorted = sorted.map { suggestion, score in
                (
                    suggestion,
                    suggestion.id == "input" && suggestion.kind == .search
                        ? max(score, query.contains(where: { $0.isWhitespace }) ? 185 : 160) : score
                )
            }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        }



        func destinationPriority(_ suggestion: Suggestion) -> Int {
            if matchesAddress(suggestion) { return 2 }
            guard !needle.isEmpty, suggestion.defaultSearchQuery == nil else { return 0 }
            let typedAddress = addressKey(literal)
            if !literal.contains(where: { $0.isWhitespace }), typedAddress.contains(where: { "/?#".contains($0) }),
                !addressKey(suggestion.destination).hasPrefix(typedAddress) { return 0 }
            if [.tab, .history, .favorite].contains(suggestion.kind) { return 1 }
            if suggestion.kind == .site, suggestion.id.hasPrefix("site-"),
                suggestion.title.localizedStandardContains(literal) { return 1 }
            return 0
        }
        sorted = sorted.sorted {
            let lhs = destinationPriority($0.0), rhs = destinationPriority($1.0)
            if lhs != rhs { return lhs > rhs }
            return $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
        }
        var chosen: [Suggestion] = []
        var keys = Set<String>()
        var domains: [String: Int] = [:]
        var kinds: [SuggestionKind: Int] = [:]
        func take(_ suggestion: Suggestion) -> Bool {
            let key =
                suggestion.kind == .search
                ? "search-query:" + suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : canonical(suggestion.destination, kind: suggestion.kind)
            guard !keys.contains(key), chosen.count < 6 else { return false }
            let kindLimit: Int
            switch suggestion.kind {
            case .history, .favorite, .tab: kindLimit = 2
            case .site, .search: kindLimit = 3
            case .page: kindLimit = 2
            }
            if kinds[suggestion.kind, default: 0] >= kindLimit { return false }
            let host = suggestion.siteURL?.host ?? ""
            let domain = host.isEmpty ? "" : PublicSuffixList.shared.registrableDomain(host)
            let shortHost = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let domainLimit = domainPrefix.map { shortHost.lowercased().hasPrefix($0) } == true ? 3 : 2
            if !domain.isEmpty && domains[domain, default: 0] >= domainLimit { return false }
            chosen.append(suggestion)
            keys.insert(key)
            kinds[suggestion.kind, default: 0] += 1
            if !domain.isEmpty { domains[domain, default: 0] += 1 }
            return true
        }
        if let first = sorted.first { _ = take(first.0) }
        let utilities = sorted.filter { suggestion, _ in
            guard suggestion.kind == .page else { return false }
            if needle.isEmpty {
                return [BrowserPage.history.address, BrowserPage.downloads.address].contains(suggestion.destination)
            }
            return true
        }
        for (suggestion, _) in utilities.prefix(2) { _ = take(suggestion) }
        for (suggestion, _) in sorted { _ = take(suggestion) }

        if let input = sorted.first(where: { $0.0.id == "input" })?.0,
            !chosen.contains(where: { $0.id == input.id })
        {
            if chosen.count == 6 { chosen.removeLast() }
            chosen.append(input)
        }
        return chosen
    }
    func historyChanged(store: BrowserStore) {
        historySignature = nil
        prepareHistory(for: store)
    }
    private func prepareHistory(for store: BrowserStore) {
        let profile = store.profile
        let profileID = store.selectedProfileID
        let visits = profile.privateMode ? [] : profile.history
        let signature = HistorySignature(
            profile: profileID, count: visits.count, firstID: visits.first?.id, firstDate: visits.first?.date,
            lastID: visits.last?.id)
        guard signature != historySignature else { return }
        historySignature = signature
        historyPreparationTask?.cancel()
        historyPreparations += 1

        let previous = preparedProfileID == profileID ? preparedHistoryByID : [:]
        if preparedProfileID != profileID {
            preparedHistory = []
            preparedHistoryByID = [:]
            hostVisits = [:]
            addressVisits = [:]
        }
        historyPreparationTask = Task {
            let preparation = Task.detached(priority: .utility) {
                HistorySuggestionWork.prepare(visits, previous: previous)
            }
            let snapshot = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, historySignature == signature else { return }
            preparedProfileID = profileID
            preparedHistory = snapshot.rows
            preparedHistoryByID = snapshot.byID
            hostVisits = snapshot.hostVisits
            addressVisits = snapshot.addressVisits
            historyRowsPrepared += snapshot.rowsPrepared

            guard currentStore === store, self.profileID == profileID else { return }
            update(previousQuery, store: store)
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
                id: "search-" + phrase, title: String(phrase.prefix(200)), detail: "Google search", icon: .search,
                destination: phrase)
        }
    }
    private func canonical(_ destination: String, kind: SuggestionKind) -> String {
        if kind == .page { return destination.lowercased() }
        let address = destination.contains("://") ? URL(string: destination) : BrowserAddress.resolve(destination)
        guard kind != .search, let url = address,
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host
        else { return "search:" + destination.lowercased() }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? destination
    }
    private func publish(_ values: [Suggestion], remoteUpdate: Bool = false) {

        if remoteUpdate && keyboardSelection && values.contains(where: { $0.id == selectedID }) {
            let surviving = suggestions.compactMap { previous in values.first { $0.id == previous.id } }
            suggestions = surviving + values.filter { next in !surviving.contains { $0.id == next.id } }
            publishedQuery = previousQuery
            return
        }
        if !values.contains(where: { $0.id == selectedID }) {
            keyboardSelection = false
            explicitSelection = false
        }
        let old = selectedID
        suggestions = values
        publishedQuery = previousQuery
        selectedID = explicitSelection && values.contains { $0.id == old } ? old : values.first?.id
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
        guard suggestions.indices.contains(selected) else { return nil }
        let suggestion = suggestions[selected]
        if prefix == publishedQuery, !prefix.isEmpty, suggestion.id != "input", suggestion.defaultSearchQuery == nil,
            [.tab, .history, .favorite, .site].contains(suggestion.kind),
            !suggestion.visibleTitle.isEmpty
        {
            return suggestion.visibleTitle
        }
        guard explicitSelection, inline(for: prefix) == nil else { return nil }
        return suggestion.fieldText
    }
    func holdOrder() { keyboardSelection = true }
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
    private var faviconURL: URL? { suggestion.siteURL }
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
private struct OmnibarPanelHeight: AnimatableModifier {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }
    func body(content: Content) -> some View {
        content.frame(height: height, alignment: .top).clipped()
    }
}

struct OmnibarView: View {
    private enum ModifiedAction {
        case alternateSearch, newTab, backgroundTab, copyAddress
    }

    private static let actionModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    @ObservedObject var store: BrowserStore
    @StateObject private var engine = SuggestionEngine()
    @State private var hoveredID: String?
    @State private var pointerMovedSinceTyping = false
    @State private var closeHovered = false
    @State private var presentedSuggestionText: String?
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
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
        let rowsHeight = OmnibarMetrics.suggestionsHeight(count: displayed.count, maximum: suggestionHeight)
        let selectedAction = engine.action(query: query, profile: profileID)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if let selectedAction, let presentedSuggestionText, current,
                        presentedSuggestionText == engine.inline(for: query)
                            || presentedSuggestionText == engine.fieldPreview(for: query)
                    {
                        SuggestionIcon(suggestion: selectedAction, store: store, size: 20)
                    } else {
                        GolzheimIcon(icon: .search, size: 20).foregroundStyle(.secondary)
                    }
                }.frame(width: 20, height: 20)
                OmnibarTextField(
                    windowID: store.id, text: $store.omnibarQuery,
                    submit: { commit(focusID: focusID, profileID: profileID) },
                    alternateSubmit: { modifiers in
                        submitWithModifiers(modifiers, focusID: focusID, profileID: profileID)
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
                    suggestionPresentationChanged: { text in
                        guard ownsSession(focusID, profile: profileID) else { return }
                        presentedSuggestionText = text
                    },
                    focusSnapshot: {
                        guard ownsSession(focusID, profile: profileID) else { return nil }
                        return (store.omnibarQuery, !store.omnibarBufferedInput)
                    }, fadesOverflow: true, reduceMotion: reduceMotion, monochromeSelection: store.profile.privateMode
                ).id(focusID).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).frame(height: 24)
                Button {
                    store.omnibarVisible = false
                } label: {
                    ZStack {
                        Text("escape").font(.system(size: 10)).foregroundStyle(.secondary).opacity(closeHovered ? 0 : 1)
                        GolzheimIcon(icon: .close, size: 12).opacity(closeHovered ? 1 : 0)
                    }.frame(width: 38, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { closeHovered = $0 }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: closeHovered)
                    .accessibilityLabel("close wonderbar")
            }.padding(16)
            if !displayed.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            let modifiers = NSApp.currentEvent?.modifierFlags ?? heldModifiers
                            if !submitWithModifiers(
                                modifiers, chosen: suggestion, focusID: focusID, profileID: profileID,
                                queryAtRender: query)
                            {
                                commit(suggestion, focusID: focusID, profileID: profileID, queryAtRender: query)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                SuggestionIcon(suggestion: suggestion, store: store)
                                Text(
                                    suggestion.title.isEmpty
                                        ? BrowserAddress.suggestionLabel(suggestion.siteURL) : suggestion.visibleTitle
                                ).lineLimit(1).truncationMode(.tail).frame(
                                    minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 8)
                                Text(actionDetail(for: suggestion)).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                                if suggestion.siteURL?.scheme == "http" {
                                    GolzheimIcon(icon: .insecure, size: 12).foregroundStyle(.secondary).help(
                                        "unencrypted connection")
                                }
                                GolzheimIcon(icon: actionIcon(for: suggestion), size: 12)
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
                        }.buttonStyle(.plain).id(suggestion.id).onContinuousHover { phase in
                            switch phase {
                            case .active:
                                guard pointerMovedSinceTyping else { return }
                                if hoveredID != suggestion.id {
                                    hoveredID = suggestion.id
                                    engine.holdOrder()
                                }
                            case .ended:
                                if hoveredID == suggestion.id { hoveredID = nil }
                            }
                        }.accessibilityLabel("\(suggestion.visibleTitle), \(actionDetail(for: suggestion))")
                    }
                }.padding(8).frame(
                    height: rowsHeight, alignment: .top
                ).clipped()
                    .allowsHitTesting(current)
                    .transition(.opacity)
            }
            HStack(spacing: 5) {
                ProfileIcon(profile: store.profile, size: 12)
                Text(store.profile.name)
                Spacer(minLength: 8)
                Text("⇥")
                Text("complete")
                Text("⇧↵")
                Text("new tab")
                if (store.preferences.alternateSearch ?? SearchRedirect()).enabled
                    && (store.preferences.aiFeaturesEnabled != false
                        || ![SearchRedirect.Provider.chatgpt, .claude, .appleIntelligence].contains(
                            (store.preferences.alternateSearch ?? SearchRedirect()).provider))
                {
                    Text((store.preferences.alternateSearch ?? SearchRedirect()).shortcut.rawValue)
                    Text((store.preferences.alternateSearch ?? SearchRedirect()).title)
                }
            }.font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 16).padding(
                .vertical, 8)

        }.frame(width: width, alignment: .top)
            .modifier(OmnibarPanelHeight(height: 56 + 30 + (displayed.isEmpty ? 0 : 1 + rowsHeight)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: rowsHeight)
            .background {
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
                pointerMovedSinceTyping = false
                heldModifiers = NSEvent.modifierFlags.intersection(Self.actionModifiers)
                if modifierMonitor == nil {
                    modifierMonitor = NSEvent.addLocalMonitorForEvents(
                        matching: [.flagsChanged, .keyDown, .keyUp, .mouseMoved, .leftMouseDown, .rightMouseDown]
                    ) { event in
                        if event.window === store.nativeWindow {
                            switch event.type {
                            case .keyDown:
                                pointerMovedSinceTyping = false
                                hoveredID = nil
                            case .mouseMoved:
                                pointerMovedSinceTyping = true
                            default: break
                            }
                        }
                        let modifiers = event.modifierFlags.intersection(Self.actionModifiers)
                        if modifiers != heldModifiers { heldModifiers = modifiers }
                        return event
                    }
                }
                engine.resetSelection()
            }.onDisappear {
                if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
                modifierMonitor = nil
                heldModifiers = []
                engine.cancel()
            }
            .task(id: focusID) {

                await Task.yield()
                guard !Task.isCancelled, ownsSession(focusID, profile: profileID) else { return }
                engine.update(store.omnibarQuery, store: store)
            }
            .onChange(of: store.omnibarQuery) { _, query in
                pointerMovedSinceTyping = false
                hoveredID = nil
                engine.update(query, store: store)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                heldModifiers = NSEvent.modifierFlags.intersection(Self.actionModifiers)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if notification.object as? NSWindow === store.nativeWindow {
                    heldModifiers = NSEvent.modifierFlags.intersection(Self.actionModifiers)
                }
            }
            .onChange(of: openTabIdentities) { _, _ in engine.update(store.omnibarQuery, store: store) }
    }
    private var openTabIdentities: [String] {
        store.application.windows.flatMap { window in
            let tabs = window.workspaces[store.selectedProfileID]?.tabs ?? []
            return tabs.map { tab in
                [
                    tab.id.uuidString, tab.address ?? tab.page.address, tab.title, tab.customTitle ?? "",
                    tab.pinnedTitle ?? "",
                ].joined(separator: "\n")
            }
        }
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
    private func modifiedAction(for modifiers: NSEvent.ModifierFlags) -> ModifiedAction? {
        let keys = modifiers.intersection(Self.actionModifiers)
        let redirect = store.preferences.alternateSearch ?? SearchRedirect()
        if redirect.enabled && redirect.shortcut.matches(keys) { return .alternateSearch }
        switch keys {
        case .shift: return .newTab
        case .option: return .backgroundTab
        case .control: return .copyAddress
        default: return nil
        }
    }
    private func actionDetail(for suggestion: Suggestion) -> String {
        switch modifiedAction(for: heldModifiers) {
        case .alternateSearch:
            return "search with \((store.preferences.alternateSearch ?? SearchRedirect()).title)"
        case .newTab:
            if suggestion.pinnedShortcutID != nil { return "open in new tab" }
            return suggestion.kind == .search ? "search in new tab" : "go to site in new tab"
        case .backgroundTab:
            return suggestion.kind == .search ? "search in background tab" : "open in background tab"
        case .copyAddress:
            return suggestion.kind == .search ? "copy search URL" : "copy address"
        case nil:
            return suggestion.visibleDetail
        }
    }
    private func actionIcon(for suggestion: Suggestion) -> LoafIcon {
        switch modifiedAction(for: heldModifiers) {
        case .copyAddress: .copy
        case nil where suggestion.kind == .tab: .sidebar
        default: .forward
        }
    }
    private func submitWithModifiers(
        _ modifiers: NSEvent.ModifierFlags, chosen: Suggestion? = nil, focusID: UUID, profileID: UUID,
        queryAtRender: String? = nil
    ) -> Bool {
        guard ownsSession(focusID, profile: profileID), let action = modifiedAction(for: modifiers) else {
            return false
        }
        guard chosen == nil || queryAtRender == store.omnibarQuery else { return true }
        if chosen == nil { refreshQuery() }
        let suggestion = engine.action(for: chosen, query: store.omnibarQuery, profile: profileID)
        guard chosen == nil || suggestion != nil else { return true }
        if action == .alternateSearch {
            let query =
                suggestion?.kind == .search && suggestion?.id != "input"
                ? suggestion?.title ?? store.omnibarQuery : store.omnibarQuery
            store.performAlternateSearch(query)
            return true
        }
        guard let url = store.resolveAddress(suggestion?.destination ?? store.omnibarQuery) else { return true }
        switch action {
        case .copyAddress:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            store.feedback.show(.copied, icon: .check, text: "address copied")
        case .newTab, .backgroundTab:
            store.openSuggestionInNewTab(url, background: action == .backgroundTab)
        case .alternateSearch:
            break
        }
        return true
    }
    private func commit(_ chosen: Suggestion? = nil, focusID: UUID, profileID: UUID, queryAtRender: String? = nil) {
        guard ownsSession(focusID, profile: profileID), chosen == nil || queryAtRender == store.omnibarQuery else {
            return
        }
        if chosen == nil { refreshQuery() }
        let suggestion = engine.action(for: chosen, query: store.omnibarQuery, profile: profileID)
        guard chosen == nil || suggestion != nil else { return }
        if let suggestion { engine.remember(suggestion, query: store.omnibarQuery, store: store) }
        if let pinID = suggestion?.pinnedShortcutID {
            guard let url = suggestion?.siteURL else { return }
            store.openPinnedSuggestion(pinID, url: url)
            store.focusPage()
        } else if let id = suggestion?.tabID {
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

extension BrowserWindowState {
    func openPinnedSuggestion(_ shortcutID: UUID, url: URL) {
        guard let pin = pinnedTabs.first(where: { $0.pinnedShortcutID == shortcutID }),
            Self.matchesPinnedPage(pin.pinnedAddress ?? pin.saved.address, url: url)
        else { return }
        openSuggestionInNewTab(url)
    }
    func openSuggestionInNewTab(_ url: URL, background: Bool = false) {
        if !background, let tab = selectedTab, tab.isEmptyNewTab {
            omnibarCreatesTab = false
            tab.load(url)
        } else {
            _ = newTab(url: url, showOmnibar: false, activate: !background)
        }
        omnibarVisible = false
    }
}

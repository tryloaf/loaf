import Foundation

nonisolated enum WonderbarScope: String, CaseIterable, Sendable {
    case tabs, history, bookmarks, closed
    var prefix: String { "@" + rawValue }
    var title: String {
        switch self {
        case .tabs: "open tabs"
        case .history: "history"
        case .bookmarks: "bookmarks"
        case .closed: "recently closed tabs"
        }
    }
    var icon: LoafIcon {
        switch self {
        case .tabs: .sidebar
        case .history, .closed: .history
        case .bookmarks: .favorite
        }
    }
}

nonisolated enum WonderbarInput: Equatable {
    case normal
    case commands(String)
    case scopes(String)
    case scoped(WonderbarScope, String)
    init(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(">") {
            self = .commands(String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
        } else if text.hasPrefix("@") {
            let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
            let token = String(text[text.index(after: text.startIndex)..<end]).lowercased()
            if let scope = WonderbarScope(rawValue: token) {
                self = .scoped(scope, String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if end == text.endIndex && WonderbarScope.allCases.contains(where: { $0.rawValue.hasPrefix(token) })
            {
                self = .scopes(token)
            } else {
                self = .normal
            }
        } else {
            self = .normal
        }
    }
    var isLocal: Bool { self != .normal }
}

nonisolated enum WonderbarCommand: Hashable, Sendable {
    case scope(WonderbarScope)
    case newTab
    case page(BrowserPage)
    case reopen(UUID)
    case duplicate(UUID)
    case bookmark(UUID)
    case copyURL(UUID)
    case popOut(UUID)
    case pin(UUID, Bool)
    case mute(UUID, Bool)
    case split(UUID, UUID)
    case endSplit(UUID, UUID)
    case saveSplit(UUID, UUID)
    case move(UUID, UUID)
    case switchProfile(UUID)
    var id: String { "command-" + String(describing: self) }
}

@MainActor enum WonderbarCommands {
    static func suggestions(store: BrowserStore) -> [Suggestion] {
        var result: [Suggestion] = []
        func add(_ command: WonderbarCommand, _ title: String, _ detail: String, _ icon: LoafIcon) {
            result.append(
                Suggestion(
                    id: command.id, title: title, detail: detail, icon: icon,
                    destination: "", kind: .command, command: command))
        }
        add(.newTab, "new tab", "open an empty tab", .plus)
        if let closed = store.recentlyClosedTabs.first {
            add(.reopen(closed.id), "reopen last closed tab", closed.saved.title, .history)
        }
        if let tab = store.selectedTab, !tab.isDisposed {
            if tab.url != nil {
                add(.copyURL(tab.id), "copy current URL", "⌘⇧C", .copy)
                if store.canPopOutPin(tab) { add(.popOut(tab.id), "pop out tab", "keep this page and its saved pin", .external) }
                add(.bookmark(tab.id), "save bookmark…", tab.sidebarTitle, .favorite)
                add(.duplicate(tab.id), "duplicate tab", tab.sidebarTitle, .copy)
                add(.pin(tab.id, !tab.pinned), tab.pinned ? "unpin tab" : "pin tab", tab.sidebarTitle, .pinned)
            }
            if !tab.media.isEmpty {
                let muted = tab.media.allSatisfy(\.muted)
                add(
                    .mute(tab.id, !muted), muted ? "unmute tab" : "mute tab", tab.sidebarTitle, muted ? .volume : .muted
                )
            }
            if let split = store.visibleSplit {
                if store.canSaveSplitBookmark {
                    add(
                        .saveSplit(split.left, split.right), "save split view…", "save both pages as one bookmark",
                        .favorite)
                }
                add(.endSplit(split.left, split.right), "end split view", "keep both tabs open", .collapse)
            }
            for other in store.splittableTabs where other !== tab && tab.page == .web && tab.url != nil {
                add(.split(tab.id, other.id), "split with " + other.sidebarTitle, "open side by side", .expand)
            }
            if !store.profile.privateMode {
                for profile in store.profiles where profile.id != store.selectedProfileID && !profile.privateMode {
                    add(
                        .move(tab.id, profile.id), "move tab to " + profile.name, "open in that profile’s session",
                        .profiles)
                }
            }
        }
        for scope in WonderbarScope.allCases {
            add(.scope(scope), "search " + scope.title, scope.prefix, scope.icon)
        }
        for page in [BrowserPage.history, .favorites, .downloads, .cookies, .settings, .profiles, .extensions] {
            add(.page(page), "open " + page.title, page.address, page.icon)
        }
        for profile in store.profiles where profile.id != store.selectedProfileID {
            add(.switchProfile(profile.id), "switch to " + profile.name, "profile", .profiles)
        }
        return result
    }
    static func score(_ suggestion: Suggestion, query: String) -> Double? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let corpus = suggestion.title + " " + suggestion.detail
        guard text.split(whereSeparator: \.isWhitespace).allSatisfy({ corpus.localizedStandardContains(String($0)) })
        else { return nil }
        return suggestion.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) ? 100 : 50
    }
}

extension BrowserWindowState {
    @discardableResult func performWonderbarCommand(_ command: WonderbarCommand) -> Bool {
        func selected(_ id: UUID) -> BrowserTab? {
            guard let tab = selectedTab, tab.id == id, tab.store === self, !tab.isDisposed,
                tab.profileID == selectedProfileID
            else { return nil }
            return tab
        }
        // Rebuild from live state so an old command cannot target a closed tab, replaced split or deleted profile.
        guard WonderbarCommands.suggestions(store: self).contains(where: { $0.command == command }) else {
            return false
        }
        if case .scope(let scope) = command {
            omnibarQuery = scope.prefix + " "
            return true
        }
        switch command {
        case .scope: return false
        case .newTab:
            dismissOmnibar()
            _ = newTab()
        case .page(let page):
            dismissOmnibar()
            showPage(page)
        case .reopen(let id):
            guard recentlyClosedTabs.contains(where: { $0.id == id }) else { return false }
            dismissOmnibar()
            _ = reopenClosedTab(id)
        case .duplicate(let id):
            guard let tab = selected(id) else { return false }
            var saved = tab.saved
            saved.pinned = false
            saved.pinnedShortcutID = nil
            dismissOmnibar()
            _ = openSavedTab(saved)
        case .copyURL(let id):
            guard let tab = selected(id) else { return false }
            dismissOmnibar()
            copyAddress(tab)
        case .popOut(let id):
            guard let tab = selected(id), let open = popOutPin(tab) else { return false }
            dismissOmnibar()
            select(open)
        case .bookmark(let id):
            guard let tab = selected(id) else { return false }
            dismissOmnibar()
            editBookmark(tab: tab)
        case .pin(let id, let pinned):
            guard let tab = selected(id), tab.pinned != pinned else { return false }
            dismissOmnibar()
            if pinned {
                setPinPresentation(tab, row: true)
            } else {
                removePin(tab)
                tabChanged(tab)
            }
        case .mute(let id, let muted):
            guard let tab = selected(id), !tab.media.isEmpty else { return false }
            dismissOmnibar()
            for source in tab.media where source.muted != muted { tab.control(source, action: "mute") }
        case .split(let leftID, let rightID):
            guard let left = selected(leftID), let right = splittableTabs.first(where: { $0.id == rightID }),
                splittableTabs.contains(where: { $0 === left }), splittableTabs.contains(where: { $0 === right })
            else { return false }
            dismissOmnibar()
            split(left, with: right)
        case .endSplit(let left, let right):
            guard visibleSplit?.left == left, visibleSplit?.right == right else { return false }
            dismissOmnibar()
            endSplit()
        case .saveSplit(let left, let right):
            guard visibleSplit?.left == left, visibleSplit?.right == right else { return false }
            dismissOmnibar()
            editSplitBookmark()
        case .move(let id, let profileID):
            guard let tab = selected(id), !profile.privateMode,
                profiles.contains(where: { $0.id == profileID && !$0.privateMode })
            else { return false }
            dismissOmnibar()
            moveTabToProfile(tab, profileID: profileID)
        case .switchProfile(let id):
            guard profiles.contains(where: { $0.id == id }) else { return false }
            dismissOmnibar()
            switchProfile(id)
        }
        return true
    }
}

extension HistorySuggestionWork {
    nonisolated static func distinctMatches(
        rows: [PreparedHistoryVisit], addressVisits: [String: Int],
        query: LocalPageSearch.Query, now: Date
    ) -> [HistorySuggestionMatch] {
        var best: [HistorySuggestionMatch] = []
        func precedes(_ left: HistorySuggestionMatch, _ right: HistorySuggestionMatch) -> Bool {
            left.score == right.score ? left.visit.id.uuidString < right.visit.id.uuidString : left.score > right.score
        }
        for (index, row) in rows.enumerated() {
            if index % 256 == 0, Task.isCancelled { return [] }
            guard let score = row.score(query: query) else { continue }
            let adjusted =
                score + (query.text.isEmpty ? 35 : 20)
                + min(20, log2(Double((addressVisits[row.visit.address] ?? 1) + 1)) * 5)
                + max(0, 12 - now.timeIntervalSince(row.visit.date) / 86400) - (row.savedSearch ? 15 : 0)
            if best.count == 6, adjusted < best.last!.score { continue }
            let match = HistorySuggestionMatch(visit: row.visit, label: row.label, score: adjusted)
            if let slot = best.firstIndex(where: { $0.visit.address == row.visit.address }) {
                guard precedes(match, best[slot]) else { continue }
                best.remove(at: slot)
            }
            best.append(match)
            best.sort(by: precedes)
            if best.count > 6 { best.removeLast() }
        }
        return best
    }
}

nonisolated enum BookmarkScopeWork {
    static func matches(_ favorites: [Favorite], query: LocalPageSearch.Query) -> [Int] {
        var best: [(index: Int, score: Double)] = []
        for (index, favorite) in favorites.enumerated() {
            if index % 128 == 0, Task.isCancelled { return [] }
            let address = favorite.searchAddress
            guard let score = LocalPageSearch.Document(title: favorite.title, address: address).score(query) else {
                continue
            }
            if best.count == 6, score <= best.last!.score { continue }
            best.append((index, score))
            best.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            if best.count > 6 { best.removeLast() }
        }
        return Task.isCancelled ? [] : best.map(\.index)
    }
}

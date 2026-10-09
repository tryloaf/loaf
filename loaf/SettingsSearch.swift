import Foundation

struct SettingsSearchResult: Identifiable {
    let id: String
    let section: String
    let title: String
    let keywords: String
}

enum SettingsSearch {
    static let entries: [SettingsSearchResult] = [
        .init(
            id: "pinned-layout", section: "general", title: "pinned tab layout", keywords: "grid list sidebar pins rows"
        ),
        .init(
            id: "restore", section: "general", title: "restore windows and tabs",
            keywords: "startup launch session reopen"),
        .init(
            id: "quit-warning", section: "general", title: "warn before quitting",
            keywords: "quit exit confirmation unsaved work command q"),
        .init(
            id: "ai-features", section: "search", title: "AI features",
            keywords: "enable disable ChatGPT Apple Intelligence answers models"),
        .init(
            id: "sleep-tabs", section: "general", title: "sleep idle tabs",
            keywords: "memory performance suspend unload battery thirty minutes"),
        .init(
            id: "custom-new-tab", section: "general", title: "custom new tab URL",
            keywords: "homepage start page website"),
        .init(
            id: "browsing-time", section: "general", title: "local browsing time",
            keywords: "tracking screen time private consent statistics widgets"),
        .init(
            id: "power-saver", section: "general", title: "power saver",
            keywords: "battery low energy percentage background"),
        .init(
            id: "import-data", section: "profiles", title: "import browsing data",
            keywords: "profile cookies history bookmarks export migrate full disk access"),
        .init(
            id: "web-notifications", section: "websites", title: "website notifications",
            keywords: "permission alerts notifications"),
        .init(
            id: "download-permissions", section: "websites", title: "ask before downloading from a new site",
            keywords: "downloads permission prompt allow block domain subdomain private"),
        .init(id: "link-groups", section: "general", title: "browsing trails", keywords: "links groups tab history"),
        .init(
            id: "resize-transition", section: "appearance", title: "soften sidebar resizing",
            keywords: "resize fade blur crossfade motion"),
        .init(
            id: "tint-wonderbar", section: "appearance", title: "tint wonderbar",
            keywords: "omnibar theme container background colour color"),
        .init(
            id: "applescript", section: "advanced", title: "JavaScript from AppleScript",
            keywords: "automation scripting"),
        .init(
            id: "haptics", section: "general", title: "trackpad haptics", keywords: "feedback vibration touch tactile"),
        .init(id: "appearance", section: "appearance", title: "appearance", keywords: "light dark system theme"),
        .init(
            id: "sidebar-only-chrome", section: "appearance", title: "sidebar-only titlebar",
            keywords: "hide titlebar toolbar traffic lights gray grey dots window controls hover"),
        .init(
            id: "page-margins", section: "appearance", title: "keep page margins when sidebar is hidden",
            keywords: "rounded border edges detection background inset padding compact sidebar-only"),
        .init(
            id: "profile-color", section: "appearance", title: "profile color",
            keywords:
                "theme tint intensity custom colour picker palette sidebar subtle balanced rich window transparency translucent glass frosted"
        ),
        .init(
            id: "default-browser", section: "general", title: "default browser",
            keywords: "open links default application"),
        .init(
            id: "weather", section: "general", title: "weather city and provider",
            keywords: "forecast location fahrenheit celsius temperature weatherkit"),
        .init(
            id: "google-suggestions", section: "search", title: "search suggestions",
            keywords: "autocomplete wonderbar prediction Google DuckDuckGo Wikipedia provider"),
        .init(
            id: "alternate-search", section: "search", title: "alternate search shortcut",
            keywords: "provider redirect perplexity custom command return ai overview chatgpt luna ask loaf"),
        .init(
            id: "site-discovery", section: "search", title: "remote site discovery",
            keywords: "popular websites catalog suggestions"),
        .init(
            id: "profiles", section: "profiles", title: "profiles and personalization",
            keywords: "name emoji icon tint color edit container private"),
        .init(
            id: "websites", section: "websites", title: "saved website decisions",
            keywords: "site permissions camera microphone javascript autoplay zoom"),
        .init(
            id: "pointerCapture", section: "websites", title: "allow websites to capture the pointer",
            keywords: "mouse cursor lock pointer capture games escape"),
        .init(
            id: "blocker", section: "privacy", title: "block ads and trackers",
            keywords: "adblock privacy content blocking exceptions"),
        .init(id: "filters", section: "privacy", title: "update blocking filters", keywords: "adguard ads trackers"),
        .init(
            id: "cookies", section: "privacy", title: "allow and manage cookies",
            keywords: "cookie storage website data sign out delete"),
        .init(
            id: "clear", section: "privacy", title: "clear browsing data",
            keywords: "delete erase history cache cookies downloads timeframe"),
        .init(
            id: "save-passwords", section: "passwords", title: "offer to save login passwords",
            keywords: "credentials keychain remember login"),
        .init(
            id: "autofill", section: "passwords", title: "suggest saved logins",
            keywords: "autofill password username email fill"),
        .init(
            id: "saved-passwords", section: "passwords", title: "saved passwords",
            keywords:
                "reveal delete username keychain credentials import csv password manager generate copy edit touch id"),
        .init(
            id: "extensions", section: "extensions", title: "installed extensions",
            keywords: "plugins chrome disable enable remove compatibility"),
        .init(
            id: "install-extension", section: "extensions", title: "install an extension",
            keywords: "chrome web store crx unpacked folder package"),
        .init(
            id: "developer", section: "advanced", title: "developer menu and inspection",
            keywords: "inspect devtools console source debug"),
        .init(
            id: "inspector-mode", section: "advanced", title: "web inspector placement",
            keywords: "devtools inline dock detached separate window"),
        .init(
            id: "identity", section: "advanced", title: "default browser identity",
            keywords: "user agent safari desktop automatic webkit"),
    ]
    static func results(for query: String) -> [SettingsSearchResult] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        func stem(_ word: String) -> String { word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word }
        return entries.filter { entry in
            let terms = (entry.title + " " + entry.section + " " + entry.keywords).lowercased()
            let vocabulary = terms.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { stem(String($0)) }
            return words.allSatisfy { word in vocabulary.contains { $0.contains(stem(word)) } }
        }.sorted { left, right in
            let a = words.filter { left.title.contains($0) }.count
            let b = words.filter { right.title.contains($0) }.count
            return a == b ? left.title < right.title : a > b
        }
    }
}

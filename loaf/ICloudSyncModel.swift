import Foundation

nonisolated struct SyncStamp: Codable, Equatable, Comparable, Sendable {
    var counter: UInt64
    var device: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
    }
}
nonisolated struct SyncField: Codable, Equatable, Sendable {
    var value: Data?
    var stamp: SyncStamp
}
nonisolated struct SyncDocument: Codable, Equatable, Sendable {
    var version = 1
    var fields: [String: SyncField] = [:]

    var deleted = false
    mutating func merge(_ other: Self) throws {
        guard other.version == 1, other.fields.count <= 4096, other.fields.keys.allSatisfy({ $0.utf8.count <= 128 }),
            other.fields.values.allSatisfy({ $0.stamp.counter < UInt64.max - 1 && $0.stamp.device.count <= 64 })
        else { throw ICloudSyncFailure.invalidData }
        deleted = deleted || other.deleted
        for (key, field) in other.fields where fields[key] == nil || fields[key]!.stamp < field.stamp {
            fields[key] = field
        }
        guard fields.count <= 4096 else { throw ICloudSyncFailure.tooLarge }
        if deleted { fields = [:] }
    }
}
nonisolated enum ICloudSyncFailure: LocalizedError {
    case invalidData, tooLarge, accountChanged, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidData: "iCloud data couldn’t be read safely. Sync is paused; local data is retained."
        case .tooLarge: "There’s too much data in a sync record. Local data is retained."
        case .accountChanged: "Your iCloud account changed. Turn sync on again to use the current account."
        case .unavailable: "Sign in to iCloud in System Settings to use sync."
        }
    }
}
nonisolated struct SyncedTab: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var profileID: UUID
    var title: String
    var address: String
}
nonisolated struct SyncedMac: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var updatedAt: Date
    var tabs: [SyncedTab]
}

nonisolated enum ICloudSyncProjection {

    static let preferenceKeys: Set<String> = [
        "haptics", "showLinkPreview", "fahrenheit", "sidebarWidth", "alternateSearch", "capitalizeMenus",
        "userAgentMode", "restoreSession", "warnBeforeQuitting", "warnBeforeClosingOtherProfiles", "sleepIdleTabs", "sidebarOnlyChrome",
        "insetCollapsedPage", "pinnedLayout", "tintWonderbar", "tabSleepMinutes",
        "customNewTabURL", "searchEngine", "customSearchTemplate", "suggestionProvider", "linkTabGroups",
    ]
    static let profileKeys: Set<String> = ["name", "emoji", "customIconPNG", "tint", "blockerEnabled", "blocksCookies"]
    static let appearanceKeys: Set<String> = [
        "customTint", "sidebarWeather", "compactSidebarWeather", "tintStrength", "windowTransparency",
        "background", "pinStyle", "widgets", "hiddenWidgets", "widgetSizes", "widgetPositions",
    ]
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
    static func value(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    static func address(_ text: String?) -> String? {
        guard let text, text.utf8.count <= 16_384, let url = URL(string: text),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            !BrowserAddress.isLocalHost(host)
        else { return nil }
        return url.absoluteString
    }
    static func tab(_ saved: SavedTab) -> SavedTab? {
        guard saved.page == .web, let address = address(saved.pinnedAddress ?? saved.address) else { return nil }
        var tab = saved
        tab.address = address
        tab.pinnedAddress = saved.pinned ? address : nil
        tab.title = String(tab.title.prefix(512))
        tab.customTitle = tab.customTitle.map { String($0.prefix(512)) }
        tab.pinnedTitle = tab.pinnedTitle.map { String($0.prefix(512)) }

        for key in [\SavedTab.customIcon, \SavedTab.pinnedIcon] {
            if let icon = tab[keyPath: key], icon.contains("/") || icon.contains(":") || icon.count > 64 {
                tab[keyPath: key] = nil
            }
        }
        return tab
    }
    static func profile(_ profile: Profile) throws -> [String: Data] {
        guard !profile.privateMode else { return [:] }
        let raw = try object(profile)
        var fields = try raw.filter { profileKeys.contains($0.key) }.mapValues(data)
        if let appearance = profile.personalization {
            for (key, val) in try object(appearance) where appearanceKeys.contains(key) {
                if key == "background", let name = val as? String,
                    name.contains("/") || name.contains(":") { continue }
                fields["appearance." + key] = try data(val)
            }
        }
        let pins = (profile.pinShortcuts ?? []).compactMap(tab)
        fields["pinOrder"] = try data(pins.map { $0.id.uuidString })
        for pin in pins { fields["pin." + pin.id.uuidString] = try encoded(pin) }
        let groups = (profile.pinnedGroups ?? []).map { group in
            var group = group
            group.savedTabs = (group.savedTabs ?? []).compactMap(tab)
            return group
        }
        fields["groupOrder"] = try data(groups.map { $0.id.uuidString })
        for group in groups { fields["group." + group.id.uuidString] = try encoded(group) }
        return fields
    }
    static func preferences(_ preferences: BrowserPreferences) throws -> [String: Data] {
        try object(preferences).filter { preferenceKeys.contains($0.key) }.mapValues(data)
    }
    static func applyPreferences(_ document: SyncDocument, to preferences: BrowserPreferences) throws -> BrowserPreferences {
        var raw = try object(preferences)
        for (key, field) in document.fields where preferenceKeys.contains(key) {
            raw[key] = try field.value.map(value)
        }
        var result = try JSONDecoder().decode(BrowserPreferences.self, from: data(raw))
        result.sidebarWidth = min(360, max(192, result.sidebarWidth.isFinite ? result.sidebarWidth : 220))
        if let text = result.customNewTabURL, !text.isEmpty, address(text) == nil { result.customNewTabURL = nil }
        if let template = result.customSearchTemplate, !template.isEmpty,
            address(template.replacingOccurrences(of: "%s", with: "query").replacingOccurrences(of: "{query}", with: "query")) == nil {
            result.customSearchTemplate = nil
        }
        return result
    }
    static func applyProfile(_ document: SyncDocument, to profile: Profile) throws -> Profile {
        var raw = try object(profile)
        var appearance = try object(profile.personalization ?? Personalization())
        let defaultAppearance = try object(Personalization())
        for (key, field) in document.fields {
            if profileKeys.contains(key) { raw[key] = try field.value.map(value) }
            if key.hasPrefix("appearance."), appearanceKeys.contains(String(key.dropFirst(11))) {
                let name = String(key.dropFirst(11))
                if name == "background", let blob = field.value, let val = try value(blob) as? String,
                    val.contains("/") || val.contains(":") { continue }
                appearance[name] = try field.value.map(value) ?? defaultAppearance[name]
            }
        }
        raw["personalization"] = appearance
        var result = try JSONDecoder().decode(Profile.self, from: data(raw))
        result.name = String(result.name.prefix(128))
        result.emoji = String(result.emoji.prefix(4))
        if (result.customIconPNG?.count ?? 0) > 100_000 { result.customIconPNG = nil }
        result.tint = min(15, max(0, result.tint))
        let tintStrength = result.personalization?.tintStrength ?? 0.06
        result.personalization?.tintStrength = min(1, max(0, tintStrength))
        let pins = try document.fields.filter { $0.key.hasPrefix("pin.") }.compactMap { key, field -> SavedTab? in
            guard let blob = field.value else { return nil }
            let decoded = try JSONDecoder().decode(SavedTab.self, from: blob)
            guard key == "pin." + decoded.id.uuidString else { throw ICloudSyncFailure.invalidData }
            return tab(decoded)
        }
        let groups = try document.fields.filter { $0.key.hasPrefix("group.") }.compactMap { key, field -> TabGroup? in
            guard let blob = field.value else { return nil }
            var group = try JSONDecoder().decode(TabGroup.self, from: blob)
            guard key == "group." + group.id.uuidString, (group.savedTabs ?? []).count <= 2000,
                Set((group.savedTabs ?? []).map(\.id)).count == (group.savedTabs ?? []).count
            else { throw ICloudSyncFailure.invalidData }
            group.name = String(group.name.prefix(128))
            group.icon = String(group.icon.prefix(64))
            group.color = min(15, max(0, group.color))
            let localOnly = (profile.pinnedGroups ?? []).first { $0.id == group.id }?.savedTabs?.filter { tab($0) == nil } ?? []
            group.savedTabs = (group.savedTabs ?? []).compactMap(tab) + localOnly
            return group
        }
        result.pinShortcuts = try ordered(pins, document: document, key: "pinOrder") + (profile.pinShortcuts ?? []).filter { tab($0) == nil }
        result.pinnedGroups = try ordered(groups, document: document, key: "groupOrder")
        return result
    }
    static func ordered<T: Identifiable>(_ values: [T], document: SyncDocument, key: String) throws -> [T] where T.ID == UUID {
        let order = try document.fields[key]?.value.map { try JSONDecoder().decode([String].self, from: $0) } ?? []
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return values.sorted {
            let a = rank[$0.id.uuidString] ?? Int.max, b = rank[$1.id.uuidString] ?? Int.max
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }
    static func mac(_ snapshot: BrowserSnapshot, id: String, name: String, now: Date = Date()) -> SyncedMac {
        let privateIDs = Set(snapshot.profiles.filter(\.privateMode).map(\.id))
        let regular = Set(snapshot.profiles.filter { !$0.privateMode }.map(\.id)).subtracting(privateIDs)
        var seen = Set<UUID>()
        var tabs: [SyncedTab] = []
        for window in snapshot.windows ?? [] {
            for (profileID, workspace) in window.workspaces.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where regular.contains(profileID) {
                for saved in workspace.tabs where seen.insert(saved.id).inserted {
                    guard saved.page == .web, let url = address(saved.address) else { continue }
                    tabs.append(SyncedTab(id: saved.id, profileID: profileID, title: String(saved.title.prefix(512)), address: url))
                }
            }
        }
        return SyncedMac(id: id, name: String(name.prefix(128)), updatedAt: now, tabs: tabs)
    }
}

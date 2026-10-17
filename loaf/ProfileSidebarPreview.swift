import SwiftUI

struct ProfileSidebarPreview: View {
    let store: BrowserStore
    let profile: Profile
    private var pins: [SavedTab] { profile.pinShortcuts ?? profile.tabs.filter(\.pinned) }
    enum Entry: Identifiable {
        case tab(SavedTab)
        case group(TabGroup)
        case newTab
        var id: UUID {
            switch self {
            case .tab(let tab): tab.id
            case .group(let group): group.id
            case .newTab: SidebarEntry.newTabID
            }
        }
    }
    var entries: [Entry] { Self.entries(profile: profile, workspace: store.workspaces[profile.id]) }
    static func entries(profile: Profile, workspace: WindowWorkspace?) -> [Entry] {
        let pins = profile.pinShortcuts ?? profile.tabs.filter(\.pinned)
        let pinned = profile.pinnedGroups ?? []
        let pinnedIDs = Set(pinned.map(\.id))
        let groups = pinned + (workspace?.groups ?? []).filter { !pinnedIDs.contains($0.id) }
        let membersByGroup = Dictionary(
            grouping: profile.tabs.compactMap { tab in
                tab.groupID.map { ($0, tab) }
            }, by: { $0.0 }
        ).mapValues { $0.map { $0.1 } }
        func entries(_ group: TabGroup) -> [Entry] {
            guard !group.collapsed else { return [.group(group)] }
            let members =
                group.isPinned
                ? group.savedTabs ?? membersByGroup[group.id] ?? []
                : (membersByGroup[group.id] ?? []).filter { !$0.pinned }
            return [.group(group)]
                + members.map { member in
                    var copy = member
                    copy.groupID = group.id
                    return .tab(copy)
                }
        }
        let groupIDs = Set(groups.map(\.id))
        let loose = profile.tabs.filter { !$0.pinned && ($0.groupID.map { !groupIDs.contains($0) } ?? true) }
        let local = groups.filter { !$0.isPinned }
        let available = local.map(\.id) + loose.map(\.id)
        let availableIDs = Set(available)
        let savedOrder = workspace?.sidebarOrder ?? []
        let savedIDs = Set(savedOrder)
        let order = savedOrder.filter { availableIDs.contains($0) } + available.filter { !savedIDs.contains($0) }
        let localByID = local.reduce(into: [UUID: TabGroup]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        let looseByID = loose.reduce(into: [UUID: SavedTab]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        return pins.filter { $0.pinPresentation == "row" }.map(Entry.tab)
            + groups.filter(\.isPinned).flatMap(entries) + [.newTab]
            + order.flatMap { id in
                if let group = localByID[id] { return entries(group) }
                return looseByID[id].map { [Entry.tab($0)] } ?? []
            }
    }
    var body: some View {
        let grid = pins.filter { $0.pinPresentation != "row" }
        let list = store.preferences.pinnedLayout == "list"
        let liveTabs = existingTabs
        VStack(spacing: 0) {
            if !grid.isEmpty {
                ScrollView {
                    if list {
                        VStack(spacing: 4) { ForEach(grid) { row($0, live: liveTabs[$0.id]) } }
                    } else {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 6),
                                count: PinGridLayout.columns(for: grid.count)), spacing: 6
                        ) {
                            ForEach(grid) { pin in
                                icon(pin, live: liveTabs[pin.id]).frame(maxWidth: .infinity).frame(
                                    height: PinGridLayout.tileHeight
                                )
                                .background(PinnedTileBackground(selected: isSelected(pin)))
                            }
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: PinGridLayout.height(for: grid.count, list: list))
                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            }
            ScrollView {
                LazyVStack(spacing: SidebarTabMetrics.spacing) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .tab(let tab):
                            row(tab, live: liveTabs[tab.id]).padding(.leading, tab.groupID == nil ? 0 : 12)
                        case .group(let group): groupRow(group)
                        case .newTab: SidebarNewTabLabel()
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, SidebarTabMetrics.bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .top)
            }.scrollIndicators(.hidden)
                .padding(.top, grid.isEmpty && pins.contains { $0.pinPresentation == "row" } ? 10 : 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    var existingTabs: [UUID: BrowserTab] {
        var result: [UUID: BrowserTab] = [:]
        if let tabs = store.application.runtimes[profile.id]?.tabs.values {
            for tab in tabs where tab.windowID == store.id {
                for id in [tab.id, tab.pinnedShortcutID, tab.groupMemberID].compactMap({ $0 }) {
                    if result[id] == nil { result[id] = tab }
                }
            }
        }
        for previews in [store.pinPreviews, store.groupPreviews] {
            for (id, tab) in previews where tab.profileID == profile.id && result[id] == nil {
                result[id] = tab
            }
        }
        return result
    }
    private func isSelected(_ saved: SavedTab) -> Bool {
        guard let selected = profile.selectedTab else { return false }
        if saved.id == selected { return true }
        let live = store.application.runtimes[profile.id]?.tabs[selected]
        return live?.pinnedShortcutID == saved.id || live?.groupMemberID == saved.id
    }
    private func icon(_ saved: SavedTab, live: BrowserTab?) -> some View {
        let url = (saved.pinnedAddress ?? saved.address).flatMap(URL.init(string:))
        let image =
            live?.favicon
            ?? url.flatMap {
                store.application.favicons.cachedImage(for: $0, privateID: profile.privateMode ? profile.id : nil)
            }
        return SiteIconContent(
            glyph: saved.pinned ? saved.pinnedIcon ?? saved.customIcon : saved.customIcon,
            image: image, page: saved.page
        ).frame(width: 16, height: 16)
    }
    private func row(_ saved: SavedTab, live: BrowserTab?) -> some View {
        let title =
            live?.sidebarTitle
            ?? (saved.pinned
                ? saved.pinnedTitle ?? saved.customTitle ?? saved.title : saved.customTitle ?? saved.title)
        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                icon(saved, live: live)
                FadingTitle(text: BrowserAddress.visible(title)).frame(height: 32)
            }.padding(.leading, 8).padding(.trailing, 12)
        }.padding(.trailing, 4).frame(height: 32)
            .modifier(SidebarRowChrome(selected: isSelected(saved)))
    }
    private func groupRow(_ group: TabGroup) -> some View {
        HStack(spacing: 4) {
            EmojiIcon(glyph: group.icon, size: 17).frame(width: 24, height: 28)
            Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            HStack(spacing: 0) {
                GolzheimIcon(icon: .disclosureDown, size: 17, weight: 220)
                    .rotationEffect(.degrees(group.collapsed ? -90 : 0)).frame(width: 20, height: 28)
                Color.clear.frame(width: 22, height: 24)
            }.fixedSize()
        }.padding(.horizontal, 6).frame(height: 32)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

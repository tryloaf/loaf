import SwiftUI

struct ProfileSidebarPreview: View {
    let store: BrowserStore
    let profile: Profile
    private var pins: [SavedTab] { profile.pinShortcuts ?? profile.tabs.filter(\.pinned) }
    private var groups: [TabGroup] {
        let pinned = profile.pinnedGroups ?? []
        return pinned + (store.workspaces[profile.id]?.groups ?? []).filter { group in !pinned.contains { $0.id == group.id } }
    }
    enum Entry: Identifiable {
        case tab(SavedTab), group(TabGroup), newTab
        var id: UUID {
            switch self {
            case .tab(let tab): tab.id
            case .group(let group): group.id
            case .newTab: SidebarEntry.newTabID
            }
        }
    }
    var entries: [Entry] {
        func entries(_ group: TabGroup) -> [Entry] {
            guard !group.collapsed else { return [.group(group)] }
            let members = group.isPinned ? group.savedTabs ?? profile.tabs.filter { $0.groupID == group.id }
                : profile.tabs.filter { $0.groupID == group.id && !$0.pinned }
            return [.group(group)] + members.map { member in
                var copy = member
                copy.groupID = group.id
                return .tab(copy)
            }
        }
        let groupIDs = Set(groups.map(\.id))
        let loose = profile.tabs.filter { !$0.pinned && ($0.groupID.map { !groupIDs.contains($0) } ?? true) }
        let local = groups.filter { !$0.isPinned }
        let available = local.map(\.id) + loose.map(\.id)
        let savedOrder = store.workspaces[profile.id]?.sidebarOrder ?? []
        let order = savedOrder.filter { available.contains($0) } + available.filter { !savedOrder.contains($0) }
        return pins.filter { $0.pinPresentation == "row" }.map(Entry.tab)
            + groups.filter(\.isPinned).flatMap(entries) + [.newTab]
            + order.flatMap { id in
                if let group = local.first(where: { $0.id == id }) { return entries(group) }
                return loose.first(where: { $0.id == id }).map { [Entry.tab($0)] } ?? []
            }
    }
    var body: some View {
        let grid = pins.filter { $0.pinPresentation != "row" }
        let list = store.preferences.pinnedLayout == "list"
        VStack(spacing: 0) {
            if !grid.isEmpty {
                ScrollView {
                    if list {
                        VStack(spacing: 4) { ForEach(grid) { row($0) } }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                            count: PinGridLayout.columns(for: grid.count)), spacing: 6) {
                            ForEach(grid) { pin in
                                icon(pin).frame(maxWidth: .infinity).frame(height: PinGridLayout.tileHeight)
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
                        case .tab(let tab): row(tab).padding(.leading, tab.groupID == nil ? 0 : 12)
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
    private func existing(_ saved: SavedTab) -> BrowserTab? {
        let tabs = store.application.runtimes[profile.id]?.tabs.values
        return tabs?.first { $0.windowID == store.id && ($0.id == saved.id || $0.pinnedShortcutID == saved.id || $0.groupMemberID == saved.id) }
            ?? [store.pinPreviews[saved.id], store.groupPreviews[saved.id]].compactMap { $0 }.first { $0.profileID == profile.id }
    }
    private func isSelected(_ saved: SavedTab) -> Bool {
        guard let selected = profile.selectedTab else { return false }
        if saved.id == selected { return true }
        let live = store.application.runtimes[profile.id]?.tabs[selected]
        return live?.pinnedShortcutID == saved.id || live?.groupMemberID == saved.id
    }
    private func title(_ saved: SavedTab) -> String {
        existing(saved)?.sidebarTitle ?? (saved.pinned ? saved.pinnedTitle ?? saved.customTitle ?? saved.title : saved.customTitle ?? saved.title)
    }
    private func icon(_ saved: SavedTab) -> some View {
        let live = existing(saved)
        let url = (saved.pinnedAddress ?? saved.address).flatMap(URL.init(string:))
        let image = live?.favicon ?? url.flatMap {
            store.application.favicons.cachedImage(for: $0, privateID: profile.privateMode ? profile.id : nil)
        }
        return SiteIconContent(glyph: saved.pinned ? saved.pinnedIcon ?? saved.customIcon : saved.customIcon,
            image: image, page: saved.page).frame(width: 16, height: 16)
    }
    private func row(_ saved: SavedTab) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                icon(saved)
                FadingTitle(text: BrowserAddress.visible(title(saved))).frame(height: 32)
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

import SwiftUI

/// Metadata only: a neighboring profile never loads pages or fetches icons during a swipe.
struct ProfileSidebarPreview: View {
    let store: BrowserStore
    let profile: Profile
    private var pins: [SavedTab] { profile.pinShortcuts ?? profile.tabs.filter(\.pinned) }
    private var groups: [TabGroup] {
        let pinned = profile.pinnedGroups ?? []
        return pinned + (store.workspaces[profile.id]?.groups ?? []).filter { group in !pinned.contains { $0.id == group.id } }
    }
    var body: some View {
        VStack(spacing: 0) {
            let grid = pins.filter { $0.pinPresentation != "row" }
            if !grid.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                    count: store.preferences.pinnedLayout == "list" ? 1 : PinGridLayout.columns(for: grid.count)), spacing: 6) {
                    ForEach(grid) { pin in
                        HStack(spacing: 6) {
                            icon(pin)
                            if store.preferences.pinnedLayout == "list" { Text(title(pin)).lineLimit(1); Spacer() }
                        }.frame(maxWidth: .infinity).frame(height: 32)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(.top, 10).padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(pins.filter { $0.pinPresentation == "row" }) { row($0) }
                    ForEach(groups.filter(\.isPinned)) { group in groupRows(group) }
                    HStack(spacing: 8) {
                        GolzheimIcon(icon: .plus, size: 16)
                        Text("new tab")
                        Spacer()
                        Text("⌘T").foregroundStyle(.tertiary)
                    }.padding(.horizontal, 8).frame(height: 40)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    let loose = profile.tabs.filter { !$0.pinned && $0.groupID == nil }
                    let local = groups.filter { !$0.isPinned }
                    let available = local.map(\.id) + loose.map(\.id)
                    let savedOrder = store.workspaces[profile.id]?.sidebarOrder ?? []
                    let order = savedOrder.filter { available.contains($0) } + available.filter { !savedOrder.contains($0) }
                    ForEach(order, id: \.self) { id in
                        if let group = local.first(where: { $0.id == id }) { groupRows(group) }
                        else if let tab = loose.first(where: { $0.id == id }) { row(tab) }
                    }
                }.padding(.bottom, 8)
            }.scrollIndicators(.hidden).allowsHitTesting(false)
        }.padding(.horizontal, 8).font(.system(size: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
    }
    private func title(_ tab: SavedTab) -> String { tab.pinnedTitle ?? tab.customTitle ?? tab.title }
    @ViewBuilder private func icon(_ tab: SavedTab) -> some View {
        if let glyph = tab.pinnedIcon ?? tab.customIcon { EmojiIcon(glyph: glyph, size: 16) }
        else if let url = tab.address.flatMap(URL.init(string:)),
            let image = store.application.favicons.cachedImage(for: url, privateID: profile.privateMode ? profile.id : nil) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
        } else { GolzheimIcon(icon: tab.page.icon, size: 16) }
    }
    private func row(_ tab: SavedTab) -> some View {
        HStack(spacing: 8) { icon(tab); Text(title(tab)).lineLimit(1); Spacer(minLength: 0) }
            .padding(.horizontal, 8).frame(height: 32)
            .background(Color.primary.opacity(tab.id == profile.selectedTab ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 7))
    }
    @ViewBuilder private func groupRows(_ group: TabGroup) -> some View {
        HStack(spacing: 8) {
            GolzheimIcon(icon: .folder, size: 16)
            Text(group.name).lineLimit(1)
            Spacer()
        }.padding(.horizontal, 8).frame(height: 32)
        if !group.collapsed {
            ForEach(group.savedTabs ?? profile.tabs.filter { $0.groupID == group.id && !$0.pinned }) { tab in
                row(tab).padding(.leading, 12)
            }
        }
    }
}

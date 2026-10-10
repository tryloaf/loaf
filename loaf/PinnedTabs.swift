import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension BrowserWindowState {
    @discardableResult func openSavedTab(_ saved: SavedTab, profileID: UUID? = nil) -> BrowserTab {
        let destination = profileID ?? selectedProfileID
        if destination != selectedProfileID { switchProfile(destination) }
        var copy = saved
        copy.id = UUID()
        copy.groupMemberID = nil
        if !tabGroups.contains(where: { $0.id == copy.groupID }) || destination != selectedProfileID {
            copy.groupID = nil
        }
        updateProfile(destination) { $0.tabs.append(copy) }
        let tab = attach(copy, profileID: destination)
        if let groupID = copy.groupID { assignTab(tab, to: groupID) }
        select(tab)
        persistSoon()
        return tab
    }
    func moveTabToProfile(_ tab: BrowserTab, profileID: UUID) {
        guard tab.store === self, !tab.isDisposed, profileID != tab.profileID,
            profiles.contains(where: { $0.id == profileID })
        else { return }
        var saved = tab.saved
        saved.pinnedShortcutID = nil
        saved.groupID = nil
        saved.groupMemberID = nil
        if tab.pinned { removePin(tab) }
        _ = openSavedTab(saved, profileID: profileID)
        close(tab)
        tabHover.dismiss()
    }
    func moveTabToNewWindow(_ tab: BrowserTab) {
        guard tab.store === self, !tab.isDisposed, let coordinator = application.coordinator else { return }
        let destination = application.makeWindow(profileID: tab.profileID, restore: false)
        var saved = tab.saved
        saved.groupID = nil
        saved.groupMemberID = nil
        _ = destination.openSavedTab(saved)
        coordinator.show(destination)
        close(tab)
        tabHover.dismiss()
    }
    func favorite(_ tab: BrowserTab) {
        guard tab.store === self, !tab.isDisposed, let url = tab.url, ["http", "https"].contains(url.scheme),
            url.user == nil
        else { return }
        updateProfile(tab.profileID) { profile in
            if let index = profile.favorites.firstIndex(where: { $0.address == url.absoluteString }) {
                profile.favorites.remove(at: index)
            } else {
                profile.favorites.append(Favorite(title: tab.sidebarTitle, address: url.absoluteString))
            }
        }
        persistSoon()
    }
    func copyAddress(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        feedback.show(.copied, icon: .check, text: "address copied")
    }
    func toggleMute(_ tab: BrowserTab) {
        let muted = tab.media.contains { !$0.muted }
        for source in tab.media where source.muted != muted { tab.control(source, action: "mute") }
    }
    func editPin(_ tab: BrowserTab, address: Bool = false) {
        guard (!address || tab.pinned), !tab.isDisposed, let coordinator = application.coordinator else { return }
        tabHover.dismiss()
        let alert = NSAlert()
        alert.messageText = address ? "edit pinned page" : "rename tab"
        alert.informativeText =
            address ? "the return button will open this address." : "this name appears in the sidebar."
        let field = NSTextField(string: address ? tab.pinnedAddress ?? tab.url?.absoluteString ?? "" : tab.sidebarTitle)
        field.frame.size = NSSize(width: 284, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "save")
        alert.addButton(withTitle: "cancel")
        alert.window.initialFirstResponder = field
        coordinator.alert(alert, for: self) { [weak self, weak tab] result in
            guard result == .alertFirstButtonReturn, let self, let tab, !tab.isDisposed, (!address || tab.pinned),
                self.selectedProfileID == tab.profileID
            else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if address {
                guard let url = BrowserAddress.resolve(value), ["https", "http"].contains(url.scheme), url.host != nil,
                    url.user == nil
                else {
                    self.error = "use a valid website address"
                    return
                }
                tab.pinnedAddress = url.absoluteString
            } else if tab.pinned {
                tab.pinnedTitle = value.isEmpty ? nil : String(value.prefix(200))
            } else {
                tab.customTitle = value.isEmpty ? nil : String(value.prefix(200))
            }
            self.tabChanged(tab)
        }
    }
    func editPinIcon(_ tab: BrowserTab) {
        guard !tab.isDisposed, tab.store === self, tab.profileID == selectedProfileID else { return }
        tabHover.dismiss()
        editingTabIconID = tab.id
        if let groupID = tab.groupID { updateGroup(groupID) { $0.collapsed = false } }
    }

}

struct TabActions: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    var body: some View {
        if store.isPersistentTab(tab) {
            Button("unpin tab") { store.removePersistentTab(tab) }
        } else {
            Button("pin tab") { store.setPinPresentation(tab, row: true) }
            Button("pin to grid") { store.setPinPresentation(tab, row: false) }
        }
        Button(store.groupingTabs(including: tab).count > 1 ? "group selected tabs" : "new group with tab") {
            store.groupSelectedTabs(including: tab)
        }
        if tab.pinned {
            Button(tab.pinPresentation == "row" ? "move pin to grid" : "show pin as row") {
                store.setPinPresentation(tab, row: tab.pinPresentation != "row")
            }
        }
        if !tab.pinned {
            Button("rename…") { store.editPin(tab) }
            Menu("move to group") {
                Button("new group…") { store.groupSelectedTabs(including: tab) }
                ForEach(store.tabGroups) { group in
                    Button(group.name) { store.moveSelectedTabs(including: tab, to: group.id) }
                }
                if store.groupingTabs(including: tab).contains(where: { $0.groupID != nil }) {
                    Divider()
                    Button("remove from group") { store.moveSelectedTabs(including: tab, to: nil) }
                }
            }
        }
        let splitSelection = store.splitSelection(including: tab)
        if splitSelection.count == 2 {
            Button("split these tabs") { store.splitSelectedTabs(including: tab) }
        } else if splitSelection.count == 1 {
            let candidates = store.splittableTabs.filter { $0 !== tab }
            if !candidates.isEmpty {
                Menu("split with…") {
                    ForEach(candidates) { other in Button(other.sidebarTitle) { store.split(tab, with: other) } }
                }
            }
        }
        Divider()
        Button("change icon…") { store.editPinIcon(tab) }
        Button("duplicate tab") {
            var saved = tab.saved
            saved.pinned = false
            saved.pinnedShortcutID = nil
            _ = store.openSavedTab(saved)
        }
        if !store.profileFor(tab.profileID).privateMode {
            Menu("move to profile") {
                ForEach(store.profiles.filter { $0.id != tab.profileID && !$0.privateMode }) { profile in
                    Button(profile.name) { store.moveTabToProfile(tab, profileID: profile.id) }
                }
            }.disabled(store.profiles.filter { !$0.privateMode }.count < 2)
        }
        Button("open in new window") { store.moveTabToNewWindow(tab) }.disabled(store.application.coordinator == nil)
        Divider()
        Button("save bookmark…") { store.editBookmark(tab: tab) }.disabled(tab.url == nil)
        if store.profileFor(tab.profileID).favorites.contains(where: { $0.address == tab.url?.absoluteString }) {
            Button("remove bookmark") { store.favorite(tab) }
        }
        Button("copy link") { store.copyAddress(tab) }.disabled(tab.url == nil)
        if tab.pinned {
            Divider()
            Button("rename…") { store.editPin(tab) }
            Button("edit pinned page…") { store.editPin(tab, address: true) }
            Button("return to pinned page") { store.returnToPin(tab) }.disabled(tab.pinnedAddress == nil)
        }
        Divider()
        Button("reload") {
            let open = store.openPinned(tab)
            store.select(open)
            open.reload()
        }
        if !tab.media.isEmpty {
            Button(tab.media.contains { !$0.muted } ? "mute tab" : "unmute tab") { store.toggleMute(tab) }
            Button("show miniplayer") { tab.dismissedMedia.removeAll() }
        }
        Divider()
        Button("close tab") { store.close(tab) }.disabled(!store.tabs.contains(where: { $0 === tab }))
        Button("close other tabs") {
            for other in store.tabs where other.id != tab.id && !other.pinned { store.close(other) }
        }
    }
}

struct PinnedTabGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BrowserStore
    private struct Item: Identifiable {
        let id: UUID
        let tab: BrowserTab?
    }
    private var items: [Item] {
        let preview = store.pinDropPreview
        var pins = store.gridPinnedTabs
        if preview?.row == false { pins.removeAll { $0.id == store.draggedTabID } }
        var items = pins.map { Item(id: $0.pinnedShortcutID ?? $0.id, tab: $0) }
        if let preview, !preview.row, let id = store.draggedTabID {
            let index =
                preview.position.flatMap { position in
                    pins.firstIndex { $0.id == position.target }.map { $0 + (position.after ? 1 : 0) }
                } ?? items.count
            items.insert(Item(id: id, tab: nil), at: min(items.count, index))
        }
        return items
    }
    var body: some View {
        let items = items
        let list = store.preferences.pinnedLayout == "list"
        let columns = PinGridLayout.columns(for: items.count)
        Group {
            if items.isEmpty, store.draggedTabID != nil {
                Text("pin to grid").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: PinGridLayout.tileHeight)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            } else if !items.isEmpty {
                ScrollView {
                    if list {
                        VStack(spacing: 4) { ForEach(items) { item in tile(item, list: true) } }
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6
                        ) {
                            ForEach(items) { item in tile(item, list: false) }
                        }
                    }
                }.scrollIndicators(.hidden)
                    .frame(height: PinGridLayout.height(for: items.count, list: list))
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("pinned tabs").id(store.selectedProfileID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: items.map(\.id))
    }
    @ViewBuilder private func tile(_ item: Item, list: Bool) -> some View {
        if let tab = item.tab {
            if list { TabRow(tab: tab, store: store) } else { PinnedTabTile(tab: tab, store: store) }
        } else {
            RoundedRectangle(cornerRadius: 8).fill(profileTint(store.profile).opacity(0.08))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(profileTint(store.profile).opacity(0.25)) }
                .frame(height: PinGridLayout.tileHeight).allowsHitTesting(false)
        }
    }
}

struct PinnedTabTile: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @State private var pressed = false
    @State private var hovered = false
    private var selected: Bool { store.selectedTab?.id == tab.id || store.selectedSidebarTabIDs.contains(tab.id) }
    var body: some View {
        Button {
            store.selectSidebarTab(tab, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        } label: {
            EditableTabIcon(tab: tab, store: store, size: 16).frame(maxWidth: .infinity).frame(
                height: PinGridLayout.tileHeight
            ).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(
                (scheme == .dark ? Color.white : Color.black).opacity(selected ? 0.12 : hovered ? 0.08 : 0.045),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(pressed || store.draggedTabID == tab.id ? 0.55 : 1)
            .overlay {
                TabDragArea(tab: tab, store: store, title: tab.sidebarTitle, selected: selected, pressed: $pressed)
            }
            .background(TabHoverAnchor(tab: tab, store: store))
            .contextMenu { TabActions(tab: tab, store: store) }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .task(id: tab.pinnedAddress) {
                guard tab.pinnedIcon == nil, tab.favicon == nil,
                    let address = tab.pinnedAddress ?? tab.url?.absoluteString, let url = URL(string: address)
                else { return }
                let image = await store.application.favicons.image(
                    for: url, privateID: store.profileFor(tab.profileID).privateMode ? tab.profileID : nil)
                guard !Task.isCancelled, !tab.isDisposed, tab.favicon == nil,
                    tab.url.flatMap(BrowserAddress.websiteOrigin) == BrowserAddress.websiteOrigin(url)
                else { return }
                tab.favicon = image
            }

    }
}

nonisolated enum PinGridLayout {
    static let tileHeight: CGFloat = 32
    static func height(for count: Int, list: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        return list
            ? CGFloat(min(6, count)) * 36 - 4
            : CGFloat(min(3, (count + columns(for: count) - 1) / columns(for: count))) * (tileHeight + 6) - 6
    }
    static func columns(for count: Int) -> Int { count <= 3 ? max(1, count) : count == 4 ? 2 : 3 }
}

struct EditableTabIcon: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    var size: CGFloat = 16
    private var presented: Binding<Bool> {
        Binding(
            get: { store.editingTabIconID == tab.id },
            set: { if !$0 && store.editingTabIconID == tab.id { store.editingTabIconID = nil } })
    }
    var body: some View {
        Group {
            if tab.pinned, let icon = tab.pinnedIcon {
                EmojiIcon(glyph: icon, size: size)
            } else {
                SiteIcon(tab: tab, size: size)
            }
        }.frame(width: size, height: size)
            .popover(isPresented: presented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("tab icon").font(.system(size: 13, weight: .medium))
                        Spacer()
                        IconButton(icon: .close, label: "close icon picker") { store.editingTabIconID = nil }
                    }
                    Button("use website icon") { save(nil) }.controlSize(.small)
                    GolzheimPicker(
                        selection: Binding(
                            get: { (tab.pinned ? tab.pinnedIcon : tab.customIcon) ?? LoafIcon.globe.rawValue },
                            set: { save($0) }), gridHeight: 220)
                }.padding(16).frame(width: 360)
                    .preferredColorScheme(store.profile.privateMode ? .dark : nil)
                    .tint(store.profile.privateMode ? PrivateChrome.accent : Color.accentColor)
            }
            .onDisappear { if store.editingTabIconID == tab.id { store.editingTabIconID = nil } }
    }
    private func save(_ icon: String?) {
        guard !tab.isDisposed, tab.store === store, tab.profileID == store.selectedProfileID else {
            store.editingTabIconID = nil
            return
        }
        if tab.pinned { tab.pinnedIcon = icon } else { tab.customIcon = icon }
        store.tabChanged(tab)
        store.editingTabIconID = nil
    }
}

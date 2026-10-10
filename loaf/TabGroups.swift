import AppKit
import Combine
import SwiftUI

@MainActor enum SidebarEntry: Identifiable {
    case group(TabGroup)
    case tab(BrowserTab)
    case newTab
    static let newTabID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id: UUID {
        switch self {
        case .group(let group): group.id
        case .tab(let tab): tab.id
        case .newTab: Self.newTabID
        }
    }
    var height: CGFloat {
        if case .newTab = self { return 44 }
        return 32
    }
    var tab: BrowserTab? {
        if case .tab(let tab) = self { return tab }
        return nil
    }
}

@MainActor struct SidebarEntryCache {
    struct Key: Equatable {
        let profileID: UUID
        let tabs: [SavedTab]
        let localGroups: [TabGroup]?
        let pinnedGroups: [TabGroup]?
        let shortcuts: [SavedTab]?
        let order: [UUID]?
        let runtimeRevision: UInt64
        let split: [UUID]?
    }
    let key: Key
    let entries: [SidebarEntry]
}

extension BrowserWindowState {
    var tabGroups: [TabGroup] {
        let pinned = profile.pinnedGroups ?? []
        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + (workspaces[selectedProfileID]?.groups ?? []).filter { !pinnedIDs.contains($0.id) }
    }
    var sidebarEntries: [SidebarEntry] {
        guard application.profiles.contains(where: { $0.id == selectedProfileID }) else {
            sidebarEntryCache = nil
            return []
        }
        let current = profile
        let workspace = workspaces[selectedProfileID]
        let key = SidebarEntryCache.Key(
            profileID: selectedProfileID, tabs: current.tabs, localGroups: workspace?.groups,
            pinnedGroups: current.pinnedGroups, shortcuts: current.pinShortcuts, order: workspace?.sidebarOrder,
            runtimeRevision: runtime.tabsRevision,
            split: browserSplit.map { [$0.left, $0.right] })
        if let sidebarEntryCache, sidebarEntryCache.key == key { return sidebarEntryCache.entries }
        let openTabs = tabs
        let regular = openTabs.filter { !$0.pinned }
        let membersByGroup = openTabs.reduce(into: [UUID: [BrowserTab]]()) { result, tab in
            if let id = tab.groupID { result[id, default: []].append(tab) }
        }
        func entries(_ group: TabGroup) -> [SidebarEntry] {
            guard !group.collapsed else { return [.group(group)] }
            let open = membersByGroup[group.id] ?? []
            let members = group.isPinned ? groupTabs(group, openTabs: open) : open.filter { !$0.pinned }
            return [.group(group)] + members.map(SidebarEntry.tab)
        }
        let groups = tabGroups
        let groupIDs = Set(groups.map(\.id))
        let loose = regular.filter { tab in tab.groupID.map { !groupIDs.contains($0) } ?? true }
        let local = groups.filter { !$0.isPinned }
        let available = local.map(\.id) + loose.map(\.id)
        let availableIDs = Set(available)
        let order = (workspaces[selectedProfileID]?.sidebarOrder ?? []).filter { availableIDs.contains($0) }
        let orderedIDs = Set(order)
        let groupsByID = local.reduce(into: [UUID: TabGroup]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        let looseByID = loose.reduce(into: [UUID: BrowserTab]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        let result =
            rowPinnedTabs.map(SidebarEntry.tab) + groups.filter(\.isPinned).flatMap(entries) + [.newTab]
            + (order + available.filter { !orderedIDs.contains($0) }).flatMap { id in
                if let group = groupsByID[id] { return entries(group) }
                return looseByID[id].map { [SidebarEntry.tab($0)] } ?? []
            }
        let visible = result.filter { browserSplit?.right != $0.id }
        sidebarEntryCache = SidebarEntryCache(key: key, entries: visible)
        return visible
    }
    func groupTabs(_ group: TabGroup) -> [BrowserTab] {
        guard application.profiles.contains(where: { $0.id == selectedProfileID }) else { return [] }
        return groupTabs(group, openTabs: tabs)
    }
    private func groupTabs(_ group: TabGroup, openTabs: [BrowserTab]) -> [BrowserTab] {
        guard let saved = group.savedTabs else { return openTabs.filter { !$0.pinned && $0.groupID == group.id } }
        let openByMember = openTabs.reduce(into: [UUID: BrowserTab]()) { result, tab in
            if tab.groupID == group.id, let id = tab.groupMemberID, result[id] == nil { result[id] = tab }
        }
        let privateMode = profile.privateMode
        return saved.map { member in
            if let open = openByMember[member.id] { return open }
            if let preview = groupPreviews[member.id], preview.profileID == selectedProfileID, !preview.isDisposed {
                if preview.title != member.title || preview.customTitle != member.customTitle
                    || preview.url?.absoluteString != member.address
                {
                    refreshShortcutPreviewsLater()
                }
                return preview
            }
            var copy = member
            copy.id = UUID()
            copy.groupID = group.id
            copy.groupMemberID = member.id
            let preview = BrowserTab(saved: copy, profileID: selectedProfileID, store: self)
            preview.favicon = copy.address.flatMap(URL.init(string:)).flatMap {
                application.favicons.cachedImage(for: $0, privateID: privateMode ? selectedProfileID : nil)
            }
            groupPreviews[member.id] = preview
            return preview
        }
    }
    func isPersistentTab(_ tab: BrowserTab) -> Bool {
        tab.pinned || profileFor(tab.profileID).pinnedGroups?.contains { $0.id == tab.groupID } == true
    }
    func updateGroup(_ id: UUID, profileID: UUID? = nil, _ change: (inout TabGroup) -> Void) {
        let profileID = profileID ?? selectedProfileID
        if var group = profileFor(profileID).pinnedGroups?.first(where: { $0.id == id }) {
            let previous = group
            change(&group)
            guard group != previous else { return }
            application.updateProfile(profileID) { profile in
                if let index = profile.pinnedGroups?.firstIndex(where: { $0.id == id }) {
                    profile.pinnedGroups?[index] = group
                }
            }
            persistSoon()
            return
        }
        guard var workspace = workspaces[profileID], let index = workspace.groups?.firstIndex(where: { $0.id == id })
        else { return }
        var group = workspace.groups![index]
        change(&group)
        guard group != workspace.groups![index] else { return }
        workspace.groups?[index] = group
        workspaces[profileID] = workspace
        objectWillChange.send()
        persistSoon()
    }
    @discardableResult func createTabGroup(with tab: BrowserTab? = nil) -> UUID {
        let group = TabGroup()
        guard var workspace = workspaces[selectedProfileID] else { return group.id }
        let order = sidebarEntries.compactMap { entry -> UUID? in
            switch entry {
            case .group(let group): return group.isPinned ? nil : group.id
            case .tab(let tab): return !tab.pinned && tab.groupID == nil ? tab.id : nil
            case .newTab: return nil
            }
        }
        workspace.groups = (workspace.groups ?? []) + [group]

        workspace.sidebarOrder = workspace.sidebarOrder ?? order
        workspace.sidebarOrder?.append(group.id)
        workspaces[selectedProfileID] = workspace
        if let tab { assignTab(tab, to: group.id) }
        objectWillChange.send()
        persistSoon()
        return group.id
    }
    func assignTab(_ tab: BrowserTab, to groupID: UUID?) {
        guard tab.store === self, tab.profileID == selectedProfileID, !tab.pinned, tabs.contains(where: { $0 === tab }),
            groupID == nil || tabGroups.contains(where: { $0.id == groupID })
        else { return }
        let moving = tab.groupID != groupID
        if moving, browserSplit?.contains(tab.id) == true { endSplit() }
        let lastMember = groupID.flatMap { id in regularTabs.last { $0.groupID == id && $0 !== tab } }
        if moving { detachGroupMember(tab) }
        tab.groupID = groupID
        if let groupID, tabGroups.contains(where: { $0.id == groupID && $0.isPinned }), tab.groupMemberID == nil {
            tab.groupMemberID = UUID()
            tab.pinnedAddress = tab.url?.absoluteString
        }
        tabChanged(tab)
        if let groupID {
            updateGroup(groupID) { $0.collapsed = false }
            if moving, tabGroups.contains(where: { $0.id == groupID && !$0.isPinned }), let lastMember {
                moveTab(tab.id, relativeTo: lastMember.id, after: true)
            }
        }
    }
    func insertTab(_ tab: BrowserTab, in groupID: UUID, relativeTo target: BrowserTab?, after: Bool) {
        guard let group = tabGroups.first(where: { $0.id == groupID }), target == nil || target?.groupID == groupID
        else { return }
        assignTab(tab, to: groupID)
        if group.isPinned, let member = tab.groupMemberID, let destination = target?.groupMemberID,
            member != destination
        {
            updateGroup(groupID) { group in
                guard var pages = group.savedTabs, let from = pages.firstIndex(where: { $0.id == member }) else {
                    return
                }
                let page = pages.remove(at: from)
                guard let index = pages.firstIndex(where: { $0.id == destination }) else { return }
                pages.insert(page, at: index + (after ? 1 : 0))
                group.savedTabs = pages
            }
        } else if let target, target !== tab {
            moveTab(tab.id, relativeTo: target.id, after: after)
        }
        persistSoon()
    }
    func syncGroupMember(for tab: BrowserTab) {
        guard let groupID = tab.groupID, let memberID = tab.groupMemberID,
            workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) == true,
            var group = profileFor(tab.profileID).pinnedGroups?.first(where: { $0.id == groupID })
        else { return }
        if tab.pinnedAddress == nil, let old = group.savedTabs?.first(where: { $0.id == memberID }) {
            tab.pinnedAddress = old.pinnedAddress ?? old.address
        }
        var saved = tab.saved
        saved.id = memberID
        saved.groupMemberID = nil
        let previous = group.savedTabs
        if let index = group.savedTabs?.firstIndex(where: { $0.id == memberID }) {
            group.savedTabs?[index] = saved
        } else {
            group.savedTabs = (group.savedTabs ?? []) + [saved]
        }
        guard group.savedTabs != previous else { return }
        application.updateProfile(tab.profileID) { profile in
            if let index = profile.pinnedGroups?.firstIndex(where: { $0.id == groupID }) {
                profile.pinnedGroups?[index] = group
            }
        }
        persistSoon()
    }
    func detachGroupMember(_ tab: BrowserTab) {
        guard let groupID = tab.groupID, let memberID = tab.groupMemberID else { return }
        updateGroup(groupID, profileID: tab.profileID) { $0.savedTabs?.removeAll { $0.id == memberID } }
        for window in application.windows {
            window.groupPreviews.removeValue(forKey: memberID)?.dispose()
            for other in window.runtime(for: tab.profileID).tabs.values
            where other.windowID == window.id && other.groupMemberID == memberID {
                other.groupMemberID = nil
                other.groupID = nil
                if !other.pinned { other.pinnedAddress = nil }
                window.tabChanged(other)
            }
        }
        tab.groupMemberID = nil
        tab.groupID = nil
        if !tab.pinned { tab.pinnedAddress = nil }
    }
    @discardableResult func openGroupMember(_ preview: BrowserTab) -> BrowserTab {
        guard !tabs.contains(where: { $0 === preview }), preview.profileID == selectedProfileID,
            let memberID = preview.groupMemberID, let group = tabGroups.first(where: { $0.id == preview.groupID }),
            let member = group.savedTabs?.first(where: { $0.id == memberID })
        else { return preview }
        if let existing = tabs.first(where: { $0.groupID == group.id && $0.groupMemberID == memberID }) {
            return existing
        }
        var copy = member
        copy.id = UUID()
        copy.groupID = group.id
        copy.groupMemberID = memberID
        updateProfile(selectedProfileID) { $0.tabs.append(copy) }
        return attach(copy, profileID: selectedProfileID)
    }
    func toggleGroupPin(_ id: UUID) {
        guard var group = tabGroups.first(where: { $0.id == id }) else { return }
        if group.isPinned {
            application.updateProfile(selectedProfileID) { $0.pinnedGroups?.removeAll { $0.id == id } }
            for window in application.windows {
                if window.workspaces[selectedProfileID] != nil {
                    var workspace = window.workspaces[selectedProfileID]!
                    group.savedTabs = nil
                    if workspace.groups?.contains(where: { $0.id == id }) != true {
                        workspace.groups = (workspace.groups ?? []) + [group]
                    }
                    window.workspaces[selectedProfileID] = workspace
                }
                for tab in window.runtime(for: selectedProfileID).tabs.values
                where tab.windowID == window.id && tab.groupID == id {
                    tab.groupMemberID = nil
                    tab.pinnedAddress = nil
                    window.tabChanged(tab)
                }
                for (key, preview) in window.groupPreviews where preview.groupID == id {
                    preview.dispose()
                    window.groupPreviews.removeValue(forKey: key)
                }
                window.objectWillChange.send()
            }
        } else {
            let members = regularTabs.filter { $0.groupID == id }
            group.savedTabs = members.map { tab in
                let memberID = UUID()
                tab.groupMemberID = memberID
                tab.pinnedAddress = tab.url?.absoluteString
                var saved = tab.saved
                saved.id = memberID
                saved.groupMemberID = nil
                return saved
            }
            workspaces[selectedProfileID]?.groups?.removeAll { $0.id == id }
            application.updateProfile(selectedProfileID) { $0.pinnedGroups = ($0.pinnedGroups ?? []) + [group] }
            for tab in members { tabChanged(tab) }
        }
        objectWillChange.send()
        persistSoon()
    }
    func removePersistentTab(_ tab: BrowserTab) {
        guard !tab.isDisposed, tab.store === self, tab.profileID == selectedProfileID else { return }
        if tab.pinned {
            removePin(tab)
            tabChanged(tab)
        } else {
            detachGroupMember(tab)
            tabChanged(tab)
        }
    }
    func closeTabGroup(_ id: UUID) { for tab in tabs.filter({ $0.groupID == id }) { close(tab) } }
    @discardableResult func closeTabGroupFromPointer(
        _ id: UUID, profileID: UUID, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {

        guard profileID == selectedProfileID, tabGroups.contains(where: { $0.id == id })
        else { return false }
        closeTabGroup(id)
        removeTabGroup(id)
        return true
    }
    func removeTabGroup(_ groupID: UUID) {
        if tabGroups.first(where: { $0.id == groupID })?.isPinned == true { toggleGroupPin(groupID) }
        for tab in regularTabs where tab.groupID == groupID {
            tab.groupID = nil
            tab.groupMemberID = nil
            tabChanged(tab)
        }
        guard var workspace = workspaces[selectedProfileID] else { return }
        workspace.groups?.removeAll { $0.id == groupID }
        workspace.sidebarOrder?.removeAll { $0 == groupID }
        workspaces[selectedProfileID] = workspace
        objectWillChange.send()
        persistSoon()
    }
    func moveTabOutsideGroup(_ preview: BrowserTab, relativeTo target: UUID, after: Bool) {
        let tab = preview.groupMemberID != nil ? openGroupMember(preview) : preview
        if tab.pinned { removePin(tab) }
        assignTab(tab, to: nil)
        var order = sidebarEntries.compactMap { entry -> UUID? in
            switch entry {
            case .group(let group): return group.isPinned ? nil : group.id
            case .tab(let item): return !item.pinned && item.groupID == nil ? item.id : nil
            case .newTab: return nil
            }
        }
        order.removeAll { $0 == tab.id }
        if let index = order.firstIndex(of: target) {
            order.insert(tab.id, at: index + (after ? 1 : 0))
        } else {
            order.insert(tab.id, at: 0)
        }
        workspaces[selectedProfileID]?.sidebarOrder = order
        objectWillChange.send()
        persistSoon()
    }
    func moveTabGroup(_ id: UUID, relativeTo target: UUID, after: Bool) {
        guard id != target, let group = tabGroups.first(where: { $0.id == id }) else { return }
        if group.isPinned {
            guard tabGroups.contains(where: { $0.id == target && $0.isPinned }) else { return }
            application.updateProfile(selectedProfileID) { profile in
                guard var groups = profile.pinnedGroups, let index = groups.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let moved = groups.remove(at: index)
                guard let destination = groups.firstIndex(where: { $0.id == target }) else { return }
                groups.insert(moved, at: destination + (after ? 1 : 0))
                profile.pinnedGroups = groups
            }
        } else {
            var order = sidebarEntries.compactMap { entry -> UUID? in
                switch entry {
                case .group(let group): return group.isPinned ? nil : group.id
                case .tab(let tab): return !tab.pinned && tab.groupID == nil ? tab.id : nil
                case .newTab: return nil
                }
            }
            guard let index = order.firstIndex(of: id), order.contains(target) else { return }
            order.remove(at: index)
            let destination = order.firstIndex(of: target)!
            order.insert(id, at: destination + (after ? 1 : 0))
            workspaces[selectedProfileID]?.sidebarOrder = order
        }
        objectWillChange.send()
        persistSoon()
    }
    func editTabGroup(_ id: UUID) {
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        editingGroupID = id
    }
    var sidebarSelectableTabs: [BrowserTab] {
        pinnedTabs
            + sidebarEntries.flatMap { entry -> [BrowserTab] in
                guard let tab = entry.tab else { return [] }
                if let split = browserSplit, split.left == tab.id,
                    let right = tabs.first(where: { $0.id == split.right })
                {
                    return [tab, right]
                }
                return [tab]
            }
    }
    func selectSidebarTab(_ tab: BrowserTab, modifiers: NSEvent.ModifierFlags = []) {
        guard !tab.isDisposed, tab.store === self, tab.profileID == selectedProfileID else { return }
        let visible = sidebarSelectableTabs
        if modifiers.contains(.shift), let anchor = sidebarSelectionAnchor ?? selectedTab?.id,
            let start = visible.firstIndex(where: { $0.id == anchor }),
            let end = visible.firstIndex(where: { $0.id == tab.id })
        {
            let range = Set(visible[min(start, end)...max(start, end)].map(\.id))
            selectedSidebarTabIDs = modifiers.contains(.command) ? selectedSidebarTabIDs.union(range) : range
        } else if modifiers.contains(.command) {
            if selectedSidebarTabIDs.isEmpty, let selectedTab { selectedSidebarTabIDs.insert(selectedTab.id) }
            if selectedSidebarTabIDs.contains(tab.id) {
                selectedSidebarTabIDs.remove(tab.id)
            } else {
                selectedSidebarTabIDs.insert(tab.id)
            }
            sidebarSelectionAnchor = tab.id
        } else {
            selectedSidebarTabIDs = []
            sidebarSelectionAnchor = tab.id
            select(tab)
        }
    }
    func groupingTabs(including tab: BrowserTab? = nil) -> [BrowserTab] {
        if let tab {
            guard tab.store === self, tab.profileID == selectedProfileID, !tab.isDisposed else { return [] }
            if !selectedSidebarTabIDs.contains(tab.id) { return [tab] }
        }
        var seen = Set<UUID>()
        return (sidebarSelectableTabs + tabs + Array(groupPreviews.values)).filter {
            $0.profileID == selectedProfileID && !$0.isDisposed && selectedSidebarTabIDs.contains($0.id)
                && seen.insert($0.id).inserted
        }
    }
    func moveSelectedTabs(including tab: BrowserTab, to groupID: UUID?) {
        guard tab.store === self, tab.profileID == selectedProfileID, !tab.isDisposed,
            groupID == nil || tabGroups.contains(where: { $0.id == groupID })
        else { return }
        let selected = groupingTabs(including: tab)
        for preview in selected where !preview.isDisposed {
            let open = preview.pinned ? openPinned(preview) : openGroupMember(preview)
            if open.pinned { removePin(open) }
            assignTab(open, to: groupID)
        }
        selectedSidebarTabIDs = []
    }
    func groupSelectedTabs(including tab: BrowserTab? = nil) {
        let selected = groupingTabs(including: tab)
        guard !selected.isEmpty else { return }
        let id = createTabGroup()
        for preview in selected where !preview.isDisposed {
            let open = preview.pinned ? openPinned(preview) : openGroupMember(preview)
            if open.pinned { removePin(open) }
            assignTab(open, to: id)
        }
        selectedSidebarTabIDs = []
        editingGroupID = id
    }
}

struct TabGroupRow: View {
    let group: TabGroup
    @ObservedObject var store: BrowserStore
    @State private var hoveredIcon = false
    @State private var hovered = false
    @State private var styling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var editing: Bool { store.editingGroupID == group.id }
    private var tint: Color { store.profile.privateMode ? PrivateChrome.accent : profileTint(group.color) }
    var body: some View {
        let profileID = store.selectedProfileID
        return HStack(spacing: 4) {
            Button {
                store.tabHover.dismiss()
                styling = true
            } label: {
                EmojiIcon(glyph: group.icon, size: 17).foregroundStyle(.primary)
                    .opacity(hoveredIcon ? 0 : 1)
                    .overlay {
                        GolzheimIcon(icon: .more, size: 15, weight: 220).foregroundStyle(.primary).opacity(
                            hoveredIcon ? 1 : 0)
                    }
                    .frame(width: 24, height: 28).contentShape(Rectangle())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredIcon)
            }.buttonStyle(.plain).onHover { hoveredIcon = $0 }.help("group icon and color")
                .popover(isPresented: $styling) { TabGroupStylePicker(group: group, store: store) }
            Group {
                if editing {
                    InlineGroupNameField(group: group, store: store)
                } else {
                    Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                        .overlay { GroupDragArea(group: group, store: store) }
                }
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            HStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        store.updateGroup(group.id) { $0.collapsed.toggle() }
                    }
                } label: {
                    GolzheimIcon(icon: .disclosureDown, size: 17, weight: 220).rotationEffect(
                        .degrees(group.collapsed ? -90 : 0)
                    ).frame(width: 20, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(group.collapsed ? "expand group" : "collapse group")
                Button {
                    store.closeTabGroupFromPointer(group.id, profileID: profileID)
                } label: {
                    GolzheimIcon(icon: .close, size: 16, weight: 180).foregroundStyle(.secondary).frame(
                        width: 22, height: 24)
                }.buttonStyle(PlayerActionStyle(outline: false)).opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered).accessibilityHidden(
                        !hovered
                    ).help("delete folder").accessibilityLabel("delete folder")
            }.fixedSize()
        }.padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle())
            .background(
                Color.primary.opacity(store.draggedGroupTargetID == group.id ? 0.14 : hovered ? 0.06 : 0.025),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .opacity(store.draggedFolderID == group.id ? 0.5 : 1).onHover { hovered = $0 }
            .background(TabHoverAnchor(group: group, store: store))
            .accessibilityElement(children: .contain).accessibilityLabel(group.name)
            .contextMenu {
                Button("rename group") { store.editTabGroup(group.id) }
                Button("icon and color…") { styling = true }
                Button(group.isPinned ? "unpin group" : "pin group") { store.toggleGroupPin(group.id) }
                Button("new tab in group") {
                    let tab = store.newTab()
                    store.assignTab(tab, to: group.id)
                }
                Divider()
                Button("close group pages") { store.closeTabGroup(group.id) }
                Button("ungroup tabs") { store.removeTabGroup(group.id) }
            }
    }
}

private struct TabGroupStylePicker: View {
    let group: TabGroup
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(0..<6) { index in
                    Button {
                        store.updateGroup(group.id) { $0.color = index }
                    } label: {
                        Circle().fill(store.profile.privateMode ? PrivateChrome.accent : profileTint(index)).frame(
                            width: 22, height: 22
                        ).overlay(
                            Circle().strokeBorder(Color.primary.opacity(group.color == index ? 0.7 : 0), lineWidth: 2)
                                .padding(3))
                    }.buttonStyle(.plain).accessibilityLabel(
                        ["lime", "amber", "blue", "rose", "mint", "violet"][index])
                }
            }
            GolzheimPicker(
                selection: Binding(
                    get: { store.tabGroups.first(where: { $0.id == group.id })?.icon ?? group.icon },
                    set: { value in store.updateGroup(group.id) { $0.icon = value } }))
        }.padding(14).frame(width: 280).preferredColorScheme(store.profile.privateMode ? .dark : nil)
    }
}

private struct InlineGroupNameField: NSViewRepresentable {
    let group: TabGroup
    let store: BrowserStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store, id: group.id) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "group name"
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = group.name == "untitled group" ? "" : group.name
        let profileID = context.coordinator.profileID
        field.delegate = context.coordinator
        field.editingAllowed = { [weak store] in
            store?.editingGroupID == group.id && store?.selectedProfileID == profileID
        }
        field.setAccessibilityLabel("group name")
        return field
    }
    func updateNSView(_ field: Field, context: Context) {}
    final class Field: NSTextField {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
        var editingAllowed: (() -> Bool)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editingAllowed?() == true, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var store: BrowserStore?
        let id: UUID
        let profileID: UUID
        init(store: BrowserStore, id: UUID) {
            self.store = store
            self.id = id
            profileID = store.selectedProfileID
        }
        func commit(_ field: NSTextField) {
            guard let store, store.editingGroupID == id, store.selectedProfileID == profileID,
                store.application.windows.contains(where: { $0 === store })
            else { return }
            let name = String(
                field.stringValue.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).prefix(200))
            let profileID = store.selectedProfileID

            DispatchQueue.main.async { [weak store] in
                guard let store, store.selectedProfileID == profileID, store.editingGroupID == self.id else { return }
                store.updateGroup(self.id, profileID: profileID) { $0.name = name.isEmpty ? "untitled group" : name }
                store.editingGroupID = nil
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { commit(field) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let store, store.editingGroupID == id, store.selectedProfileID == profileID,
                let field = control as? NSTextField, field.currentEditor() === textView
            else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                store.editingGroupID = nil
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let field = control as? NSTextField {
                field.stringValue = textView.string
                commit(field)
                return true
            }
            return false
        }
    }
}

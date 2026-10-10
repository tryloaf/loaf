import AppKit
import Combine
import WebKit

extension BrowserWindowState {

    var gridPinnedTabs: [BrowserTab] { pinnedTabs.filter { $0.pinPresentation != "row" } }
    var rowPinnedTabs: [BrowserTab] { pinnedTabs.filter { $0.pinPresentation == "row" } }
    var pinnedTabs: [BrowserTab] {
        guard application.profiles.contains(where: { $0.id == selectedProfileID }) else { return [] }
        let current = profile
        guard let shortcuts = current.pinShortcuts, !shortcuts.isEmpty else { return [] }
        let selected = selectedTab
        let openByShortcut = tabs.reduce(into: [UUID: BrowserTab]()) { result, tab in
            if let id = tab.pinnedShortcutID, result[id] == nil { result[id] = tab }
        }
        return shortcuts.map { pin in
            if let selected, selected.pinnedShortcutID == pin.id { return selected }
            if let open = openByShortcut[pin.id] { return open }
            if let preview = pinPreviews[pin.id], preview.profileID == selectedProfileID, !preview.isDisposed {
                if preview.title != pin.title || preview.pinnedTitle != pin.pinnedTitle
                    || preview.pinnedIcon != pin.pinnedIcon
                    || preview.pinPresentation != pin.pinPresentation
                    || preview.pinnedAddress != (pin.pinnedAddress ?? pin.address)
                    || preview.url?.absoluteString != pin.address
                {
                    refreshShortcutPreviewsLater()
                }
                return preview
            }
            var saved = pin
            saved.id = UUID()
            saved.pinnedShortcutID = pin.id
            let preview = BrowserTab(saved: saved, profileID: selectedProfileID, store: self)
            preview.favicon = saved.address.flatMap(URL.init(string:)).flatMap {
                application.favicons.cachedImage(for: $0, privateID: current.privateMode ? selectedProfileID : nil)
            }
            pinPreviews[pin.id] = preview
            return preview
        }
    }
    func refreshShortcutPreviewsLater() {
        guard !previewRefreshPending else { return }
        previewRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewRefreshPending = false

            for pin in self.profile.pinShortcuts ?? [] {
                guard let preview = self.pinPreviews[pin.id], !preview.isDisposed else { continue }
                if preview.title != pin.title { preview.title = pin.title }
                if preview.pinnedTitle != pin.pinnedTitle { preview.pinnedTitle = pin.pinnedTitle }
                if preview.pinnedIcon != pin.pinnedIcon { preview.pinnedIcon = pin.pinnedIcon }
                if preview.pinPresentation != pin.pinPresentation { preview.pinPresentation = pin.pinPresentation }
                preview.pinnedAddress = pin.pinnedAddress ?? pin.address
                let url = pin.address.flatMap(URL.init(string:))
                if preview.url != url { preview.url = url }
            }
            for group in self.profile.pinnedGroups ?? [] {
                for member in group.savedTabs ?? [] {
                    guard let preview = self.groupPreviews[member.id], !preview.isDisposed else { continue }
                    if preview.title != member.title { preview.title = member.title }
                    if preview.customTitle != member.customTitle { preview.customTitle = member.customTitle }
                    preview.pinnedAddress = member.pinnedAddress ?? member.address
                    let url = member.address.flatMap(URL.init(string:))
                    if preview.url != url { preview.url = url }
                }
            }
        }
    }
    func ensurePinShortcut(for tab: BrowserTab) {
        guard tab.pinned else { return }
        if let id = tab.pinnedShortcutID,
            let pin = profileFor(tab.profileID).pinShortcuts?.first(where: { $0.id == id })
        {

            tab.pinnedAddress = pin.pinnedAddress ?? pin.address ?? tab.pinnedAddress ?? tab.saved.address
            return
        }
        let id = UUID()
        tab.pinnedShortcutID = id
        tab.groupID = nil
        if tab.pinnedAddress == nil, tab.url?.user == nil { tab.pinnedAddress = tab.url?.absoluteString }
        var shortcut = tab.saved
        shortcut.id = id
        shortcut.pinnedShortcutID = nil
        shortcut.address = shortcut.pinnedAddress ?? shortcut.address
        shortcut.groupID = nil
        updateProfile(tab.profileID) { profile in
            profile.pinShortcuts = (profile.pinShortcuts ?? []) + [shortcut]
            if let index = profile.tabs.firstIndex(where: { $0.id == tab.id }) { profile.tabs[index] = tab.saved }
        }
    }
    func syncPinShortcut(for tab: BrowserTab) {
        guard tab.pinned, let id = tab.pinnedShortcutID else { return }
        guard var pin = profileFor(tab.profileID).pinShortcuts?.first(where: { $0.id == id }) else { return }
        if tab.pinnedAddress == nil { tab.pinnedAddress = pin.pinnedAddress ?? pin.address }
        let saved = tab.saved
        let previous = pin
        pin.pinnedTitle = saved.pinnedTitle
        pin.pinnedIcon = saved.pinnedIcon
        pin.pinPresentation = saved.pinPresentation
        pin.pinnedAddress = saved.pinnedAddress
        if let home = saved.pinnedAddress { pin.address = home }
        if tab.url?.absoluteString == pin.address { pin.title = tab.title }
        guard pin != previous else { return }
        updateProfile(tab.profileID) { profile in
            if let index = profile.pinShortcuts?.firstIndex(where: { $0.id == id }) {
                profile.pinShortcuts?[index] = pin
            }
        }
        for window in application.windows {
            for other in window.runtime(for: tab.profileID).tabs.values
            where other.windowID == window.id && other.profileID == tab.profileID && other.pinnedShortcutID == id
                && other !== tab
            {
                other.pinnedTitle = pin.pinnedTitle
                other.pinnedIcon = pin.pinnedIcon
                other.pinPresentation = pin.pinPresentation
                other.pinnedAddress = pin.pinnedAddress
                if var workspace = window.workspaces[tab.profileID],
                    let index = workspace.tabs.firstIndex(where: { $0.id == other.id })
                {
                    workspace.tabs[index] = other.saved
                    window.workspaces[tab.profileID] = workspace
                }
            }
        }
    }
    @discardableResult func openPinned(_ preview: BrowserTab) -> BrowserTab {
        guard workspaces[preview.profileID]?.tabs.contains(where: { $0.id == preview.id }) != true,
            let pinID = preview.pinnedShortcutID,
            let pin = profileFor(preview.profileID).pinShortcuts?.first(where: { $0.id == pinID })
        else { return preview }
        var saved = pin
        saved.id = UUID()
        saved.pinnedShortcutID = pinID
        updateProfile(preview.profileID) { $0.tabs.append(saved) }
        return attach(saved, profileID: preview.profileID)
    }
    func removePin(_ tab: BrowserTab) {
        guard let id = tab.pinnedShortcutID else {
            tab.pinned = false
            return
        }
        updateProfile(tab.profileID) { $0.pinShortcuts?.removeAll { $0.id == id } }
        for window in application.windows {
            window.tabHover.dismiss()
            for other in window.runtime(for: tab.profileID).tabs.values
            where other.windowID == window.id && other.profileID == tab.profileID && other.pinnedShortcutID == id {
                other.pinned = false
                other.pinnedShortcutID = nil
                window.tabChanged(other)
                window.runtime(for: tab.profileID).extensions.controller.didChangeTabProperties(.pinned, for: other)
            }
            if window.pinPreviews[id]?.profileID == tab.profileID {
                window.pinPreviews.removeValue(forKey: id)?.dispose()
            }
        }
        tab.pinned = false
        tab.pinnedShortcutID = nil
    }
    func setPinPresentation(_ preview: BrowserTab, row: Bool) {
        let tab = preview.pinned ? openPinned(preview) : openGroupMember(preview)
        if !tab.pinned { togglePin(tab) }
        tab.pinPresentation = row ? "row" : nil
        tabChanged(tab)
        sidebarEntryCache = nil
        objectWillChange.send()
    }
    func returnToPin(_ tab: BrowserTab) {
        let open = tab.pinned ? openPinned(tab) : openGroupMember(tab)
        select(open)
        let profile = profileFor(tab.profileID)
        let shortcut = profile.pinShortcuts?.first { $0.id == open.pinnedShortcutID }
        let origin =
            open.pinnedAddress ?? shortcut?.pinnedAddress ?? shortcut?.address
            ?? profile.pinnedGroups?.first(where: { $0.id == tab.groupID })?.savedTabs?.first(where: {
                $0.id == tab.groupMemberID
            })?.address
        if let address = origin, let url = URL(string: address) { open.load(url) }
    }
    func movePin(_ source: BrowserTab, before target: BrowserTab, after: Bool = false) {
        guard source.profileID == selectedProfileID, target.profileID == selectedProfileID,
            let sourceID = source.pinnedShortcutID, let targetID = target.pinnedShortcutID, sourceID != targetID
        else { return }
        updateCurrent { profile in
            guard var pins = profile.pinShortcuts, let from = pins.firstIndex(where: { $0.id == sourceID }) else {
                return
            }
            let pin = pins.remove(at: from)
            guard let to = pins.firstIndex(where: { $0.id == targetID }) else { return }
            pins.insert(pin, at: to + (after ? 1 : 0))
            profile.pinShortcuts = pins
        }
    }
}

nonisolated enum LinkOpenDestination: Equatable {
    case backgroundTab, foregroundTab, window
    static func from(_ modifiers: NSEvent.ModifierFlags) -> Self? {
        guard modifiers.contains(.command), !modifiers.contains(.control) else { return nil }
        if modifiers.contains(.option) { return .window }
        return modifiers.contains(.shift) ? .foregroundTab : .backgroundTab
    }
}
extension BrowserWindowState {
    @discardableResult func openLink(
        _ url: URL, destination: LinkOpenDestination, profileID: UUID, source: BrowserTab? = nil
    ) -> BrowserTab? {
        guard profiles.contains(where: { $0.id == profileID }),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        if destination == .window, let coordinator = application.coordinator {
            return coordinator.newWindow(profileID: profileID, url: url).selectedTab
        }
        let tab = newTab(url: url, profileID: profileID, showOmnibar: false, activate: destination != .backgroundTab)
        if let source { joinBrowsingTrail(tab, source: source) }
        return tab
    }
}

extension BrowserWindowState {
    func joinBrowsingTrail(_ tab: BrowserTab, source: BrowserTab) {
        guard preferences.linkTabGroups == true, tab.profileID == selectedProfileID,
            source.profileID == tab.profileID, source.store === self
        else { return }
        let groupID = source.groupID ?? createTabGroup(with: source)
        if source.groupID == nil { source.groupID = groupID }
        updateGroup(groupID) { if $0.name == "untitled group" { $0.name = source.url?.host ?? "browsing trail" } }
        tab.groupID = groupID
        tabChanged(tab)
        persistSoon()
    }
}

import AppKit

enum SiteShortcutBridge {
    static let script = #"""
        (() => {
          if (globalThis.__loafShortcuts) return; globalThis.__loafShortcuts = true;
          window.addEventListener('keydown', event => {
            const key = event.key.toLowerCase();
            if (!event.isTrusted || event.repeat || !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
                !['a','d','s','f','l','r'].includes(key)) return;
            setTimeout(() => {
              window.webkit.messageHandlers.loafShortcut.postMessage({key, claimed: event.defaultPrevented});
            }, 0);
          }, true);
        })();
        """#
}

extension LoafBrowserWindow {
    func performBrowserShortcut(_ key: String) {
        guard let store else { return }
        switch key {
        case "s": store.sidebarVisible.toggle()
        case "d": if let tab = store.selectedTab { store.editBookmark(tab: tab) }
        case "f":
            store.findVisible = true
            store.findFocusID = UUID()
        case "l": store.openOmnibar()
        case "r": store.selectedTab?.reload()
        default: break
        }
    }
    func resolveBrowserShortcut(_ key: String, event: NSEvent) {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        if key == "a" {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        } else {
            performBrowserShortcut(key)
        }
    }

    func siteClaimedShortcut(_ key: String, tabID: UUID, claimed: Bool = true) {
        guard let tab = store?.selectedTab, tab.id == tabID, ["s", "f", "l", "r", "a", "d"].contains(key),
            let index = pendingSiteShortcuts.firstIndex(where: { $0.key == key && $0.tabID == tabID })
        else { return }
        let pending = pendingSiteShortcuts.remove(at: index)
        guard tab.navigationID == pending.navigationID else { return }
        if !claimed {
            armedSiteShortcut = nil
            resolveBrowserShortcut(key, event: pending.event)
            return
        }
        guard ["s", "f", "l", "r"].contains(key) else {
            armedSiteShortcut = nil
            return
        }
        let armed = ArmedSiteShortcut(key: key, tabID: tabID, navigationID: tab.navigationID,
            time: ProcessInfo.processInfo.systemUptime)
        armedSiteShortcut = armed
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ArmedSiteShortcut.lifetime))
            if self?.armedSiteShortcut?.id == armed.id { self?.armedSiteShortcut = nil }
        }
        let action = [
            "s": store?.sidebarVisible == true ? "hide the sidebar" : "show the sidebar", "f": "search this page",
            "l": "open the wonderbar", "r": "reload this page",
        ][key]!
        store?.feedback.show(
            .info, icon: .info, text: "press ⌘\(key.uppercased()) again to \(action)", duration: .seconds(ArmedSiteShortcut.lifetime))
    }
}

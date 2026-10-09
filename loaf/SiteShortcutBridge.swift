import AppKit

enum SiteShortcutBridge {
    static let script = #"""
        (() => {
          if (globalThis.__loafShortcuts) return; globalThis.__loafShortcuts = true;
          window.addEventListener('keydown', event => {
            if (!event.isTrusted || event.repeat || !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
                !['s','f','l','r'].includes(event.key.toLowerCase())) return;
            const key = event.key.toLowerCase();
            setTimeout(() => {
              if (event.defaultPrevented) window.webkit.messageHandlers.loafShortcut.postMessage({key});
            }, 0);
          }, true);
        })();
        """#
}

extension LoafBrowserWindow {
    func siteClaimedShortcut(_ key: String, tabID: UUID) {
        guard store?.selectedTab?.id == tabID, isKeyWindow, ["s", "f", "l", "r"].contains(key) else { return }
        armedSiteShortcut = (key, tabID, ProcessInfo.processInfo.systemUptime)
        let action = ["s": "show sidebar", "f": "find on page", "l": "open wonderbar", "r": "reload page"][key]!
        store?.feedback.show(
            .info, icon: .info, text: "press ⌘ + \(key.uppercased()) again to \(action)", duration: .seconds(2))
    }
}

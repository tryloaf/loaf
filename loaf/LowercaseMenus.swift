import AppKit
import Combine
import ObjectiveC.runtime
import WebKit

@MainActor enum LowercaseMenus {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        for (selector, replacement) in [
            (NSSelectorFromString("_agent_setHighlighted:"), #selector(NSMenuItem.loaf_setAgentHighlighted(_:))),
            (
                NSSelectorFromString("_agent_setHighlighted:fencedWithWindow:"),
                #selector(NSMenuItem.loaf_setAgentHighlighted(_:fencedWithWindow:))
            ),
        ] {
            if let original = class_getInstanceMethod(NSMenuItem.self, selector),
                let guarded = class_getInstanceMethod(NSMenuItem.self, replacement)
            {
                method_exchangeImplementations(original, guarded)
            }
        }
        installed = true
        if let menu = NSApp.mainMenu { normalize(menu) }
    }

    static func normalize(_ menu: NSMenu) {}
    static func normalize(_ item: NSMenuItem) {}

}

extension NSMenuItem {
    @objc fileprivate func loaf_setAgentHighlighted(_ highlighted: Bool) {
        loaf_setAgentHighlighted(highlighted && isEnabled)
    }

    @objc fileprivate func loaf_setAgentHighlighted(_ highlighted: Bool, fencedWithWindow window: NSWindow?) {
        loaf_setAgentHighlighted(highlighted && isEnabled, fencedWithWindow: window)
    }
}

@MainActor final class LoafMainMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private enum Command: String {
        case about, updates, settings, newWindow, newTab, newPrivateWindow, closeTab, save, printPage
        case find, location, password, sidebar, reload, reloadFromOrigin, reader, zoomIn, zoomOut, actualSize
        case back, forward, history, reopenTab, reopenWindow, bookmark, favorites
        case nextTab, previousTab, pin, duplicate, downloads, previousProfile, nextProfile, editProfile, addProfile
        case inspector, inlineInspector, detachedInspector, source, report, help
    }
    private let coordinator: WindowCoordinator
    private var observations = Set<AnyCancellable>()
    private var editingMenu: NSMenu?
    private var refreshPending = false
    private let bookmarks = NSMenu(title: "Bookmarks")
    private let profiles = NSMenu(title: "Profiles")
    private let develop = NSMenu(title: "Develop")
    private let userAgents = NSMenu(title: "User Agent")
    private var store: BrowserStore? { coordinator.commandState }

    init(coordinator: WindowCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func install() {
        LowercaseMenus.install()
        NSApp.mainMenu?.removeAllItems()
        let main = NSMenu(title: "loaf")
        let app = appendMenu("loaf", to: main)
        add("About loaf", .about, to: app)
        add("Check for Updates…", .updates, to: app)
        app.addItem(.separator())
        add("Settings…", .settings, key: ",", to: app)
        app.addItem(.separator())
        let services = appendMenu("Services", to: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        system("Hide loaf", #selector(NSApplication.hide(_:)), key: "h", target: NSApp, to: app)
        system(
            "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", flags: [.command, .option],
            target: NSApp, to: app)
        system("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp, to: app)
        app.addItem(.separator())
        system("Quit loaf", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp, to: app)

        let file = appendMenu("File", to: main)
        add("New Window", .newWindow, key: "n", to: file)
        add("New Tab", .newTab, key: "t", to: file)
        add("New Private Window", .newPrivateWindow, key: "n", flags: [.command, .shift], to: file)
        file.addItem(.separator())
        add("Close Tab", .closeTab, key: "w", to: file)
        system("Close Window", #selector(NSWindow.performClose(_:)), key: "w", flags: [.command, .shift], to: file)
        add("Save As…", .save, key: "s", flags: [.command, .shift], to: file)
        add("Print…", .printPage, key: "p", to: file)

        let edit = appendMenu("Edit", to: main)
        editingMenu = edit
        system("Undo", NSSelectorFromString("undo:"), key: "z", to: edit)
        system("Redo", NSSelectorFromString("redo:"), key: "z", flags: [.command, .shift], to: edit)
        edit.addItem(.separator())
        system("Cut", #selector(NSText.cut(_:)), key: "x", to: edit)
        system("Copy", #selector(NSText.copy(_:)), key: "c", to: edit)
        system("Paste", #selector(NSText.paste(_:)), key: "v", to: edit)
        system(
            "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "v",
            flags: [.command, .option, .shift], to: edit)
        system("Delete", #selector(NSText.delete(_:)), to: edit)
        system("Select All", #selector(NSText.selectAll(_:)), key: "a", to: edit)
        edit.addItem(.separator())
        add("Find on Page", .find, key: "f", to: edit)
        add("Search or Enter URL", .location, key: "l", to: edit)
        add("Fill Saved Password", .password, key: "k", flags: [.command, .shift], to: edit)
        edit.addItem(.separator())
        let spelling = appendMenu("Spelling and Grammar", to: edit)
        for (title, action) in [
            ("Show Spelling and Grammar", "showGuessPanel:"), ("Check Document Now", "checkSpelling:"),
            ("Check Spelling While Typing", "toggleContinuousSpellChecking:"),
            ("Check Grammar With Spelling", "toggleGrammarChecking:"),
            ("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:"),
        ] {
            system(title, NSSelectorFromString(action), to: spelling)
        }
        let substitutions = appendMenu("Substitutions", to: edit)
        for (title, action) in [
            ("Smart Copy/Paste", "toggleSmartInsertDelete:"), ("Smart Quotes", "toggleAutomaticQuoteSubstitution:"),
            ("Smart Dashes", "toggleAutomaticDashSubstitution:"), ("Smart Links", "toggleAutomaticLinkDetection:"),
            ("Data Detectors", "toggleAutomaticDataDetection:"),
            ("Text Replacement", "toggleAutomaticTextReplacement:"),
        ] {
            system(title, NSSelectorFromString(action), to: substitutions)
        }
        let transformations = appendMenu("Transformations", to: edit)
        for (title, action) in [
            ("Make Upper Case", "uppercaseWord:"), ("Make Lower Case", "lowercaseWord:"),
            ("Capitalize", "capitalizeWord:"),
        ] {
            system(title, NSSelectorFromString(action), to: transformations)
        }
        let speech = appendMenu("Speech", to: edit)
        system("Start Speaking", NSSelectorFromString("startSpeaking:"), to: speech)
        system("Stop Speaking", NSSelectorFromString("stopSpeaking:"), to: speech)
        edit.addItem(.separator())
        system(
            "Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), key: " ",
            flags: [.control, .command], target: NSApp, to: edit)

        let view = appendMenu("View", to: main)
        add("Toggle Sidebar", .sidebar, key: "s", to: view)
        add("Reload", .reload, key: "r", to: view)
        add("Reload Without Cache", .reloadFromOrigin, key: "r", flags: [.command, .shift], to: view)
        add("Reading View", .reader, key: "r", flags: [.command, .option], to: view)
        view.addItem(.separator())
        add("Zoom In", .zoomIn, key: "+", to: view)
        add("Zoom Out", .zoomOut, key: "-", to: view)
        add("Actual Size", .actualSize, key: "0", to: view)
        view.addItem(.separator())
        system(
            "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", flags: [.command, .control],
            to: view)

        let history = appendMenu("History", to: main)
        add("Back", .back, key: "[", to: history)
        add("Forward", .forward, key: "]", to: history)
        add("Show History", .history, key: "y", to: history)
        add("Reopen Closed Tab", .reopenTab, key: "t", flags: [.command, .shift], to: history)
        add("Reopen Last Closed Window", .reopenWindow, key: "n", flags: [.command, .option, .shift], to: history)

        appendMenu("Bookmarks", submenu: bookmarks, to: main)
        bookmarks.delegate = self
        rebuildBookmarks()
        let tabs = appendMenu("Tab", to: main)
        add("Next Tab", .nextTab, key: "\t", flags: .control, to: tabs)
        add("Previous Tab", .previousTab, key: "\t", flags: [.control, .shift], to: tabs)
        add("Pin or Unpin Tab", .pin, to: tabs)
        add("Duplicate Tab", .duplicate, to: tabs)
        add("Downloads", .downloads, key: "j", flags: [.command, .shift], to: tabs)
        appendMenu("Profiles", submenu: profiles, to: main)
        profiles.delegate = self
        rebuildProfiles()
        configureDevelop()

        let window = appendMenu("Window", to: main)
        system("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
        system("Zoom", #selector(NSWindow.performZoom(_:)), to: window)
        window.addItem(.separator())
        system("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp, to: window)
        NSApp.windowsMenu = window
        let help = appendMenu("Help", to: main)
        add("Report a Bug…", .report, to: help)
        add("loaf Help", .help, to: help)
        NSApp.helpMenu = help
        LowercaseMenus.normalize(main)
        NSApp.mainMenu = main
        for publisher in [
            coordinator.application.objectWillChange.eraseToAnyPublisher(),
            coordinator.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.sink { [weak self] in self?.scheduleRefresh() }.store(in: &observations)
        }
        for name in [
            NSWindow.didBecomeKeyNotification, NSControl.textDidBeginEditingNotification,
            NSText.didBeginEditingNotification, NSApplication.didBecomeActiveNotification,
        ] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.editingMenu?.update()
                    self?.refreshCommands()
                }
            }.store(in: &observations)
        }
        syncDevelop()
        LowercaseMenus.normalize(main)
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.syncDevelop()
            self.refreshCommands()
        }
    }

    @discardableResult private func appendMenu(_ title: String, submenu: NSMenu? = nil, to parent: NSMenu) -> NSMenu {
        let menu = submenu ?? NSMenu(title: title.lowercased(with: Locale.current))
        menu.title = title.lowercased(with: Locale.current)
        menu.delegate = self
        let item = NSMenuItem(title: title.lowercased(with: Locale.current), action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult private func add(
        _ title: String, _ command: Command, key: String = "", flags: NSEvent.ModifierFlags = .command, to menu: NSMenu
    ) -> NSMenuItem {
        let equivalent = flags.contains(.shift) ? key.uppercased() : key
        let item = NSMenuItem(
            title: title.lowercased(with: Locale.current), action: #selector(run(_:)), keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = flags
        item.target = self
        item.representedObject = command.rawValue
        item.isEnabled = validateMenuItem(item)
        menu.addItem(item)
        return item
    }

    @discardableResult private func system(
        _ title: String, _ action: Selector, key: String = "", flags: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil, to menu: NSMenu
    ) -> NSMenuItem {
        let equivalent = flags.contains(.shift) ? key.uppercased() : key
        let item = NSMenuItem(title: title.lowercased(with: Locale.current), action: action, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = flags
        item.target = target
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === bookmarks { rebuildBookmarks() }
        if menu === profiles { rebuildProfiles() }
        if menu === userAgents { rebuildUserAgents() }
        refreshCommands(in: menu)
        LowercaseMenus.normalize(menu)
    }

    private func refreshCommands(in menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        for item in menu.items {
            if item.target === self {
                let enabled = validateMenuItem(item)
                if item.isEnabled != enabled { item.isEnabled = enabled }
            }
            if let submenu = item.submenu { refreshCommands(in: submenu) }
        }
    }

    private func rebuildBookmarks() {
        bookmarks.removeAllItems()
        add("Save Bookmark…", .bookmark, key: "d", to: bookmarks)
        add("Show Favorites", .favorites, key: "b", flags: [.command, .shift], to: bookmarks)
        if let store, !store.profile.favorites.isEmpty {
            bookmarks.addItem(.separator())
            for favorite in store.profile.favorites.prefix(12) {
                let item = system(favorite.title, #selector(openFavorite(_:)), target: self, to: bookmarks)
                item.representedObject = favorite.address
            }
        }
    }

    private func rebuildProfiles() {
        profiles.removeAllItems()
        add(
            "Previous Profile", .previousProfile, key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            flags: [.command, .option], to: profiles)
        add(
            "Next Profile", .nextProfile, key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            flags: [.command, .option], to: profiles)
        profiles.addItem(.separator())
        for (index, profile) in coordinator.application.profiles.enumerated() {
            let item = system(
                profile.name, #selector(switchProfile(_:)), key: index < 9 ? String(index + 1) : "",
                flags: [.command, .option], target: self, to: profiles)
            item.representedObject = profile.id
            item.state = store?.selectedProfileID == profile.id ? .on : .off
            let window = system(
                "New Window · " + profile.name, #selector(newProfileWindow(_:)), target: self, to: profiles)
            window.representedObject = profile.id
        }
        profiles.addItem(.separator())
        add("Edit Profile…", .editProfile, to: profiles)
        add("New Profile…", .addProfile, to: profiles)
    }

    private func configureDevelop() {
        add("Show Web Inspector", .inspector, key: "i", flags: [.command, .option], to: develop)
        add("Show Inspector Inline", .inlineInspector, to: develop)
        add("Show Inspector in Separate Window", .detachedInspector, to: develop)
        add("View Page Source", .source, key: "u", flags: [.command, .option], to: develop)
        appendMenu("User Agent", submenu: userAgents, to: develop)
        userAgents.delegate = self
        rebuildUserAgents()
    }

    private func syncDevelop() {
        guard let main = NSApp.mainMenu else { return }
        let existing = main.items.first { $0.submenu === develop }
        if coordinator.application.preferences.developerMenu == true {
            if existing == nil {
                let item = NSMenuItem(title: "develop", action: nil, keyEquivalent: "")
                item.submenu = develop
                let index = main.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? main.numberOfItems
                main.insertItem(item, at: index)
            }
        } else if let existing {
            main.removeItem(existing)
        }
    }

    private func rebuildUserAgents() {
        userAgents.removeAllItems()
        for mode in UserAgentMode.allCases {
            let item = system(mode.title, #selector(changeUserAgent(_:)), target: self, to: userAgents)
            item.representedObject = mode.rawValue
            item.state = store?.currentUserAgentMode == mode ? .on : .off
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openFavorite(_:)) || item.action == #selector(switchProfile(_:))
            || item.action == #selector(newProfileWindow(_:)) || item.action == #selector(changeUserAgent(_:))
        {
            return !coordinator.application.onboardingVisible
        }
        guard let raw = item.representedObject as? String, let command = Command(rawValue: raw) else { return true }
        switch command {
        case .about: return true
        case .updates: return SoftwareUpdateManager.shared.canCheckForUpdates
        default: break
        }
        guard !coordinator.application.onboardingVisible else { return false }
        switch command {
        case .save: return store?.selectedTab?.url != nil && store?.selectedTab?.loading == false
        case .bookmark, .duplicate: return store?.selectedTab?.url != nil
        case .back: return store?.selectedTab?.canGoBack == true
        case .forward: return store?.selectedTab?.canGoForward == true
        case .reopenWindow: return coordinator.canReopenClosedWindow
        case .previousProfile: return store != nil && store?.profiles.first?.id != store?.selectedProfileID
        case .nextProfile: return store != nil && store?.profiles.last?.id != store?.selectedProfileID
        case .addProfile: return coordinator.application.profiles.count < 8
        case .newWindow, .newTab, .newPrivateWindow, .location, .report, .help, .closeTab: return true
        default: return store != nil
        }
    }

    @objc private func openFavorite(_ item: NSMenuItem) {
        guard validateMenuItem(item), let address = item.representedObject as? String else { return }
        store?.navigate(address, inNewTab: true)
    }
    @objc private func switchProfile(_ item: NSMenuItem) {
        guard validateMenuItem(item), let id = item.representedObject as? UUID else { return }
        store?.switchProfile(id)
    }
    @objc private func newProfileWindow(_ item: NSMenuItem) {
        guard validateMenuItem(item), let id = item.representedObject as? UUID else { return }
        coordinator.newWindow(profileID: id)
    }
    @objc private func changeUserAgent(_ item: NSMenuItem) {
        guard validateMenuItem(item), let raw = item.representedObject as? String,
            let mode = UserAgentMode(rawValue: raw)
        else { return }
        if mode == .custom { store?.editCustomUserAgent() } else { store?.setUserAgent(mode) }
    }

    @objc private func run(_ item: NSMenuItem) {
        guard validateMenuItem(item), let raw = item.representedObject as? String, let command = Command(rawValue: raw)
        else { return }
        switch command {
        case .about: coordinator.showAbout()
        case .updates: SoftwareUpdateManager.shared.checkForUpdates()
        case .settings: if let store { coordinator.showSettings(for: store) }
        case .newWindow: coordinator.newWindow()
        case .newTab: _ = coordinator.activateBrowser()?.newTab()
        case .newPrivateWindow: coordinator.newPrivateWindow()
        case .closeTab: coordinator.closeKeyWindowTab()
        case .save: store?.selectedTab?.savePage()
        case .printPage: store?.selectedTab?.printPage()
        case .find:
            store?.findVisible = true
            store?.findFocusID = UUID()
        case .location: coordinator.activateBrowser()?.openOmnibar()
        case .password: if let tab = store?.selectedTab { PasswordVault.fill(tab: tab) }
        case .sidebar: store?.sidebarVisible.toggle()
        case .reload: store?.selectedTab?.reload()
        case .reloadFromOrigin: store?.selectedTab?.webView.reloadFromOrigin()
        case .reader: if let tab = store?.selectedTab { Task { await tab.toggleReader() } }
        case .zoomIn: if let tab = store?.selectedTab { store?.setPageZoom(tab.webView.pageZoom + 0.1) }
        case .zoomOut: if let tab = store?.selectedTab { store?.setPageZoom(tab.webView.pageZoom - 0.1) }
        case .actualSize: store?.resetPageZoom()
        case .back: store?.selectedTab?.webView.goBack()
        case .forward: store?.selectedTab?.webView.goForward()
        case .history: store?.showPage(.history)
        case .reopenTab: store?.reopenTab()
        case .reopenWindow: coordinator.reopenLastClosedWindow()
        case .bookmark: if let tab = store?.selectedTab { store?.editBookmark(tab: tab) }
        case .favorites: store?.showPage(.favorites)
        case .nextTab: store?.cycleTab(1)
        case .previousTab: store?.cycleTab(-1)
        case .pin: if let tab = store?.selectedTab { store?.togglePin(tab) }
        case .duplicate: if let url = store?.selectedTab?.url { _ = store?.newTab(url: url, showOmnibar: false) }
        case .downloads: store?.showPage(.downloads)
        case .previousProfile: store?.swipeProfile(-1)
        case .nextProfile: store?.swipeProfile(1)
        case .editProfile: store?.editingProfileID = store?.selectedProfileID
        case .addProfile:
            store?.addProfile(name: "untitled", emoji: "🌱")
            store?.editingProfileID = store?.selectedProfileID
        case .inspector: store?.selectedTab?.inspect()
        case .inlineInspector: store?.selectedTab?.inspect(mode: .inline)
        case .detachedInspector: store?.selectedTab?.inspect(mode: .detached)
        case .source: store?.selectedTab?.showSource()
        case .report: openHelp(BrowserBrand.reportBug)
        case .help: openHelp(BrowserBrand.website)
        }
    }
    private func openHelp(_ url: URL) {
        if let state = coordinator.activateBrowser() {
            _ = state.newTab(url: url, showOmnibar: false)
        } else {
            coordinator.newWindow(url: url)
        }
    }
}

import AppKit
import Combine
import LocalAuthentication
import SwiftUI
import WebKit

@MainActor final class BrowserWindowState: ObservableObject {
    let id: UUID
    let feedback = BrowserFeedback()
    let tabHover = TabHoverController()
    let sidebarMedia = SidebarMediaCollection()
    var previewRefreshPending = false
    var pinPreviews: [UUID: BrowserTab] = [:]
    var groupPreviews: [UUID: BrowserTab] = [:]
    var sidebarEntryCache: SidebarEntryCache?
    @Published var bookmarkDraft: BookmarkDraft?
    @Published var editingTabIconID: UUID?
    @Published var selectedSidebarTabIDs = Set<UUID>()
    var sidebarSelectionAnchor: UUID?
    @Published var editingGroupID: UUID?
    @Published var draggedFolderID: UUID?
    let sitePanel = SiteSettingsPanelController()
    lazy var tabSwitcher = TabSwitcher(store: self)
    private var retainedSuggestions: SuggestionEngine?
    var suggestionEngine: SuggestionEngine {
        if let retainedSuggestions { return retainedSuggestions }
        let engine = SuggestionEngine()
        retainedSuggestions = engine
        return engine
    }
    let application: BrowserApplication
    weak var nativeWindow: NSWindow? { didSet { syncWindowTitle() } }
    var workspaces: [UUID: WindowWorkspace]
    var restoredInteractionStates: [UUID: Any] = [:]
    var savedFrame: String?
    var isPopupWindow = false
    var profiles: [Profile] { application.profiles.map { profileFor($0.id) } }
    @Published var selectedProfileID = UUID() {
        didSet {
            editingTabIconID = nil
            bookmarkDraft = nil
            syncWindowTitle()
        }
    }
    var preferences: BrowserPreferences {
        get { application.preferences }
        set { application.preferences = newValue }
    }
    @Published var browserSplit: BrowserSplit?
    var splitOriginalMinimum: NSSize?
    @Published var omnibarFocusID = UUID()
    @Published var omnibarVisible = false
    @Published var omnibarCreatesTab = false
    @Published var omnibarQuery = ""
    var omnibarBufferedInput = false
    var omnibarOriginalURL: URL?
    var settingsVisible: Bool {
        get { false }
        set { if newValue { application.coordinator?.showSettings(for: self) } }
    }
    @Published var draggedTabID: UUID?
    @Published var hoveredSidebar = false
    @Published var profileDirection = 0
    @Published var profileResistance: CGFloat = 0
    weak var trayGestureAnchor: NSView?
    @Published var traySwipeDistance: CGFloat = 0
    @Published var extensionsVisible = false
    @Published var translationText: String?
    @Published var sourceText: String?
    @Published var editingProfileID: UUID?
    @Published var siteSettingsVisible = false
    var siteSettingsTrigger: SiteSettingsAnchor.Source?
    func toggleSiteSettings(from source: SiteSettingsAnchor.Source) {
        siteSettingsTrigger = source
        siteSettingsVisible.toggle()
    }
    @Published var chromeControlsCenterY: CGFloat = 16
    @Published var fullscreenControlsVisible = false
    @Published var isFullscreen = false
    @Published var sidebarVisible = true {
        didSet {
            guard sidebarVisible != oldValue else { return }
            hoveredSidebar = false
            sidebarTransitionGeneration += 1
            let generation = sidebarTransitionGeneration
            let visible = sidebarVisible
            let host = selectedTab?.existingWebView?.superview as? WebViewHost.HostView
            guard sidebarPresented != visible else {
                host?.cancelResizeSnapshot()
                return
            }
            sidebarRevealReadyAt = .infinity
            let present = { [weak self] in
                guard let self, self.sidebarTransitionGeneration == generation else { return }
                self.sidebarPresented = visible
                self.sidebarRevealReadyAt = ProcessInfo.processInfo.systemUptime + (visible ? 0 : 0.26)
            }
            if let host, preferences.resizeTransition != false {
                host.beginResizeSnapshot { DispatchQueue.main.async { present() } }
            } else {
                present()
            }
        }
    }
    @Published private(set) var sidebarPresented = true
    private var sidebarTransitionGeneration = 0
    var usesSidebarOnlyChrome: Bool { preferences.sidebarOnlyChrome != false }
    var compactToolbarHeight: CGFloat { !sidebarPresented && !usesSidebarOnlyChrome ? 32 : 0 }
    var pageEdgeInset: CGFloat {
        sidebarPresented || (usesSidebarOnlyChrome && preferences.insetCollapsedPage != false) ? 8 : 0
    }
    var pageLeadingInset: CGFloat { sidebarPresented ? preferences.sidebarWidth : pageEdgeInset }
    private(set) var sidebarRevealReadyAt = 0.0
    @discardableResult func revealSidebarFromEdge(
        at point: NSPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard !sidebarVisible, now >= sidebarRevealReadyAt, point.x >= 0, point.x < 8,
            let content = nativeWindow?.contentView, content.bounds.contains(point)
        else { return false }
        hoveredSidebar = true
        return true
    }
    func revealSidebarFromEdge() {
        guard let window = nativeWindow, window.isKeyWindow, let content = window.contentView else { return }
        let point = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        revealSidebarFromEdge(at: point)
    }
    var pageCornerRadius: CGFloat { pageEdgeInset > 0 ? 8 : isFullscreen ? 0 : 16 }
    @Published var findVisible = false
    @Published var findFocusID = UUID()
    @Published var error: String?
    @Published var pointerLockOffer: PointerLockOffer?
    func cancelPointerLock() {
        let offer = pointerLockOffer
        pointerLockOffer = nil
        offer?.finish(false)
    }
    @Published var passwordOffer: PasswordOffer?
    @Published var passwordFillOffer: PasswordFillOffer?
    private(set) var passwordFillGeneration = UUID()
    var passwordAuthentication: LAContext?
    func beginPasswordFillAuthentication() -> (generation: UUID, context: LAContext)? {

        guard passwordAuthentication == nil else { return nil }
        cancelPasswordFill()
        let context = LAContext()
        passwordAuthentication = context
        return (passwordFillGeneration, context)
    }
    func passwordFillApplicationDidResignActive() {

        guard passwordAuthentication == nil else { return }
        selectedTab?.approvedPasswordFill = nil
        cancelPasswordFill()
    }
    func cancelPasswordFill() {
        passwordFillGeneration = UUID()
        passwordAuthentication?.invalidate()
        passwordAuthentication = nil
        passwordFillOffer = nil
    }
    var ready: Bool { application.ready }
    var blocker: ContentBlocker { application.blocker }
    var downloads: DownloadManager { application.downloads }
    var weather: WeatherService { application.weather }
    var runtimes: [UUID: ProfileRuntime] { application.runtimes }
    private var adapters: [UUID: ExtensionWindow] = [:]
    private var restoredProfiles = Set<UUID>()
    private struct ClosedTab {
        var saved: SavedTab
        let interactionState: Any?
    }
    private var recentTabIDs: [UUID: [UUID]] = [:]
    private var closedTabs: [UUID: [ClosedTab]] = [:]
    private var tabObservers: [UUID: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var notificationPending = false

    func invalidateLater() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            self.syncWindowTitle()
            self.objectWillChange.send()
        }
    }
    @Published var draggedGroupTargetID: UUID?
    var directory: URL { application.directory }

    var profile: Profile { profileFor(selectedProfileID) }
    var runtime: ProfileRuntime { runtime(for: selectedProfileID) }
    var tabs: [BrowserTab] {
        guard let current = application.runtimes[selectedProfileID]?.tabs,
            let workspace = workspaces[selectedProfileID]
        else { return [] }
        return workspace.tabs.compactMap { current[$0.id] }
    }
    var regularTabs: [BrowserTab] { tabs.filter { !$0.pinned } }
    var sidebarTabs: [BrowserTab] { tabs.filter(\.pinned) + tabs.filter { !$0.pinned } }
    var selectedTab: BrowserTab? {
        guard let id = workspaces[selectedProfileID]?.selectedTab,
            let tab = application.runtimes[selectedProfileID]?.tabs[id], !tab.isDisposed
        else { return nil }
        return tab
    }
    func syncWindowTitle() {
        guard let window = nativeWindow else { return }

        let workspace = workspaces[selectedProfileID]
        let selected = workspace?.selectedTab
        let liveTitle = selected.flatMap { application.runtimes[selectedProfileID]?.tabs[$0]?.sidebarTitle }
        let savedTab = workspace?.tabs.first { $0.id == selected }
        let savedTitle = savedTab.map { tab in
            tab.pinned ? tab.pinnedTitle ?? tab.customTitle ?? tab.title : tab.customTitle ?? tab.title
        }
        let title = (liveTitle ?? savedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = title.isEmpty ? "loaf" : title + " — loaf"
        if window.title != value { window.title = value }
    }

    convenience init(directory: URL? = nil, prepareServices: Bool = true) {
        let application = BrowserApplication(directory: directory, prepareServices: prepareServices)
        let saved = application.initialWindows().first?.snapshot()
        self.init(application: application, saved: saved)

        application.windows = [self]
    }
    init(application: BrowserApplication, saved: SavedWindow? = nil, profileID: UUID? = nil) {
        self.application = application
        id = saved?.id ?? UUID()
        workspaces = saved?.workspaces ?? [:]
        savedFrame = saved?.frame
        selectedProfileID = profileID ?? saved?.selectedProfile ?? application.profiles[0].id
        if !application.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = application.profiles[0].id
        }
        sidebarVisible = saved?.sidebarVisible ?? true
        sidebarPresented = sidebarVisible
        application.objectWillChange.sink { [weak self] in self?.invalidateLater() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.passwordFillApplicationDidResignActive() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] event in
                guard let self, let window = event.object as? NSWindow, window !== self.nativeWindow,
                    window is LoafBrowserWindow || window is LoafSettingsWindow
                else { return }
                self.cancelPasswordFill()
            }.store(in: &cancellables)
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in self?.cancelPasswordFill() }.store(in: &cancellables)
        }
    }
    func snapshot() -> SavedWindow? {
        let valid = application.profiles.filter { !$0.privateMode }.map(\.id)
        let kept = workspaces.filter { valid.contains($0.key) }
        guard let selected = valid.contains(selectedProfileID) ? selectedProfileID : valid.first else { return nil }

        if profile.privateMode && kept.isEmpty { return nil }
        return SavedWindow(
            id: id, selectedProfile: selected, workspaces: kept,
            frame: nativeWindow.map { NSStringFromRect($0.frame) } ?? savedFrame, sidebarVisible: sidebarVisible)
    }
    func extensionWindow(for profileID: UUID) -> ExtensionWindow {
        if let adapter = adapters[profileID] { return adapter }
        let adapter = ExtensionWindow(profileID: profileID, store: self)
        adapters[profileID] = adapter
        return adapter
    }
    func forgetProfile(_ profileID: UUID) {
        sidebarEntryCache = nil
        for (id, tab) in groupPreviews where tab.profileID == profileID {
            tab.dispose()
            groupPreviews.removeValue(forKey: id)
        }
        for (id, tab) in pinPreviews where tab.profileID == profileID {
            tab.dispose()
            pinPreviews.removeValue(forKey: id)
        }
        cancelPasswordFill()
        if passwordOffer?.profileID == profileID { passwordOffer = nil }
        for tab in runtime(for: profileID).tabs.values.filter({ $0.windowID == id }) {
            tab.dispose()
            tabObservers.removeValue(forKey: tab.id)
            runtime(for: profileID).tabs.removeValue(forKey: tab.id)
        }
        workspaces.removeValue(forKey: profileID)
        restoredProfiles.remove(profileID)
        closedTabs.removeValue(forKey: profileID)
        adapters.removeValue(forKey: profileID)
        if selectedProfileID == profileID, let fallback = application.profiles.first(where: { !$0.privateMode }) {
            selectedProfileID = fallback.id
            restoreTabs(for: fallback.id)
        }
    }
    func dispose() {
        restoredInteractionStates.removeAll()
        sidebarEntryCache = nil
        cancelPasswordFill()
        passwordOffer = nil
        for tab in pinPreviews.values { tab.dispose() }
        pinPreviews.removeAll()
        retainedSuggestions?.cancel()
        retainedSuggestions = nil
        tabHover.dismiss()
        sitePanel.dismiss()
        tabSwitcher.finish(commit: false)
        feedback.clear()
        cancelPointerLock()
        for (profileID, _) in workspaces {
            let rt = runtime(for: profileID)
            for tab in rt.tabs.values.filter({ $0.windowID == id }) {
                rt.extensions.controller.didCloseTab(tab)
                tab.dispose()
                rt.tabs.removeValue(forKey: tab.id)
            }
            if let adapter = adapters[profileID] { rt.extensions.controller.didCloseWindow(adapter) }
        }
        for tab in groupPreviews.values { tab.dispose() }
        groupPreviews.removeAll()
        tabObservers.removeAll()
    }

    func runtime(for id: UUID) -> ProfileRuntime { application.runtime(for: id) }
    func restoreTabs(for id: UUID, configuration: WKWebViewConfiguration? = nil) {
        guard !restoredProfiles.contains(id) else {
            selectedTab?.ensureLoaded()
            return
        }
        restoredProfiles.insert(id)
        let rt = runtime(for: id)
        rt.extensions.controller.didOpenWindow(extensionWindow(for: id))
        let savedTabs = profileFor(id).tabs
        func restore() {
            for saved in savedTabs {
                let tab = self.attach(saved, profileID: id)
                if saved.page == .web, let state = self.restoredInteractionStates.removeValue(forKey: saved.id) {
                    tab.sleepState = state
                    tab.sleeping = true
                }
            }
            if !self.profileFor(id).tabs.contains(where: { $0.id == self.profileFor(id).selectedTab }) {
                self.updateProfile(id) { $0.selectedTab = $0.tabs.first?.id }
            }
            if self.profileFor(id).tabs.isEmpty {
                _ = self.newTab(
                    profileID: id, showOmnibar: false, configuration: configuration,
                    activate: id == self.selectedProfileID)
            }
            self.selectedTab?.ensureLoaded()
        }
        if savedTabs.contains(where: { $0.address.flatMap(URL.init(string:))?.scheme == "webkit-extension" }) {
            Task {
                await rt.extensionRestoration?.value
                restore()
            }
        } else {
            restore()
        }
    }

    @discardableResult func attach(_ saved: SavedTab, profileID: UUID, configuration: WKWebViewConfiguration? = nil)
        -> BrowserTab
    {
        let contextConfiguration = saved.address.flatMap(URL.init(string:)).flatMap { url in
            runtime(for: profileID).extensions.contexts.values.first {
                $0.baseURL.host == url.host && url.scheme == "webkit-extension"
            }?.webViewConfiguration
        }
        let tab = BrowserTab(
            saved: saved, profileID: profileID, store: self, configuration: configuration ?? contextConfiguration)
        runtime(for: profileID).tabs[tab.id] = tab
        sidebarMedia.observe(tab)
        ensurePinShortcut(for: tab)
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self, weak tab] in

            guard let self, let tab, self.selectedTab === tab else { return }
            self.invalidateLater()
        }
        runtime(for: profileID).extensions.controller.didOpenTab(tab)
        return tab
    }

    @discardableResult func newTab(
        url: URL? = nil, profileID: UUID? = nil, showOmnibar: Bool = true, configuration: WKWebViewConfiguration? = nil,
        activate: Bool = true
    ) -> BrowserTab {
        let id = profileID ?? selectedProfileID
        if activate && id != selectedProfileID { switchProfile(id) }
        let custom = preferences.customNewTabURL.flatMap {
            URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .flatMap { ["https", "http"].contains($0.scheme) && $0.host != nil && $0.user == nil ? $0 : nil }
        if url == nil, configuration == nil, showOmnibar, activate, id == selectedProfileID,
            let tab = tabs.first(where: { custom != nil && !$0.pinned && $0.page == .web && $0.url == custom })
                ?? tabs.first(where: { $0.isEmptyNewTab })
        {
            select(tab)
            if !omnibarVisible { openOmnibar(newTab: false, query: "") }
            return tab
        }
        let internalPage = url.flatMap(BrowserPage.from)
        let destination: URL?
        if let internalPage {
            destination = internalPage == .web && configuration == nil ? custom : nil
        } else {
            destination = url ?? (configuration == nil ? custom : nil)
        }
        let saved = SavedTab(
            title: internalPage?.title ?? "new tab", address: destination?.absoluteString, page: internalPage ?? .web)
        let tab = attach(saved, profileID: id, configuration: configuration)
        updateProfile(id) { $0.tabs.append(saved) }
        if activate { select(tab) }
        if let destination, !tab.loaded {
            tab.load(destination)
        } else if showOmnibar {
            openOmnibar(newTab: false, query: "")
        }
        persistSoon()
        return tab
    }

    func select(_ tab: BrowserTab) {
        if workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) != true, tab.groupMemberID != nil {
            let open = openGroupMember(tab)
            if open !== tab { select(open) }
            return
        }
        if workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) != true, tab.pinnedShortcutID != nil {
            let open = openPinned(tab)
            if open !== tab { select(open) }
            return
        }
        if pointerLockOffer?.tabID != tab.id { cancelPointerLock() }
        if selectedTab?.id != tab.id {
            selectedTab?.approvedPasswordFill = nil
            cancelPasswordFill()
        }
        let previous = profileFor(tab.profileID).selectedTab.flatMap { runtime(for: tab.profileID).tabs[$0] }
        if let previous, previous.id != tab.id { application.tabPreviews.capture(previous) }
        recentTabIDs[tab.profileID, default: []].removeAll { $0 == tab.id }
        recentTabIDs[tab.profileID, default: []].append(tab.id)
        updateProfile(tab.profileID) { $0.selectedTab = tab.id }
        if let groupID = tab.groupID { updateGroup(groupID, profileID: tab.profileID) { $0.collapsed = false } }
        tab.ensureLoaded()
        runtime(for: tab.profileID).extensions.controller.didActivateTab(tab, previousActiveTab: previous)
        persistSoon()
    }

    func isOpenTab(_ tab: BrowserTab) -> Bool {
        !tab.isDisposed && tab.windowID == id && application.runtimes[tab.profileID]?.tabs[tab.id] === tab
    }
    @discardableResult func closeFromPointer(
        _ tab: BrowserTab, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard tab.profileID == selectedProfileID, isOpenTab(tab) else { return false }
        close(tab)
        return true
    }
    func close(_ tab: BrowserTab) {
        guard !tab.isDisposed, workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) == true else {
            return
        }
        TabClosingAnimation.close(tab)
        tabHover.dismiss()
        let splitSurvivor = browserSplit.flatMap { split -> UUID? in
            guard split.contains(tab.id) else { return nil }
            let id = split.left == tab.id ? split.right : split.left
            return tabs.contains(where: { $0.id == id && !$0.isDisposed }) ? id : nil
        }
        if browserSplit?.contains(tab.id) == true { endSplit() }
        if editingTabIconID == tab.id { editingTabIconID = nil }
        selectedSidebarTabIDs.remove(tab.id)
        syncGroupMember(for: tab)
        if selectedProfileID == tab.profileID, profileFor(tab.profileID).selectedTab == tab.id {
            omnibarVisible = false
            omnibarCreatesTab = false
            omnibarBufferedInput = false
            omnibarQuery = ""
            omnibarOriginalURL = nil

            omnibarFocusID = UUID()
            OmnibarTextField.fields.removeValue(forKey: id)
        }
        if pointerLockOffer?.tabID == tab.id { cancelPointerLock() }
        if selectedTab?.id == tab.id || passwordFillOffer?.tabID == tab.id { cancelPasswordFill() }
        if tab.isEmptyNewTab, tab.profileID == selectedProfileID,
            profileFor(tab.profileID).tabs.count == 1, let window = nativeWindow
        {
            window.performClose(nil)
            return
        }
        let rt = runtime(for: tab.profileID)
        recentTabIDs[tab.profileID]?.removeAll { $0 == tab.id }
        let recent = recentTabIDs[tab.profileID]?.reversed().first { id in
            workspaces[tab.profileID]?.tabs.contains { $0.id == id } == true && rt.tabs[id]?.isDisposed == false
        }
        closedTabs[tab.profileID, default: []].append(
            ClosedTab(saved: tab.saved, interactionState: tab.existingWebView?.interactionState ?? tab.sleepState))
        closedTabs[tab.profileID] = Array(closedTabs[tab.profileID, default: []].suffix(20))
        rt.extensions.controller.didCloseTab(tab)
        tab.dispose()
        tabObservers.removeValue(forKey: tab.id)
        rt.tabs.removeValue(forKey: tab.id)
        updateProfile(tab.profileID) { profile in
            let index = profile.tabs.firstIndex { $0.id == tab.id } ?? 0
            profile.tabs.removeAll { $0.id == tab.id }
            if profile.selectedTab == tab.id {
                profile.selectedTab =
                    splitSurvivor ?? recent
                    ?? (profile.tabs.isEmpty ? nil : profile.tabs[min(index, profile.tabs.count - 1)].id)
            }
        }
        if profileFor(tab.profileID).tabs.isEmpty {
            _ = newTab(profileID: tab.profileID, showOmnibar: false, activate: tab.profileID == selectedProfileID)
        }
        if let selectedTab { select(selectedTab) }
        persistSoon()
    }

    func reopenTab() {
        guard let closed = closedTabs[selectedProfileID]?.popLast() else { return }
        var saved = closed.saved
        saved.id = UUID()
        if let pinID = saved.pinnedShortcutID,
            !(profile.pinShortcuts ?? []).contains(where: { $0.id == pinID })
                || tabs.contains(where: { $0.pinnedShortcutID == pinID })
        {

            saved.pinned = false
            saved.pinnedShortcutID = nil
        }
        if let memberID = saved.groupMemberID,
            !tabGroups.contains(where: {
                $0.id == saved.groupID && $0.savedTabs?.contains(where: { $0.id == memberID }) == true
            }) || tabs.contains(where: { $0.groupMemberID == memberID })
        {
            saved.groupMemberID = nil
            saved.groupID = nil
        }
        if let groupID = saved.groupID, !tabGroups.contains(where: { $0.id == groupID }) {
            saved.groupID = nil
            saved.groupMemberID = nil
        }
        updateProfile(selectedProfileID) { $0.tabs.append(saved) }
        let tab = attach(saved, profileID: selectedProfileID)
        if saved.page == .web, let state = closed.interactionState {
            tab.sleepState = state
            tab.sleeping = true
        }
        select(tab)
    }

    func openOmnibar(newTab: Bool = false, query: String? = nil) {
        guard !application.onboardingVisible else { return }
        feedback.clear()
        cancelPointerLock()
        OmnibarTextField.fields.removeValue(forKey: id)
        omnibarFocusID = UUID()
        omnibarBufferedInput = false
        omnibarCreatesTab = newTab
        omnibarOriginalURL = query == nil ? selectedTab?.url : nil
        omnibarQuery =
            query ?? selectedTab?.url.map {
                BrowserAddress.defaultSearchQuery($0) ?? BrowserAddress.visible($0.absoluteString)
            } ?? ""
        omnibarVisible = true
    }
    func neverSavePasswords(for offer: PasswordOffer) {
        guard passwordOffer?.id == offer.id, selectedProfileID == offer.profileID,
            !profileFor(offer.profileID).privateMode
        else { return }
        updateProfile(offer.profileID) { profile in
            var settings =
                profile.siteSettings?[offer.origin] ?? SiteSettings(userAgent: preferences.userAgentMode ?? .desktop)
            settings.savePasswords = false
            profile.siteSettings = profile.siteSettings ?? [:]
            profile.siteSettings?[offer.origin] = settings
        }
        for window in application.windows
        where window.passwordOffer?.profileID == offer.profileID
            && window.passwordOffer?.origin == offer.origin
        {
            window.passwordOffer = nil
        }
    }

    func focusPage() {
        guard !application.onboardingVisible, !omnibarVisible, !findVisible, let tab = selectedTab, tab.page == .web,
            tab.url != nil, tab.existingWebView?.fullscreenState == .notInFullscreen,
            let window = nativeWindow, window.isKeyWindow, window.attachedSheet == nil,
            let view = tab.visibleWebView, view.window === window
        else { return }
        if let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) {
            return
        }
        window.makeFirstResponder(view)
    }

    func resolveAddress(_ input: String, original: URL? = nil) -> URL? {
        BrowserAddress.resolveEditing(
            input, original: original, engine: preferences.searchEngine ?? .google,
            customTemplate: preferences.customSearchTemplate)
    }
    func searchAddress(_ input: String) -> URL? {
        BrowserAddress.search(
            input, engine: preferences.searchEngine ?? .google, customTemplate: preferences.customSearchTemplate)
    }
    func navigate(_ input: String, inNewTab: Bool = false) {
        guard let url = resolveAddress(input, original: omnibarVisible ? omnibarOriginalURL : nil) else { return }
        omnibarVisible = false
        if let page = BrowserPage.from(url) {
            openInternal(page, inNewTab: inNewTab || omnibarCreatesTab)
            return
        }
        if inNewTab || omnibarCreatesTab || selectedTab == nil {
            _ = newTab(url: url, showOmnibar: false)
        } else {
            selectedTab?.load(url)
        }
    }

    func performAlternateSearch(_ query: String) {
        let redirect = preferences.alternateSearch ?? SearchRedirect()
        guard redirect.enabled else { return }
        if redirect.provider == .chatgpt || redirect.provider == .appleIntelligence {
            guard preferences.aiFeaturesEnabled != false else {
                navigate(query)
                return
            }
            let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { return }

            let createsTab = omnibarCreatesTab || (selectedTab?.page != .ask && selectedTab?.isEmptyNewTab != true)
            omnibarVisible = false
            omnibarCreatesTab = false
            openInternal(.ask, inNewTab: createsTab)
            selectedTab?.chatGPTSearch.open(
                query: input,
                provider: redirect.provider == .chatgpt
                    ? .chatgpt : preferences.aiProvider == .privateCloud ? .privateCloud : .onDevice)
            return
        }
        guard let url = redirect.url(for: query) else {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error = "use an HTTPS search URL with one {query} placeholder"
            }
            return
        }
        navigate(url.absoluteString)
    }
    func showPage(_ page: BrowserPage) {
        if let section = page.settingsSection {
            application.coordinator?.showSettings(for: self, section: section)
            return
        }
        if let tab = tabs.first(where: { $0.page == page }) {
            select(tab)
            return
        }
        var saved = SavedTab(title: page.title, page: page)
        saved.address = nil
        updateProfile(selectedProfileID) { $0.tabs.append(saved) }
        select(attach(saved, profileID: selectedProfileID))
    }
    func openInternal(_ page: BrowserPage, inNewTab: Bool) {
        if let section = page.settingsSection {
            application.coordinator?.showSettings(for: self, section: section)
            return
        }
        if page == .web {
            if let existing = tabs.first(where: { $0.isEmptyNewTab }) {
                select(existing)
                return
            }
            if selectedTab?.isEmptyNewTab != true { _ = newTab(showOmnibar: false) }
            return
        }
        if inNewTab || selectedTab == nil { _ = newTab(showOmnibar: false) }
        guard let tab = selectedTab else { return }
        if browserSplit?.contains(tab.id) == true { endSplit() }
        if tab.page == .ask, page != .ask { tab.existingChatGPTSearch?.clear() }
        tab.existingWebView?.stopLoading()
        tab.url = nil
        tab.page = page
        tab.title = page.title
        tab.navigationID = UUID()
        tab.favicon = nil
        tab.loading = false
        tab.navigationError = nil
        tab.readerArticle = nil
        tab.readerDocument = nil
        tab.media = []
        tab.dismissedMedia = []
        tabChanged(tab)
    }

    func switchProfile(_ id: UUID) {
        if id != selectedProfileID { endSplit() }
        guard profiles.contains(where: { $0.id == id }), id != selectedProfileID else { return }
        for tab in tabs { tab.existingChatGPTSearch?.clear() }
        cancelPasswordFill()
        tabHover.dismiss()
        profileDirection =
            (profiles.firstIndex { $0.id == id } ?? 0) > (profiles.firstIndex { $0.id == selectedProfileID } ?? 0)
            ? 1 : -1
        feedback.clear()
        cancelPointerLock()
        if let tab = selectedTab { application.tabPreviews.capture(tab) }
        selectedSidebarTabIDs = []
        sidebarSelectionAnchor = nil
        editingGroupID = nil
        selectedProfileID = id
        omnibarVisible = false
        passwordOffer = nil
        passwordFillOffer = nil
        siteSettingsVisible = false
        findVisible = false
        translationText = nil
        restoreTabs(for: id)
        runtime.extensions.controller.didFocusWindow(extensionWindow(for: id))
        persistSoon()
    }

    func addProfile(name: String, emoji: String, privateMode: Bool = false) {
        guard profiles.count < 8 else {
            error = "loaf supports up to 8 profiles"
            return
        }
        let profile = Profile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "untitled" : String(name.prefix(40)),
            emoji: String(emoji.prefix(4)), tint: profiles.count % 4, privateMode: privateMode)
        application.profiles.append(profile)
        switchProfile(profile.id)
    }

    func endPrivateSession() { application.endPrivateProfile(selectedProfileID) }
    func swipeProfile(_ direction: Int) {
        guard let current = profiles.firstIndex(where: { $0.id == selectedProfileID }),
            profiles.indices.contains(current + direction)
        else { return }
        switchProfile(profiles[current + direction].id)
        LoafHaptics.perform(enabled: preferences.haptics != false)
    }

    func togglePin(_ tab: BrowserTab) {
        guard tab.store === self, !tab.isDisposed else { return }
        if browserSplit?.contains(tab.id) == true { endSplit() }
        if tab.pinned {
            removePin(tab)
        } else {
            detachGroupMember(tab)

            tab.pinnedAddress = tab.saved.address
            tab.pinned = true
            ensurePinShortcut(for: tab)
        }
        tabHover.dismiss()
        tabChanged(tab)
        if workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) == true {
            runtime(for: tab.profileID).extensions.controller.didChangeTabProperties(.pinned, for: tab)
        }
    }

    func moveTab(_ id: UUID, before target: UUID) { moveTab(id, relativeTo: target, after: false) }
    func moveTab(_ id: UUID, relativeTo target: UUID, after: Bool) {
        let oldIndex = tabs.firstIndex { $0.id == id } ?? 0
        guard let tab = runtime.tabs[id], let destination = runtime.tabs[target],
            tab.windowID == self.id, destination.windowID == self.id,
            tab.profileID == selectedProfileID, destination.profileID == selectedProfileID,
            tab.pinned == destination.pinned, id != target
        else { return }
        if !tab.pinned, tab.groupID != destination.groupID { assignTab(tab, to: destination.groupID) }
        updateProfile(selectedProfileID) { profile in
            guard let from = profile.tabs.firstIndex(where: { $0.id == id }),
                profile.tabs.contains(where: { $0.id == target })
            else { return }
            let saved = tab.saved
            profile.tabs.remove(at: from)
            guard let to = profile.tabs.firstIndex(where: { $0.id == target }) else { return }
            profile.tabs.insert(saved, at: to + (after ? 1 : 0))
        }
        if !tab.pinned, tab.groupID == nil {
            var order = sidebarEntries.compactMap { entry -> UUID? in
                switch entry {
                case .group(let group): return group.isPinned ? nil : group.id
                case .tab(let tab): return tab.groupID == nil ? tab.id : nil
                case .newTab: return nil
                }
            }
            if let from = order.firstIndex(of: id), order.contains(target) {
                order.remove(at: from)
                let to = order.firstIndex(of: target)!
                order.insert(id, at: to + (after ? 1 : 0))
                workspaces[selectedProfileID]?.sidebarOrder = order
            }
        }
        runtime.extensions.controller.didMoveTab(tab, from: oldIndex, in: extensionWindow(for: selectedProfileID))
        persistSoon()
    }

    func tabChanged(_ tab: BrowserTab) {
        guard profiles.contains(where: { $0.id == tab.profileID }) else { return }
        syncPinShortcut(for: tab)
        syncGroupMember(for: tab)

        if var workspace = workspaces[tab.profileID], let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }),
            workspace.tabs[index] != tab.saved
        {
            workspace.tabs[index] = tab.saved
            workspaces[tab.profileID] = workspace
            invalidateLater()
            persistSoon()
        }
        if workspaces[tab.profileID]?.tabs.contains(where: { $0.id == tab.id }) == true {
            runtime(for: tab.profileID).extensions.controller.didChangeTabProperties(
                [.title, .URL, .loading], for: tab)
        }
    }

    func visited(_ tab: BrowserTab) {
        guard profiles.contains(where: { $0.id == tab.profileID }) else { return }
        guard let url = tab.url, ["https", "http"].contains(url.scheme), !profileFor(tab.profileID).privateMode else {
            return
        }

        guard url.user == nil, url.password == nil else { return }
        updateProfile(tab.profileID) { profile in
            profile.history.insert(Visit(title: tab.title, address: url.absoluteString), at: 0)
            profile.history = Array(profile.history.prefix(50_000))
        }
        persistSoon()
    }

    func profileFor(_ id: UUID) -> Profile {
        var profile = application.profiles.first { $0.id == id } ?? application.profiles[0]
        profile.tabs = workspaces[id]?.tabs ?? []
        profile.selectedTab = workspaces[id]?.selectedTab
        return profile
    }
    func updateProfile(_ id: UUID, _ update: (inout Profile) -> Void) {
        guard application.profiles.contains(where: { $0.id == id }) else { return }
        var profile = profileFor(id)
        update(&profile)
        workspaces[id] = WindowWorkspace(
            sidebarOrder: workspaces[id]?.sidebarOrder, groups: workspaces[id]?.groups, tabs: profile.tabs,
            selectedTab: profile.selectedTab)
        application.updateProfile(id) { $0 = profile }
        syncWindowTitle()
        invalidateLater()
    }
    func updateCurrent(_ update: (inout Profile) -> Void) {
        updateProfile(selectedProfileID, update)
        persistSoon()
    }

    var isCurrentPageFavorite: Bool {
        guard let url = selectedTab?.url else { return false }
        return profile.favorites.contains { $0.address == url.absoluteString }
    }
    func favoriteCurrent() {
        guard let tab = selectedTab, let url = tab.url, ["http", "https"].contains(url.scheme), url.user == nil else {
            return
        }
        let removing = profile.favorites.contains { $0.address == url.absoluteString }
        updateCurrent { profile in
            if let index = profile.favorites.firstIndex(where: { $0.address == url.absoluteString }) {
                profile.favorites.remove(at: index)
            } else {
                profile.favorites.append(Favorite(title: tab.title, address: url.absoluteString))
            }
        }
        feedback.show(
            .favorite, icon: removing ? .favorite : .favoriteFilled,
            text: removing ? "removed from favorites" : "added to favorites")
        LoafHaptics.perform(enabled: preferences.haptics != false)
    }
    func setPageZoom(_ zoom: Double) {
        guard zoom.isFinite, let tab = selectedTab, tab.page == .web, tab.url != nil else { return }
        let value = min(3, max(0.5, zoom))
        let previous = tab.webView.pageZoom
        guard abs(value - previous) > 0.0001 else { return }
        tab.webView.pageZoom = value
        tab.readerWebView?.pageZoom = value
        if let origin = tab.url.flatMap(BrowserAddress.websiteOrigin) {
            updateCurrent { profile in
                var settings =
                    profile.siteSettings?[origin] ?? SiteSettings(userAgent: preferences.userAgentMode ?? .desktop)
                settings.zoom = value
                profile.siteSettings = profile.siteSettings ?? [:]
                profile.siteSettings?[origin] = settings
            }
        }
        feedback.show(
            .zoom, icon: value > previous ? .zoomIn : .zoomOut, text: "zoom · \(Int((value * 100).rounded()))%")
        if abs(value - 1) < 0.001 { LoafHaptics.perform(enabled: preferences.haptics != false) }
    }
    func resetPageZoom() {
        guard let tab = selectedTab, tab.page == .web, tab.url != nil else { return }
        let view = tab.webView
        let previous = view.pageZoom
        let magnified = [view, tab.readerWebView].compactMap { $0 }.filter { abs($0.magnification - 1) > 0.0001 }
        setPageZoom(1)
        for page in magnified {
            page.setMagnification(1, centeredAt: NSPoint(x: page.bounds.midX, y: page.bounds.midY))
        }
        if abs(previous - 1) <= 0.0001, !magnified.isEmpty {
            feedback.show(.zoom, icon: .zoomOut, text: "zoom · 100%")
            LoafHaptics.perform(enabled: preferences.haptics != false)
        }
    }
    func copyCurrentAddress() {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        feedback.show(.copied, icon: .check, text: "address copied")
    }

    func toggleBlockerForSite() {
        guard let host = selectedTab?.url?.host else { return }
        updateCurrent { p in
            if p.allowedSites.contains(host) {
                p.allowedSites.removeAll { $0 == host }
            } else {
                p.allowedSites.append(host)
            }
        }
        applyBlocker()
        selectedTab?.reload()
    }

    func applyBlocker() { for tab in runtime.tabs.values { tab.updateBlocker() } }
    func applyPasswordPreference() {
        passwordOffer = nil
        cancelPasswordFill()
        for runtime in runtimes.values { for tab in runtime.tabs.values { tab.updatePasswordCapture() } }
        persistSoon()
    }
    func cycleTab(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == profile.selectedTab } ?? 0
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    func persistSoon() { application.persistSoon() }
    func persist() { application.persist() }
}

typealias BrowserStore = BrowserWindowState

@MainActor final class ProfileRuntime {
    let dataStore: WKWebsiteDataStore
    private(set) var tabsRevision: UInt64 = 0
    var tabs: [UUID: BrowserTab] = [:] { didSet { tabsRevision &+= 1 } }
    var extensionRestoration: Task<Void, Never>?
    let extensions: ExtensionManager
    init(profile: Profile, application: BrowserApplication) {
        dataStore = profile.privateMode ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: profile.id)
        extensions = ExtensionManager(profileID: profile.id, dataStore: dataStore, application: application)
        Task { await dataStore.httpCookieStore.setCookiePolicy(profile.blocksCookies == true ? .disallow : .allow) }
    }
}

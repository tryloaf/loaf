import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class WindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let application: BrowserApplication
    @Published var focused: BrowserWindowState?
    private var native: [UUID: NSWindow] = [:]
    private var auxiliary: [NSWindow] = []
    private func configureAuxiliary(_ window: NSWindow) {
        window.level = .normal
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.hidesOnDeactivate = false
    }
    func showAuxiliary(_ window: NSWindow) {
        auxiliary.append(window)
        configureAuxiliary(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private weak var lastKeyWindow: NSWindow?
    private weak var updateReturnWindow: NSWindow?
    private var auxiliaryReturnWindows: [ObjectIdentifier: WindowReference] = [:]
    private var keyWindowObserver: NSObjectProtocol?
    func prepareForUpdatePresentation() { updateReturnWindow = NSApp.keyWindow }
    private weak var settingsOwner: BrowserWindowState?
    private var observations = Set<AnyCancellable>()
    private var focusObservation: AnyCancellable?
    private struct CommandSnapshot: Equatable {
        var windowID: UUID?
        var profileID: UUID?
        var tabID: UUID?
        var profiles: [String]
        var favorites: [String]
        var onboarding: Bool
        var developer: Bool
        var userAgent: UserAgentMode?
        var navigation: [Bool]
    }
    private var commandSnapshot: CommandSnapshot?
    private func snapshotCommands() -> CommandSnapshot {
        let state = commandState
        let tab = state?.selectedTab
        return CommandSnapshot(
            windowID: nil, profileID: state?.selectedProfileID, tabID: nil,
            profiles: application.profiles.map { $0.id.uuidString + "\n" + $0.name + "\n" + String($0.privateMode) },
            favorites: state?.profile.favorites.prefix(12).map {
                $0.id.uuidString + "\n" + $0.title + "\n" + $0.address
            } ?? [],
            onboarding: application.onboardingVisible, developer: application.preferences.developerMenu == true,
            userAgent: state?.currentUserAgentMode,
            navigation: [tab?.canGoBack == true, tab?.canGoForward == true, tab?.url != nil, tab?.loading == true])
    }
    private var notificationPending = false
    private func invalidateLater() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            let snapshot = self.snapshotCommands()
            guard snapshot != self.commandSnapshot else { return }
            self.commandSnapshot = snapshot
            self.objectWillChange.send()
        }
    }
    private var menuTrackingObservers: [NSObjectProtocol] = []
    struct ClosedWindow {
        let saved: SavedWindow
        let interactionStates: [UUID: Any]
    }
    @Published private(set) var closedWindows: [ClosedWindow] = []
    var canReopenClosedWindow: Bool {
        !application.onboardingVisible
            && closedWindows.contains { record in
                application.profiles.contains { !$0.privateMode && record.saved.workspaces[$0.id] != nil }
            }
    }
    func forgetProfile(_ id: UUID) {
        closedWindows = closedWindows.compactMap { record in
            var saved = record.saved
            let forgotten = Set(saved.workspaces[id]?.tabs.map(\.id) ?? [])
            saved.workspaces.removeValue(forKey: id)
            guard !saved.workspaces.isEmpty else { return nil }
            if saved.selectedProfile == id {
                saved.selectedProfile = saved.workspaces.keys.sorted { $0.uuidString < $1.uuidString }.first!
            }
            return ClosedWindow(saved: saved, interactionStates: record.interactionStates.filter { !forgotten.contains($0.key) })
        }
    }
    private var auxiliaryCloseObserver: NSObjectProtocol?
    private var positioningOnboarding = false
    private var hiddenForOnboarding: [NSWindow] = []
    var terminating = false
    private struct SheetRequest {
        let start: (@escaping () -> Void) -> Void
        let cancel: () -> Void
    }
    private var sheets: [UUID: [SheetRequest]] = [:]
    private var presenting = Set<UUID>()
    func enqueueSheet(
        for state: BrowserWindowState, cancel: @escaping () -> Void, start: @escaping (@escaping () -> Void) -> Void
    ) {
        sheets[state.id, default: []].append(SheetRequest(start: start, cancel: cancel))
        nextSheet(state.id)
    }
    private func nextSheet(_ id: UUID) {
        guard !presenting.contains(id), let request = sheets[id]?.first else { return }
        guard application.windows.contains(where: { $0.id == id && $0.nativeWindow?.isVisible == true }) else {
            sheets[id]?.removeFirst()
            request.cancel()
            nextSheet(id)
            return
        }
        presenting.insert(id)
        request.start { [weak self] in
            guard let self, self.presenting.remove(id) != nil else { return }
            if self.sheets[id]?.isEmpty == false { self.sheets[id]?.removeFirst() }
            DispatchQueue.main.async { [weak self] in self?.nextSheet(id) }
        }
    }
    func alert(
        _ alert: NSAlert, for state: BrowserWindowState, completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        alert.icon = LoafAppIcon.image
        enqueueSheet(for: state, cancel: { completion(.abort) }) { done in
            guard let window = state.nativeWindow else {
                completion(.abort)
                done()
                return
            }
            alert.beginSheetModal(for: window) { response in
                completion(response)
                done()
            }
        }
    }
    init(application: BrowserApplication) {
        self.application = application
        super.init()
        application.coordinator = self
        application.objectWillChange.sink { [weak self] in self?.invalidateLater() }.store(in: &observations)
        application.$onboardingVisible.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateOnboardingWindows() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink {
            [weak self] _ in
            self?.updateOnboardingWindows()
        }.store(in: &observations)
        $focused.sink { [weak self] state in
            self?.focusObservation = state?.objectWillChange.sink { [weak self] in self?.invalidateLater() }
        }.store(in: &observations)

        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuTrackingObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        if let menu = note.object as? NSMenu {
                            PageSaveCommand.track(menu, active: name == NSMenu.didBeginTrackingNotification)
                        }
                    }
                })
        }
        lastKeyWindow = NSApp?.keyWindow
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }



                guard !(window is NSSavePanel), !window.isSheet else { return }
                let contentWindow = window === self.settingsWindow || self.native.values.contains { $0 === window }
                if !contentWindow, let previous = self.updateReturnWindow, previous !== window {
                    self.auxiliaryReturnWindows[ObjectIdentifier(window)] = WindowReference(previous)
                    self.updateReturnWindow = nil
                }
                if !contentWindow, self.auxiliaryReturnWindows[ObjectIdentifier(window)] == nil,
                    let previous = self.lastKeyWindow, previous !== window, previous.isVisible
                {
                    self.auxiliaryReturnWindows[ObjectIdentifier(window)] = WindowReference(previous)
                }
                self.lastKeyWindow = window
            }
        }
        auxiliaryCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            guard !(window is NSSavePanel), !window.isSheet else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let owned =
                    self.auxiliary.contains { $0 === window } || window === self.settingsWindow
                    || window === self.aboutWindow
                let returnWindow = self.auxiliaryReturnWindows.removeValue(forKey: ObjectIdentifier(window))?.window
                let wasKey = window.isKeyWindow || self.lastKeyWindow === window
                self.auxiliary.removeAll { $0 === window }
                guard (owned || returnWindow != nil), wasKey, NSApp.isActive else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, NSApp.isActive else { return }
                    if let returnWindow, returnWindow.isVisible, returnWindow.isOnActiveSpace,
                        NSApp.keyWindow == nil || self.native.values.contains(where: { $0 === NSApp.keyWindow })
                    {
                        returnWindow.makeKeyAndOrderFront(nil)
                        return
                    }
                    guard NSApp.keyWindow == nil,
                        let browser = self.focused?.nativeWindow, browser.isVisible, browser.isOnActiveSpace,
                        self.application.windows.contains(where: { state in
                            state.tabs.contains {
                                $0.existingWebView?.fullscreenState != nil
                                    && $0.existingWebView?.fullscreenState != .notInFullscreen
                            }
                        }) != true
                    else {
                        return
                    }
                    browser.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
    @discardableResult func activateBrowser() -> BrowserWindowState? {
        let state = commandState
        state?.nativeWindow?.makeKeyAndOrderFront(nil)
        return state
    }
    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        if let auxiliaryCloseObserver { NotificationCenter.default.removeObserver(auxiliaryCloseObserver) }
        for observer in menuTrackingObservers { NotificationCenter.default.removeObserver(observer) }
    }
    func start() {
        let windows = application.initialWindows()
        for state in windows { show(state) }
        if let error = application.error {
            windows.first?.error = error
            application.error = nil
        }
    }
    @discardableResult func newWindow(
        profileID: UUID? = nil, url: URL? = nil, configuration: WKWebViewConfiguration? = nil
    ) -> BrowserWindowState {
        if application.onboardingVisible, let owner = application.windows.first {
            show(owner)
            return owner
        }
        let state = application.makeWindow(profileID: profileID ?? commandState?.selectedProfileID, restore: false)
        state.isPopupWindow = configuration != nil
        state.restoreTabs(for: state.selectedProfileID, configuration: configuration)
        if let url { state.selectedTab?.load(url) } else if configuration == nil { state.openOmnibar(query: "") }
        show(state)
        application.persistSoon()
        return state
    }
    func openReceivedURLs(_ urls: [URL]) {
        let urls = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard let first = urls.first else { return }
        let state: BrowserWindowState
        if let existing = commandState {
            state = existing
            for url in urls { state.openReceivedURL(url) }
        } else {
            state = newWindow(url: first)
            state.dismissOmnibar()
            for url in urls.dropFirst() { state.openReceivedURL(url) }
        }
        show(state)
        state.focusPage()
    }

    @discardableResult func newPrivateWindow() -> BrowserWindowState {
        if application.onboardingVisible, let owner = application.windows.first {
            show(owner)
            return owner
        }
        let profile = Profile(name: "private", emoji: LoafIcon.privateMode.rawValue, privateMode: true)
        application.profiles.append(profile)
        return newWindow(profileID: profile.id)
    }
    @discardableResult func reopenLastClosedWindow() -> BrowserWindowState? {
        guard !application.onboardingVisible else { return nil }
        while let record = closedWindows.popLast() {
            var saved = record.saved
            let allowed = Set(application.profiles.filter { !$0.privateMode }.map(\.id))
            saved.workspaces = saved.workspaces.filter { allowed.contains($0.key) }
            guard !saved.workspaces.isEmpty else { continue }
            saved.id = UUID()
            if saved.workspaces[saved.selectedProfile] == nil {
                saved.selectedProfile = saved.workspaces.keys.sorted { $0.uuidString < $1.uuidString }.first!
            }
            let state = application.makeWindow(saved: saved, restore: false)
            state.restoredInteractionStates = record.interactionStates
            state.restoreTabs(for: state.selectedProfileID)
            show(state)
            application.persistSoon()
            return state
        }
        return nil
    }
    func show(_ state: BrowserWindowState) {
        if let window = native[state.id] {
            if application.onboardingVisible, application.windows.first !== state {
                window.orderOut(nil)
                return
            }
            window.makeKeyAndOrderFront(nil)
            if focused !== state { focused = state }
            return
        }
        let window = LoafBrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1132, height: 811),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.store = state
        window.collectionBehavior = [.managed, .primary, .fullScreenPrimary, .fullScreenDisallowsTiling]
        window.updateTrafficLightAvailability()
        window.title = "loaf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 540)
        window.identifier = NSUserInterfaceItemIdentifier(state.id.uuidString)
        window.delegate = self
        state.nativeWindow = window
        window.contentView = NSHostingView(rootView: ContentView(store: state))
        window.center()
        if let frame = state.savedFrame { window.setFrame(NSRectFromString(frame), display: false) }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.setSidebarOnlyChrome(state.usesSidebarOnlyChrome)
        native[state.id] = window
        if application.onboardingVisible, application.windows.first !== state {
            hiddenForOnboarding.append(window)
            return
        }
        window.makeKeyAndOrderFront(nil)
        if focused !== state { focused = state }
    }
    func state(for window: NSWindow?) -> BrowserWindowState? {
        guard let window else { return nil }
        return application.windows.first { $0.nativeWindow === window }
    }
    func fitOnboardingWindow(_ state: BrowserWindowState) {
        guard application.onboardingVisible, application.windows.first === state, !positioningOnboarding,
            let window = state.nativeWindow as? LoafBrowserWindow, let screen = window.screen ?? NSScreen.main
        else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        positioningOnboarding = true
        defer { positioningOnboarding = false }
        onboardingWindowsLocked = true
        window.lockForOnboarding()
        let available = screen.visibleFrame
        let size = NSSize(width: min(available.width, 1060), height: min(available.height, 820))
        let frame = NSRect(
            x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width,
            height: size.height)
        window.setOnboardingSize(size)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }
    private var onboardingWindowsLocked = false
    private func updateOnboardingWindows() {
        if application.onboardingVisible, let owner = application.windows.first {
            onboardingWindowsLocked = true
            for window in NSApp.windows where window !== owner.nativeWindow && window.isVisible && !window.isSheet {
                if !hiddenForOnboarding.contains(where: { $0 === window }) { hiddenForOnboarding.append(window) }
                window.orderOut(nil)
            }
            fitOnboardingWindow(owner)
            owner.nativeWindow?.makeKeyAndOrderFront(nil)
        } else {
            guard onboardingWindowsLocked else { return }
            onboardingWindowsLocked = false
            for window in native.values { (window as? LoafBrowserWindow)?.unlockAfterOnboarding() }
            for window in hiddenForOnboarding { window.orderFront(nil) }
            hiddenForOnboarding.removeAll()
            focused?.nativeWindow?.makeKeyAndOrderFront(nil)
        }
    }
    var commandState: BrowserWindowState? {

        if let state = state(for: NSApp.keyWindow) { return state }
        guard let focused, application.windows.contains(where: { $0 === focused }) else { return nil }
        return focused
    }
    func closeKeyWindowTab() {

        guard let window = NSApp.keyWindow else { return }
        guard let state = state(for: window) else {
            window.performClose(nil)
            return
        }
        if let tab = state.selectedTab { state.close(tab) }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let state = state(for: notification.object as? NSWindow) else { return }
        if focused !== state { focused = state }
        state.objectWillChange.send()
        state.runtime.extensions.controller.didFocusWindow(state.extensionWindow(for: state.selectedProfileID))
    }
    func windowDidResignKey(_ notification: Notification) {
        state(for: notification.object as? NSWindow)?.objectWillChange.send()
    }
    func windowDidResize(_ notification: Notification) {
        if application.onboardingVisible, let state = state(for: notification.object as? NSWindow) {
            fitOnboardingWindow(state)
            return
        }
        guard (notification.object as? NSWindow)?.inLiveResize != true else { return }
        application.persistSoon()
    }
    func windowDidEndLiveResize(_ notification: Notification) { application.persistSoon() }
    func windowDidMove(_ notification: Notification) {
        if application.onboardingVisible, let state = state(for: notification.object as? NSWindow) {
            fitOnboardingWindow(state)
            return
        }
        application.persistSoon()
    }
    func windowDidChangeScreen(_ notification: Notification) {
        if let state = state(for: notification.object as? NSWindow) { fitOnboardingWindow(state) }
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        (notification.object as? LoafBrowserWindow)?.captureTrafficLightFrames()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? LoafBrowserWindow, let state = state(for: window) else { return }

        window.hideFullscreenTitlebar()
        window.updateTrafficLightAvailability()
        state.isFullscreen = true
        state.chromeControlsCenterY = 16
        state.fullscreenControlsVisible = true
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? LoafBrowserWindow else { return }
        window.restoreTitlebar()
        state(for: window)?.fullscreenControlsVisible = false
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? LoafBrowserWindow else { return }
        window.restoreTitlebar()
        state(for: window)?.fullscreenControlsVisible = false
        state(for: window)?.isFullscreen = false
        window.updateTrafficLightAvailability()
        if let state = state(for: window) { fitOnboardingWindow(state) }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        (window as? LoafBrowserWindow)?.restoreTitlebar()
        state(for: window)?.fullscreenControlsVisible = false
        state(for: window)?.isFullscreen = false
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard let window = window as? LoafBrowserWindow else { return }
        window.hideFullscreenTitlebar()
        state(for: window)?.fullscreenControlsVisible = true
        state(for: window)?.isFullscreen = true
    }
    func windowWillClose(_ notification: Notification) {
        guard !terminating, let state = state(for: notification.object as? NSWindow) else { return }
        if !state.profile.privateMode, let saved = state.snapshot() {
            var interactions: [UUID: Any] = [:]
            for (profileID, workspace) in saved.workspaces {
                for tab in workspace.tabs {
                    if let live = application.runtimes[profileID]?.tabs[tab.id],
                        let interaction = live.existingWebView?.interactionState ?? live.sleepState
                    {
                        interactions[tab.id] = interaction
                    }
                }
            }
            closedWindows.append(ClosedWindow(saved: saved, interactionStates: interactions))
            closedWindows = Array(closedWindows.suffix(10))
        }
        application.downloads.closeWindow(state.id)
        for request in (sheets.removeValue(forKey: state.id) ?? []).dropFirst(presenting.contains(state.id) ? 1 : 0) {
            request.cancel()
        }
        presenting.remove(state.id)
        OmnibarTextField.fields.removeValue(forKey: state.id)
        state.dispose()
        state.nativeWindow?.contentView = nil
        application.windows.removeAll { $0.id == state.id }
        native.removeValue(forKey: state.id)
        if focused === state {
            let next = application.windows.last { $0.nativeWindow?.isVisible == true } ?? application.windows.last
            focused = next
            DispatchQueue.main.async {
                guard NSApp.isActive, NSApp.keyWindow == nil, let window = next?.nativeWindow, window.isVisible else {
                    return
                }
                window.makeKeyAndOrderFront(nil)
            }
        }
        if settingsOwner === state {
            if let next = focused {
                settingsOwner = next
                settingsWindow?.contentView = NSHostingView(rootView: SettingsView(store: next))
            } else {
                settingsWindow?.close()
                settingsWindow?.contentView = nil
                settingsOwner = nil
            }
        }
        for id in state.workspaces.keys where application.profiles.first(where: { $0.id == id })?.privateMode == true {
            if !application.windows.contains(where: { $0.workspaces[id] != nil }) { application.endPrivateProfile(id) }
        }
        application.persist()
    }
    func showAbout() {
        guard !application.onboardingVisible else { return }
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "about loaf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AboutLoafView().environment(
                \.openURL,
                OpenURLAction { [weak self] url in
                    guard let self else { return .discarded }
                    if let state = self.activateBrowser() {
                        _ = state.newTab(url: url, showOmnibar: false)
                    } else {
                        self.newWindow(url: url)
                    }
                    return .handled
                }))
        aboutWindow = window
        configureAuxiliary(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func showSettings(for state: BrowserWindowState, section: String? = nil) {
        guard !application.onboardingVisible else { return }
        if let settingsWindow {
            if settingsOwner !== state || section != nil {
                settingsWindow.contentView = NSHostingView(
                    rootView: SettingsView(store: state, initialSection: section ?? "general"))
                settingsOwner = state
            }
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = LoafSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.title = "settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 680)
        window.contentMaxSize = window.contentMinSize
        window.contentView = NSHostingView(rootView: SettingsView(store: state, initialSection: section ?? "general"))
        window.center()
        settingsWindow = window
        settingsOwner = state
        configureAuxiliary(window)
        window.makeKeyAndOrderFront(nil)
    }

}

@MainActor final class LoafBrowserWindow: NSWindow {
    weak var store: BrowserStore?
    private struct OnboardingGeometry {
        let minimum: NSSize
        let maximum: NSSize
        let movable: Bool
        let backgroundMovable: Bool
        let resizable: Bool
        let behavior: NSWindow.CollectionBehavior
    }
    private var onboardingGeometry: OnboardingGeometry?
    private var onboardingSize: NSSize?
    override var minSize: NSSize {
        get { super.minSize }
        set { super.minSize = onboardingSize ?? newValue }
    }
    override var maxSize: NSSize {
        get { super.maxSize }
        set { super.maxSize = onboardingSize ?? newValue }
    }
    private var onboardingContentSize: NSSize? {
        onboardingSize.map { contentRect(forFrameRect: NSRect(origin: .zero, size: $0)).size }
    }
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = onboardingContentSize ?? newValue }
    }
    override var contentMaxSize: NSSize {
        get { super.contentMaxSize }
        set { super.contentMaxSize = onboardingContentSize ?? newValue }
    }
    func setOnboardingSize(_ size: NSSize) {
        guard onboardingGeometry != nil else { return }

        onboardingSize = size
        minSize = size
        maxSize = size
    }
    func lockForOnboarding() {
        guard onboardingGeometry == nil else { return }
        onboardingGeometry = OnboardingGeometry(
            minimum: minSize, maximum: maxSize, movable: isMovable,
            backgroundMovable: isMovableByWindowBackground, resizable: styleMask.contains(.resizable),
            behavior: collectionBehavior)
        isMovable = false
        isMovableByWindowBackground = false
        styleMask.remove(.resizable)
        collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        collectionBehavior.insert(.fullScreenNone)
        standardWindowButton(.zoomButton)?.isEnabled = false
        standardWindowButton(.miniaturizeButton)?.isEnabled = !styleMask.contains(.fullScreen)
        makeFirstResponder(nil)
    }
    func unlockAfterOnboarding() {
        guard let saved = onboardingGeometry else { return }
        onboardingGeometry = nil
        onboardingSize = nil
        minSize = saved.minimum
        maxSize = saved.maximum
        isMovable = saved.movable
        isMovableByWindowBackground = saved.backgroundMovable
        if saved.resizable { styleMask.insert(.resizable) }
        collectionBehavior = saved.behavior
        updateTrafficLightAvailability()
    }
    var allowsFullScreen: Bool {
        store?.application.onboardingVisible != true
            && (styleMask.contains(.resizable) || styleMask.contains(.fullScreen))
    }
    func updateTrafficLightAvailability() {
        standardWindowButton(.zoomButton)?.isEnabled = allowsFullScreen
        standardWindowButton(.miniaturizeButton)?.isEnabled = !styleMask.contains(.fullScreen)
    }
    override func miniaturize(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen) else { return }
        super.miniaturize(sender)
    }
    override func performMiniaturize(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen) else { return }
        super.performMiniaturize(sender)
    }
    override func performDrag(with event: NSEvent) {
        guard store?.application.onboardingVisible != true else { return }
        super.performDrag(with: event)
    }
    override func performZoom(_ sender: Any?) {
        guard store?.application.onboardingVisible != true else { return }
        super.performZoom(sender)
    }
    private var pointerEscape = PointerEscapeGesture()
    private var pointerEscapeTab: UUID?
    private var escapeHeld = false
    private var swallowEscapeUp = false
    private weak var escapePage: BrowserTab?
    private let pageKeyboard = CapturedPageKeyboard()
    private let forwardedPageCommands = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])
    var armedSiteShortcut: (key: String, tabID: UUID, time: TimeInterval)?
    @discardableResult func handlePageEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, attachedSheet == nil,
            let store, !store.omnibarVisible, !store.findVisible, !store.application.onboardingVisible,
            store.selectedTab?.pointerCapturePosition.captured != true, let view = store.selectedTab?.existingWebView,
            let responder = firstResponder as? NSView, responder === view || responder.isDescendant(of: view),
            !forwardedPageCommands.contains(event)
        else { return false }
        forwardedPageCommands.add(event)
        responder.keyDown(with: event)
        return true
    }
    @discardableResult func handlePageKeyboard(_ event: NSEvent) -> Bool {
        guard store?.application.onboardingVisible != true else { return false }
        let view = store?.selectedTab?.existingWebView
        let focused =
            (firstResponder as? NSView).map { responder in
                view.map { responder === $0 || responder.isDescendant(of: $0) } ?? false
            } ?? false
        pageKeyboard.observe(event, webView: focused && attachedSheet == nil ? view : nil)
        guard focused, attachedSheet == nil, event.type == .keyDown, event.modifierFlags.contains(.command), let view
        else { return false }

        guard !forwardedPageCommands.contains(event) else { return false }
        let editing =
            ["a", "c", "x", "v", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
            && !event.modifierFlags.contains(.control)

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let siteFirst =
            ["s", "f", "l", "r"].contains(key)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        if siteFirst {
            guard !event.isARepeat else { return true }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                performBrowserShortcut(key)
            }
            return true
        }
        if !editing && !siteFirst, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }

        forwardedPageCommands.add(event)
        view.keyDown(with: event)
        if let up = CapturedPageKeyboard.keyUp(event) { view.keyUp(with: up) }
        return true
    }
    func handlePointerEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        if event.type == .keyUp {
            escapeHeld = false
            if let page = escapePage {
                WebKitAdapter.capturedEscape(page, type: "keyup", modifiers: event.modifierFlags)
            }
            escapePage = nil
            let consumed = swallowEscapeUp
            swallowEscapeUp = false
            return consumed
        }
        guard event.type == .keyDown, let tab = store?.selectedTab, tab.pointerCapturePosition.captured,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else {
            pointerEscape.reset()
            pointerEscapeTab = nil
            return false
        }
        if pointerEscapeTab != tab.id {
            pointerEscape.reset()
            pointerEscapeTab = tab.id
            escapeHeld = false
        }
        swallowEscapeUp = true
        guard !escapeHeld, !event.isARepeat else {
            if let page = escapePage {
                WebKitAdapter.capturedEscape(page, type: "keydown", repeatKey: true, modifiers: event.modifierFlags)
            }
            return true
        }
        escapeHeld = true
        if pointerEscape.press(at: event.timestamp, repeatKey: event.isARepeat) {
            tab.existingWebView?.evaluateJavaScript(
                "document.exitPointerLock()", in: tab.pointerCaptureFrame, in: .defaultClient
            ) { _ in }
        } else {
            escapePage = tab
            WebKitAdapter.capturedEscape(tab, type: "keydown", modifiers: event.modifierFlags)
            store?.feedback.show(
                .pointer, icon: .pointer, text: "press esc again to release pointer", duration: .seconds(1))
        }
        return true
    }
    private(set) var trafficLightFrames: [NSRect] = []
    private var windowedStyleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]
    private(set) var sidebarOnlyChrome = false
    func setSidebarOnlyChrome(_ enabled: Bool) {
        guard sidebarOnlyChrome != enabled else { return }
        if enabled {
            if !styleMask.contains(.fullScreen) { restoreTitlebar() }
            contentView?.layoutSubtreeIfNeeded()
            captureTrafficLightFrames()
        }
        sidebarOnlyChrome = enabled
        if enabled { hideFullscreenTitlebar() } else if !styleMask.contains(.fullScreen) { restoreTitlebar() }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set {
            let responder = firstResponder
            super.styleMask = onboardingGeometry == nil ? newValue : newValue.subtracting(.resizable)
            updateTrafficLightAvailability()

            if let view = responder as? NSView, let content = contentView,
                view.isDescendant(of: content), firstResponder !== view
            {
                makeFirstResponder(view)
            }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePointerEscape(event) { return true }
        if handlePageEscape(event) { return true }
        if event.modifierFlags.contains(.command) {

            if handlePageKeyboard(event) { return true }
        }

        let handled = super.performKeyEquivalent(with: event)
        if handled { return true }

        if let captured = store?.selectedTab?.pointerCapturePosition.captured, captured {
            return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let view = store?.selectedTab?.existingWebView, let responder = firstResponder as? NSView,
            responder === view || responder.isDescendant(of: view)
        {
            return
        }
        if handlePointerEscape(event) { return }

        if let captured = store?.selectedTab?.pointerCapturePosition.captured, captured {
            return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if !handlePointerEscape(event) { super.keyUp(with: event) } }
    override func resignKey() {
        pageKeyboard.release()
        if let page = escapePage { WebKitAdapter.capturedEscape(page, type: "keyup") }
        escapePage = nil
        escapeHeld = false
        pointerEscape.reset()
        pointerEscapeTab = nil
        super.resignKey()
    }
    override func toggleFullScreen(_ sender: Any?) {
        guard store?.application.onboardingVisible != true || styleMask.contains(.fullScreen) else { return }

        if styleMask.contains(.fullScreen) {
            if !styleMask.contains(.titled) { restoreTitlebar() }
        } else {
            captureTrafficLightFrames()
            collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
            collectionBehavior.insert(.fullScreenPrimary)
        }
        super.toggleFullScreen(sender)
    }
    override func performClose(_ sender: Any?) {
        let wasFullscreen = styleMask.contains(.fullScreen)
        if wasFullscreen { restoreTitlebar() }
        super.performClose(sender)
        if wasFullscreen && isVisible { hideFullscreenTitlebar() }
    }
    func captureTrafficLightFrames() {
        guard styleMask.contains(.titled) else { return }
        windowedStyleMask = styleMask.subtracting(.fullScreen)
        guard let content = contentView else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let frames = types.compactMap { type -> NSRect? in
            guard let button = standardWindowButton(type) else { return nil }
            let rect = content.convert(button.bounds, from: button)
            return NSRect(
                x: rect.minX, y: content.isFlipped ? rect.minY : content.bounds.maxY - rect.maxY,
                width: rect.width, height: rect.height)
        }
        if frames.count == types.count, frames.allSatisfy({ $0.width > 0 && (4...32).contains($0.minY) }),
            zip(frames, frames.dropFirst()).allSatisfy({ $0.minX < $1.minX })
        { trafficLightFrames = frames }
    }
    func restoreTitlebar() {
        styleMask.formUnion(windowedStyleMask)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        WebKitAdapter.setWindowTitlebarOpacity(self, value: 1)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = false
        }
        if sidebarOnlyChrome { hideFullscreenTitlebar() }
    }
    func hideFullscreenTitlebar() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = true
        }

        WebKitAdapter.setWindowTitlebarOpacity(self, value: 0)
    }
}

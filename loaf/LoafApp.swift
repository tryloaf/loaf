import AppKit
import SwiftUI
import WebKit

@main struct LoafApp: App {
    @StateObject private var coordinator: WindowCoordinator
    @NSApplicationDelegateAdaptor(LoafAppDelegate.self) private var delegate
    init() {
        UserDefaults.standard.set(false, forKey: "NSAutomaticPeriodSubstitutionEnabled")
        let coordinator = WindowCoordinator(application: MarketingLaunch.application())
        _coordinator = StateObject(wrappedValue: coordinator)
        delegate.coordinator = coordinator
    }
    var body: some Scene {
        Settings { EmptyView() }
            .commandsRemoved()
    }
}

@MainActor final class LoafAppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: WindowCoordinator?
    private var menus: LoafMainMenus?
    private var pendingURLs: [URL] = []
    private var inputMonitor: Any?
    private var quitWarningVisible = false
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {

        NSApp.terminate(self)
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard LegalAcceptance.shared.isAccepted else { return nil }
        return menus?.dockMenu()
    }
    private func presentQuitAlert(
        _ alert: NSAlert, for sender: NSApplication,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        let window = sender.keyWindow ?? sender.mainWindow ?? coordinator?.commandState?.nativeWindow
        sender.activate()
        if let window, window.attachedSheet == nil, !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            DispatchQueue.main.async { completion(alert.runModal()) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UpdateInstallationState.shared.isInstalling {
            coordinator?.terminating = true
            coordinator?.application.persist()
            return .terminateNow
        }
        if !LegalAcceptance.shared.isAccepted { return .terminateNow }
        if let downloads = coordinator?.application.downloads, downloads.hasActiveDownloads {
            guard !quitWarningVisible else { return .terminateLater }
            quitWarningVisible = true
            let alert = NSAlert()
            alert.icon = LoafAppIcon.image
            alert.messageText = "downloads are still running"
            alert.informativeText = "keep loaf running in the background to finish them, or pause downloads and quit."
            alert.addButton(withTitle: "keep downloading")
            alert.addButton(withTitle: "pause and quit")
            alert.addButton(withTitle: "cancel")
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.quitWarningVisible = false
                if response == .alertSecondButtonReturn {
                    Task {
                        await downloads.prepareToQuit()
                        self.coordinator?.terminating = true
                        self.coordinator?.application.persist()
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                } else {
                    sender.reply(toApplicationShouldTerminate: false)
                    if response == .alertFirstButtonReturn { sender.hide(nil) }
                }
            }
            presentQuitAlert(alert, for: sender, completion: finish)
            return .terminateLater
        }
        guard coordinator?.application.preferences.warnBeforeQuitting == true else {
            coordinator?.terminating = true
            coordinator?.application.persist()
            return .terminateNow
        }
        guard !quitWarningVisible else { return .terminateLater }
        quitWarningVisible = true
        let alert = NSAlert()
        alert.icon = LoafAppIcon.image
        alert.messageText = "are you sure you want to quit loaf?"
        alert.informativeText = "you may have unsaved work in your tabs."
        let quit = alert.addButton(withTitle: "quit")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = "\r"
        alert.addButton(withTitle: "cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "always quit")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.quitWarningVisible = false
            let confirmed = response == .alertFirstButtonReturn || response == .alertThirdButtonReturn
            if response == .alertThirdButtonReturn {
                self.coordinator?.application.preferences.warnBeforeQuitting = false
            }
            if confirmed {
                self.coordinator?.terminating = true
                self.coordinator?.application.persist()
            }
            sender.reply(toApplicationShouldTerminate: confirmed)
        }
        presentQuitAlert(alert, for: sender, completion: finish)
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard LegalAcceptance.shared.isAccepted else {
            LegalAcceptance.shared.showExistingWindow()
            return true
        }
        if !flag { coordinator?.newWindow() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard LegalAcceptance.shared.isAccepted else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        coordinator?.openReceivedURLs(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {

        _ = NSScriptSuiteRegistry.shared()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        LowercaseMenus.install()
        if let coordinator {
            let menus = LoafMainMenus(coordinator: coordinator)
            self.menus = menus
            menus.install()
        }
        NSApp.setActivationPolicy(.regular)
        let onboarding = coordinator?.application.onboardingVisible ?? false
        if !LegalAcceptance.shared.isAccepted {
            coordinator?.application.onboardingVisible = true
            LegalAcceptance.shared.present { [weak self] in
                self?.coordinator?.application.onboardingVisible = onboarding
                self?.finishLaunching()
            }
            return
        }
        finishLaunching()
    }
    private func finishLaunching() {
        SoftwareUpdateManager.shared.startAfterAgreement()
        BrowserScripting.coordinator = coordinator
        NSApp.setActivationPolicy(.regular)
        coordinator?.start()
        NSApp.activate()
        if let application = coordinator?.application { MarketingLaunch.prepareIcons(in: application) }
        let queued = pendingURLs
        pendingURLs.removeAll()
        if !queued.isEmpty { application(NSApp, open: queued) }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown, event.isARepeat,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                    event.charactersIgnoringModifiers?.lowercased() == "s"
                {
                    return true
                }
                if let window = (event.window ?? NSApp.keyWindow) as? LoafBrowserWindow {
                    if window.handlePageKeyboard(event) { return true }
                    if window.handlePointerEscape(event) { return true }
                    if window.handlePageEscape(event) { return true }
                }
                if let state = self?.coordinator?.state(
                    for: event.window ?? (event.type == .flagsChanged ? NSApp.keyWindow : nil)),
                    !state.application.onboardingVisible, state.nativeWindow?.isKeyWindow == true,
                    state.nativeWindow?.attachedSheet == nil,
                    (state.tabSwitcher.handle(event) || WebKitAdapter.handleInspectorChromeKey(event, store: state))
                {
                    return true
                }
                guard event.type == .keyDown else { return false }
                guard let state = self?.coordinator?.state(for: event.window), state.omnibarVisible,
                    !OmnibarTextField.isEditing(in: state.id),
                    event.modifierFlags.intersection([.command, .control]).isEmpty,
                    let characters = event.characters, !characters.isEmpty
                else { return false }
                if event.keyCode == 53 {
                    state.omnibarVisible = false
                    return true
                }
                guard
                    characters.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0) && !((0xF700...0xF8FF).contains($0.value))
                    })
                else { return false }
                if !state.omnibarBufferedInput {
                    state.omnibarQuery = ""
                    state.omnibarBufferedInput = true
                }
                state.omnibarQuery += characters
                return true
            }
            return consumed ? nil : event
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
}

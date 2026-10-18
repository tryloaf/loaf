import AppKit
import Combine
import SwiftUI

#if canImport(Sparkle)
    import Sparkle
#endif

final class UpdateInstallationState: @unchecked Sendable {
    nonisolated static let shared = UpdateInstallationState()
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var value = false

    nonisolated var isInstalling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    nonisolated func begin() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor final class SoftwareUpdateManager: NSObject, ObservableObject {
    static let shared = SoftwareUpdateManager()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published var automaticallyChecksForUpdates =
        UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks")
            if !automaticallyChecksForUpdates { automaticallyInstallsUpdates = false }
            #if canImport(Sparkle)
                if enabled { updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
            #endif
        }
    }
    @Published var automaticallyInstallsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate") {
        didSet {
            guard automaticallyInstallsUpdates != oldValue else { return }
            UserDefaults.standard.set(automaticallyInstallsUpdates, forKey: "SUAutomaticallyUpdate")
            if automaticallyInstallsUpdates { automaticallyChecksForUpdates = true }
            #if canImport(Sparkle)
                if enabled { updater?.automaticallyDownloadsUpdates = automaticallyInstallsUpdates }
            #endif
        }
    }
    private var started = false
    let enabled: Bool
    private let supportsUpdateChecks: Bool
    #if canImport(Sparkle)
        private var updater: SPUUpdater?
        private var userDriver: LoafUpdateUserDriver?
        private var refreshAfterSession: Bool?
        private var observation: AnyCancellable?
        private var settingsObservation: AnyCancellable?
    #endif

    private override init() {
        #if DEBUG
            enabled = false
        #else
            enabled = Bundle.main.bundleIdentifier == "app.tryloaf.loaf"
        #endif
        supportsUpdateChecks = Bundle.main.bundleIdentifier == "app.tryloaf.loaf"
        super.init()
        configureUpdater()
    }

    #if DEBUG
        init(enabledForTesting: Bool, manualChecksForTesting: Bool? = nil) {
            enabled = enabledForTesting
            supportsUpdateChecks = manualChecksForTesting ?? enabledForTesting
            super.init()
            configureUpdater()
        }

        func checkInBackgroundForTesting() {
            #if canImport(Sparkle)
                updater?.checkForUpdatesInBackground()
            #endif
        }
    #endif

    private func configureUpdater() {
        #if canImport(Sparkle)
            guard supportsUpdateChecks else { return }
            clearSkippedUpdates()
            let driver = LoafUpdateUserDriver(hostBundle: .main, delegate: self)
            driver.manager = self
            userDriver = driver
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            self.updater = updater
            if enabled {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
                updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates
                updater.updateCheckInterval = 60 * 60
            }
            settingsObservation = Publishers.CombineLatest(
                updater.publisher(for: \.automaticallyChecksForUpdates),
                updater.publisher(for: \.automaticallyDownloadsUpdates)
            ).receive(on: RunLoop.main).sink { [weak self, weak updater] _, _ in
                guard let self, self.enabled, let updater else { return }
                self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                self.automaticallyInstallsUpdates = updater.automaticallyDownloadsUpdates
            }
            observation = updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.canCheckForUpdates = value }
        #endif
    }

    func startAfterAgreement() {
        #if canImport(Sparkle)
            guard supportsUpdateChecks, !started, LegalAcceptance.shared.isAccepted else { return }
            do {
                try updater?.start()
                started = true
                if enabled, updater?.automaticallyChecksForUpdates == true {
                    updater?.checkForUpdatesInBackground()
                }
            } catch { canCheckForUpdates = false }
        #endif
    }

    private func clearSkippedUpdates() {
        for key in ["SUSkippedVersion", "SUSkippedMinorVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    #if canImport(Sparkle)
        func discovered(_ item: SUAppcastItem) { availableVersion = item.displayVersionString }



        func isSuperseded(_ item: SUAppcastItem) async throws -> Bool {
            guard let feed = updater?.feedURL else { throw URLError(.badURL) }
            var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 4 * 1024 * 1024 else {
                throw URLError(.badServerResponse)
            }
            return try Self.feedHasNewerUpdate(data, than: item.versionString)
        }

        static func feedHasNewerUpdate(_ data: Data, than version: String) throws -> Bool {
            let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            guard let channel = xml.rootElement()?.elements(forName: "channel").first else {
                throw URLError(.cannotParseResponse)
            }
            let comparator = SUStandardVersionComparator.default
            let system = ProcessInfo.processInfo.operatingSystemVersion
            let os = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            return channel.elements(forName: "item").contains { entry in
                func value(_ name: String) -> String? {
                    entry.children?.first { $0.localName == name }?.stringValue
                }
                guard let build = value("version"),
                    comparator.compareVersion(build, toVersion: version) == .orderedDescending,
                    value("channel") == nil || value("channel") == "stable",
                    let enclosure = entry.elements(forName: "enclosure").first,
                    let address = enclosure.attribute(forName: "url")?.stringValue,
                    URL(string: address)?.scheme == "https"
                else { return false }
                if let minimum = value("minimumSystemVersion"),
                    comparator.compareVersion(os, toVersion: minimum) == .orderedAscending { return false }
                if let maximum = value("maximumSystemVersion"),
                    comparator.compareVersion(os, toVersion: maximum) == .orderedDescending { return false }
                return true
            }
        }

        func discardSupersededUpdate(userInitiated: Bool) {
            availableVersion = nil
            refreshAfterSession = userInitiated
        }
    #endif

    private func focusUpdateWindow() {
        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(100))
                guard
                    let window = NSApp.windows.first(where: {
                        $0.isVisible && !($0 is LoafBrowserWindow)
                            && $0.windowController.map {
                                String(reflecting: type(of: $0)).contains("Sparkle")
                                    || Bundle(for: type(of: $0)).bundleIdentifier?.contains("Sparkle") == true
                            } == true
                    })
                else { continue }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    func checkForUpdates() {
        guard supportsUpdateChecks else { return }
        #if canImport(Sparkle)
            startAfterAgreement()
            guard updater?.canCheckForUpdates == true else { return }
            BrowserScripting.coordinator?.prepareForUpdatePresentation()
            if !NSApp.isActive { NSApp.activate() }
            clearSkippedUpdates()
            updater?.checkForUpdates()
            focusUpdateWindow()
        #endif
    }
}

#if canImport(Sparkle)
    extension SoftwareUpdateManager: SPUStandardUserDriverDelegate {
        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
        ) -> Bool { false }
        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            let userInitiated = state.userInitiated
            let version = update.displayVersionString
            Task { @MainActor [weak self] in
                self?.availableVersion = version
                if userInitiated { self?.focusUpdateWindow() }
            }
        }
        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            Task { @MainActor [weak self] in self?.focusUpdateWindow() }
        }
        nonisolated func standardUserDriverWillFinishUpdateSession() {
            Task { @MainActor [weak self] in self?.focusUpdateWindow() }
        }
    }
    extension SoftwareUpdateManager: SPUUpdaterDelegate {
        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            guard enabled || updateCheck == .updates else {
                throw NSError(
                    domain: "loaf.updates", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "development builds only support manual update checks"])
            }
        }
        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
            clearSkippedUpdates()
            guard let userInitiated = refreshAfterSession else { return }
            refreshAfterSession = nil
            Task { @MainActor [weak self] in
                if userInitiated { self?.checkForUpdates() }
                else { self?.updater?.checkForUpdatesInBackground() }
            }
        }
        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
            availableVersion = nil
        }
        nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            UpdateInstallationState.shared.begin()

            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            UpdateInstallationState.shared.begin()
        }
    }
#endif

#if canImport(Sparkle)
    @MainActor final class LoafUpdateUserDriver: SPUStandardUserDriver {
        weak var manager: SoftwareUpdateManager?
        private var offeredItem: SUAppcastItem?

        override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
            reply: @escaping (SPUUserUpdateChoice) -> Void) {

            offeredItem = appcastItem
            manager?.discovered(appcastItem)
            if !state.userInitiated && state.stage == .notDownloaded {
                reply(.dismiss)
                return
            }
            Task { @MainActor [weak self] in
                guard let self, let manager else { reply(.dismiss); return }
                do {
                    if try await manager.isSuperseded(appcastItem) {


                        manager.discardSupersededUpdate(userInitiated: state.userInitiated)
                        reply(.skip)
                        return
                    }
                    self.closeStandardWindows()
                    if !state.userInitiated { reply(.dismiss); return }
                    let choice = prompt(version: appcastItem.displayVersionString,
                        ready: state.stage != .notDownloaded)
                    if choice == .install, try await manager.isSuperseded(appcastItem) {
                        manager.discardSupersededUpdate(userInitiated: state.userInitiated)
                        reply(.skip)
                    } else {
                        reply(choice == .dismiss && state.stage == .installing ? .skip : choice)
                    }
                } catch {
                    self.showFailure(error) { reply(.dismiss) }
                }
            }
        }

        override func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
            do {
                if let offeredItem, let manager, try await manager.isSuperseded(offeredItem) {
                    manager.discardSupersededUpdate(userInitiated: true)
                    return .skip
                }
                closeStandardWindows()
                let choice = prompt(version: manager?.availableVersion ?? "", ready: true)
                return choice == .dismiss ? .skip : choice
            } catch {
                await withCheckedContinuation { continuation in
                    showFailure(error) { continuation.resume() }
                }
                return .skip
            }
        }
        private func closeStandardWindows() { super.dismissUpdateInstallation() }
        private func showFailure(_ error: Error, completion: @escaping () -> Void) {
            super.showUpdaterError(error, acknowledgement: completion)
        }

        private func prompt(version: String, ready: Bool) -> SPUUserUpdateChoice {
            let alert = NSAlert()
            alert.messageText = "loaf \(version) is available"
            alert.informativeText = ready ? "install the update and reopen loaf." : "install the latest update when you’re ready."
            alert.addButton(withTitle: ready ? "install and relaunch" : "install")
            alert.addButton(withTitle: "remind me later")
            let notes = NSHostingView(rootView:
                Link("release notes", destination: URL(string: "https://tryloaf.app/updates")!)
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading))
            notes.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = notes
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn ? .install : .dismiss
        }
    }
#endif

struct SoftwareUpdateReminder: View {
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    var body: some View {
        if let version = updates.availableVersion {
            SoftwareUpdateCard(version: version) {
                updates.checkForUpdates()
            }.disabled(!updates.canCheckForUpdates).padding(.bottom, 8)
        }
    }
}

struct SoftwareUpdateCard: View {
    let version: String
    let review: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: review) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    GolzheimIcon(icon: .download, size: 16, weight: 200)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("update available").font(.system(size: 12, weight: .medium))
                        Text("loaf \(version)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text("review update").font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    GolzheimIcon(icon: .forward, size: 12, weight: 180)
                        .accessibilityHidden(true)
                }.padding(.horizontal, 8).frame(height: 26)
                    .background(
                        Color.primary.opacity(enabled && hovered ? 0.085 : 0.045),
                        in: RoundedRectangle(cornerRadius: 6))
                    .opacity(enabled ? 1 : 0.4)
            }.padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        }.buttonStyle(LoafButtonStyle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .accessibilityLabel("loaf \(version) update available")
            .accessibilityHint("review and install the update")
            .help("review and install the update")
    }
}

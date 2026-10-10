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
                controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            #endif
        }
    }
    @Published var automaticallyInstallsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate") {
        didSet {
            guard automaticallyInstallsUpdates != oldValue else { return }
            UserDefaults.standard.set(automaticallyInstallsUpdates, forKey: "SUAutomaticallyUpdate")
            if automaticallyInstallsUpdates { automaticallyChecksForUpdates = true }
            #if canImport(Sparkle)
                controller?.updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates
            #endif
        }
    }
    private var started = false
    let enabled: Bool
    #if canImport(Sparkle)
        private var controller: SPUStandardUpdaterController?
        private var observation: AnyCancellable?
        private var settingsObservation: AnyCancellable?
    #endif

    private override init() {
        #if DEBUG
            enabled = false
        #else
            enabled = Bundle.main.bundleIdentifier == "app.tryloaf.loaf"
        #endif
        super.init()
        configureUpdater()
    }

    #if DEBUG
        init(enabledForTesting: Bool) {
            enabled = enabledForTesting
            super.init()
            configureUpdater()
        }

        func checkInBackgroundForTesting() {
            #if canImport(Sparkle)
                controller?.updater.checkForUpdatesInBackground()
            #endif
        }
    #endif

    private func configureUpdater() {
        #if canImport(Sparkle)
            guard enabled else { return }
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
            self.controller = controller
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            controller.updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates
            controller.updater.updateCheckInterval = 6 * 60 * 60
            settingsObservation = Publishers.CombineLatest(
                controller.updater.publisher(for: \.automaticallyChecksForUpdates),
                controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            ).receive(on: RunLoop.main).sink { [weak self, weak controller] _, _ in
                guard let self, let updater = controller?.updater else { return }
                self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                self.automaticallyInstallsUpdates = updater.automaticallyDownloadsUpdates
            }
            observation = controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.canCheckForUpdates = value }
        #endif
    }

    func startAfterAgreement() {
        #if canImport(Sparkle)
            guard enabled, !started, LegalAcceptance.shared.isAccepted else { return }
            do {
                try controller?.updater.start()
                started = true
            } catch { canCheckForUpdates = false }
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
            guard enabled, canCheckForUpdates else { return }
            BrowserScripting.coordinator?.prepareForUpdatePresentation()
            if !NSApp.isActive { NSApp.activate() }
            controller?.checkForUpdates(nil)
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
                self?.availableVersion = userInitiated ? nil : version
            }
        }
        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            Task { @MainActor [weak self] in self?.availableVersion = nil }
        }
        nonisolated func standardUserDriverWillFinishUpdateSession() {
            Task { @MainActor [weak self] in self?.availableVersion = nil }
        }
    }
    extension SoftwareUpdateManager: SPUUpdaterDelegate {
        nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            UpdateInstallationState.shared.begin()

            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            UpdateInstallationState.shared.begin()
        }
    }
#endif

struct SoftwareUpdateReminder: View {
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    var body: some View {
        if let version = updates.availableVersion {
            Button {
                updates.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    GolzheimIcon(icon: .download, size: 14)
                    Text("loaf \(version) is available").font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    GolzheimIcon(icon: .forward, size: 12)
                }.padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!updates.canCheckForUpdates)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .help("review and install the update")
        }
    }
}

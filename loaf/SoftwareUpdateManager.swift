import AppKit
import Combine

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
    let enabled: Bool
    #if canImport(Sparkle)
        private var controller: SPUStandardUpdaterController?
        private var observation: AnyCancellable?
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
            observation = controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.canCheckForUpdates = value }
        #endif
    }

    func startAfterAgreement() {
        #if canImport(Sparkle)
            guard enabled, LegalAcceptance.shared.isAccepted else { return }
            do { try controller?.updater.start() } catch { canCheckForUpdates = false }
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
        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            guard handleShowingUpdate else { return }
            let userInitiated = state.userInitiated
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !userInitiated { BrowserScripting.coordinator?.prepareForUpdatePresentation() }
                if !NSApp.isActive { NSApp.activate() }
                if !userInitiated { self.controller?.checkForUpdates(nil) }
            }
        }
    }
    extension SoftwareUpdateManager: SPUUpdaterDelegate {
        nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            UpdateInstallationState.shared.begin()
            // Sparkle's external quit Apple event can be delayed by sandbox/event routing.
            // Its installer connection is resumed before this next-main-loop termination.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
            UpdateInstallationState.shared.begin()
        }
    }
#endif

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
                if enabled { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
            #endif
        }
    }
    @Published var automaticallyInstallsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate") {
        didSet {
            guard automaticallyInstallsUpdates != oldValue else { return }
            UserDefaults.standard.set(automaticallyInstallsUpdates, forKey: "SUAutomaticallyUpdate")
            if automaticallyInstallsUpdates { automaticallyChecksForUpdates = true }
            #if canImport(Sparkle)
                if enabled { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates }
            #endif
        }
    }
    private var started = false
    let enabled: Bool
    private let supportsUpdateChecks: Bool
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
                controller?.updater.checkForUpdatesInBackground()
            #endif
        }
    #endif

    private func configureUpdater() {
        #if canImport(Sparkle)
            guard supportsUpdateChecks else { return }
            let controller = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
            self.controller = controller
            if enabled {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
                controller.updater.automaticallyDownloadsUpdates = automaticallyInstallsUpdates
                controller.updater.updateCheckInterval = 6 * 60 * 60
            }
            settingsObservation = Publishers.CombineLatest(
                controller.updater.publisher(for: \.automaticallyChecksForUpdates),
                controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            ).receive(on: RunLoop.main).sink { [weak self, weak controller] _, _ in
                guard let self, self.enabled, let updater = controller?.updater else { return }
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
            guard supportsUpdateChecks, !started, LegalAcceptance.shared.isAccepted else { return }
            do {
                try controller?.updater.start()
                started = true
            } catch { canCheckForUpdates = false }
        #endif
    }

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
            guard controller?.updater.canCheckForUpdates == true else { return }
            BrowserScripting.coordinator?.prepareForUpdatePresentation()
            if !NSApp.isActive { NSApp.activate() }
            controller?.checkForUpdates(nil)
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

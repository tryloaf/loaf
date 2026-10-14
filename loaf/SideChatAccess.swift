import AppKit
import Combine
import LocalAuthentication
import SwiftUI

@MainActor final class SideChatAccess: ObservableObject {
    @Published private(set) var unlocked = false
    @Published private(set) var authenticating = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var pending: Task<Bool, Never>?
    private var context: LAContext?
    private let authenticate: (() async throws -> Bool)?
    private let onLock: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(authenticate: (() async throws -> Bool)? = nil, onLock: @escaping () -> Void = {}) {
        self.authenticate = authenticate
        self.onLock = onLock
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    func allowsAccess(requiresPassword: Bool) -> Bool { !requiresPassword || unlocked }

    func unlock(requiresPassword: Bool) async -> Bool {
        if allowsAccess(requiresPassword: requiresPassword) { return true }
        if let pending { return await pending.value }
        let token = generation
        authenticating = true
        error = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if generation == token {
                    authenticating = false
                    pending = nil
                    context?.invalidate()
                    context = nil
                }
            }
            do {
                let accepted: Bool
                if let authenticate { accepted = try await authenticate() } else {
                    let context = LAContext()
                    self.context = context
                    accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock side chat in loaf")
                }
                guard accepted, !Task.isCancelled, generation == token else { return false }
                unlocked = true
                return true
            } catch {
                guard generation == token else { return false }
                if let failure = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(failure.code) { return false }
                self.error = "couldn’t unlock side chat. try again."
                return false
            }
        }
        pending = task
        return await task.value
    }
    func lock() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        context?.invalidate()
        context = nil
        authenticating = false
        unlocked = false
        error = nil
        onLock()
    }
}

struct SideChatAccessPanel: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject var access: SideChatAccess
    init(store: BrowserStore, tab: BrowserTab) {
        self.store = store
        self.tab = tab
        access = store.application.sideChatAccess
    }
    var body: some View {
        if tab.isDisposed || tab.store !== store || store.selectedTab !== tab {
            Color.clear.allowsHitTesting(false)
        } else if access.allowsAccess(requiresPassword: store.preferences.requireSideChatPassword == true) {
            if let panel = SideChatPanel(store: store, tab: tab) { panel }
        } else {
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    IconButton(icon: .close, label: "close chat") { store.closeSideChat(tab) }
                }
                Spacer()
                GolzheimIcon(icon: .lock, size: 24)
                Text("side chat is locked").font(.system(size: 13, weight: .medium))
                Button(access.authenticating ? "unlocking…" : "unlock side chat") {
                    Task { _ = await access.unlock(requiresPassword: store.preferences.requireSideChatPassword == true) }
                }.buttonStyle(.borderedProminent).disabled(access.authenticating)
                if let error = access.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.985))
        }
    }
}

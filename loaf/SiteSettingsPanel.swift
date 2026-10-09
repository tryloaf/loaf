import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class SiteSettingsSession {
    private weak var store: BrowserStore?
    let profileID: UUID
    let tabID: UUID?
    let url: URL?
    let origin: String?
    private let navigationID: UUID?
    private var invalidated = false
    init(store: BrowserStore) {
        self.store = store
        profileID = store.selectedProfileID
        tabID = store.selectedTab?.id
        url = store.selectedTab?.url
        origin = url.flatMap(BrowserAddress.websiteOrigin)
        navigationID = store.selectedTab?.navigationID
    }
    var valid: Bool {
        guard !invalidated, let store, store.selectedProfileID == profileID, store.selectedTab?.id == tabID,
            store.selectedTab?.navigationID == navigationID,
            store.application.profiles.contains(where: { $0.id == profileID })
        else { return false }
        return store.selectedTab?.url.flatMap(BrowserAddress.websiteOrigin) == origin
    }
    func invalidate() { invalidated = true }
    var profile: Profile? { store?.application.profiles.first { $0.id == profileID } }
    var tab: BrowserTab? { valid ? store?.selectedTab : nil }
    var settings: SiteSettings {
        origin.flatMap { profile?.siteSettings?[$0] }
            ?? SiteSettings(userAgent: store?.preferences.userAgentMode ?? .desktop)
    }
    func set<Value>(_ key: WritableKeyPath<SiteSettings, Value>, _ value: Value) {
        guard valid, let store, let origin, let url else { return }
        store.updateProfile(profileID) { profile in
            var settings =
                profile.siteSettings?[origin] ?? SiteSettings(userAgent: store.preferences.userAgentMode ?? .desktop)
            settings[keyPath: key] = value
            profile.siteSettings = profile.siteSettings ?? [:]
            profile.siteSettings?[origin] = settings
        }
        tab?.applySiteSettings(url)
        if key == \SiteSettings.pointerLock, let tab { WebKitAdapter.applyPointerLockPolicy(tab) }
    }
    func reset() {
        guard valid, let store, let origin, let url else { return }
        store.updateProfile(profileID) { $0.siteSettings?.removeValue(forKey: origin) }
        tab?.applySiteSettings(url)
        if let tab { WebKitAdapter.applyPointerLockPolicy(tab) }
    }
}

nonisolated enum SitePanelPlacement {
    static func frame(anchor: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, max(0, visible.width - 24))
        let height = min(size.height, max(0, visible.height - 24))
        return CGRect(
            x: min(max(anchor.minX, visible.minX + 12), visible.maxX - width - 12),
            y: min(max(anchor.minY - height - 8, visible.minY + 12), visible.maxY - height - 12), width: width,
            height: height)
    }
}

@MainActor final class SiteSettingsPanelController: NSObject {
    private(set) var panel: NSPanel?
    private(set) var session: SiteSettingsSession?
    private weak var store: BrowserStore?
    private weak var anchor: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var mouseMonitor: Any?
    func synchronize(store: BrowserStore, anchor: NSView, active: Bool) {
        guard active else { return }
        self.anchor = anchor
        if !store.siteSettingsVisible {
            dismiss()
            return
        }
        guard let owner = anchor.window, owner === store.nativeWindow, owner.isVisible else { return }
        if panel != nil {
            if session?.valid != true { dismiss() } else { position() }
            return
        }
        self.store = store
        let session = SiteSettingsSession(store: store)
        self.session = session
        let panel = SitePanel(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: session.origin == nil ? 156 : 480),
            styleMask: [.borderless, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "website settings"
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.dismiss = { [weak self] in self?.dismiss() }
        panel.contentView = NSHostingView(
            rootView: SiteSettingsView(store: store, session: session, close: { [weak self] in self?.dismiss() }))
        self.panel = panel
        owner.addChildWindow(panel, ordered: .above)
        position()
        panel.makeKeyAndOrderFront(nil)
        store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.panel != nil else { return }
                if self.session?.valid != true || self.store?.siteSettingsVisible != true { self.dismiss() }
            }
        }.store(in: &subscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.publisher(for: name, object: owner).sink { [weak self] _ in self?.position() }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: owner).sink { [weak self] _ in
            self?.dismiss()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
            self?.dismiss()
        }.store(in: &subscriptions)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let panel = self.panel, let target = event.window else { return event }
            var ancestor: NSWindow? = target
            while let window = ancestor {
                if window === panel { return event }
                ancestor = window.parent
            }
            if target === self.anchor?.window, let anchor = self.anchor,
                anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
            {
                return event
            }
            self.dismiss()
            return event
        }
    }
    private func position() {
        guard let panel, let anchor, let owner = anchor.window, let screen = owner.screen else { return }
        let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(
            SitePanelPlacement.frame(
                anchor: rect, visible: screen.visibleFrame,
                size: CGSize(width: 340, height: session?.origin == nil ? 156 : 480)), display: true)
    }
    func dismiss() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        subscriptions.removeAll()
        session?.invalidate()
        let old = panel
        panel = nil
        session = nil
        if let old {
            old.parent?.removeChildWindow(old)
            old.orderOut(nil)
            old.contentView = nil
        }
        if store?.siteSettingsVisible == true { store?.siteSettingsVisible = false }
        if let store {
            if store.siteSettingsTrigger == .sidebar && !store.sidebarVisible { store.hoveredSidebar = false }
            store.siteSettingsTrigger = nil
        }
        store = nil
    }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }
    private final class SitePanel: NSPanel {
        var dismiss: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { dismiss?() }
        override func performClose(_ sender: Any?) { dismiss?() }
    }
}

struct SiteSettingsAnchor: NSViewRepresentable {
    enum Source { case toolbar, sidebar }
    @ObservedObject var store: BrowserStore
    var active = true
    var source: Source? = nil
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {

        DispatchQueue.main.async { [weak view, weak store] in
            guard let view, let store else { return }
            let trigger =
                store.siteSettingsTrigger ?? (store.sidebarVisible || store.hoveredSidebar ? .sidebar : .toolbar)
            store.sitePanel.synchronize(
                store: store, anchor: view, active: active && (source == nil || source == trigger))
        }
    }
    final class AnchorView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

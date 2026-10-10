import AppKit
import QuartzCore
import SwiftUI

enum SidebarMotion {
    static let duration = 0.26
    static let snapshotFade = 0.16
    static var pageTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }
}

struct SidebarDock: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        SidebarDockHost(store: store, scheme: scheme, reduceMotion: reduceMotion)
            .frame(width: store.preferences.sidebarWidth + 32)
            .accessibilityHidden(!store.sidebarPresented && !store.hoveredSidebar)
    }
}

struct SidebarDockPane: View {
    @ObservedObject var store: BrowserStore
    var scheme: ColorScheme
    var floating: Bool
    var body: some View {
        SidebarView(store: store, floating: floating)
            .frame(width: store.preferences.sidebarWidth - (floating ? 6 : 0))
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: floating ? 13 : 0, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: floating ? 13 : 0, style: .continuous).strokeBorder(
                    Color.primary.opacity(floating ? 0.12 : 0), lineWidth: 1
                ).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(floating ? 0.18 : 0), radius: 12, x: 3, y: 3)
            .padding(floating ? 3 : 0)
            .environment(\.colorScheme, scheme)
            .ignoresSafeArea()
            .animation(nil, value: store.sidebarPresented)
            .animation(nil, value: store.hoveredSidebar)
            .tint(store.profile.privateMode ? PrivateChrome.accent : Color.accentColor)
            .onHover {
                if !store.sidebarPresented && !$0
                    && !(store.siteSettingsVisible && store.siteSettingsTrigger == .sidebar)
                {
                    store.hoveredSidebar = false
                }
            }
    }
}

struct SidebarDockHost: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    var scheme: ColorScheme
    var reduceMotion: Bool
    private var pane: SidebarDockPane {
        .init(store: store, scheme: scheme, floating: !store.sidebarPresented && store.hoveredSidebar)
    }
    func makeNSView(context: Context) -> ContainerView { ContainerView(pane: pane) }
    func updateNSView(_ view: ContainerView, context: Context) {
        let shown = store.sidebarPresented || store.hoveredSidebar

        if shown { view.floating = !store.sidebarPresented }
        view.hostedSidebar.rootView = .init(store: store, scheme: scheme, floating: view.floating)
        view.configure(
            width: store.preferences.sidebarWidth, shown: shown,
            duration: store.hoveredSidebar ? 0.22 : SidebarMotion.duration, reduceMotion: reduceMotion,
            hiddenOffset: -store.preferences.sidebarWidth - 32)
    }
    static func dismantleNSView(_ view: ContainerView, coordinator: ()) { view.stopMotion() }

    final class ContainerView: NSView {
        let hostedSidebar: NSHostingView<SidebarDockPane>
        private var link: CADisplayLink?
        private var startX: CGFloat = 0
        private var started: CFTimeInterval = 0
        private(set) var motionDuration: CFTimeInterval = SidebarMotion.duration
        private final class TickTarget: NSObject {
            weak var view: ContainerView?
            init(_ view: ContainerView) { self.view = view }
            @objc func update(_ sender: CADisplayLink) {
                if let view { view.tick(sender) } else { sender.invalidate() }
            }
        }
        private var sidebarWidth: CGFloat = 0
        private(set) var shown = true
        private(set) var moving = false
        var floating: Bool
        private var initialized = false
        private var laidOut = false
        private var targetX: CGFloat = 0
        override var isFlipped: Bool { true }
        init(pane: SidebarDockPane) {
            floating = pane.floating
            hostedSidebar = NSHostingView(rootView: pane)
            hostedSidebar.sizingOptions = []
            hostedSidebar.wantsLayer = true
            hostedSidebar.layer?.masksToBounds = !floating
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            addSubview(hostedSidebar)
            registerForDraggedTypes(BrowserDragTypes.links)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(
            width: CGFloat, shown: Bool, duration: Double, reduceMotion: Bool, hiddenOffset: CGFloat
        ) {
            hostedSidebar.layer?.masksToBounds = !floating
            let destination: CGFloat = shown ? 0 : floating ? -width - 32 : hiddenOffset
            let changed = !initialized || self.shown != shown || sidebarWidth != width
            self.shown = shown
            sidebarWidth = width
            hostedSidebar.setAccessibilityHidden(!shown)
            guard changed || reduceMotion && moving else { return }
            initialized = true
            stopMotion()
            targetX = destination
            guard !hostedSidebar.isHidden || shown, laidOut, window != nil, !reduceMotion,
                abs(hostedSidebar.frame.minX - destination) > 0.01
            else {
                position(destination)
                hostedSidebar.isHidden = !shown
                needsLayout = true
                return
            }
            hostedSidebar.isHidden = false
            startX = hostedSidebar.frame.minX
            started = CACurrentMediaTime()
            motionDuration = duration
            moving = true
            let link = displayLink(target: TickTarget(self), selector: #selector(TickTarget.update(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        private func position(_ x: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedSidebar.setFrameOrigin(.init(x: x, y: 0))
            CATransaction.commit()
        }
        private func tick(_ sender: CADisplayLink) {
            let progress = min(1, max(0, (CACurrentMediaTime() - started) / motionDuration))
            let eased = progress * progress * (3 - 2 * progress)
            position(startX + (targetX - startX) * eased)
            if progress >= 1 {
                stopMotion()
                hostedSidebar.isHidden = !shown
            }
        }
        func stopMotion() {
            link?.invalidate()
            link = nil
            moving = false
        }
        deinit { link?.invalidate() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedSidebar.setFrameSize(.init(width: sidebarWidth, height: bounds.height))
            CATransaction.commit()
            if !laidOut {
                position(targetX)
                laidOut = true
            }
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMotion()
                position(targetX)
                hostedSidebar.isHidden = !shown
            }
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            shown && !BrowserDragTypes.urls(sender.draggingPasteboard).isEmpty ? .copy : []
        }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard shown else { return false }
            let urls = BrowserDragTypes.urls(sender.draggingPasteboard)
            for url in urls { _ = hostedSidebar.rootView.store.newTab(url: url, showOmnibar: false) }
            return !urls.isEmpty
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard shown else { return nil }
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }
}

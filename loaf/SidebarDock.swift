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
    var floating: Bool = false
    var body: some View {
        SidebarContentSurface(store: store, floating: floating, scheme: scheme)
            .frame(width: store.preferences.sidebarWidth - (floating ? 6 : 0))
            .fixedSize(horizontal: true, vertical: false)
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
            .tint(store.profile.privateMode ? profileTint(store.profile) : Color.accentColor)
    }
}

struct SidebarContentSurface: NSViewRepresentable {
    let store: BrowserStore
    let floating: Bool
    let scheme: ColorScheme

    struct Content: View {
        let store: BrowserStore
        let floating: Bool
        let scheme: ColorScheme
        var body: some View {
            SidebarView(store: store, floating: floating).environment(\.colorScheme, scheme)
        }
    }

    func makeNSView(context: Context) -> ClipView {
        ClipView(content: .init(store: store, floating: floating, scheme: scheme))
    }
    func updateNSView(_ view: ClipView, context: Context) {
        view.configure(content: .init(store: store, floating: floating, scheme: scheme))
    }

    final class ClipView: NSView {
        let content: NSHostingView<Content>
        override var isFlipped: Bool { true }
        init(content: Content) {
            self.content = NSHostingView(rootView: content)
            self.content.sizingOptions = []
            self.content.safeAreaRegions = []
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerCurve = .continuous
            layer?.cornerRadius = content.floating ? 13 : 0
            addSubview(self.content)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(content value: Content) {
            let previous = content.rootView
            guard
                previous.store !== value.store || previous.floating != value.floating
                    || previous.scheme != value.scheme
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = value.floating ? 13 : 0
            CATransaction.commit()
            content.rootView = value
        }
        override func layout() {
            super.layout()
            if content.frame != bounds { content.frame = bounds }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)) else { return nil }
            return super.hitTest(point)
        }
    }
}

struct SidebarDockHost: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    var scheme: ColorScheme
    var reduceMotion: Bool
    private var pane: SidebarDockPane {
        .init(store: store, scheme: scheme, floating: !store.sidebarPresented)
    }
    func makeNSView(context: Context) -> ContainerView { ContainerView(pane: pane) }
    func updateNSView(_ view: ContainerView, context: Context) {
        let shown = store.sidebarPresented || store.hoveredSidebar

        view.updatePresentation(
            floating: !store.sidebarPresented, shown: shown, reduceMotion: reduceMotion, store: store)
        view.updateScheme(scheme, store: store)
        view.configure(
            width: store.preferences.sidebarWidth, shown: shown,
            duration: store.hoveredSidebar ? 0.22 : SidebarMotion.duration, reduceMotion: reduceMotion,
            hiddenOffset: -store.preferences.sidebarWidth - 32)
    }
    static func dismantleNSView(_ view: ContainerView, coordinator: ()) {
        view.finishPresentation()
        view.stopMotion()
    }

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
        private var scheme: ColorScheme
        private(set) var shown = true
        private(set) var moving = false
        private(set) var floating: Bool
        private var targetFloating: Bool
        private var presentationTask: Task<Void, Never>?
        private var initialized = false
        private var laidOut = false
        private var targetX: CGFloat = 0
        private var hoverArea: NSTrackingArea?
        private var hoverHasPointer = false
        override var isFlipped: Bool { true }
        init(pane: SidebarDockPane) {
            floating = pane.floating
            targetFloating = pane.floating
            scheme = pane.scheme
            hostedSidebar = NSHostingView(rootView: pane)
            hostedSidebar.sizingOptions = []
            hostedSidebar.safeAreaRegions = []
            hostedSidebar.wantsLayer = true
            hostedSidebar.layer?.masksToBounds = true
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            addSubview(hostedSidebar)
            registerForDraggedTypes(BrowserDragTypes.links)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func updatePresentation(floating: Bool, shown: Bool, reduceMotion: Bool, store: BrowserStore) {
            guard shown else {
                presentationTask?.cancel()
                presentationTask = nil
                targetFloating = self.floating
                return
            }
            guard targetFloating != floating || presentationTask != nil && (!shown || reduceMotion) else { return }
            presentationTask?.cancel()
            presentationTask = nil
            targetFloating = floating
            if self.floating, self.shown, !hostedSidebar.isHidden, !floating, shown, !reduceMotion, window != nil {

                presentationTask = Task { @MainActor [weak self, weak store] in
                    do { try await Task.sleep(for: .seconds(SidebarMotion.duration)) } catch { return }
                    guard !Task.isCancelled, let self, let store, !self.targetFloating else { return }
                    self.presentationTask = nil
                    self.floating = false
                    self.updateScheme(self.scheme, store: store)
                    self.updateShape()
                    self.updateHoverTracking()
                }
            } else {
                self.floating = floating
                updateScheme(scheme, store: store)
                updateShape()
            }
        }
        func finishPresentation() {
            presentationTask?.cancel()
            presentationTask = nil
            floating = targetFloating
            updateScheme(scheme, store: hostedSidebar.rootView.store)
            updateShape()
        }
        private func updateShape() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedSidebar.layer?.masksToBounds = true
            hostedSidebar.layer?.cornerRadius = floating ? 16 : 0
            CATransaction.commit()
        }
        func updateScheme(_ value: ColorScheme, store: BrowserStore) {
            guard scheme != value || hostedSidebar.rootView.floating != floating else { return }
            scheme = value
            hostedSidebar.rootView = .init(store: store, scheme: value, floating: floating)
        }
        func configure(
            width: CGFloat, shown: Bool, duration: Double, reduceMotion: Bool, hiddenOffset: CGFloat
        ) {
            updateShape()
            let destination: CGFloat = shown ? 0 : floating ? -width - 32 : hiddenOffset
            let changed = !initialized || self.shown != shown || sidebarWidth != width
            self.shown = shown
            sidebarWidth = width
            updateHoverTracking()
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
            // Tracking can be installed after the pointer has already crossed onto the page.
            // Use the destination bounds while the card moves under the pointer.
            if let window {
                dismissFloatingSidebarIfOutside(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
        func stopMotion() {
            link?.invalidate()
            link = nil
            moving = false
        }
        deinit { link?.invalidate(); presentationTask?.cancel() }
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
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            updateHoverTracking()
        }
        private func updateHoverTracking() {
            let rect = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
            if shown, floating, hoverArea?.rect == rect { return }
            if let hoverArea { removeTrackingArea(hoverArea) }
            hoverArea = nil
            guard shown, floating else {
                hoverHasPointer = false
                return
            }
            if let window, rect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                hoverHasPointer = true
            }

            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeAlways, .assumeInside], owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            dismissFloatingSidebarIfOutside(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        override func mouseExited(with event: NSEvent) {
            guard let window else { return }
            dismissFloatingSidebarIfOutside(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        func dismissFloatingSidebarIfOutside(at point: NSPoint) {
            let store = hostedSidebar.rootView.store
            guard shown, floating, !store.sidebarPresented, store.hoveredSidebar else { return }
            if NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).contains(point) {
                hoverHasPointer = true
                return
            }
            // Download feedback can reveal the card before the pointer has ever entered it.
            guard hoverHasPointer, !(store.siteSettingsVisible && store.siteSettingsTrigger == .sidebar) else { return }
            store.hoveredSidebar = false
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                finishPresentation()
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

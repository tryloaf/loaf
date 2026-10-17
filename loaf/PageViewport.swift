import AppKit
import CoreImage
import WebKit
import QuartzCore
import SwiftUI

struct PageViewport<Content: View>: NSViewRepresentable {
    let leading: CGFloat
    let edge: CGFloat
    let cornerRadius: CGFloat
    let sidebarPresented: Bool
    let reduceMotion: Bool
    var trailing: CGFloat = 0
    var resizeTransition = true
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> Container {
        Container(content: Root(content: content(), environment: environment))
    }
    func updateNSView(_ view: Container, context: Context) {
        view.configure(
            leading: leading, edge: edge, radius: cornerRadius,
            sidebarPresented: sidebarPresented, reduceMotion: reduceMotion, trailing: trailing,
            resizeTransition: resizeTransition)
        view.host.rootView = Root(content: content(), environment: environment)
    }
    static func dismantleNSView(_ view: Container, coordinator: ()) {
        view.surface.layer?.removeAllAnimations()
        view.contentSurface.layer?.removeAllAnimations()
        view.stopMotion()
    }

    struct Root: View {
        let content: Content
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment) }
    }
    final class Container: NSView {
        let host: WebCursorHostingView<Root>
        let surface = NSView()
        let contentSurface = NSView()
        let resizeSnapshot = SnapshotView()
        var resizeSnapshotVisible: Bool { !resizeSnapshot.isHidden }
        final class SnapshotView: NSImageView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        private var snapshotGeneration = UUID()
        private var waitingForSnapshot = false
        private var snapshotTimeout: DispatchWorkItem?
        private var snapshotFade: DispatchWorkItem?
        private var cachedNativeSnapshot: NSImage?
        private var nativeCapture: DispatchWorkItem?

        private var leading: CGFloat = 0
        private var edge: CGFloat = 0
        private var trailing: CGFloat = 0
        private var radius: CGFloat = 0
        private var initialized = false
        private var sidebarPresented = true
        private var animateNextLayout = false
        private var lastLayoutSize: NSSize?
        private var resizeTransition = true
        private var reduceMotion = false
        private var link: CADisplayLink?
        private var motionStart = NSRect.zero
        private var motionTarget = NSRect.zero
        private var motionStartRadius: CGFloat = 0
        private var motionStarted: CFTimeInterval = 0
        private(set) var moving = false
        private final class TickTarget: NSObject {
            weak var view: Container?
            init(_ view: Container) { self.view = view }
            @objc func update(_ sender: CADisplayLink) {
                if let view { view.tick() } else { sender.invalidate() }
            }
        }
        override var isFlipped: Bool { true }

        init(content: Root) {
            host = WebCursorHostingView(rootView: content)
            host.sizingOptions = []
            host.safeAreaRegions = []
            super.init(frame: .zero)
            wantsLayer = true
            surface.wantsLayer = true
            surface.identifier = .init("loaf.page.viewport")
            surface.layer?.masksToBounds = true
            surface.layer?.cornerCurve = .continuous
            contentSurface.wantsLayer = true
            contentSurface.layer?.masksToBounds = true
            contentSurface.addSubview(host)
            surface.addSubview(contentSurface)
            resizeSnapshot.wantsLayer = true
            resizeSnapshot.imageScaling = .scaleAxesIndependently
            resizeSnapshot.isHidden = true
            resizeSnapshot.setAccessibilityHidden(true)
            surface.addSubview(resizeSnapshot)
            addSubview(surface)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            leading: CGFloat, edge: CGFloat, radius: CGFloat,
            sidebarPresented: Bool, reduceMotion: Bool, trailing: CGFloat = 0, resizeTransition: Bool = true
        ) {
            guard
                !initialized || self.leading != leading || self.edge != edge || self.trailing != trailing
                    || self.radius != radius || self.sidebarPresented != sidebarPresented
                    || self.reduceMotion != reduceMotion || self.resizeTransition != resizeTransition
            else { return }
            let changed = initialized && self.sidebarPresented != sidebarPresented
            if changed && resizeTransition && !reduceMotion && window != nil {
                prepareTransitionSnapshot()
            }
            self.leading = leading
            self.edge = edge
            self.trailing = trailing
            self.radius = radius
            self.sidebarPresented = sidebarPresented
            self.resizeTransition = resizeTransition
            self.reduceMotion = reduceMotion
            initialized = true
            if changed { animateNextLayout = !reduceMotion && window != nil }
            if reduceMotion || !resizeTransition {
                cancelCapture()
                stopMotion()
                clearSnapshot()
            }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            if waitingForSnapshot { return }
            let windowResized = lastLayoutSize != bounds.size || window?.inLiveResize == true
            if windowResized { clearSnapshot(); cachedNativeSnapshot = nil }
            lastLayoutSize = bounds.size
            let target = NSRect(
                x: leading, y: edge,
                width: max(0, bounds.width - leading - edge - trailing), height: max(0, bounds.height - 2 * edge))
            let previous = surface.frame
            let previousRadius = surface.layer?.cornerRadius ?? radius
            let animate =
                (animateNextLayout || moving) && !windowResized && !reduceMotion && resizeTransition
                && previous.width > 0 && previous.height > 0 && target != previous
            animateNextLayout = false
            if moving && target == motionTarget && !windowResized { return }
            guard target != surface.frame || surface.layer?.cornerRadius != radius else {
                scheduleNativeCapture()
                return
            }
            stopMotion()
            motionTarget = target
            guard animate, window != nil else {
                applyGeometry(target, radius: radius)
                scheduleNativeCapture()
                return
            }
            motionStart = previous
            motionTarget = target
            motionStartRadius = previousRadius
            motionStarted = CACurrentMediaTime()
            moving = true
            if resizeSnapshotVisible { animateSnapshot() }
            applyGeometry(previous, radius: previousRadius)
            let link = displayLink(target: TickTarget(self), selector: #selector(TickTarget.update(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        private func applyGeometry(_ frame: NSRect, radius: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame = frame
            surface.layer?.cornerRadius = radius
            // The stretched texture carries the animation while WebKit lays out once,
            // at its destination size, underneath it.
            let contentFrame = moving && resizeSnapshotVisible
                ? NSRect(origin: .zero, size: motionTarget.size) : moving
                ? NSRect(origin: .zero, size: NSSize(
                    width: max(motionStart.width, motionTarget.width),
                    height: max(motionStart.height, motionTarget.height))) : surface.bounds
            if contentSurface.frame != contentFrame { contentSurface.frame = contentFrame }
            if host.frame != contentSurface.bounds {
                host.frame = contentSurface.bounds
                host.layoutSubtreeIfNeeded()
            }
            if resizeSnapshot.frame != surface.bounds { resizeSnapshot.frame = surface.bounds }
            CATransaction.commit()
        }
        private func tick() {
            let progress = min(1, max(0, (CACurrentMediaTime() - motionStarted) / SidebarMotion.duration))
            let eased = progress * progress * (3 - 2 * progress)
            func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * eased }
            applyGeometry(
                NSRect(
                    x: mix(motionStart.minX, motionTarget.minX), y: mix(motionStart.minY, motionTarget.minY),
                    width: mix(motionStart.width, motionTarget.width),
                    height: mix(motionStart.height, motionTarget.height)),
                radius: mix(motionStartRadius, radius))
            if progress >= 1 {
                link?.invalidate()
                link = nil
                moving = false
                applyGeometry(motionTarget, radius: radius)
                scheduleNativeCapture()
            }
        }
        func stopMotion() {
            link?.invalidate()
            link = nil
            moving = false
            surface.layer?.removeAllAnimations()
            contentSurface.layer?.removeAllAnimations()
        }
        deinit { link?.invalidate(); nativeCapture?.cancel(); snapshotTimeout?.cancel(); snapshotFade?.cancel() }

        private func webViews() -> [WKWebView] {
            func find(_ root: NSView) -> [WKWebView] {
                if let web = root as? WKWebView { return web.isHiddenOrHasHiddenAncestor ? [] : [web] }
                return root.subviews.flatMap(find)
            }
            return find(host)
        }
        private func scheduleNativeCapture() {
            guard !moving, !waitingForSnapshot, webViews().isEmpty, window?.isVisible == true else { return }
            nativeCapture?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.moving, !self.waitingForSnapshot,
                    self.contentSurface.bounds.width > 0, self.contentSurface.bounds.height > 0,
                    let bitmap = self.contentSurface.bitmapImageRepForCachingDisplay(in: self.contentSurface.bounds)
                else { return }
                self.contentSurface.cacheDisplay(in: self.contentSurface.bounds, to: bitmap)
                let image = NSImage(size: self.contentSurface.bounds.size)
                image.addRepresentation(bitmap)
                self.cachedNativeSnapshot = image
            }
            nativeCapture = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        private func cancelCapture() {
            snapshotGeneration = UUID()
            waitingForSnapshot = false
            snapshotTimeout?.cancel()
            snapshotTimeout = nil
            nativeCapture?.cancel()
            nativeCapture = nil
        }
        private func prepareTransitionSnapshot() {
            if resizeSnapshotVisible { return }
            cancelCapture()
            let pages = webViews()
            if pages.isEmpty {
                if let cachedNativeSnapshot, cachedNativeSnapshot.size == contentSurface.bounds.size {
                    showSnapshot(cachedNativeSnapshot)
                }
                return
            }
            cachedNativeSnapshot = nil
            let generation = snapshotGeneration
            let sourceBounds = contentSurface.bounds
            guard sourceBounds.width > 0, sourceBounds.height > 0 else { return }
            waitingForSnapshot = true
            // Bound capture latency. A slow or hidden WebKit process must never block the sidebar.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.snapshotGeneration == generation else { return }
                self.cancelCapture()
                self.needsLayout = true
            }
            snapshotTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: timeout)
            var pending = pages.count
            var images: [(NSImage, NSRect)] = []
            for page in pages {
                let rect = contentSurface.convert(page.bounds, from: page)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = page.bounds
                configuration.snapshotWidth = NSNumber(value: Double(min(1600, page.bounds.width)))
                configuration.afterScreenUpdates = false
                page.takeSnapshot(with: configuration) { [weak self] image, _ in
                    guard let self, self.snapshotGeneration == generation else { return }
                    if let image { images.append((image, rect)) }
                    pending -= 1
                    guard pending == 0 else { return }
                    self.snapshotTimeout?.cancel()
                    self.snapshotTimeout = nil
                    self.waitingForSnapshot = false
                    if images.count == pages.count {
                        let image = NSImage(size: sourceBounds.size, flipped: true) { bounds in
                            NSColor.windowBackgroundColor.setFill()
                            bounds.fill()
                            for (image, rect) in images {
                                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                            }
                            return true
                        }
                        self.showSnapshot(image)
                    }
                    self.needsLayout = true
                }
            }
        }
        private func showSnapshot(_ image: NSImage) {
            snapshotFade?.cancel()
            resizeSnapshot.layer?.removeAllAnimations()
            resizeSnapshot.image = image
            resizeSnapshot.frame = surface.bounds
            resizeSnapshot.layer?.opacity = 1
            resizeSnapshot.isHidden = false
        }
        private func animateSnapshot() {
            snapshotFade?.cancel()
            guard let filter = CIFilter(name: "CIGaussianBlur"), let layer = resizeSnapshot.layer else { return }
            filter.name = "sidebarResize"
            filter.setValue(0, forKey: kCIInputRadiusKey)
            resizeSnapshot.layerUsesCoreImageFilters = true
            resizeSnapshot.contentFilters = [filter]
            let blur = CAKeyframeAnimation(keyPath: "filters.sidebarResize.inputRadius")
            blur.values = [0, 3, 3, 0]
            blur.keyTimes = [0, 0.2, 0.7, 1]
            blur.duration = SidebarMotion.duration + 0.12
            layer.add(blur, forKey: "sidebarResizeBlur")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + SidebarMotion.duration
            fade.duration = 0.12
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "sidebarSnapshotFade")
            let cleanup = DispatchWorkItem { [weak self] in self?.clearSnapshot() }
            snapshotFade = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.duration + 0.12, execute: cleanup)
        }
        private func clearSnapshot() {
            snapshotFade?.cancel(); snapshotFade = nil
            resizeSnapshot.layer?.removeAllAnimations()
            resizeSnapshot.contentFilters = []
            resizeSnapshot.layerUsesCoreImageFilters = false
            resizeSnapshot.image = nil
            resizeSnapshot.isHidden = true
        }
        override func setFrameSize(_ newSize: NSSize) {
            guard frame.size != newSize else { return }
            super.setFrameSize(newSize)
            needsLayout = true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelCapture(); stopMotion(); clearSnapshot() } else { needsLayout = true }
        }
    }
}

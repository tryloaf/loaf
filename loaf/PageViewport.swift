import AppKit
import CoreImage
import QuartzCore
import SwiftUI
import WebKit

struct PageViewport<Content: View>: NSViewRepresentable {
    let leading: CGFloat
    let edge: CGFloat
    let cornerRadius: CGFloat
    let sidebarPresented: Bool
    let reduceMotion: Bool
    var trailing: CGFloat = 0
    var resizeTransition = true
    var contentID: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> Container {
        Container(content: Root(content: content(), environment: environment))
    }
    func updateNSView(_ view: Container, context: Context) {
        view.replaceContent(ifNeeded: contentID)
        view.configure(
            leading: leading, edge: edge, radius: cornerRadius,
            sidebarPresented: sidebarPresented, reduceMotion: reduceMotion, trailing: trailing,
            resizeTransition: resizeTransition, reduceTransparency: reduceTransparency)
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
        private var snapshotFade: DispatchWorkItem?
        private var cachedNativeSnapshot: NSImage?
        private var liveBlurEnd: DispatchWorkItem?
        private var transitionCapture = false
        private var snapshotAdoption: DispatchWorkItem?
        private var cachedPageURLs: [URL?] = []
        private var contentID: String?
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
        private var motionEnd: DispatchWorkItem?
        private var contentLayout: DispatchWorkItem?
        private var pageObservations: [NSKeyValueObservation] = []
        private var observedPages: [ObjectIdentifier] = []
        private var inputMonitor: Any?
        private var reduceTransparency = false
        private var motionTarget = NSRect.zero
        private var motionSource = NSRect.zero
        private var motionStarted: CFTimeInterval = 0
        private(set) var moving = false
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

        func replaceContent(ifNeeded id: String?) {
            guard contentID != id else { return }
            contentID = id
            stopMotion()
            clearSnapshot()
            invalidateSnapshot()
            needsLayout = true
        }
        func configure(
            leading: CGFloat, edge: CGFloat, radius: CGFloat,
            sidebarPresented: Bool, reduceMotion: Bool, trailing: CGFloat = 0, resizeTransition: Bool = true,
            reduceTransparency: Bool = false
        ) {
            guard
                !initialized || self.leading != leading || self.edge != edge || self.trailing != trailing
                    || self.radius != radius || self.sidebarPresented != sidebarPresented
                    || self.reduceMotion != reduceMotion || self.resizeTransition != resizeTransition
                    || self.reduceTransparency != reduceTransparency
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
            self.reduceTransparency = reduceTransparency
            if reduceTransparency {
                clearLiveBlur()
                resizeSnapshot.layer?.removeAnimation(forKey: "sidebarResizeBlur")
                resizeSnapshot.contentFilters = []
                resizeSnapshot.layerUsesCoreImageFilters = false
            }
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
            observePages()
            let windowResized = lastLayoutSize != bounds.size || window?.inLiveResize == true
            if windowResized {
                clearSnapshot()
                cachedNativeSnapshot = nil
            }
            lastLayoutSize = bounds.size
            let target = NSRect(
                x: leading, y: edge,
                width: max(0, bounds.width - leading - edge - trailing), height: max(0, bounds.height - 2 * edge))
            let presentation = surface.layer?.presentation()


            let previous = presentation?.frame ?? (moving ? motionSource : surface.frame)
            let previousRadius = presentation?.cornerRadius ?? surface.layer?.cornerRadius ?? radius
            let animate =
                (animateNextLayout || moving) && !windowResized && !reduceMotion && resizeTransition
                && previous.width > 0 && previous.height > 0 && target != previous
            animateNextLayout = false
            if moving && target == motionTarget && surface.layer?.cornerRadius == radius && !windowResized { return }
            guard target != surface.frame || surface.layer?.cornerRadius != radius else {
                if !transitionCapture { layoutLiveContent() }
                scheduleNativeCapture()
                return
            }

            let snapshotState = snapshotPresentation()
            let liveBlur = blurPresentation(contentSurface)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stopMotion()
            motionTarget = target
            guard animate, window != nil else {
                applyGeometry(target, radius: radius)
                CATransaction.commit()
                scheduleNativeCapture()
                return
            }
            moving = true
            motionStarted = CACurrentMediaTime()
            motionSource = previous

            applyGeometry(target, radius: radius, deferContent: true)
            if let layer = surface.layer {
                let transform = Self.transitionTransform(from: previous, to: layer.frame, anchor: layer.anchorPoint)
                animateLayer(
                    layer, key: "transform", from: NSValue(caTransform3D: transform),
                    to: NSValue(caTransform3D: CATransform3DIdentity))
            }
            animateLayer(surface.layer, key: "cornerRadius", from: previousRadius, to: radius)
            let needsFreshCover = !resizeSnapshotVisible || snapshotState.opacity < 0.999
            if !needsFreshCover {
                animateSnapshot(from: snapshotState)
            } else {
                animateBlur(on: contentSurface, from: liveBlur)
                let cleanup = DispatchWorkItem { [weak self] in self?.clearLiveBlur() }
                liveBlurEnd = cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.duration + 0.12, execute: cleanup)
            }
            CATransaction.commit()

            CATransaction.flush()
            let layout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.contentLayout = nil



                if !self.transitionCapture { self.layoutLiveContent() }
            }
            contentLayout = layout


            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.duration - 0.06, execute: layout)
            if needsFreshCover {
                transitionCapture = true
                let capture = DispatchWorkItem { [weak self] in self?.captureIdleSnapshot(forTransition: true) }
                nativeCapture = capture
                DispatchQueue.main.async(execute: capture)
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.cancelCapture()
                    self.layoutLiveContent()
                }
                contentLayout?.cancel()
                contentLayout = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: deadline)
            }
            let end = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.moving = false
                self.motionEnd = nil
                self.scheduleNativeCapture()
            }
            motionEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.duration, execute: end)
        }
        static func transitionTransform(from source: CGRect, to destination: CGRect, anchor: CGPoint) -> CATransform3D {
            guard destination.width > 0, destination.height > 0 else { return CATransform3DIdentity }
            var transform = CATransform3DIdentity
            transform.m11 = source.width / destination.width
            transform.m22 = source.height / destination.height
            transform.m41 = source.minX - destination.minX + anchor.x * (source.width - destination.width)
            transform.m42 = source.minY - destination.minY + anchor.y * (source.height - destination.height)
            return transform
        }
        private func animateLayer(_ layer: CALayer?, key: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = SidebarMotion.duration
            animation.timingFunction = SidebarMotion.pageTiming
            layer?.add(animation, forKey: "sidebar." + key)
        }
        private func applyGeometry(_ frame: NSRect, radius: CGFloat, deferContent: Bool = false) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame = frame
            surface.layer?.cornerRadius = radius


            let contentFrame = surface.bounds
            let contentSize = contentSurface.bounds.size
            if contentSurface.frame != contentFrame { contentSurface.frame = contentFrame }
            if deferContent, contentSize.width > 0, contentSize.height > 0 {

                contentSurface.setBoundsSize(contentSize)
            }
            if !deferContent { layoutLiveContent() }
            if resizeSnapshot.frame != surface.bounds { resizeSnapshot.frame = surface.bounds }
            CATransaction.commit()
        }
        private func layoutLiveContent() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if contentSurface.bounds.size != contentSurface.frame.size {
                contentSurface.setBoundsSize(contentSurface.frame.size)
            }
            if host.frame != contentSurface.bounds {
                host.frame = contentSurface.bounds
                host.layoutSubtreeIfNeeded()
            }
            CATransaction.commit()
        }
        func stopMotion() {
            cancelCapture()
            clearLiveBlur()
            contentLayout?.cancel()
            contentLayout = nil
            motionEnd?.cancel()
            motionEnd = nil
            moving = false
            surface.layer?.removeAnimation(forKey: "sidebar.transform")
            surface.layer?.removeAnimation(forKey: "sidebar.cornerRadius")
        }
        deinit {
            snapshotAdoption?.cancel()
            liveBlurEnd?.cancel()
            motionEnd?.cancel()
            contentLayout?.cancel()
            nativeCapture?.cancel()
            snapshotFade?.cancel()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        }

        private func observePages() {
            let pages = webViews()
            let ids = pages.map(ObjectIdentifier.init)
            guard ids != observedPages else { return }
            observedPages = ids
            pageObservations = pages.flatMap { page in
                [
                    page.observe(\.url) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.invalidateSnapshot() }
                    },
                    page.observe(\.isLoading) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.invalidateSnapshot() }
                    },
                ]
            }
            invalidateSnapshot()
        }
        private func invalidateSnapshot() {
            cancelCapture()
            cachedNativeSnapshot = nil
            scheduleNativeCapture()
        }
        private func webViews() -> [WKWebView] {
            func find(_ root: NSView) -> [WKWebView] {
                if let web = root as? WKWebView { return web.isHiddenOrHasHiddenAncestor ? [] : [web] }
                return root.subviews.flatMap(find)
            }
            return find(host)
        }

        private func scheduleNativeCapture() {
            guard !moving, !transitionCapture, !waitingForSnapshot, resizeTransition, !reduceMotion, window?.isVisible == true else {
                return
            }
            if cachedNativeSnapshot?.size == contentSurface.bounds.size, cachedPageURLs == webViews().map(\.url) {
                return
            }
            nativeCapture?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.moving, self.window?.isVisible == true,
                    self.contentSurface.bounds.width > 0, self.contentSurface.bounds.height > 0
                else { return }
                self.captureIdleSnapshot()
            }
            nativeCapture = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
        private func cancelCapture() {
            transitionCapture = false
            snapshotAdoption?.cancel()
            snapshotAdoption = nil
            snapshotGeneration = UUID()
            waitingForSnapshot = false
            nativeCapture?.cancel()
            nativeCapture = nil
        }
        private func prepareTransitionSnapshot() {
            cancelCapture()
            let pages = webViews()
            guard !moving, !resizeSnapshotVisible, let image = cachedNativeSnapshot,
                image.size == contentSurface.bounds.size, observedPages == pages.map(ObjectIdentifier.init),
                cachedPageURLs == pages.map(\.url), !pages.contains(where: \.isLoading)
            else { return }
            showSnapshot(image)
        }
        private func captureIdleSnapshot(forTransition: Bool = false) {


            observePages()
            nativeCapture?.cancel()
            nativeCapture = nil
            guard (forTransition || !moving), !waitingForSnapshot else { return }
            let pages = webViews()
            guard !pages.contains(where: \.isLoading) else { return }
            if pages.isEmpty {
                guard let bitmap = contentSurface.bitmapImageRepForCachingDisplay(in: contentSurface.bounds) else {
                    return
                }
                contentSurface.cacheDisplay(in: contentSurface.bounds, to: bitmap)
                let image = NSImage(size: contentSurface.bounds.size)
                image.addRepresentation(bitmap)
                cachedNativeSnapshot = image
                cachedPageURLs = []
                if forTransition { adoptTransitionSnapshot(image) }
                return
            }

            var nativeImage: NSImage?
            if let bitmap = contentSurface.bitmapImageRepForCachingDisplay(in: contentSurface.bounds) {
                contentSurface.cacheDisplay(in: contentSurface.bounds, to: bitmap)
                let image = NSImage(size: contentSurface.bounds.size)
                image.addRepresentation(bitmap)
                nativeImage = image
            }
            let generation = snapshotGeneration
            let sourceBounds = contentSurface.bounds
            let urls = pages.map(\.url)
            waitingForSnapshot = true
            var pending = pages.count
            var images: [(NSImage, NSRect)] = []
            for page in pages {
                let pageFrame = contentSurface.convert(page.bounds, from: page)

                let rect = NSRect(
                    x: pageFrame.minX - sourceBounds.minX,
                    y: contentSurface.isFlipped
                        ? pageFrame.minY - sourceBounds.minY : sourceBounds.maxY - pageFrame.maxY,
                    width: pageFrame.width, height: pageFrame.height)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = page.bounds
                configuration.snapshotWidth = NSNumber(value: Double(min(1600, page.bounds.width)))
                configuration.afterScreenUpdates = false
                page.takeSnapshot(with: configuration) { [weak self] image, _ in
                    guard let self, self.snapshotGeneration == generation else { return }
                    if let image { images.append((image, rect)) }
                    pending -= 1
                    guard pending == 0 else { return }
                    self.waitingForSnapshot = false
                    guard (forTransition || !self.moving), self.contentSurface.bounds == sourceBounds, images.count == pages.count else {
                        return
                    }
                    guard self.webViews().map(\.url) == urls else { return }
                    self.cachedPageURLs = urls
                    let composite = NSImage(size: sourceBounds.size, flipped: true) { bounds in
                        NSColor.windowBackgroundColor.setFill()
                        bounds.fill()
                        nativeImage?.draw(
                            in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                            hints: nil)
                        for (image, rect) in images {
                            image.draw(
                                in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                        }
                        return true
                    }

                    if let pixels = composite.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        self.cachedNativeSnapshot = NSImage(cgImage: pixels, size: sourceBounds.size)
                    } else {
                        self.cachedNativeSnapshot = composite
                    }
                    if forTransition, let image = self.cachedNativeSnapshot { self.adoptTransitionSnapshot(image) }
                }
            }
        }
        private func adoptTransitionSnapshot(_ image: NSImage) {
            guard transitionCapture else { return }
            if resizeSnapshotVisible {

                let adoption = DispatchWorkItem { [weak self] in self?.adoptTransitionSnapshot(image) }
                snapshotAdoption = adoption
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: adoption)
                return
            }
            transitionCapture = false
            snapshotAdoption = nil
            contentLayout?.cancel()
            contentLayout = nil
            let blur = blurPresentation(contentSurface)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            showSnapshot(image)
            animateSnapshot(from: (1, blur))
            CATransaction.commit()

            CATransaction.flush()
            let layout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.contentLayout = nil
                self.clearLiveBlur()
                self.layoutLiveContent()
            }
            contentLayout = layout
            let delay = max(0.06, SidebarMotion.duration - 0.06 - (CACurrentMediaTime() - motionStarted))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: layout)
        }
        private func showSnapshot(_ image: NSImage) {
            snapshotFade?.cancel()
            resizeSnapshot.layer?.removeAllAnimations()
            resizeSnapshot.image = image
            resizeSnapshot.frame = surface.bounds
            resizeSnapshot.layer?.opacity = 1
            resizeSnapshot.isHidden = false
        }
        private func snapshotPresentation() -> (opacity: Float, blur: Double) {
            guard let layer = resizeSnapshot.layer else { return (1, 0) }
            let visible = layer.presentation()
            let opacity = layer.animation(forKey: "sidebarSnapshotFade") == nil
                ? layer.opacity : (visible?.opacity ?? layer.opacity)
            return (opacity, blurPresentation(resizeSnapshot))
        }
        private func blurPresentation(_ view: NSView) -> Double {
            (view.layer?.presentation()?.value(forKeyPath: "filters.sidebarResize.inputRadius") as? NSNumber)?.doubleValue ?? 0
        }
        private func animateBlur(on view: NSView, from radius: Double) {
            guard !reduceTransparency, let layer = view.layer else { return }
            if view.contentFilters.isEmpty, let filter = CIFilter(name: "CIGaussianBlur") {
                filter.name = "sidebarResize"
                filter.setValue(0, forKey: kCIInputRadiusKey)
                view.layerUsesCoreImageFilters = true
                view.contentFilters = [filter]
            }
            let blur = CAKeyframeAnimation(keyPath: "filters.sidebarResize.inputRadius")
            blur.values = [radius, 3, 3, 0]
            blur.keyTimes = [0, 0.2, 0.7, 1]
            blur.duration = SidebarMotion.duration + 0.12
            layer.add(blur, forKey: "sidebarResizeBlur")
        }
        private func clearLiveBlur() {
            liveBlurEnd?.cancel()
            liveBlurEnd = nil
            contentSurface.layer?.removeAnimation(forKey: "sidebarResizeBlur")
            contentSurface.contentFilters = []
            contentSurface.layerUsesCoreImageFilters = false
        }
        private func animateSnapshot(from state: (opacity: Float, blur: Double)) {
            snapshotFade?.cancel()
            guard let layer = resizeSnapshot.layer else { return }
            layer.removeAnimation(forKey: "sidebarSnapshotFade")
            layer.opacity = 1
            animateBlur(on: resizeSnapshot, from: state.blur)


            let fade = CAKeyframeAnimation(keyPath: "opacity")
            let total = SidebarMotion.duration + 0.12
            fade.values = [state.opacity, 1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: 0.06 / total), NSNumber(value: SidebarMotion.duration / total), 1]
            fade.duration = total
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "sidebarSnapshotFade")
            let cleanup = DispatchWorkItem { [weak self] in self?.clearSnapshot() }
            snapshotFade = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.duration + 0.12, execute: cleanup)
        }
        private func clearSnapshot() {
            snapshotFade?.cancel()
            snapshotFade = nil
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
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            if window == nil {
                cancelCapture()
                stopMotion()
                clearSnapshot()
            } else {
                inputMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [
                        .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                        .rightMouseDown, .rightMouseUp, .keyDown, .keyUp, .magnify, .smartMagnify,
                    ]
                ) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window, event.window === window else { return }
                        if event.type == .keyDown || event.type == .keyUp {
                            guard !event.modifierFlags.contains(.command),
                                let responder = window.firstResponder as? NSView,
                                responder === self.host || responder.isDescendant(of: self.host)
                            else { return }
                        } else {
                            let point = self.contentSurface.convert(event.locationInWindow, from: nil)
                            guard self.contentSurface.bounds.contains(point) else { return }
                        }
                        self.invalidateSnapshot()
                    }
                    return event
                }
                needsLayout = true
            }
        }
    }
}

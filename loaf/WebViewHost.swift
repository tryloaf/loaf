import AppKit
import CoreImage
import SwiftUI
import WebKit

struct WebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    var topInset: CGFloat = 0
    var sidebarVisible = true
    var viewportSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    final class HostView: NSView {
        final class ResizeImageView: NSView {
            private nonisolated static let blurContext = CIContext(options: [.cacheIntermediates: false])
            private nonisolated static let blurQueue = DispatchQueue(
                label: "app.tryloaf.loaf.resize-snapshot", qos: .userInteractive)
            nonisolated static func blur(_ image: CGImage, sourceWidth: CGFloat) -> CGImage {
                let input = CIImage(cgImage: image)
                let radius = 3 * CGFloat(image.width) / max(1, sourceWidth)
                let blurred = input.clampedToExtent().applyingFilter(
                    "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]
                ).cropped(to: input.extent)
                return blurContext.createCGImage(
                    blurred, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    ?? image
            }
            static func prepare(
                _ image: CGImage, sourceWidth: CGFloat, completion: @escaping @MainActor @Sendable (CGImage) -> Void
            ) {
                blurQueue.async {
                    let texture = blur(image, sourceWidth: sourceWidth)
                    DispatchQueue.main.async { completion(texture) }
                }
            }
            let imageLayer = CALayer()
            let sourceSize: CGSize
            private(set) var topInset: CGFloat = 0
            init(image: CGImage, sourceSize: CGSize, frame: NSRect, background: CGColor) {
                self.sourceSize = sourceSize
                super.init(frame: frame)
                wantsLayer = true
                layerContentsRedrawPolicy = .never
                layer?.backgroundColor = background
                layer?.masksToBounds = true

                imageLayer.contents = image
                imageLayer.contentsGravity = .resize
                layer?.addSublayer(imageLayer)
                update(frame: frame, contentHeight: frame.height)
                setAccessibilityElement(false)
            }
            func update(frame: NSRect, contentHeight: CGFloat) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.frame = frame
                let height = min(bounds.height, max(0, contentHeight))
                topInset = bounds.height - height

                imageLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
                CATransaction.commit()
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)

            let inset = max(fallbackInset, configuredInset ?? requestedInset)
            if inset > 0, bounds.contains(local), local.y >= bounds.maxY - inset { return nil }
            return super.hitTest(point)
        }
        weak var hostedWebView: WKWebView?
        var fallbackInset: CGFloat = 0
        var configuredInset: CGFloat?
        var requestedInset: CGFloat = 0
        var viewportSize: CGSize?
        var configuredSidebar: Bool?
        var configuredNavigation: UUID?
        var wasInFullscreen = false
        func restoreAfterFullscreen() {
            configuredInset = nil
            previousBounds = nil
            pendingResize?.cancel()
            pendingResize = nil
            applyChromeInset()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        var reduceMotion = false
        var transitionEnabled = true
        private var resizeImage: ResizeImageView?
        private var snapshotEnd: DispatchWorkItem?
        private var snapshotGeneration = 0
        private var snapshotDeadline = 0.0
        private var snapshotPending = false
        private var snapshotPrepared = false
        private var snapshotReady: (() -> Void)?
        private var skipNextSnapshot = false
        private var snapshotPaintReady = false
        private var snapshotPaintRequested = false
        private var snapshotStartSize = CGSize.zero
        private var snapshotStartInset: CGFloat = 0
        var resizeSnapshotVisible: Bool { resizeImage != nil }
        var preparingResizeSnapshot: Bool { snapshotPending || snapshotPrepared }
        private var targetFrame = NSRect.zero
        private var previousBounds: NSRect?
        private var resizeEnd: DispatchWorkItem?
        private var pendingResize: DispatchWorkItem?
        private var lastResize = 0.0
        private(set) var resizing = false
        private(set) var resizeCommits = 0
        func applyChromeInset() {
            guard !snapshotPending, !snapshotPrepared, configuredInset != requestedInset,
                let webView = hostedWebView, webView.fullscreenState == .notInFullscreen
            else { return }
            configuredInset = requestedInset
            fallbackInset = WebKitAdapter.setChromeInset(webView, height: requestedInset) ? 0 : requestedInset
            needsLayout = true
        }
        func cancelResizeSnapshot() {
            let wasActive = snapshotPending || resizeImage != nil
            let ready = snapshotReady
            snapshotReady = nil
            snapshotGeneration += 1
            snapshotEnd?.cancel()
            snapshotEnd = nil
            snapshotPending = false
            snapshotPrepared = false
            snapshotPaintReady = false
            snapshotPaintRequested = false
            resizeImage?.removeFromSuperview()
            resizeImage = nil
            if wasActive {
                resizing = false
                applyChromeInset()

                targetFrame = pageFrame(for: bounds.size)
                apply(targetFrame)
                previousBounds = bounds
                needsLayout = true
            }
            if let ready {
                skipNextSnapshot = true
                ready()
            }
        }
        func beginResizeSnapshot(onReady: (() -> Void)? = nil) {
            snapshotReady = onReady
            snapshotPrepared = false
            skipNextSnapshot = false
            guard transitionEnabled, !reduceMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                let webView = hostedWebView, webView.window != nil,
                webView.fullscreenState == .notInFullscreen, webView.superview === self,
                !WebKitAdapter.inspectorIsDocked(webView), webView.bounds.width > 0, webView.bounds.height > 0
            else {
                cancelResizeSnapshot()
                return
            }
            snapshotGeneration += 1
            let generation = snapshotGeneration
            snapshotDeadline = ProcessInfo.processInfo.systemUptime + 0.26
            snapshotEnd?.cancel()
            resizeEnd?.cancel()
            pendingResize?.cancel()
            pendingResize = nil
            snapshotPaintReady = false
            snapshotPaintRequested = false

            snapshotStartSize =
                resizeImage?.frame.size
                ?? CGSize(width: webView.bounds.width, height: webView.bounds.height + fallbackInset)
            snapshotStartInset = resizeImage?.topInset ?? (configuredInset ?? 0)

            if let resizeImage {
                resizeImage.layer?.removeAllAnimations()
                resizeImage.alphaValue = 1
                completeSnapshotPreparation()
                needsLayout = true
                return
            }

            snapshotPending = true
            let config = WKSnapshotConfiguration()
            let inset = fallbackInset == 0 ? min(webView.bounds.height, configuredInset ?? 0) : 0
            let sourceSize = CGSize(width: webView.bounds.width, height: max(0, webView.bounds.height - inset))
            config.rect = CGRect(
                x: 0, y: webView.isFlipped ? inset : 0, width: sourceSize.width, height: sourceSize.height)
            config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1200)))
            config.afterScreenUpdates = false
            webView.takeSnapshot(with: config) { [weak self, weak webView] image, _ in
                guard let self, let webView, self.snapshotGeneration == generation else { return }
                guard self.hostedWebView === webView, webView.superview === self,
                    webView.window != nil, webView.fullscreenState == .notInFullscreen,
                    !WebKitAdapter.inspectorIsDocked(webView),
                    ProcessInfo.processInfo.systemUptime < self.snapshotDeadline,
                    let image, let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else {
                    self.cancelResizeSnapshot()
                    return
                }
                ResizeImageView.prepare(pixels, sourceWidth: sourceSize.width) { [weak self, weak webView] texture in
                    guard let self, let webView, self.snapshotGeneration == generation else { return }
                    guard webView.superview === self, webView.window != nil,
                        webView.fullscreenState == .notInFullscreen, !WebKitAdapter.inspectorIsDocked(webView),
                        ProcessInfo.processInfo.systemUptime < self.snapshotDeadline
                    else {
                        self.cancelResizeSnapshot()
                        return
                    }
                    let overlay = ResizeImageView(
                        image: texture, sourceSize: sourceSize, frame: self.bounds,
                        background: webView.underPageBackgroundColor.cgColor)
                    self.addSubview(overlay, positioned: .above, relativeTo: webView)
                    self.resizeImage = overlay
                    self.snapshotPending = false
                    self.completeSnapshotPreparation()
                    if !self.snapshotPrepared { self.applyChromeInset() }
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
            }
            scheduleSnapshotEnd()
        }
        private func completeSnapshotPreparation() {
            if let ready = snapshotReady {
                snapshotReady = nil
                snapshotPrepared = true
                snapshotEnd?.cancel()
                snapshotEnd = nil
                ready()
            } else {
                scheduleSnapshotEnd()
            }
        }
        func startPreparedResize() {
            snapshotPrepared = false
            snapshotDeadline = ProcessInfo.processInfo.systemUptime + 0.26
            snapshotPaintReady = false
            snapshotPaintRequested = false
            scheduleSnapshotEnd()
        }
        func sidebarDidChange() {
            if snapshotPrepared {
                startPreparedResize()
            } else if skipNextSnapshot {
                skipNextSnapshot = false
            } else {
                beginResizeSnapshot()
            }
        }
        private func pageFrame(for size: CGSize) -> NSRect {
            let scale = window?.backingScaleFactor ?? 1
            return NSRect(
                x: 0, y: isFlipped ? fallbackInset : 0,
                width: ceil(size.width * scale) / scale,
                height: ceil(max(0, size.height - fallbackInset) * scale) / scale)
        }
        private func updateResizeImage() {
            guard let resizeImage else { return }
            let destination = viewportSize ?? bounds.size
            let widthChange = destination.width - snapshotStartSize.width
            let heightChange = destination.height - snapshotStartSize.height
            let progress: CGFloat
            if abs(widthChange) > 0.5 {
                progress = (bounds.width - snapshotStartSize.width) / widthChange
            } else if abs(heightChange) > 0.5 {
                progress = (bounds.height - snapshotStartSize.height) / heightChange
            } else {
                progress = 1
            }
            let startHeight = max(0, snapshotStartSize.height - snapshotStartInset)
            let endHeight = max(0, destination.height - requestedInset)
            let height = startHeight + (endHeight - startHeight) * min(1, max(0, progress))
            resizeImage.update(frame: bounds, contentHeight: height)
        }
        private func waitForSnapshotPaint(_ webView: WKWebView, frame: NSRect) {
            snapshotPaintRequested = true
            snapshotPaintReady = false
            let generation = snapshotGeneration
            webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;",
                arguments: [:], in: nil, in: .defaultClient
            ) { [weak self, weak webView] result in
                guard case .success = result, let self, let webView, self.snapshotGeneration == generation,
                    self.hostedWebView === webView, webView.frame == frame
                else { return }
                self.snapshotPaintReady = true
            }
        }
        private func scheduleSnapshotEnd(delay: TimeInterval? = nil) {
            snapshotEnd?.cancel()
            let generation = snapshotGeneration
            let delay = delay ?? max(0, snapshotDeadline - ProcessInfo.processInfo.systemUptime)
            let end = DispatchWorkItem { [weak self] in
                guard let self, self.snapshotGeneration == generation else { return }
                guard let overlay = self.resizeImage else {
                    self.cancelResizeSnapshot()
                    return
                }
                self.layoutSubtreeIfNeeded()
                let actualFrame = self.pageFrame(for: self.bounds.size)
                let matches =
                    abs(actualFrame.width - self.targetFrame.width) <= 0.5
                    && abs(actualFrame.height - self.targetFrame.height) <= 0.5
                if (!matches || !self.snapshotPaintReady),
                    ProcessInfo.processInfo.systemUptime < self.snapshotDeadline + 0.12
                {
                    self.scheduleSnapshotEnd(delay: 1.0 / 60)
                    return
                }

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    overlay.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self, self.snapshotGeneration == generation else { return }
                    self.cancelResizeSnapshot()
                }
            }
            snapshotEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: end)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { cancelResizeSnapshot() }
        }
        override func setFrameSize(_ newSize: NSSize) {
            guard frame.size != newSize else { return }
            super.setFrameSize(newSize)
            needsLayout = true
        }
        override func setBoundsSize(_ newSize: NSSize) {
            guard bounds.size != newSize else { return }
            super.setBoundsSize(newSize)
            needsLayout = true
        }
        private func apply(_ frame: NSRect) {
            guard let webView = hostedWebView, webView.fullscreenState == .notInFullscreen,
                webView.superview === self, !WebKitAdapter.inspectorIsDocked(webView), webView.frame != frame
            else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = frame
            CATransaction.commit()
            resizeCommits += 1
            lastResize = ProcessInfo.processInfo.systemUptime
        }
        private func finishResize() {
            guard !snapshotPending, !snapshotPrepared, resizeImage == nil else { return }
            pendingResize?.cancel()
            pendingResize = nil
            apply(targetFrame)
            resizing = false
        }
        override func layout() {
            super.layout()

            let inheritedTop = safeAreaInsets.top - additionalSafeAreaInsets.top
            let extraTop = max(0, (configuredInset ?? 0) - inheritedTop)
            if additionalSafeAreaInsets.top != extraTop { additionalSafeAreaInsets.top = extraTop }
            guard let webView = hostedWebView, webView.fullscreenState == .notInFullscreen, webView.superview === self
            else {
                cancelResizeSnapshot()
                return
            }

            guard !WebKitAdapter.inspectorIsDocked(webView) else {
                cancelResizeSnapshot()
                return
            }
            updateResizeImage()
            if snapshotPending || snapshotPrepared { return }
            if resizeImage != nil {
                let frame = pageFrame(for: viewportSize ?? bounds.size)
                let changed = targetFrame != frame
                targetFrame = frame
                apply(frame)
                resizing = true
                if changed || !snapshotPaintRequested { waitForSnapshotPaint(webView, frame: frame) }
                return
            }
            let frame = pageFrame(for: bounds.size)
            if window?.inLiveResize == true {
                pendingResize?.cancel()
                pendingResize = nil
                resizeEnd?.cancel()
                targetFrame = frame
                previousBounds = bounds
                resizing = false
                apply(frame)
                return
            }
            guard frame != targetFrame || previousBounds == nil || webView.frame != frame else { return }
            targetFrame = frame
            if previousBounds == nil {
                previousBounds = bounds
                apply(frame)
                return
            }
            previousBounds = bounds
            if reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                cancelResizeSnapshot()
                resizeEnd?.cancel()
                pendingResize?.cancel()
                pendingResize = nil
                webView.layer?.removeAnimation(forKey: "loaf.resize.bounds")
                webView.layer?.removeAnimation(forKey: "loaf.resize.position")
                resizing = false
                apply(frame)
                return
            }
            if !resizing {
                resizing = true
                wantsLayer = true
            }
            layer?.backgroundColor = webView.underPageBackgroundColor.cgColor
            resizeEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.finishResize() }
            resizeEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: end)
            let elapsed = ProcessInfo.processInfo.systemUptime - lastResize
            if elapsed >= 1.0 / 60 {
                apply(frame)
            } else if pendingResize == nil {
                let pending = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingResize = nil
                    self.apply(self.targetFrame)
                }
                pendingResize = pending
                DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60 - elapsed), execute: pending)
            }
        }
    }
    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        attach(to: host)
        return host
    }
    func updateNSView(_ host: HostView, context: Context) {
        guard !tab.isDisposed else {
            host.cancelResizeSnapshot()
            return
        }
        guard tab.webView.fullscreenState == .notInFullscreen else {
            host.wasInFullscreen = true
            host.cancelResizeSnapshot()
            return
        }
        configure(host)
        if host.wasInFullscreen {
            host.wasInFullscreen = false
            host.restoreAfterFullscreen()
        }

        if host.hostedWebView !== tab.webView || !tab.webView.isDescendant(of: host) { attach(to: host) }
    }
    private func attach(to host: HostView) {
        guard !tab.isDisposed else { return }
        guard tab.webView.fullscreenState == .notInFullscreen else { return }
        host.cancelResizeSnapshot()
        if let old = host.hostedWebView, old !== tab.webView, WebKitAdapter.inspectorIsDocked(old) {
            WebKitAdapter.closeInspector(old)
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        let view = tab.webView
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = host.bounds
        view.autoresizingMask = []
        host.addSubview(view)
        host.hostedWebView = view
        configure(host)
    }
    static func dismantleNSView(_ host: HostView, coordinator: ()) {
        host.cancelResizeSnapshot()
        if let view = host.hostedWebView, view.fullscreenState == .notInFullscreen,
            WebKitAdapter.inspectorIsDocked(view)
        {
            WebKitAdapter.closeInspector(view)
        }
    }
    private func configure(_ host: HostView) {
        let geometryChanged =
            host.viewportSize != viewportSize || host.configuredSidebar != sidebarVisible
            || host.requestedInset != topInset || host.configuredNavigation != tab.navigationID
        host.reduceMotion = reduceMotion
        host.transitionEnabled = tab.store?.preferences.resizeTransition != false
        if reduceMotion || host.configuredNavigation != tab.navigationID { host.cancelResizeSnapshot() }
        host.configuredNavigation = tab.navigationID
        host.viewportSize = viewportSize
        if let previous = host.configuredSidebar, previous != sidebarVisible { host.sidebarDidChange() }
        host.configuredSidebar = sidebarVisible
        host.requestedInset = topInset
        host.applyChromeInset()
        if geometryChanged { host.needsLayout = true }
    }
}

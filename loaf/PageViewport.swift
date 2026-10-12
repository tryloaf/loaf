import AppKit
import CoreImage
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
        view.host.rootView = Root(content: content(), environment: environment)
        view.configure(
            leading: leading, edge: edge, radius: cornerRadius,
            sidebarPresented: sidebarPresented, reduceMotion: reduceMotion, trailing: trailing,
            resizeTransition: resizeTransition)
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
        let host: NSHostingView<Root>
        let surface = NSView()
        let contentSurface = NSView()
        private var leading: CGFloat = 0
        private var edge: CGFloat = 0
        private var trailing: CGFloat = 0
        private var radius: CGFloat = 0
        private var initialized = false
        private var sidebarPresented = true
        private var animateNextLayout = false
        private var sidebarResizePending = false
        private var lastLayoutSize: NSSize?
        private var resizeTransition = true
        private var reduceMotion = false
        private var blurEnd: DispatchWorkItem?
        override var isFlipped: Bool { true }

        init(content: Root) {
            host = NSHostingView(rootView: content)
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
            addSubview(surface)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            leading: CGFloat, edge: CGFloat, radius: CGFloat,
            sidebarPresented: Bool, reduceMotion: Bool, trailing: CGFloat = 0, resizeTransition: Bool = true
        ) {
            let changed = initialized && self.sidebarPresented != sidebarPresented
            sidebarResizePending = sidebarResizePending || initialized && (changed || self.leading != leading)
            self.leading = leading
            self.edge = edge
            self.trailing = trailing
            self.radius = radius
            self.sidebarPresented = sidebarPresented
            self.resizeTransition = resizeTransition
            self.reduceMotion = reduceMotion
            initialized = true
            if changed { animateNextLayout = !reduceMotion && window != nil }
            if reduceMotion { stopMotion() }
            if !resizeTransition { clearResizeBlur() }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let windowResized = lastLayoutSize != bounds.size || window?.inLiveResize == true
            let soften = sidebarResizePending && !windowResized && resizeTransition && !reduceMotion
            sidebarResizePending = false
            lastLayoutSize = bounds.size
            if windowResized { clearResizeBlur() }
            let target = NSRect(
                x: leading, y: edge,
                width: max(0, bounds.width - leading - edge - trailing), height: max(0, bounds.height - 2 * edge))
            let previous = surface.layer?.presentation()?.frame ?? surface.frame
            let previousRadius = surface.layer?.presentation()?.cornerRadius ?? surface.layer?.cornerRadius ?? radius
            let animate = animateNextLayout && previous.width > 0 && previous.height > 0 && target != surface.frame
            animateNextLayout = false
            guard target != surface.frame || surface.layer?.cornerRadius != radius else { return }
            stopMotion()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame = target
            surface.layer?.cornerRadius = radius
            contentSurface.frame = surface.bounds
            host.frame = contentSurface.bounds
            host.layoutSubtreeIfNeeded()
            CATransaction.commit()
            if soften, window != nil { beginResizeBlur(duration: animate ? SidebarMotion.duration : 0.18) }
            guard animate, let layer = surface.layer else { return }
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = CGPoint(
                x: previous.minX + layer.anchorPoint.x * previous.width,
                y: previous.minY + layer.anchorPoint.y * previous.height)
            position.toValue = layer.position
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = CGRect(origin: layer.bounds.origin, size: previous.size)
            bounds.toValue = layer.bounds
            let contentScale = CABasicAnimation(keyPath: "transform")
            contentScale.fromValue = CATransform3DMakeScale(
                previous.width / max(1, target.width), previous.height / max(1, target.height), 1)
            contentScale.toValue = CATransform3DIdentity
            let contentPosition = CABasicAnimation(keyPath: "position")
            if let contentLayer = contentSurface.layer {
                contentPosition.fromValue = CGPoint(
                    x: contentLayer.anchorPoint.x * previous.width,
                    y: contentLayer.anchorPoint.y * previous.height)
                contentPosition.toValue = contentLayer.position
            }
            let corners = CABasicAnimation(keyPath: "cornerRadius")
            corners.fromValue = previousRadius
            corners.toValue = radius
            for animation in [position, bounds, corners, contentPosition, contentScale] {
                animation.duration = SidebarMotion.duration
                animation.timingFunction = SidebarMotion.pageTiming
            }
            layer.add(position, forKey: "sidebarPosition")
            layer.add(bounds, forKey: "sidebarBounds")
            layer.add(corners, forKey: "sidebarCorners")
            contentSurface.layer?.add(contentPosition, forKey: "sidebarContentPosition")
            contentSurface.layer?.add(contentScale, forKey: "sidebarContentScale")
        }
        func stopMotion() {
            surface.layer?.removeAllAnimations()
            contentSurface.layer?.removeAllAnimations()
            clearResizeBlur()
        }
        private func beginResizeBlur(duration: TimeInterval) {
            guard let layer = contentSurface.layer, let filter = CIFilter(name: "CIGaussianBlur") else { return }
            filter.name = "sidebarResize"
            filter.setValue(0, forKey: kCIInputRadiusKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.filters = [filter]
            CATransaction.commit()
            let blur = CABasicAnimation(keyPath: "filters.sidebarResize.inputRadius")
            blur.fromValue = 3
            blur.toValue = 0
            blur.duration = duration
            blur.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(blur, forKey: "sidebarResizeBlur")
            let end = DispatchWorkItem { [weak self] in self?.clearResizeBlur() }
            blurEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: end)
        }
        private func clearResizeBlur() {
            blurEnd?.cancel()
            blurEnd = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentSurface.layer?.removeAnimation(forKey: "sidebarResizeBlur")
            contentSurface.layer?.filters = nil
            CATransaction.commit()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMotion() }
        }
    }
}

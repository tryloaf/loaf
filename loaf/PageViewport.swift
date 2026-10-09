import AppKit
import QuartzCore
import SwiftUI



struct PageViewport<Content: View>: NSViewRepresentable {
    let leading: CGFloat
    let edge: CGFloat
    let cornerRadius: CGFloat
    let sidebarPresented: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> Container {
        Container(content: Root(content: content(), environment: environment))
    }
    func updateNSView(_ view: Container, context: Context) {
        view.host.rootView = Root(content: content(), environment: environment)
        view.configure(
            leading: leading, edge: edge, radius: cornerRadius,
            sidebarPresented: sidebarPresented, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: Container, coordinator: ()) {
        view.surface.layer?.removeAllAnimations()
        view.contentSurface.layer?.removeAllAnimations()
        view.clipMask.removeAllAnimations()
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
        let clipMask = CAShapeLayer()
        private var leading: CGFloat = 0
        private var edge: CGFloat = 0
        private var radius: CGFloat = 0
        private var initialized = false
        private var sidebarPresented = true
        private var animateNextLayout = false
        override var isFlipped: Bool { true }

        init(content: Root) {
            host = NSHostingView(rootView: content)
            host.sizingOptions = []


            host.safeAreaRegions = []
            contentSurface.wantsLayer = true
            super.init(frame: .zero)
            wantsLayer = true
            surface.wantsLayer = true
            surface.layer?.masksToBounds = false
            clipMask.fillColor = NSColor.white.cgColor
            clipMask.anchorPoint = .zero
            clipMask.position = .zero
            surface.layer?.mask = clipMask
            surface.layer?.cornerCurve = .continuous
            contentSurface.addSubview(host)
            surface.addSubview(contentSurface)
            addSubview(surface)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            leading: CGFloat, edge: CGFloat, radius: CGFloat,
            sidebarPresented: Bool, reduceMotion: Bool
        ) {
            let changed = initialized && self.sidebarPresented != sidebarPresented
            self.leading = leading
            self.edge = edge
            self.radius = radius
            self.sidebarPresented = sidebarPresented
            initialized = true
            if changed { animateNextLayout = !reduceMotion && window != nil }
            if reduceMotion {
                surface.layer?.removeAllAnimations()
                clipMask.removeAllAnimations()
                contentSurface.layer?.removeAllAnimations()
            }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let target = NSRect(
                x: leading, y: edge,
                width: max(0, bounds.width - leading - edge), height: max(0, bounds.height - 2 * edge))
            guard target != surface.frame || surface.layer?.cornerRadius != radius else {
                animateNextLayout = false
                return
            }
            let previous = surface.layer?.presentation()?.frame ?? surface.layer?.frame ?? surface.frame
            let previousPath = clipMask.presentation()?.path ?? clipMask.path
            let previousRadius = surface.layer?.presentation()?.cornerRadius ?? surface.layer?.cornerRadius ?? radius
            let animate =
                animateNextLayout && previous.width > 0 && previous.height > 0
                && target.width > 0 && target.height > 0
            animateNextLayout = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer?.removeAllAnimations()
            clipMask.removeAllAnimations()
            contentSurface.layer?.removeAllAnimations()
            surface.frame = target
            surface.layer?.cornerRadius = radius
            clipMask.bounds = surface.bounds



            let expansion: CGFloat = edge == 0 && radius > 0 ? 1 / (window?.backingScaleFactor ?? 2) : 0
            clipMask.path =
                RoundedRectangle(cornerRadius: radius + expansion, style: .continuous)
                .path(in: surface.bounds.insetBy(dx: -expansion, dy: -expansion)).cgPath
            contentSurface.frame = NSRect(origin: .zero, size: target.size)
            host.frame = contentSurface.bounds
            host.layoutSubtreeIfNeeded()
            CATransaction.commit()
            guard animate, let layer = surface.layer else { return }
            let position = CABasicAnimation(keyPath: "position")


            position.fromValue = CGPoint(
                x: previous.minX + layer.anchorPoint.x * previous.width,
                y: previous.minY + layer.anchorPoint.y * previous.height)
            position.toValue = layer.position


            let clipBounds = CABasicAnimation(keyPath: "bounds")
            clipBounds.fromValue = CGRect(origin: layer.bounds.origin, size: previous.size)
            clipBounds.toValue = layer.bounds
            let corners = CABasicAnimation(keyPath: "cornerRadius")
            corners.fromValue = previousRadius
            corners.toValue = radius
            let clipPath = CABasicAnimation(keyPath: "path")
            clipPath.fromValue = previousPath
            clipPath.toValue = clipMask.path
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = CATransform3DMakeScale(
                previous.width / target.width, previous.height / target.height, 1)
            transform.toValue = CATransform3DIdentity
            for animation in [position, clipBounds, corners, clipPath, transform] {
                animation.duration = 0.26
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            layer.add(position, forKey: "sidebarPosition")
            layer.add(clipBounds, forKey: "sidebarBounds")
            layer.add(corners, forKey: "sidebarCorners")
            clipMask.add(clipBounds, forKey: "sidebarMaskBounds")
            clipMask.add(clipPath, forKey: "sidebarClipPath")
            contentSurface.layer?.add(transform, forKey: "sidebarContentSize")
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
    }
}

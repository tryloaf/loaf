import AppKit
import SwiftUI

@MainActor enum TabClosingAnimation {
    private final class WeakAnchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private static var anchors: [UUID: WeakAnchor] = [:]
    static func register(_ view: NSView, tabID: UUID) {
        anchors = anchors.filter { $0.value.view != nil }
        anchors[tabID] = WeakAnchor(view)
    }
    static func close(_ tab: BrowserTab) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let anchor = anchors[tab.id]?.view, let window = anchor.window, let content = window.contentView,
            let overlay = content.superview,
            anchor.bounds.width > 0, anchor.bounds.height > 0
        else { return }

        let frame = content.convert(anchor.bounds, from: anchor)
        guard content.bounds.intersects(frame), let bitmap = content.bitmapImageRepForCachingDisplay(in: frame) else {
            return
        }
        content.cacheDisplay(in: frame, to: bitmap)
        let image = NSImage(size: anchor.bounds.size)
        image.addRepresentation(bitmap)
        let overlayFrame = content.convert(frame, to: overlay)
        let ghost = Ghost(frame: overlayFrame)
        ghost.wantsLayer = true
        ghost.layer?.masksToBounds = false
        ghost.image = image
        ghost.imageScaling = .scaleAxesIndependently
        ghost.setAccessibilityElement(false)
        overlay.addSubview(ghost, positioned: .above, relativeTo: content)
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().alphaValue = 0
            ghost.animator().frame = overlayFrame.offsetBy(dx: -10, dy: 0)
        } completionHandler: {
            ghost.removeFromSuperview()
        }
    }
    private final class Ghost: NSImageView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

struct TabClosingAnchor: NSViewRepresentable {
    let tabID: UUID
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { TabClosingAnimation.register(view, tabID: tabID) }
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            wantsLayer = true
        }
    }
}

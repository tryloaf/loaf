import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    func makeNSView(context: Context) -> MetricsView {
        let view = MetricsView()
        view.store = store
        return view
    }
    func updateNSView(_ view: MetricsView, context: Context) {
        view.store = store
        view.translucent =
            !context.environment.accessibilityReduceTransparency
            && ProfileTransparency.bounded(store.profile.personalization?.windowTransparency ?? 0) > 0
        view.measureLater()
    }
    final class MetricsView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        weak var store: BrowserStore?
        private var measurementPending = false
        var translucent = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measureLater()
        }
        override func layout() {
            super.layout()
            measureLater()
        }
        func measureLater() {
            guard !measurementPending else { return }
            measurementPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementPending = false
                guard let store = self.store, let window = self.window else { return }
                if window.isOpaque == self.translucent {
                    window.isOpaque = !self.translucent
                    window.invalidateShadow()
                }
                let background: NSColor = self.translucent ? .clear : .windowBackgroundColor
                if window.backgroundColor != background { window.backgroundColor = background }
                if let browser = window as? LoafBrowserWindow {
                    browser.setSidebarOnlyChrome(store.usesSidebarOnlyChrome)
                }
                guard let content = window.contentView, let close = window.standardWindowButton(.closeButton) else {
                    return
                }
                let center = content.convert(close.bounds, from: close).midY
                let fromTop = content.isFlipped ? center : content.bounds.maxY - center
                guard fromTop.isFinite, (8...32).contains(fromTop), abs(store.chromeControlsCenterY - fromTop) > 0.25
                else { return }
                store.chromeControlsCenterY = fromTop
            }
        }
    }
}

struct ChromeBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BackdropView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let name: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
    final class BackdropView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct FullscreenWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}
    final class ControlsView: NSView {
        private var hoverArea: NSTrackingArea?
        private(set) var hoverSymbolsVisible = false
        var grayIdle = false {
            didSet {
                guard grayIdle != oldValue else { return }
                if grayIdle {
                    for button in subviews {
                        button.wantsLayer = true
                        let mask = CALayer()
                        mask.backgroundColor = NSColor.white.cgColor
                        mask.frame = button.bounds.insetBy(dx: -12, dy: -12)
                        button.layer?.mask = mask
                        button.layer?.masksToBounds = false
                    }
                }
                updateAppearance(animated: false)
            }
        }
        var fullscreenOnly = true { didSet { if fullscreenOnly != oldValue { updateAvailability() } } }
        var floatingInset: CGFloat = 0 { didSet { if floatingInset != oldValue { placeButtons() } } }
        var dotTint: NSColor = .systemGray {
            didSet { if dotTint != oldValue { for dot in dots { dot.backgroundColor = dotTint.cgColor } } }
        }
        private var dots: [CALayer] = []

        @objc func _mouseInGroup(_ button: NSButton) -> Bool { hoverSymbolsVisible }
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard
                    let button = NSWindow.standardWindowButton(
                        type, for: [.titled, .closable, .miniaturizable, .resizable])
                else { continue }
                button.frame.origin = NSPoint(x: 9 + CGFloat(index) * 23, y: 9)
                button.target = self
                button.action =
                    type == .closeButton
                    ? #selector(closeWindow)
                    : type == .zoomButton ? #selector(exitFullscreen) : #selector(minimizeWindow)
                button.setAccessibilityLabel(
                    type == .closeButton
                        ? "close window" : type == .miniaturizeButton ? "minimize window" : "exit full screen")
                button.isEnabled = true
                addSubview(button)
                let dot = CALayer()
                dot.backgroundColor = NSColor.systemGray.withAlphaComponent(0.6).cgColor
                dot.opacity = 0
                layer?.addSublayer(dot)
                dots.append(dot)
            }
        }
        required init?(coder: NSCoder) { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if hoverArea == nil {
                let area = NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                    userInfo: nil)
                addTrackingArea(area)
                hoverArea = area
            }
            if let window {
                setHoverSymbols(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
            }
        }
        override func mouseEntered(with event: NSEvent) { setHoverSymbols(true) }
        override func mouseExited(with event: NSEvent) { setHoverSymbols(false) }
        func setHoverSymbols(_ visible: Bool) {
            guard visible || NSEvent.pressedMouseButtons == 0 else { return }
            guard hoverSymbolsVisible != visible else { return }
            hoverSymbolsVisible = visible
            for button in subviews.compactMap({ $0 as? NSButton }) {

                let selector = NSSelectorFromString("mouseEnteredOrExited")
                if button.responds(to: selector) {
                    typealias Refresh = @convention(c) (AnyObject, Selector) -> Void
                    unsafeBitCast(button.method(for: selector), to: Refresh.self)(button, selector)
                }
                button.needsDisplay = true
            }
            updateAppearance(animated: true)
        }
        private func updateAppearance(animated: Bool) {
            let visible = !grayIdle || hoverSymbolsVisible
            let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)

            if grayIdle { for button in subviews { button.layer?.mask?.opacity = visible ? 1 : 0 } }
            for dot in dots { dot.opacity = visible ? 0 : 1 }
            CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if grayIdle {
                let local = convert(point, from: superview)
                return subviews.first { $0.frame.contains(local) && ($0 as? NSButton)?.isEnabled == true }
            }
            return super.hitTest(point)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            placeButtons()
            updateAppearance(animated: false)
        }
        override func layout() {
            super.layout()
            placeButtons()
        }
        private func updateAvailability() {
            let fullscreen = window?.styleMask.contains(.fullScreen) ?? false
            for (index, button) in subviews.enumerated() {
                (button as? NSButton)?.isEnabled =
                    index == 2
                    ? (window as? LoafBrowserWindow)?.allowsFullScreen == true && (!fullscreenOnly || fullscreen)
                    : index == 1 ? !fullscreen : true
            }
        }
        func refreshWindowControls() { placeButtons() }
        private func placeButtons() {
            updateAvailability()
            guard let window = window as? LoafBrowserWindow else { return }
            for (button, frame) in zip(subviews, window.trafficLightFrames) {
                let target = frame.offsetBy(dx: -floatingInset, dy: -floatingInset)
                if button.frame != target { button.frame = target }
            }
            if !fullscreenOnly {
                subviews.last?.setAccessibilityLabel(
                    window.styleMask.contains(.fullScreen) ? "exit full screen" : "enter full screen")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (dot, button) in zip(dots, subviews) {
                dot.frame = button.frame
                dot.cornerRadius = min(button.frame.width, button.frame.height) / 2
                button.layer?.mask?.frame = button.bounds.insetBy(dx: -12, dy: -12)
            }
            CATransaction.commit()
        }
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() {
            guard window?.styleMask.contains(.fullScreen) != true else { return }
            window?.miniaturize(nil)
        }
        @objc private func exitFullscreen() { window?.toggleFullScreen(nil) }
    }

}

struct SidebarWindowControls: NSViewRepresentable {
    var floating: Bool
    var tint: NSColor = .systemGray
    func makeNSView(context: Context) -> FullscreenWindowControls.ControlsView {
        let view = FullscreenWindowControls.ControlsView(frame: .zero)
        view.fullscreenOnly = false
        view.grayIdle = true
        return view
    }
    func updateNSView(_ view: FullscreenWindowControls.ControlsView, context: Context) {
        view.floatingInset = floating ? 3 : 0
        let base = context.environment.colorScheme == .dark ? NSColor.white : NSColor.black
        view.dotTint = (base.blended(withFraction: 0.08, of: tint) ?? base).withAlphaComponent(
            context.environment.colorScheme == .dark ? 0.32 : 0.25)
        view.layer?.masksToBounds = false
        view.refreshWindowControls()
    }
}

struct WindowDragArea: NSViewRepresentable {
    var click: (() -> Void)? = nil
    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.click = click
        return view
    }
    func updateNSView(_ view: DragView, context: Context) { view.click = click }
    final class DragView: NSView {
        var click: (() -> Void)?
        private var down: NSEvent?
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if click == nil {
                if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
            } else {
                down = event
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down,
                hypot(
                    event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 4
            else { return }
            self.down = nil
            window?.performDrag(with: down)
        }
        override func mouseUp(with event: NSEvent) {
            guard let down else { return }
            self.down = nil
            if hypot(
                event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
                < 4
            {
                click?()
            }
        }
    }
}

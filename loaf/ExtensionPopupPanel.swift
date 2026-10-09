import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class ExtensionPopupPanel: NSPanel {
    private var themeObservation: AnyCancellable?
    func followSystemTheme(webView: WKWebView) {
        appearance = ExtensionTheme.appearance
        themeObservation = LoafAppearance.shared.$systemScheme.sink { [weak self, weak webView] scheme in
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            self?.appearance = appearance
            webView?.appearance = appearance
        }
    }
    private var action: WKWebExtension.Action?
    private var sizeObservation: NSKeyValueObservation?
    init(action: WKWebExtension.Action, title: String) {
        self.action = action
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = true
        contentMinSize = CGSize(width: 64, height: 40)
        contentMaxSize = CGSize(width: 800, height: 900)
        setAccessibilityLabel(title + " extension")
    }
    func boundedSize(_ requested: CGSize) -> CGSize {
        let visible =
            screen?.visibleFrame ?? parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_000, height: 800)
        return CGSize(
            width: min(
                800, visible.width - 32,
                max(64, requested.width.isFinite && requested.width > 0 ? requested.width : 360)),
            height: min(
                900, visible.height - 64,
                max(40, requested.height.isFinite && requested.height > 0 ? requested.height : 420)))
    }
    func install(controller: NSViewController) {
        contentViewController = controller

        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            Task { @MainActor [weak self] in self?.resizeContent(size) }
        }
        resizeContent(controller.preferredContentSize)
    }
    private func resizeContent(_ requested: CGSize) {
        guard requested.width > 0, requested.height > 0 else { return }
        let size = boundedSize(requested)
        let old = frame
        guard
            abs((contentView?.bounds.width ?? 0) - size.width) > 0.5
                || abs((contentView?.bounds.height ?? 0) - size.height) > 0.5
        else { return }
        setContentSize(size)
        setFrameOrigin(CGPoint(x: old.minX, y: old.maxY - frame.height))
    }
    override func close() {
        themeObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        parent?.removeChildWindow(self)
        action?.closePopup()
        action = nil
        contentViewController = nil
        contentView = nil
        super.close()
    }
}

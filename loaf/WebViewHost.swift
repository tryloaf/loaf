import AppKit
import SwiftUI
import WebKit

enum WebCursorOwnership {
    static func webView(for event: NSEvent, in window: NSWindow?) -> WKWebView? {
        guard let content = window?.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        var view = content.hitTest(point)
        while let candidate = view {
            if let webView = candidate as? WKWebView { return webView }
            view = candidate.superview
        }
        return nil
    }
}

final class WebCursorHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {

        var pages: [NSRect] = []
        var pending = subviews
        while let view = pending.popLast() {
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            if view is WKWebView { pages.append(convert(view.visibleRect, from: view)) }
            else { pending += view.subviews }
        }
        guard !pages.isEmpty else { super.resetCursorRects(); return }
        discardCursorRects()
        var chrome = [bounds]
        for page in pages {
            chrome = chrome.flatMap { rect -> [NSRect] in
                let overlap = rect.intersection(page)
                guard !overlap.isEmpty else { return [rect] }
                return [
                    NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    NSRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    NSRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
                ].filter { !$0.isEmpty }
            }
        }
        for rect in chrome { addCursorRect(rect, cursor: .arrow) }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard WebCursorOwnership.webView(for: event, in: window) == nil else { return }
        super.cursorUpdate(with: event)
    }
}

struct WebViewHost: NSViewRepresentable {
    let tab: BrowserTab
    var topInset: CGFloat = 0
    var sidebarVisible = true
    var viewportSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    final class HostView: NSView {
        weak var hostedWebView: WKWebView?
        var fallbackInset: CGFloat = 0
        var configuredInset: CGFloat?
        var requestedInset: CGFloat = 0
        var viewportSize: CGSize?
        var configuredSidebar: Bool?
        var configuredNavigation: UUID?
        var wasInFullscreen = false
        var reduceMotion = false
        var transitionEnabled = false
        private(set) var resizeCommits = 0
        var resizing: Bool { false }
        var resizeSnapshotVisible: Bool { false }
        var preparingResizeSnapshot: Bool { false }
        var hasPreparedResizeSnapshot: Bool { false }
        func cancelResizeSnapshot() {}
        func invalidatePreparedResizeSnapshot() {}
        func prepareResizeSnapshot(delay: TimeInterval = 0.25) {}
        func beginResizeSnapshot() {}
        func sidebarDidChange() { needsLayout = true }
        func sidebarWillChange() { needsLayout = true }
        func restoreAfterFullscreen() {
            configuredInset = nil
            applyChromeInset()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let inset = max(fallbackInset, configuredInset ?? requestedInset)
            if inset > 0, bounds.contains(local), local.y >= bounds.maxY - inset { return nil }
            return super.hitTest(point)
        }
        func applyChromeInset() {
            guard configuredInset != requestedInset, let webView = hostedWebView,
                webView.superview === self, webView.fullscreenState == .notInFullscreen
            else { return }
            configuredInset = requestedInset
            fallbackInset = WebKitAdapter.setChromeInset(webView, height: requestedInset) ? 0 : requestedInset
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let inheritedTop = safeAreaInsets.top - additionalSafeAreaInsets.top
            let extraTop = max(0, (configuredInset ?? 0) - inheritedTop)
            if additionalSafeAreaInsets.top != extraTop { additionalSafeAreaInsets.top = extraTop }
            guard let webView = hostedWebView, webView.superview === self,
                webView.fullscreenState == .notInFullscreen, !WebKitAdapter.inspectorIsDocked(webView)
            else { return }
            let scale = window?.backingScaleFactor ?? 1
            let target = NSRect(
                x: 0, y: isFlipped ? fallbackInset : 0,
                width: ceil(bounds.width * scale) / scale,
                height: ceil(max(0, bounds.height - fallbackInset) * scale) / scale)
            guard target.width > 0, target.height > 0, webView.frame != target else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = target
            CATransaction.commit()
            resizeCommits += 1
        }
    }
    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        tab.webViewHost = host
        attach(to: host)
        return host
    }
    func updateNSView(_ host: HostView, context: Context) {

        guard tab.webViewHost === host else { return }
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

        if host.bounds.width > 0, host.bounds.height > 0 { view.frame = host.bounds }
        view.autoresizingMask = []
        host.addSubview(view)
        host.hostedWebView = view
        configure(host)
    }
    static func dismantleNSView(_ host: HostView, coordinator: ()) {
        host.invalidatePreparedResizeSnapshot()
        host.cancelResizeSnapshot()
        if let view = host.hostedWebView, view.isDescendant(of: host), view.fullscreenState == .notInFullscreen,
            WebKitAdapter.inspectorIsDocked(view)
        {
            WebKitAdapter.closeInspector(view)
        }
        host.hostedWebView = nil
    }
    private func configure(_ host: HostView) {
        let geometryChanged =
            host.viewportSize != viewportSize || host.configuredSidebar != sidebarVisible
            || host.requestedInset != topInset || host.configuredNavigation != tab.navigationID
        host.reduceMotion = reduceMotion
        host.transitionEnabled = false
        if !host.transitionEnabled || reduceMotion || host.configuredNavigation != tab.navigationID {
            host.invalidatePreparedResizeSnapshot()
            host.cancelResizeSnapshot()
        }
        host.configuredNavigation = tab.navigationID
        host.viewportSize = viewportSize
        if let previous = host.configuredSidebar, previous != sidebarVisible { host.sidebarDidChange() }
        host.configuredSidebar = sidebarVisible
        host.requestedInset = topInset
        host.applyChromeInset()
        if geometryChanged { host.needsLayout = true }
    }
}

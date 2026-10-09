import SwiftUI
import WebKit

struct ReaderHTMLView: NSViewRepresentable {
    let document: ReaderDocument
    let tab: BrowserTab
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator(document: document, tab: tab) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsMagnification = true
        view.navigationDelegate = context.coordinator
        if let store = tab.store, store.profileFor(tab.profileID).blockerEnabled,
            !(document.originalURL.host.map { store.profileFor(tab.profileID).allowedSites.contains($0) } ?? false)
        {
            store.blocker.ruleLists.forEach { config.userContentController.add($0) }
        }
        view.pageZoom = tab.existingWebView?.pageZoom ?? 1
        tab.readerWebView = view
        view.loadHTMLString(document.html(dark: scheme == .dark), baseURL: document.originalURL)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let dark = scheme == .dark
        guard context.coordinator.dark != dark else { return }
        context.coordinator.dark = dark

        view.evaluateJavaScript("document.documentElement.dataset.theme = '\(dark ? "dark" : "light")'") { _, _ in }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let document: ReaderDocument
        weak var tab: BrowserTab?
        let navigationID: UUID
        var dark: Bool?
        private var initializing = true
        init(document: ReaderDocument, tab: BrowserTab) {
            self.document = document
            self.tab = tab
            navigationID = tab.navigationID
        }
        private var valid: Bool {
            guard let tab, let store = tab.store else { return false }
            return tab.navigationID == navigationID && tab.readerDocument?.id == document.id
                && store.selectedTab?.id == tab.id && store.selectedProfileID == tab.profileID
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initializing = false
            guard valid, let tab else { return }
            tab.finder.reset(clearQuery: true)
            tab.finder.webView = webView
            tab.store?.focusPage()
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard valid else {
                decisionHandler(.cancel)
                return
            }
            if initializing, action.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.fragment?.hasPrefix("loaf-reader-") == true,
                url.scheme == document.originalURL.scheme, url.host == document.originalURL.host,
                url.port == document.originalURL.port, url.path == document.originalURL.path,
                url.query == document.originalURL.query
            {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else { return }
            tab?.store?.navigate(url.absoluteString, inNewTab: action.targetFrame == nil)
        }
    }
}

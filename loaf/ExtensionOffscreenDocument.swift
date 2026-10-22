import WebKit

@MainActor final class ExtensionOffscreenDocument: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var didTerminate: (() -> Void)?
    private let url: URL
    private var completion: ((Error?) -> Void)?
    private var deadline: Task<Void, Never>?

    init(url: URL, configuration: WKWebViewConfiguration) {
        self.url = url
        configuration.preferences.inactiveSchedulingPolicy = .none
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.isInspectable = false
    }

    func load(completion: @escaping (Error?) -> Void) {
        self.completion = completion
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finish(PackageError(reason: "The extension's hidden document did not finish loading."))
        }
        view.load(URLRequest(url: url))
    }

    private func finish(_ error: Error?) {
        deadline?.cancel()
        deadline = nil
        let callback = completion
        completion = nil
        callback?(error)
    }

    func stop() {
        view.stopLoading()
        view.navigationDelegate = nil
        finish(PackageError(reason: "The extension's hidden document was closed."))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(PackageError(reason: "The extension's hidden document stopped running."))
        didTerminate?()
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true,
            navigationAction.request.url != url {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

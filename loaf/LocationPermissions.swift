import WebKit

extension BrowserTab {
    func locationPermission(for origin: WKSecurityOrigin) -> WKPermissionDecision {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        if origin.port > 0 { parts.port = origin.port }
        guard let url = parts.url, url.scheme == "https", let key = BrowserAddress.websiteOrigin(url),
            let store, !store.profileFor(profileID).privateMode
        else { return .deny }
        switch store.profileFor(profileID).siteSettings?[key]?.location ?? "deny" {
        case "allow": return .grant
        case "ask": return .prompt
        default: return .deny
        }
    }
    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(webView === existingWebView ? locationPermission(for: origin) : .deny)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func legacyLocation(
        _ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(webView === existingWebView ? locationPermission(for: origin) : .deny)
    }
    @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
    func legacyFrameLocation(_ webView: WKWebView, frame: WKFrameInfo, decisionHandler: @escaping (Bool) -> Void) {
        decisionHandler(webView === existingWebView && locationPermission(for: frame.securityOrigin) == .grant)
    }
}

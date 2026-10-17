import Darwin
import WebKit

@MainActor final class PublicSearchNavigation: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil,
            let host = url.host?.lowercased(), ["www.google.com", "google.com", "html.duckduckgo.com", "www.bing.com", "bing.com"].contains(host)
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    nonisolated static func isPublicURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
            let raw = url.host?.lowercased(), !raw.hasSuffix("."), raw.contains(".")
        else { return false }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", ".localhost", ".local", ".internal", ".home", ".lan"].contains(where: {
            host == $0 || host.hasSuffix($0)
        }) {
            return false
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let address = UInt32(bigEndian: v4.s_addr)
            let a = address >> 24
            let b = (address >> 16) & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 || a == 169 && b == 254
                || a == 172 && (16...31).contains(b) || a == 192 && b == 168
                || a == 100 && (64...127).contains(b) || a == 198 && (18...19).contains(b)
            {
                return false
            }
        }

        return !host.contains(":") && !host.allSatisfy({ $0.isNumber || $0 == "." })
    }
}

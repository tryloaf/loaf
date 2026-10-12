import Darwin
import Foundation
import WebKit

@MainActor enum PublicPageReader {
    static func read(_ url: URL) async throws -> String {
        guard PublicSearchNavigation.isPublicURL(url), let host = url.host else {
            throw URLError(.unsupportedURL)
        }
        let publicHost = await Task.detached { resolvesPublicly(host) }.value
        try Task.checkCancellation()
        guard publicHost else { throw URLError(.cannotFindHost) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let transfers = AssetTransfers()
        let session = URLSession(configuration: config, delegate: transfers, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let transfer = AssetTransfer(limit: 2_000_000, originalURL: url, allowsRedirects: false)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: url)
                request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                transfers.register(transfer, task: task)
                if !transfer.start(task, continuation: continuation) { transfers.remove(task.taskIdentifier) }
            }
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        guard let html = String(data: data, encoding: .utf8),
            html.range(of: "<(html|head|body|article|main|p)[ >]", options: [.regularExpression, .caseInsensitive])
                != nil
        else { throw URLError(.cannotDecodeContentData) }
        return try await WebSearchService.extractHTML(html, queryURL: url, offlineOnly: true)
    }

    nonisolated static func resolvesPublicly(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let pointer = cursor {
            let info = pointer.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                    == 0,
                isPublicAddress(String(cString: buffer))
            else { return false }
            found = true
            cursor = info.ai_next
        }
        return found
    }

    nonisolated static func isPublicAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            let a = ip >> 24
            let b = (ip >> 16) & 255
            let c = (ip >> 8) & 255
            return
                !(a == 0 || a == 10 || a == 127 || a >= 224 || a == 169 && b == 254
                || a == 172 && (16...31).contains(b) || a == 192 && b == 168
                || a == 100 && (64...127).contains(b) || a == 198 && (18...19).contains(b)
                || a == 192 && b == 0 && (c == 0 || c == 2)
                || a == 198 && b == 51 && c == 100 || a == 203 && b == 0 && c == 113)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, value, &v6) == 1 else { return false }

        return withUnsafeBytes(of: v6) { bytes in
            bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
        }
    }
}

@MainActor final class OfflinePageNavigation: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {

        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

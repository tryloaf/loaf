import AppKit
import WebKit

struct BlockedPopup {
    let token: String
    let frame: WKFrameInfo
    let navigationID: UUID
}

enum PopupBlocking {
    static let script = #"""
        (() => {
          if (window.__loafOpenBlockedPopup) return;
          const nativeOpen = window.open;
          const pending = new Map();
          Object.defineProperty(window, '__loafOpenBlockedPopup', {value: token => {
            const request = pending.get(token);
            if (!request) return false;
            pending.delete(token);
            return Reflect.apply(nativeOpen, window, request) !== null;
          }});
          window.open = function open(url, target, features) {
            const args = Array.from(arguments);
            const child = Reflect.apply(nativeOpen, this, args);
            if (child === null) {
              try {
              const hex = [...crypto.getRandomValues(new Uint8Array(16))].map(n => n.toString(16).padStart(2, '0')).join('');
              const token = [hex.slice(0,8), hex.slice(8,12), hex.slice(12,16), hex.slice(16,20), hex.slice(20)].join('-');
              pending.set(token, args);
              while (pending.size > 8) pending.delete(pending.keys().next().value);
              window.webkit.messageHandlers.loafBlockedPopup.postMessage({token});
              } catch {}
            }
            return child;
          };
        })();
        """#

    static func origin(_ frame: WKFrameInfo) -> String? {
        let origin = frame.securityOrigin
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url.flatMap(BrowserAddress.websiteOrigin)
    }
}

extension BrowserTab {
    func allowsAutomaticPopups(in frame: WKFrameInfo) -> Bool {
        guard let origin = PopupBlocking.origin(frame) else { return false }
        return store?.profileFor(profileID).siteSettings?[origin]?.automaticPopups == true
    }
    func reportBlockedPopup(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["token"] as? String,
            UUID(uuidString: token) != nil, !allowsAutomaticPopups(in: message.frameInfo),
            let store, store.selectedTab === self, !isDisposed,
            let origin = PopupBlocking.origin(message.frameInfo)
        else { return }
        blockedPopup = BlockedPopup(token: token, frame: message.frameInfo, navigationID: navigationID)
        let host = URL(string: origin)?.host ?? "this site"
        store.feedback.show(
            .popupBlocked, icon: .external, text: "pop-up blocked from \(host)",
            duration: .seconds(12), actionTitle: "open pop-up",
            action: { [weak self] in self?.openBlockedPopup(token: token) })
    }
    func openBlockedPopup(token: String? = nil) {
        guard let request = blockedPopup, token == nil || token == request.token,
            request.navigationID == navigationID, !isDisposed,
            let store, store.selectedTab === self, store.selectedProfileID == profileID, let view = existingWebView
        else { return }
        blockedPopup = nil
        view.callAsyncJavaScript(
            "return window.__loafOpenBlockedPopup?.(token) === true;",
            arguments: ["token": request.token], in: request.frame, in: .page
        ) { [weak self, weak store] result in
            guard let self, !self.isDisposed, self.navigationID == request.navigationID,
                store?.selectedTab === self
            else { return }
            if case .success(let value) = result, value as? Bool == true { return }
            store?.feedback.show(.info, icon: .external, text: "couldn’t open this pop-up. try it again from the page.")
        }
    }
    func clearBlockedPopup() {
        blockedPopup = nil
        if store?.selectedTab === self, store?.feedback.notice?.kind == .popupBlocked { store?.feedback.clear() }
    }
}

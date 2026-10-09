import AppKit
import UserNotifications
import WebKit

@MainActor final class WebNotifications: NSObject, UNUserNotificationCenterDelegate {
    private weak var application: BrowserApplication?
    private var targets: [String: WeakTarget] = [:]
    private var deliveries: [UUID: [Date]] = [:]
    private var requesting = Set<String>()
    private struct WeakTarget {
        weak var tab: BrowserTab?
        let navigation: UUID
    }
    init(application: BrowserApplication) {
        self.application = application
        super.init()
    }
    func permission(tab: BrowserTab, origin: String) -> String {
        guard let application, application.preferences.webNotifications != false,
            let profile = application.profiles.first(where: { $0.id == tab.profileID }), !profile.privateMode
        else { return "denied" }
        switch profile.siteSettings?[origin]?.notifications {
        case "allow": return "granted"
        case "deny": return "denied"
        default: return "default"
        }
    }
    func request(tab: BrowserTab, origin: String) async -> String {
        let current = permission(tab: tab, origin: origin)
        guard current == "default", let store = tab.store, store.selectedTab === tab,
            store.nativeWindow?.isKeyWindow == true, let coordinator = application?.coordinator
        else { return current }
        let token = tab.navigationID
        let key = tab.profileID.uuidString + origin
        guard requesting.insert(key).inserted else { return "default" }
        defer { requesting.remove(key) }
        let alert = NSAlert()
        alert.messageText = "allow notifications from \(URL(string: origin)?.host ?? origin)?"
        alert.informativeText =
            "this website can send notifications while it’s open in loaf. you can change this in website settings."
        alert.addButton(withTitle: "allow")
        alert.addButton(withTitle: "don’t allow")
        let response = await withCheckedContinuation { continuation in
            coordinator.alert(alert, for: store) { continuation.resume(returning: $0) }
        }
        guard valid(tab, origin: origin, navigation: token), response != .abort else { return "denied" }
        var allowed = response == .alertFirstButtonReturn
        if allowed {
            UNUserNotificationCenter.current().delegate = self
            allowed =
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
        }
        guard valid(tab, origin: origin, navigation: token) else { return "denied" }
        store.updateProfile(tab.profileID) { profile in
            var settings = profile.siteSettings?[origin] ?? SiteSettings()
            settings.notifications = allowed ? "allow" : "deny"
            profile.siteSettings = profile.siteSettings ?? [:]
            profile.siteSettings?[origin] = settings
        }
        return allowed ? "granted" : "denied"
    }
    private func valid(_ tab: BrowserTab, origin: String, navigation: UUID) -> Bool {
        !tab.isDisposed && tab.navigationID == navigation
            && tab.existingWebView?.url.flatMap(BrowserAddress.websiteOrigin) == origin
            && permission(tab: tab, origin: origin) != "denied"
    }
    func deliver(tab: BrowserTab, origin: String, id: String, title: String, body: String, silent: Bool) async throws {
        guard permission(tab: tab, origin: origin) == "granted", !tab.isDisposed,
            tab.existingWebView?.url.flatMap(BrowserAddress.websiteOrigin) == origin
        else { throw ProfileImport.Failure(message: "Notification permission is denied.") }
        let now = Date.now
        let recent = (deliveries[tab.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 5 else {
            throw ProfileImport.Failure(message: "This website is sending notifications too quickly.")
        }
        deliveries[tab.id] = recent + [now]
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.body = String(body.prefix(1_000))
        content.subtitle = URL(string: origin)?.host ?? origin
        if !silent { content.sound = .default }
        let key = "web." + tab.id.uuidString + "." + id
        targets = targets.filter { $0.value.tab != nil }
        targets[key] = .init(tab: tab, navigation: tab.navigationID)
        if targets.count > 200 { targets = [key: .init(tab: tab, navigation: tab.navigationID)] }
        UNUserNotificationCenter.current().delegate = self
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    func close(tab: BrowserTab, id: String) {
        let key = "web." + tab.id.uuidString + "." + id
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
        targets.removeValue(forKey: key)
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let target = self.targets[identifier], let tab = target.tab, !tab.isDisposed, let store = tab.store
            else { return }
            store.switchProfile(tab.profileID)
            store.select(tab)
            store.nativeWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            guard target.navigation == tab.navigationID else { return }
            let encoded =
                (try? JSONSerialization.data(withJSONObject: [identifier.components(separatedBy: ".").last ?? ""]))
                ?? Data("[]".utf8)
            _ = try? await tab.existingWebView?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('loafNotificationClick',{detail:\(String(decoding: encoded, as: UTF8.self))}));"
            )
        }
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner, .sound]) }
}

@MainActor final class NotificationScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab }
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let tab, !tab.isDisposed, message.webView === tab.existingWebView, message.frameInfo.isMainFrame,
            let url = message.frameInfo.request.url, url.scheme == "https",
            let origin = BrowserAddress.websiteOrigin(url),
            tab.existingWebView?.url.flatMap(BrowserAddress.websiteOrigin) == origin,
            let body = message.body as? [String: Any], let operation = body["operation"] as? String,
            let notifications = tab.store?.application.notifications
        else {
            replyHandler("denied", nil)
            return
        }
        switch operation {
        case "state": replyHandler(notifications.permission(tab: tab, origin: origin), nil)
        case "permission": Task { replyHandler(await notifications.request(tab: tab, origin: origin), nil) }
        case "show":
            guard let id = body["id"] as? String, UUID(uuidString: id) != nil, let title = body["title"] as? String
            else {
                replyHandler(nil, "Invalid notification.")
                return
            }
            Task {
                do {
                    try await notifications.deliver(
                        tab: tab, origin: origin, id: id, title: title, body: body["body"] as? String ?? "",
                        silent: body["silent"] as? Bool ?? false)
                    replyHandler(true, nil)
                } catch { replyHandler(nil, "This notification couldn’t be delivered.") }
            }
        case "close":
            if let id = body["id"] as? String, UUID(uuidString: id) != nil { notifications.close(tab: tab, id: id) }
            replyHandler(true, nil)
        default: replyHandler(nil, "Unknown notification action.")
        }
    }
    static let script = #"""
        (() => {
          if (!isSecureContext || self !== top || globalThis.__loafNotifications) return;
          globalThis.__loafNotifications = true;
          const bridge = window.webkit.messageHandlers.loafNotification;
          let permission = 'default'; const active = new Map();
          bridge.postMessage({operation:'state'}).then(value => permission=value).catch(()=>permission='denied');
          class LoafNotification extends EventTarget {
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static async requestPermission(callback) {
              if (!navigator.userActivation?.isActive) { callback?.(permission); return permission; }
              permission = await bridge.postMessage({operation:'permission'}).catch(()=>'denied');
              callback?.(permission); return permission;
            }
            constructor(title, options={}) {
              super();
              if (permission !== 'granted') throw new DOMException('Notification permission is required.','NotAllowedError');
              this.title=String(title); this.body=String(options.body||''); this.tag=String(options.tag||'');
              this.data=options.data; this.silent=!!options.silent; this.id=crypto.randomUUID();
              this.onclick=this.onshow=this.onerror=this.onclose=null; active.set(this.id,this);
              bridge.postMessage({operation:'show',id:this.id,title:this.title,body:this.body,silent:this.silent})
                .then(()=>this.emit('show')).catch(()=>this.emit('error'));
            }
            emit(type) { const event=new Event(type); this.dispatchEvent(event); this['on'+type]?.(event); }
            close() { bridge.postMessage({operation:'close',id:this.id}).catch(()=>{}); active.delete(this.id); this.emit('close'); }
          }
          window.addEventListener('loafNotificationClick',event=>active.get(event.detail?.[0])?.emit('click'));
          Object.defineProperty(window,'Notification',{value:LoafNotification,configurable:true});
        })();
        """#
}

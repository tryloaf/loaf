import AppKit
import WebKit

nonisolated enum ExternalAppLinkPolicy: String, Codable, CaseIterable, Sendable {
    case inherit, ask, allow, block
    var title: String {
        switch self {
        case .inherit: "follow website setting"
        case .ask: "ask every time"
        case .allow: "always open"
        case .block: "never open"
        }
    }
    static func effective(site: Self?, application: Self?) -> Self {
        if site == .block || application == .block { return .block }
        if site == .ask || application == .ask { return .ask }
        if site == .allow || application == .allow { return .allow }
        return .ask
    }

}

nonisolated struct ExternalAppLinkPreference: Codable, Sendable {
    var name: String
    var applicationPath: String
    var policy: ExternalAppLinkPolicy

    static func identity(for application: URL) -> String {
        if let identifier = Bundle(url: application)?.bundleIdentifier, !identifier.isEmpty {
            return "bundle:" + identifier
        }
        return "path:" + application.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@MainActor final class ExternalAppLinks {
    typealias Resolver = (URL) -> URL?
    typealias Opener = (URL, URL, @escaping (Error?) -> Void) -> Void
    private let resolve: Resolver
    private let open: Opener
    private var pending = false
    private var lastAutomaticRequest: (navigation: UUID, scheme: String)?

    init(
        resolve: @escaping Resolver = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        open: @escaping Opener = { url, application, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
                completion(error)
            }
        }
    ) {
        self.resolve = resolve
        self.open = open
    }

    nonisolated static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !["http", "https", "about", "blob", "data", "javascript", "file", "webkit-extension"].contains(scheme)
    }

    func request(_ target: URL, from tab: BrowserTab, action: WKNavigationAction) {

        let origin = action.sourceFrame.securityOrigin
        var source = URLComponents()
        source.scheme = origin.protocol
        source.host = origin.host
        if origin.port != 0 { source.port = origin.port }
        request(
            target, from: tab, sourceURL: source.url ?? action.sourceFrame.request.url,
            clicked: action.navigationType == .linkActivated,
            mainFrame: action.targetFrame?.isMainFrame ?? true)
    }

    func request(_ target: URL, from tab: BrowserTab, sourceURL: URL?, clicked: Bool, mainFrame: Bool) {
        guard Self.isExternal(target), !pending, !tab.isDisposed, let store = tab.store,
            let coordinator = store.application.coordinator,
            store.selectedProfileID == tab.profileID,
            store.selectedTab?.id == tab.id || store.visibleSplit?.contains(tab.id) == true,
            store.nativeWindow?.isVisible == true
        else { return }
        let pageURL = tab.existingWebView?.url ?? tab.url


        guard clicked || mainFrame || (
            sourceURL.flatMap(BrowserAddress.websiteOrigin) != nil
                && sourceURL.flatMap(BrowserAddress.websiteOrigin) == pageURL.flatMap(BrowserAddress.websiteOrigin))
        else { return }
        let scheme = target.scheme!.lowercased()
        let navigation = tab.navigationID
        if !clicked, let lastAutomaticRequest,
            lastAutomaticRequest.navigation == navigation, lastAutomaticRequest.scheme == scheme
        { return }
        lastAutomaticRequest = (navigation, scheme)

        let applicationURL = resolve(target)

        guard applicationURL?.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
            applicationURL.flatMap({ Bundle(url: $0)?.bundleIdentifier }) != BrowserBrand.bundleIdentifier
        else { return }
        let applicationName = applicationURL.map {
            let name = FileManager.default.displayName(atPath: $0.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        let siteOrigin = sourceURL.flatMap(BrowserAddress.websiteOrigin)
            ?? (sourceURL == nil ? pageURL.flatMap(BrowserAddress.websiteOrigin) : nil)
        let origin = siteOrigin ?? "this page"
        let identity = applicationURL.map(ExternalAppLinkPreference.identity)
        let policy = store.externalAppLinkPolicy(identity: identity, origin: siteOrigin, profileID: tab.profileID)
        if let identity, let applicationURL, let applicationName,
            store.externalAppLinkPreference(identity: identity, profileID: tab.profileID) == nil {
            store.setExternalAppLinkPreference(
                .init(name: applicationName, applicationPath: applicationURL.path, policy: .inherit),
                identity: identity, profileID: tab.profileID)
        }
        if policy == .block { return }
        if policy == .allow, let applicationURL, let applicationName {
            launch(target, application: applicationURL, name: applicationName, store: store)
            return
        }
        let alert = NSAlert()
        if let applicationName {
            let site = origin == "this page" ? origin : BrowserAddress.visible(origin)
            alert.messageText = "\(site) wants to open \(applicationName)"
            alert.informativeText = store.profileFor(tab.profileID).privateMode
                ? "remember this app for this private session. app-wide blocks and ask settings still apply."
                : "remember this app across profiles on this Mac. website settings can still require permission or block opening."
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "always open \(applicationName)"
            alert.suppressionButton?.state = .off
            alert.addButton(withTitle: "open \(applicationName)")
            alert.addButton(withTitle: "cancel")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = "\u{1b}"
        } else {
            alert.messageText = "no app can open this link"
            alert.informativeText = "install an app that handles \(scheme) links, then try again."
            alert.addButton(withTitle: "ok")
        }
        alert.icon = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? LoafAppIcon.image
        pending = true
        let valid = { [weak tab, weak store] in
            guard let tab, let store else { return false }
            return !tab.isDisposed && tab.navigationID == navigation && store.selectedProfileID == tab.profileID
                && (store.selectedTab?.id == tab.id || store.visibleSplit?.contains(tab.id) == true)
        }
        coordinator.enqueueSheet(for: store, cancel: { [weak self] in self?.pending = false }) { [weak self, weak store] done in
            guard let self, let store, valid(), let window = store.nativeWindow,
                store.externalAppLinkPolicy(identity: identity, origin: siteOrigin, profileID: tab.profileID) != .block else {
                self?.pending = false
                done()
                return
            }
            alert.beginSheetModal(for: window) { [weak self, weak store] response in
                self?.pending = false
                done()
                guard response == .alertFirstButtonReturn, valid(), let store,
                    let applicationURL, let applicationName, let identity,
                    store.externalAppLinkPolicy(identity: identity, origin: siteOrigin, profileID: tab.profileID) != .block
                else { return }
                let remembered = alert.suppressionButton?.state == .on
                if remembered {
                    store.setExternalAppLinkPreference(
                        .init(name: applicationName, applicationPath: applicationURL.path, policy: .allow),
                        identity: identity, profileID: tab.profileID)
                }
                self?.launch(target, application: applicationURL, name: applicationName, store: store)
            }
        }
    }

    private func launch(_ target: URL, application: URL, name: String, store: BrowserStore) {
        open(target, application) { error in
            guard error != nil else { return }
            Task { @MainActor [weak store] in
                store?.error = "couldn’t open \(name). open the app, then try the link again."
            }
        }
    }
}

extension BrowserWindowState {
    func externalAppLinkPreference(identity: String, profileID: UUID) -> ExternalAppLinkPreference? {
        let profile = profileFor(profileID)
        if profile.privateMode, let preference = profile.externalAppLinks?[identity] { return preference }
        return preferences.externalAppLinks?[identity] ?? profile.externalAppLinks?[identity]
    }
    func externalAppLinkPolicy(identity: String?, origin: String?, profileID: UUID) -> ExternalAppLinkPolicy {
        let profile = profileFor(profileID)
        let site = origin.flatMap { profile.siteSettings?[$0]?.externalAppLinks }
        if let identity, preferences.externalAppLinks?[identity]?.policy == .block { return .block }
        let applicationPolicy: ExternalAppLinkPolicy? = identity.flatMap {
            if profile.privateMode, preferences.externalAppLinks?[$0]?.policy == .ask { return .ask }
            return externalAppLinkPreference(identity: $0, profileID: profileID)?.policy
        }
        return .effective(site: site, application: applicationPolicy)
    }
    var externalAppLinkPreferences: [String: ExternalAppLinkPreference] {
        if profile.privateMode {
            return (preferences.externalAppLinks ?? [:]).merging(profile.externalAppLinks ?? [:]) { _, local in local }
        }
        return (profile.externalAppLinks ?? [:]).merging(preferences.externalAppLinks ?? [:]) { _, global in global }
    }
    func setExternalAppLinkPreference(_ preference: ExternalAppLinkPreference, identity: String, profileID: UUID) {
        if profileFor(profileID).privateMode {
            updateProfile(profileID) {
                $0.externalAppLinks = $0.externalAppLinks ?? [:]
                $0.externalAppLinks?[identity] = preference
            }
        } else {
            preferences.externalAppLinks = preferences.externalAppLinks ?? [:]
            preferences.externalAppLinks?[identity] = preference
            persistSoon()
        }
    }
    func resetExternalAppLinkPreference(identity: String) {
        if profile.privateMode {
            updateCurrent { $0.externalAppLinks?.removeValue(forKey: identity) }
        } else {
            preferences.externalAppLinks?.removeValue(forKey: identity)
            for profile in application.profiles where !profile.privateMode && profile.externalAppLinks?[identity] != nil {
                updateProfile(profile.id) { $0.externalAppLinks?.removeValue(forKey: identity) }
            }
            persistSoon()
        }
    }
}

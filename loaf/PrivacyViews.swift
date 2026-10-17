import SwiftUI
import WebKit

extension BrowserAddress {
    nonisolated static func websiteOrigin(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), let scheme = url.scheme, ["https", "http"].contains(scheme),
            url.user == nil
        else { return nil }
        return scheme + "://" + host
            + (url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : ":\($0)" }
                ?? "")
    }
}
extension BrowserWindowState {
    func clear(_ request: ClearingRequest, profileID: UUID, now: Date = Date()) async {
        guard application.profiles.contains(where: { $0.id == profileID }),
            !application.busyProfileIDs.contains(profileID)
        else { return }
        application.busyProfileIDs.insert(profileID)
        defer { application.busyProfileIDs.remove(profileID) }
        let cutoff = request.timeframe.cutoff(now: now)
        let dataStore = runtime(for: profileID).dataStore
        if request.history { updateProfile(profileID) { $0.history.removeAll { $0.date >= cutoff } } }
        if request.cookies {

            for cookie in await dataStore.httpCookieStore.allCookies() {
                await dataStore.httpCookieStore.deleteCookie(cookie)
            }
            let types = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([
                WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeCookies,
            ])
            await dataStore.removeData(ofTypes: types, modifiedSince: cutoff)
        }
        if request.cache {
            await dataStore.removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: cutoff)
        }
        if request.downloads { downloads.clear(profileID: profileID, since: cutoff) }
        persist()
    }
    func clearSite(_ url: URL, profileID: UUID? = nil) async {
        let profileID = profileID ?? selectedProfileID
        guard let host = url.host, application.profiles.contains(where: { $0.id == profileID }),
            !application.busyProfileIDs.contains(profileID)
        else { return }
        application.busyProfileIDs.insert(profileID)
        defer { application.busyProfileIDs.remove(profileID) }
        let dataStore = runtime(for: profileID).dataStore
        let domain = PublicSuffixList.shared.registrableDomain(host)
        for cookie in await dataStore.httpCookieStore.allCookies()
        where BrowserAddress.domain(cookie.domain, belongsTo: host) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter {
            $0.displayName == domain || BrowserAddress.domain($0.displayName, belongsTo: host)
        }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }
}

struct ClearingView: View {
    @ObservedObject var store: BrowserStore
    var onCancel: (() -> Void)? = nil
    @State private var request = ClearingRequest()
    @State private var confirm = false
    @State private var clearing = false
    @State private var scope: UUID?
    @State private var scopeName = ""
    @State private var confirmedRequest = ClearingRequest()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Picker("time range", selection: $request.timeframe) {
                    ForEach(ClearingTimeframe.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("browsing history", isOn: $request.history)
                Toggle("cookies and website storage", isOn: $request.cookies)
                Toggle("cached files", isOn: $request.cache)
                Toggle("download records", isOn: $request.downloads)
            }.disabled(clearing)
            Text("scope: \(clearing ? scopeName : store.profile.name). downloaded files and favorites are retained.")
                .font(.caption).foregroundStyle(.secondary)
            if request.cookies {
                Text(
                    "cookies are cleared for the entire profile. website storage and cache may be cleared for a whole site, even when you choose a shorter time range."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let onCancel {
                    Button("cancel", action: onCancel).keyboardShortcut(.cancelAction).disabled(clearing)
                    Spacer()
                }
                SettingsActionButton(
                    "clear selected data…", busy: clearing,
                    disabled: store.application.busyProfileIDs.contains(store.selectedProfileID)
                        || !(request.history || request.cookies || request.cache || request.downloads),
                    role: .destructive
                ) {
                    scope = store.selectedProfileID
                    scopeName = store.profile.name
                    confirmedRequest = request
                    confirm = true
                }
            }
        }.interactiveDismissDisabled(clearing && onCancel != nil)
            .destructiveConfirmationDialog("clear data in \(scopeName)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("clear data", role: .destructive) {
                    guard let scope, store.application.profiles.contains(where: { $0.id == scope }),
                        !store.application.busyProfileIDs.contains(scope)
                    else { return }
                    let selected = confirmedRequest
                    clearing = true
                    Task {
                        await store.clear(selected, profileID: scope)
                        clearing = false
                        onCancel?()
                    }
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text(
                    "\(confirmedRequest.timeframe.rawValue). \(confirmedRequest.cookies ? "all cookies in this profile will be removed, which can sign you out. " : "")This cannot be undone. Downloaded files stay on disk."
                )
            }
    }
}

nonisolated struct CookieListSnapshot: Sendable {
    struct Item: Identifiable, Sendable {
        enum Content: Sendable {
            case domain(String, Int)
            case cookie(HTTPCookie)
        }
        let id: String
        let content: Content
    }
    let cookies: [HTTPCookie]
    static func identity(_ cookie: HTTPCookie) -> String {
        cookie.domain + "\n" + cookie.path + "\n" + cookie.name
    }
    init(_ cookies: [HTTPCookie]) {
        self.cookies = cookies.sorted { ($0.domain, $0.name, $0.path) < ($1.domain, $1.name, $1.path) }
    }
    func items(matching query: String) -> [Item] {
        let matching =
            query.isEmpty
            ? cookies
            : cookies.filter {
                $0.domain.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
            }
        var counts: [String: Int] = [:]
        for cookie in matching { counts[cookie.domain, default: 0] += 1 }
        var items: [Item] = []
        items.reserveCapacity(matching.count + counts.count)
        var previousDomain: String?
        for (index, cookie) in matching.enumerated() {
            if index % 256 == 0, Task.isCancelled { return [] }
            if previousDomain != cookie.domain {
                items.append(
                    Item(
                        id: "domain\n" + cookie.domain,
                        content: .domain(cookie.domain, counts[cookie.domain] ?? 0)))
                previousDomain = cookie.domain
            }
            items.append(Item(id: "cookie\n" + Self.identity(cookie), content: .cookie(cookie)))
        }
        return items
    }
}

struct CookieManagerView: View {
    @ObservedObject var store: BrowserStore
    @State private var snapshot = CookieListSnapshot([])
    @State private var items: [CookieListSnapshot.Item] = []
    @State private var snapshotProfileID: UUID?
    @State private var snapshotRevision = UUID()
    @State private var loadRevision = UUID()
    @State private var loading = true
    @State private var displayedSource: FilterSource?
    @State private var query = ""
    @State private var selectedCookies: Set<String> = []
    @State private var deletionCookies: [HTTPCookie] = []
    @State private var deletionProfileID: UUID?
    @State private var deletionProfileName = ""
    @State private var confirmDeletion = false
    @State private var deleting = false
    private struct FilterSource: Equatable {
        let profile: UUID
        let revision: UUID
        let query: String
    }
    private var filterSource: FilterSource {
        FilterSource(profile: store.selectedProfileID, revision: snapshotRevision, query: query)
    }
    private var isBusy: Bool { loading || displayedSource != filterSource }
    private var cookies: [HTTPCookie] { snapshot.cookies }
    private var filtered: [HTTPCookie] {
        items.compactMap { if case .cookie(let cookie) = $0.content { cookie } else { nil } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("search cookies…", text: $query).textFieldStyle(.roundedBorder).focusRingPadding()
                Button("select all") { selectedCookies = Set(filtered.map(cookieID)) }
                    .controlSize(.small).disabled(items.isEmpty || isBusy)
                if !selectedCookies.isEmpty {
                    Button("delete \(selectedCookies.count)…", role: .destructive) { deleteSelectedCookies() }
                        .controlSize(.small).disabled(deleting || isBusy)
                }
                Button("history") { store.showPage(.history) }.controlSize(.small)
            }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.vertical, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(
                        "\(cookies.count.formatted()) \(cookies.count == 1 ? "cookie" : "cookies") · \(store.profile.name)"
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                    if isBusy {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 32)
                            .accessibilityLabel("loading cookies")
                    } else if items.isEmpty {
                        emptyLibrary(
                            icon: .cookie, title: query.isEmpty ? "no cookies saved" : "no matching cookies",
                            detail: query.isEmpty
                                ? "cookies saved by sites in this profile will appear here."
                                : "try another domain or cookie name.")
                    }
                    ForEach(items) { item in
                        switch item.content {
                        case .domain(let domain, let count):
                            HStack(spacing: 8) {
                                WebsiteIcon(
                                    url: URL(
                                        string: "https://"
                                            + domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                                    store: store)
                                Text(domain).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(.top, 16).padding(.bottom, 4)
                                .contextMenu {
                                    Button("delete domain cookies…", role: .destructive) { deleteDomain(domain) }
                                }
                        case .cookie(let cookie):
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cookie.name).font(.system(size: 12)).lineLimit(1)
                                    Text(
                                        cookie.path + (cookie.isSecure ? " · secure" : "")
                                            + (cookie.isHTTPOnly ? " · HTTP only" : "")
                                    )
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(
                                    cookie.expiresDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
                                        ?? "session"
                                )
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                                .background(
                                    Color.accentColor.opacity(selectedCookies.contains(cookieID(cookie)) ? 0.12 : 0),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle()).onTapGesture {
                                    let id = cookieID(cookie)
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if !selectedCookies.insert(id).inserted { selectedCookies.remove(id) }
                                    } else {
                                        selectedCookies = [id]
                                    }
                                }.accessibilityAddTraits(selectedCookies.contains(cookieID(cookie)) ? .isSelected : [])
                                .contextMenu {
                                    Button("delete cookie…", role: .destructive) {
                                        selectedCookies = [cookieID(cookie)]
                                        deleteSelectedCookies()
                                    }
                                    Button("delete domain cookies…", role: .destructive) { deleteDomain(cookie.domain) }
                                }
                        }
                    }
                    .disabled(isBusy)
                    if !cookies.isEmpty {
                        Text("domain cookies may be shared by subdomains. deleting them can sign you out.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
        }.background(LibraryDeleteKey(enabled: !deleting && !selectedCookies.isEmpty, delete: deleteSelectedCookies))
            .destructiveConfirmationDialog(
                "delete \(deletionCookies.count) cookies?", isPresented: $confirmDeletion, titleVisibility: .visible
            ) {
                Button("delete cookies", role: .destructive) { performDeletion() }
                Button("cancel", role: .cancel) { deletionCookies = [] }
            } message: {
                Text("This can sign you out of websites in \(deletionProfileName). It cannot be undone.")
            }
            .task(id: store.selectedProfileID) {
                selectedCookies = []
                confirmDeletion = false
                deletionCookies = []
                items = []
                snapshot = CookieListSnapshot([])
                snapshotProfileID = nil
                displayedSource = nil
                await refresh()
            }
            .task(id: filterSource) {
                guard snapshotProfileID == store.selectedProfileID else { return }
                let snapshot = snapshot
                let source = filterSource
                let work = Task.detached(priority: .userInitiated) { snapshot.items(matching: source.query) }
                let result = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled, source == filterSource else { return }
                items = result
                selectedCookies.formIntersection(Set(filtered.map(cookieID)))
                displayedSource = source
            }
    }
    private func deleteDomain(_ domain: String) {
        requestDeletion(cookies.filter { $0.domain.lowercased() == domain.lowercased() })
    }
    private func cookieID(_ cookie: HTTPCookie) -> String { CookieListSnapshot.identity(cookie) }
    private func deleteSelectedCookies() {
        requestDeletion(cookies.filter { selectedCookies.contains(cookieID($0)) })
    }
    private func requestDeletion(_ selected: [HTTPCookie]) {
        guard !deleting, !isBusy, snapshotProfileID == store.selectedProfileID,
            !selected.isEmpty, !store.application.busyProfileIDs.contains(store.selectedProfileID)
        else {
            return
        }
        deletionCookies = selected
        deletionProfileID = store.selectedProfileID
        deletionProfileName = store.profile.name
        confirmDeletion = true
    }
    private func performDeletion() {
        guard !deleting, let id = deletionProfileID, store.application.profiles.contains(where: { $0.id == id }),
            !store.application.busyProfileIDs.contains(id)
        else { return }
        let selected = deletionCookies
        let jar = store.runtime(for: id).dataStore.httpCookieStore
        store.application.busyProfileIDs.insert(id)
        deleting = true
        selectedCookies = []
        Task {
            defer {
                deleting = false
                store.application.busyProfileIDs.remove(id)
            }
            for cookie in selected { await jar.deleteCookie(cookie) }
            if store.selectedProfileID == id { await refresh() }
        }
    }
    private func refresh() async {
        let id = store.selectedProfileID
        let revision = UUID()
        loadRevision = revision
        loading = true
        let result = await store.runtime.dataStore.httpCookieStore.allCookies()
        guard !Task.isCancelled, id == store.selectedProfileID, loadRevision == revision else { return }
        let work = Task.detached(priority: .userInitiated) { CookieListSnapshot(result) }
        let prepared = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, id == store.selectedProfileID, loadRevision == revision else { return }
        snapshot = prepared
        snapshotProfileID = id
        snapshotRevision = UUID()
        loading = false
    }
}

struct SiteSettingsView: View {
    @ObservedObject var store: BrowserStore
    let session: SiteSettingsSession
    let close: () -> Void
    @State private var confirm = false
    @State private var clearing = false
    @State private var cookieCount: Int?
    @State private var confirmReset = false
    @State private var captureRevision = 0
    private func binding<Value>(_ key: WritableKeyPath<SiteSettings, Value>) -> Binding<Value> {
        Binding(get: { session.settings[keyPath: key] }, set: { session.set(key, $0) })
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let url = session.url {
                        WebsiteIcon(url: url, store: store, size: 20)
                    } else {
                        GolzheimIcon(icon: .info, size: 20).foregroundStyle(.secondary)
                    }
                    Text(session.origin.map { BrowserAddress.visible($0) } ?? "no website selected")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: close) { GolzheimIcon(icon: .close, size: 12).frame(width: 20, height: 20) }
                        .buttonStyle(PlayerActionStyle(outline: false))
                        .help("close website settings").accessibilityLabel("close website settings")
                        .keyboardShortcut(.cancelAction)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let url = session.url, session.origin != nil {
                        Label {
                            Text(
                                url.scheme == "https"
                                    ? session.tab?.secure == true
                                        ? "encrypted connection" : "some content is not secure"
                                    : "connection is not encrypted")
                        } icon: {
                            GolzheimIcon(icon: url.scheme == "https" ? .lock : .insecure, size: 11)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(session.profile?.name ?? "profile closed").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(12)
            Divider().padding(.horizontal, 12)
            if let url = session.url, let host = url.host, session.origin != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        SiteControlSection(title: "privacy") {
                            SiteControlToggle(
                                "block ads and trackers",
                                isOn: Binding(
                                    get: {
                                        session.profile?.blockerEnabled == true
                                            && !(session.profile?.allowedSites.contains(host) ?? true)
                                    }, set: { _ in if session.valid { store.toggleBlockerForSite() } })
                            ).disabled(session.profile?.blockerEnabled != true)
                                .help("enable the blocker in privacy settings to use website exceptions")
                            SiteControlToggle(
                                "offer to save passwords",
                                isOn: Binding(
                                    get: { session.settings.savePasswords != false },
                                    set: { session.set(\.savePasswords, $0) })
                            )
                            .disabled(!store.preferences.savePasswords)
                            HStack {
                                Text("cookies")
                                Spacer()
                                Text(cookieCount.map { String($0) + " saved" } ?? "…").foregroundStyle(.secondary)
                                Button(clearing ? "clearing…" : "clear data…", role: .destructive) {
                                    confirm = true
                                }.disabled(clearing).help("clear cookies and website data")
                            }.frame(minHeight: 26)
                        }
                        Divider()
                        SiteControlSection(title: "permissions") {
                            SiteControlToggle(
                                "allow downloads",
                                isOn: Binding(
                                    get: { session.settings.downloads != false },
                                    set: { session.set(\.downloads, $0) })
                            ).help("applies to this exact site. new sites ask first when download prompts are enabled.")
                            ExternalAppLinkSitePicker(selection: Binding(
                                get: { session.settings.externalAppLinks },
                                set: { session.set(\.externalAppLinks, $0) }))
                            SiteControlPicker("camera", selection: binding(\.camera)) { permissionChoices }
                            SiteControlPicker("microphone", selection: binding(\.microphone)) { permissionChoices }
                            SiteControlPicker(
                                "location",
                                selection: Binding(
                                    get: { session.settings.location ?? "deny" }, set: { session.set(\.location, $0) })
                            ) { permissionChoices }
                            SiteControlPicker(
                                "notifications",
                                selection: Binding(
                                    get: { session.settings.notifications ?? "ask" },
                                    set: { session.set(\.notifications, $0) })
                            ) { permissionChoices }
                            SiteControlPicker(
                                "pointer capture",
                                selection: Binding(
                                    get: { session.settings.pointerLock ?? "allow" },
                                    set: { session.set(\.pointerLock, $0) })
                            ) { permissionChoices }.disabled(store.preferences.allowsPointerCapture == false)
                                .help(
                                    "press Escape twice to release the pointer. macOS camera and microphone permissions still apply."
                                )
                            SiteControlToggle(
                                "automatic pop-ups",
                                isOn: Binding(
                                    get: { session.settings.automaticPopups == true },
                                    set: { session.set(\.automaticPopups, $0) })
                            ).disabled(!WebKitAdapter.supportsSitePopups)
                            if let tab = session.tab {
                                if tab.webView.cameraCaptureState != .none {
                                    captureControl("camera", state: tab.webView.cameraCaptureState) { state in
                                        tab.webView.setCameraCaptureState(state) { captureRevision += 1 }
                                    }
                                }
                                if tab.webView.microphoneCaptureState != .none {
                                    captureControl("microphone", state: tab.webView.microphoneCaptureState) { state in
                                        tab.webView.setMicrophoneCaptureState(state) { captureRevision += 1 }
                                    }
                                }
                            }
                        }
                        Divider()
                        DisclosureGroup("page preferences") {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("zoom")
                                    Spacer()
                                    Text("\(Int((session.settings.zoom * 100).rounded()))%").monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Button("reset") { if session.valid { store.resetPageZoom() } }
                                }
                                Slider(
                                    value: Binding(
                                        get: { session.settings.zoom },
                                        set: { if session.valid { store.setPageZoom($0) } }), in: 0.5...3, step: 0.1
                                ).accessibilityLabel("website zoom")
                                SiteControlToggle("javascript", isOn: binding(\.javascript))
                                SiteControlToggle("autoplay", isOn: binding(\.autoplay)).disabled(
                                    !WebKitAdapter.supportsSiteAutoplay)
                                SiteControlPicker("browser identity", selection: binding(\.userAgent)) {
                                    Text("desktop Safari").tag(UserAgentMode.desktop)
                                    Text("automatic").tag(UserAgentMode.automatic)
                                }
                                Text("reload to apply javascript and autoplay changes").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Button("reset website overrides…") { confirmReset = true }
                                    .padding(.top, 6)
                            }.padding(.top, 4)
                        }
                    }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
                }.scrollIndicators(.hidden).font(.system(size: 12)).controlSize(.small)
                    .destructiveConfirmationDialog("clear website data?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("clear data", role: .destructive) {
                            guard session.valid else { return }
                            clearing = true
                            Task {
                                await store.clearSite(url, profileID: session.profileID)
                                await refreshCookies()
                                clearing = false
                            }
                        }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "this can sign you out of \(PublicSuffixList.shared.registrableDomain(host)) and its subdomains in \(session.profile?.name ?? "this profile")."
                        )
                    }
                    .destructiveConfirmationDialog(
                        "reset website overrides?", isPresented: $confirmReset, titleVisibility: .visible
                    ) {
                        Button("reset overrides", role: .destructive) { if session.valid { session.reset() } }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "This restores default permissions and page preferences for this website in \(session.profile?.name ?? "this profile")."
                        )
                    }
                    .task { await refreshCookies() }
                Divider().padding(.horizontal, 12)
                HStack {
                    Text("this website · this profile").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        session.tab?.reload()
                    } label: {
                        Label {
                            Text("reload")
                        } icon: {
                            GolzheimIcon(icon: .reload, size: 12)
                        }
                    }.controlSize(.small)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Text("open a website to manage permissions").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08))
        ).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var permissionChoices: some View {
        Text("ask").tag("ask")
        Text("allow").tag("allow")
        Text("deny").tag("deny")
    }
    private func captureControl(
        _ name: String, state: WKMediaCaptureState, change: @escaping (WKMediaCaptureState) -> Void
    ) -> some View {
        HStack {
            Text(name + (state == .active ? " is active" : " is muted")).foregroundStyle(.secondary)
            Spacer()
            Button(state == .active ? "mute" : "unmute") {
                if session.valid { change(state == .active ? .muted : .active) }
            }
        }.id(captureRevision)
    }
    private func refreshCookies() async {
        guard let host = session.url?.host, session.valid else { return }
        let jar = store.runtime(for: session.profileID).dataStore.httpCookieStore
        let cookies = await jar.allCookies()
        if session.valid { cookieCount = cookies.filter { BrowserAddress.domain($0.domain, belongsTo: host) }.count }
    }
}

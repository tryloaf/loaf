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
        guard let host = url.host, application.profiles.contains(where: { $0.id == profileID }) else { return }
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
    @State private var request = ClearingRequest()
    @State private var confirm = false
    @State private var clearing = false
    @State private var scope: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("time range", selection: $request.timeframe) {
                ForEach(ClearingTimeframe.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("browsing history", isOn: $request.history)
            Toggle("cookies and website storage", isOn: $request.cookies)
            Toggle("cached files", isOn: $request.cache)
            Toggle("download records", isOn: $request.downloads)
            Text("scope: \(store.profile.name). downloaded files and favorites are retained.").font(.caption)
                .foregroundStyle(.secondary)
            if request.cookies {
                Text(
                    "cookies are cleared for the entire profile. website storage and cache may be cleared for a whole site, even when you choose a shorter time range."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Button(clearing ? "clearing…" : "clear selected data…", role: .destructive) {
                scope = store.selectedProfileID
                confirm = true
            }.disabled(clearing || !(request.history || request.cookies || request.cache || request.downloads))
        }.confirmationDialog(
            "clear data in \(store.profileFor(scope ?? store.selectedProfileID).name)?", isPresented: $confirm,
            titleVisibility: .visible
        ) {
            Button("clear data", role: .destructive) {
                guard let scope else { return }
                let selected = request
                clearing = true
                Task {
                    await store.clear(selected, profileID: scope)
                    clearing = false
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(
                "\(request.timeframe.rawValue). \(request.cookies ? "all cookies in this profile will be removed. " : "")downloaded files stay on disk."
            )
        }
    }
}

struct CookieManagerView: View {
    @ObservedObject var store: BrowserStore
    @State private var cookies: [HTTPCookie] = []
    @State private var query = ""
    @State private var selectedCookies: Set<String> = []
    private var filtered: [HTTPCookie] {
        cookies.filter {
            query.isEmpty || $0.domain.localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
        }.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }
    private var domains: [String] { Array(Set(filtered.map(\.domain))).sorted() }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("search cookies…", text: $query).textFieldStyle(.roundedBorder)
                Button("select all") { selectedCookies = Set(filtered.map(cookieID)) }
                    .controlSize(.small).disabled(filtered.isEmpty)
                if !selectedCookies.isEmpty {
                    Button("delete \(selectedCookies.count)") { deleteSelectedCookies() }.controlSize(.small)
                }
                Button("history") { store.showPage(.history) }.controlSize(.small)
            }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.vertical, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("\(cookies.count.formatted()) \(cookies.count == 1 ? "cookie" : "cookies") · \(store.profile.name)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                    if filtered.isEmpty {
                        emptyLibrary(icon: .cookie, title: query.isEmpty ? "no cookies saved" : "no matching cookies",
                            detail: query.isEmpty ? "cookies saved by sites in this profile will appear here." : "try another domain or cookie name.")
                    }
                    ForEach(domains, id: \.self) { domain in
                        let domainCookies = filtered.filter { $0.domain == domain }
                        HStack(spacing: 8) {
                            WebsiteIcon(url: URL(string: "https://" + domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))), store: store)
                            Text(domain).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(domainCookies.count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 16).padding(.bottom, 4)
                            .contextMenu {
                                Button("Delete Domain Cookies") { deleteDomain(domain) }
                            }
                        ForEach(domainCookies, id: \.self) { cookie in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cookie.name).font(.system(size: 12)).lineLimit(1)
                                    Text(cookie.path + (cookie.isSecure ? " · secure" : "") + (cookie.isHTTPOnly ? " · HTTP only" : ""))
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(cookie.expiresDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "session")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color.accentColor.opacity(selectedCookies.contains(cookieID(cookie)) ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle()).onTapGesture {
                                    let id = cookieID(cookie)
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if !selectedCookies.insert(id).inserted { selectedCookies.remove(id) }
                                    } else { selectedCookies = [id] }
                                }.accessibilityAddTraits(selectedCookies.contains(cookieID(cookie)) ? .isSelected : [])
                                .contextMenu {
                                    Button("Delete Cookie") { selectedCookies = [cookieID(cookie)]; deleteSelectedCookies() }
                                    Button("Delete Domain Cookies") { deleteDomain(domain) }
                                }
                        }
                    }
                    if !cookies.isEmpty {
                        Text("domain cookies may be shared by subdomains. deleting them can sign you out.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
        }.background(LibraryDeleteKey(enabled: !selectedCookies.isEmpty, delete: deleteSelectedCookies))
            .task(id: store.selectedProfileID) { selectedCookies = []; await refresh() }
            .onChange(of: query) { _, _ in selectedCookies.formIntersection(Set(filtered.map(cookieID))) }
    }
    private func deleteDomain(_ domain: String) {
        let jar = store.runtime.dataStore.httpCookieStore
        let selected = cookies.filter { $0.domain.lowercased() == domain.lowercased() }
        Task { for cookie in selected { await jar.deleteCookie(cookie) }; await refresh() }
    }
    private func cookieID(_ cookie: HTTPCookie) -> String { cookie.domain + "\n" + cookie.path + "\n" + cookie.name }
    private func deleteSelectedCookies() {
        let jar = store.runtime.dataStore.httpCookieStore
        let selected = cookies.filter { selectedCookies.contains(cookieID($0)) }
        selectedCookies = []
        Task {
            for cookie in selected { await jar.deleteCookie(cookie) }
            await refresh()
        }
    }
    private func refresh() async {
        let id = store.selectedProfileID
        let result = await store.runtime.dataStore.httpCookieStore.allCookies()
        if id == store.selectedProfileID {
            cookies = result
            selectedCookies.formIntersection(Set(result.map(cookieID)))
        }
    }
}

struct SiteSettingsView: View {
    @ObservedObject var store: BrowserStore
    let session: SiteSettingsSession
    let close: () -> Void
    @State private var confirm = false
    @State private var clearing = false
    @State private var cookieCount: Int?
    @State private var captureRevision = 0
    private func binding<Value>(_ key: WritableKeyPath<SiteSettings, Value>) -> Binding<Value> {
        Binding(get: { session.settings[keyPath: key] }, set: { session.set(key, $0) })
    }
    private func row(_ glyph: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            EmojiIcon(glyph: glyph, size: 16)
            Text(title)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                if let url = session.url {
                    WebsiteIcon(url: url, store: store, size: 20)
                } else {
                    GolzheimIcon(icon: .info, size: 20).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.origin.map { BrowserAddress.visible($0) } ?? "no website selected").font(
                        .system(size: 13, weight: .medium)
                    ).lineLimit(1).textSelection(.enabled)
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
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) { GolzheimIcon(icon: .close, size: 12).frame(width: 20, height: 20) }.buttonStyle(
                    PlayerActionStyle(outline: false)
                ).help("close website settings").accessibilityLabel("close website settings").keyboardShortcut(
                    .cancelAction)
            }.padding(12)
            if let url = session.url, let host = url.host, session.origin != nil {
                Divider().padding(.horizontal, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            caption("privacy")
                            Toggle(
                                "block ads and trackers",
                                isOn: Binding(
                                    get: {
                                        session.profile?.blockerEnabled == true
                                            && !(session.profile?.allowedSites.contains(host) ?? true)
                                    }, set: { _ in if session.valid { store.toggleBlockerForSite() } })
                            ).disabled(session.profile?.blockerEnabled != true)
                                .help("enable the blocker in privacy settings to use website exceptions")
                            Toggle(
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
                            }
                            Button(clearing ? "clearing…" : "clear website data…", role: .destructive) {
                                confirm = true
                            }.disabled(clearing)
                        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 10) {
                            caption("permissions")
                            Toggle(
                                "allow downloads",
                                isOn: Binding(
                                    get: { session.settings.downloads != false },
                                    set: { session.set(\.downloads, $0) })
                            ).help("applies to this exact site. new sites ask first when download prompts are enabled.")
                            Picker("camera", selection: binding(\.camera)) { permissionChoices }
                            Picker("microphone", selection: binding(\.microphone)) { permissionChoices }
                            Picker(
                                "location",
                                selection: Binding(
                                    get: { session.settings.location ?? "deny" }, set: { session.set(\.location, $0) })
                            ) { permissionChoices }
                            Picker(
                                "notifications",
                                selection: Binding(
                                    get: { session.settings.notifications ?? "ask" },
                                    set: { session.set(\.notifications, $0) })
                            ) { permissionChoices }
                            Picker(
                                "pointer capture",
                                selection: Binding(
                                    get: { session.settings.pointerLock ?? "allow" },
                                    set: { session.set(\.pointerLock, $0) })
                            ) { permissionChoices }.disabled(store.preferences.allowsPointerCapture == false)
                                .help(
                                    "press Escape twice to release the pointer. macOS camera and microphone permissions still apply."
                                )
                            Toggle(
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
                        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        DisclosureGroup("page preferences") {
                            VStack(alignment: .leading, spacing: 8) {
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
                                Toggle("javascript", isOn: binding(\.javascript))
                                Toggle("autoplay", isOn: binding(\.autoplay)).disabled(
                                    !WebKitAdapter.supportsSiteAutoplay)
                                Picker("browser identity", selection: binding(\.userAgent)) {
                                    Text("desktop Safari").tag(UserAgentMode.desktop)
                                    Text("automatic").tag(UserAgentMode.automatic)
                                }
                                Text("reload to apply javascript, autoplay and pop-up changes").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Button("reset website overrides") { session.reset() }
                            }.padding(.top, 8)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden).font(.system(size: 12)).controlSize(.small).toggleStyle(.switch)
                    .confirmationDialog("clear website data?", isPresented: $confirm, titleVisibility: .visible) {
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
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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

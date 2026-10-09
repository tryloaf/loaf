import LocalAuthentication
import SwiftUI
import Translation
import WebKit

struct BrowserToolbar: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let tab = store.selectedTab
        let pageChrome = tab?.page == .web && tab?.url != nil && tab?.readerArticle == nil
        let palette = ChromePalette(
            dark: store.profile.privateMode || ((pageChrome ? tab?.chromePrefersDark : nil) ?? (scheme == .dark)),
            sample: pageChrome ? tab?.chromeColor : nil, privateMode: store.profile.privateMode)
        HStack(spacing: 4) {
            Spacer().frame(width: 76)
            IconButton(icon: .sidebar, label: "show sidebar") { store.sidebarVisible = true }
            HStack(spacing: 0) {
                IconButton(icon: .back, label: "back") { store.selectedTab?.webView.goBack() }.disabled(
                    !(store.selectedTab?.canGoBack ?? false))
                IconButton(icon: .forward, label: "forward") { store.selectedTab?.webView.goForward() }.disabled(
                    !(store.selectedTab?.canGoForward ?? false))
                IconButton(icon: store.selectedTab?.loading == true ? .close : .reload, label: "reload") {
                    if store.selectedTab?.loading == true {
                        store.selectedTab?.webView.stopLoading()
                    } else {
                        store.selectedTab?.reload()
                    }
                }
            }
            Spacer(minLength: 8)
            AddressFeedback(feedback: store.feedback, activate: { store.openOmnibar() }, horizontalInset: 12) {
                HStack(spacing: 0) {
                    AddressSecurityButton(
                        icon: BrowserAddress.defaultSearchQuery(tab?.url) != nil
                            ? .search : tab?.url?.scheme == "http" ? .insecure : tab?.secure == true ? .lock : .info
                    ) { store.toggleSiteSettings(from: .toolbar) }
                    .background(SiteSettingsAnchor(store: store, source: .toolbar))
                    Button {
                        store.openOmnibar()
                    } label: {
                        HStack(spacing: 8) {
                            AddressLabel(
                                url: tab?.url, fallback: tab?.page.address ?? "search or surf...", palette: palette,
                                pageTitle: tab?.page == .web ? tab?.title ?? "" : nil
                            ).font(.system(size: 12))
                            if store.profile.privateMode {
                                Text("private").font(.system(size: 10, weight: .medium)).foregroundStyle(
                                    palette.secondary
                                ).fixedSize()
                            }
                        }.padding(.leading, 4).padding(.trailing, 8).frame(
                            maxWidth: .infinity, maxHeight: .infinity, alignment: .leading
                        ).contentShape(Rectangle())
                    }.buttonStyle(.plain).overlay(
                        WindowDragArea(click: { store.openOmnibar() }).accessibilityHidden(true)
                    ).accessibilityLabel("address bar")
                }.padding(.leading, 4)
            }.foregroundStyle(palette.primary).frame(maxWidth: 520).frame(height: 24)
                .background(
                    palette.surface.opacity(reduceTransparency ? 1 : 0.92), in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 8)
            IconButton(
                icon: store.isCurrentPageFavorite ? .favoriteFilled : .favorite,
                label: store.isCurrentPageFavorite ? "remove favorite" : "bookmark this page"
            ) { store.favoriteCurrent() }.disabled(store.selectedTab?.url == nil)
            IconButton(icon: .plus, label: "new tab") { _ = store.newTab() }
            Menu {
                Button("find on page") {
                    store.findFocusID = UUID()
                    store.findVisible = true
                }
                Button("reading view") { if let tab = store.selectedTab { Task { await tab.toggleReader() } } }
                Divider()
                Button("history") { store.showPage(.history) }
                Button("downloads") { store.showPage(.downloads) }
                Button("settings…") { store.application.coordinator?.showSettings(for: store) }
                Divider()
                Button("save page…") { store.selectedTab?.savePage() }.disabled(
                    store.selectedTab?.url == nil || store.selectedTab?.loading != false)
                Button("print…") { store.selectedTab?.printPage() }
            } label: {
                ChromeMoreIcon(color: palette.primary).frame(width: 26, height: 26).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("page actions")
        }.foregroundStyle(palette.primary).tint(palette.primary).padding(.trailing, 8).frame(height: 32)
            .offset(y: store.chromeControlsCenterY - 16)
            .background(WindowDragArea())
            .background {
                if reduceTransparency {
                    palette.barSurface
                } else if ProfileTransparency.bounded(store.profile.personalization?.windowTransparency ?? 0) > 0 {
                    WindowBackdrop().overlay(
                        palette.barSurface.opacity(
                            ProfileTransparency.opacity(store.profile.personalization?.windowTransparency ?? 0)))
                } else {
                    ChromeBackdrop().overlay(
                        palette.barSurface.opacity(palette.sample == nil || palette.privateMode ? 0.94 : 0.80))
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(palette.primary.opacity(0.06)).frame(height: 1) }
            .environment(\.colorScheme, palette.dark ? .dark : .light)
    }
}

struct ContentView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("loaf.appearance") private var appearance = "system"
    @ObservedObject private var systemAppearance = LoafAppearance.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    Color(
                        nsColor: store.selectedTab?.existingWebView?.underPageBackgroundColor ?? .windowBackgroundColor)
                    if store.ready, let tab = store.selectedTab {
                        VStack(spacing: 0) {
                            if store.findVisible {
                                PageFindBar(store: store, finder: tab.finder).id(tab.id).padding(
                                    .top, store.compactToolbarHeight)
                            }
                            Group {
                                switch tab.page {
                                case .history: HistoryView(store: store)
                                case .downloads: DownloadsView(store: store)
                                case .favorites: FavoritesView(store: store)
                                case .cookies: CookiePage(store: store)
                                case .settings: SettingsView(store: store)
                                case .extensions: SettingsView(store: store, initialSection: "extensions")
                                case .profiles: SettingsView(store: store, initialSection: "profiles")
                                case .about: AboutPage(store: store)
                                case .ask:
                                    if store.preferences.aiFeaturesEnabled != false {
                                        ChatGPTSearchView(
                                            store: store, search: tab.chatGPTSearch,
                                            account: store.application.chatGPTAccount
                                        ).id(tab.id)
                                    } else {
                                        VStack(spacing: 12) {
                                            Text("AI features are off").font(.headline)
                                            Button("search settings") {
                                                store.application.coordinator?.showSettings(for: store)
                                            }
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                case .web:
                                    if tab.url == nil {
                                        StartPage(store: store)
                                    } else {
                                        ZStack(alignment: .top) {
                                            if let article = tab.readerArticle {
                                                ReaderView(tab: tab, article: article)
                                            } else {
                                                BrowserWebSurface(
                                                    store: store, tab: tab,
                                                    topInset: store.findVisible ? 0 : store.compactToolbarHeight,
                                                    viewport: CGSize(
                                                        width: max(
                                                            0,
                                                            geometry.size.width - store.pageLeadingInset
                                                                - store.pageEdgeInset),
                                                        height: max(
                                                            0,
                                                            geometry.size.height - 2 * store.pageEdgeInset
                                                                - (store.findVisible
                                                                    ? PageFindBar.height + store.compactToolbarHeight
                                                                    : 0)))
                                                )
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .id(store.visibleSplit.map { "split:\($0.left):\($0.right)" } ?? "tab:\(tab.id)")
                                            }
                                            if tab.loading {
                                                GeometryReader { proxy in
                                                    Rectangle().fill(Color.accentColor).frame(
                                                        width: max(4, proxy.size.width * tab.progress), height: 2
                                                    ).animation(
                                                        reduceMotion ? nil : .easeOut(duration: 0.2),
                                                        value: tab.progress)
                                                }.frame(height: 2)
                                            }
                                            if let error = tab.navigationError { pageError(error, tab: tab) }
                                        }
                                    }
                                }
                            }.padding(
                                .top,
                                !store.sidebarPresented && !store.findVisible
                                    && (tab.page != .web || tab.url == nil || tab.readerArticle != nil)
                                    ? store.compactToolbarHeight : 0)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        BrowserLoadingView()
                    }
                    if store.compactToolbarHeight > 0 { BrowserToolbar(store: store).zIndex(1) }
                    if store.omnibarVisible {
                        Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture {
                            store.omnibarVisible = false
                        }.ignoresSafeArea().transition(.opacity)
                        GeometryReader { geometry in
                            let layout = OmnibarMetrics.layout(in: geometry.size.height)
                            VStack(spacing: 0) {
                                OmnibarView(
                                    store: store, suggestionHeight: layout.suggestions,
                                    width: OmnibarMetrics.width(in: geometry.size.width))
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, layout.top)
                        }.transition(.opacity).zIndex(3)
                    }
                    TabSwitcherView(switcher: store.tabSwitcher, previews: store.application.tabPreviews).frame(
                        maxWidth: .infinity, maxHeight: .infinity
                    ).allowsHitTesting(false).zIndex(6)
                    if let offer = store.pointerLockOffer {
                        VStack {
                            HStack(spacing: 12) {
                                GolzheimIcon(icon: .info, size: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("allow \(offer.host) to capture the pointer?").font(
                                        .system(size: 13, weight: .medium))
                                    Text("press escape twice to release it").font(.system(size: 12)).foregroundStyle(
                                        .secondary)
                                }
                                Button("not now") { store.cancelPointerLock() }.focusable(false)
                                Button("allow") {
                                    store.pointerLockOffer = nil
                                    offer.finish(true)
                                }.focusable(false)
                            }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(
                                color: .black.opacity(0.12), radius: 16, y: 4
                            ).padding(.horizontal, 24).padding(.top, 48)
                            Spacer()
                        }.zIndex(5)
                    }
                    if let offer = store.passwordOffer { passwordPrompt(offer) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

                    .clipShape(
                        RoundedRectangle(cornerRadius: store.pageCornerRadius, style: .continuous)
                            .inset(
                                by: store.pageEdgeInset > 0 || store.isFullscreen
                                    ? 0 : -1 / (store.nativeWindow?.backingScaleFactor ?? 2))
                    )
                    .padding(.leading, store.pageLeadingInset)
                    .padding([.top, .trailing, .bottom], store.pageEdgeInset)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: store.sidebarPresented)
                SidebarDock(store: store).zIndex(2)
                if !store.sidebarPresented && !store.hoveredSidebar {
                    Color.clear.frame(width: 8).contentShape(Rectangle()).onHover {
                        if $0 { store.revealSidebarFromEdge() }
                    }.zIndex(2)
                }
            }
            .background {
                ProfileWindowSurface(
                    color: store.profile.privateMode
                        ? PrivateChrome.base
                        : ProfileColor.surfaceColor(
                            profileTint(store.profile), strength: store.profile.personalization?.tintStrength ?? 0.06,
                            dark: scheme == .dark), transparency: store.profile.personalization?.windowTransparency ?? 0
                )
                .environment(
                    \.colorScheme,
                    store.profile.privateMode
                        ? .dark
                        : ProfileColor.surfaceScheme(
                            profileTint(store.profile), strength: store.profile.personalization?.tintStrength ?? 0.06,
                            dark: scheme == .dark))
            }.background(WindowChrome(store: store))
            .overlay(alignment: .topLeading) {
                if store.fullscreenControlsVisible && !store.usesSidebarOnlyChrome {
                    FullscreenWindowControls().frame(width: 76, height: 32)
                }
            }
        }
        .ignoresSafeArea().frame(minWidth: 800, minHeight: 540)
        .background(
            NativeWindowAppearance(
                scheme: systemAppearance.colorScheme(for: appearance, privateMode: store.profile.privateMode))
        )
        .preferredColorScheme(systemAppearance.colorScheme(for: appearance, privateMode: store.profile.privateMode))
        .tint(store.profile.privateMode ? PrivateChrome.accent : Color.accentColor)
        .accentColor(store.profile.privateMode ? PrivateChrome.accent : nil)
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: store.omnibarVisible)
        .onChange(of: store.omnibarVisible) { _, visible in
            if !visible { DispatchQueue.main.async { store.focusPage() } }
        }
        .onChange(of: store.findVisible) { _, visible in if !visible { DispatchQueue.main.async { store.focusPage() } }
        }
        .onChange(of: store.selectedTab?.readerDocument?.id) { _, _ in DispatchQueue.main.async { store.focusPage() } }
        .onChange(of: store.selectedTab?.id) { _, _ in DispatchQueue.main.async { store.focusPage() } }

        .onChange(of: store.selectedProfileID) { _, _ in store.tabSwitcher.finish(commit: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object as? NSWindow === store.nativeWindow {
                store.cancelPointerLock()
                store.tabSwitcher.finish(commit: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.cancelPointerLock()
        }
        .sheet(item: $store.bookmarkDraft) { draft in BookmarkEditor(store: store, draft: draft) }
        .sheet(
            isPresented: Binding(
                get: { store.editingProfileID != nil }, set: { if !$0 { store.editingProfileID = nil } })
        ) { if let id = store.editingProfileID { ProfileEditor(store: store, profileID: id) } }
        .overlay {
            if store.application.onboardingVisible && store.application.windows.first?.id == store.id {
                OnboardingView(store: store).ignoresSafeArea().transition(.opacity).zIndex(20)
            }
        }
        .translationPresentation(
            isPresented: Binding(
                get: { store.translationText != nil }, set: { if !$0 { store.translationText = nil } }),
            text: store.translationText ?? ""
        )
        .alert("loaf", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("ok") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .onOpenURL { url in
            if let coordinator = store.application.coordinator {
                coordinator.openReceivedURLs([url])
            } else {
                store.openReceivedURL(url)
            }
        }
    }
    private func pageError(_ error: String, tab: BrowserTab) -> some View {
        VStack(spacing: 16) {
            GolzheimIcon(icon: .globe, size: 40).foregroundStyle(.secondary)
            Text("this page couldn’t open").font(.system(size: 21, weight: .medium))
            Text(error).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(
                maxWidth: 340)
            Button("try again") { tab.reload() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private func passwordPrompt(_ offer: PasswordOffer) -> some View {
        PasswordSavePrompt(store: store, offer: offer).id(offer.id)
    }

}

struct BrowserLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("loaf-logo").resizable().scaledToFit().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                ChromeLoadingIndicator().frame(width: 14, height: 14)
                Text("getting toast ready…").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .ignore).accessibilityLabel("loaf is loading")
    }
}

struct PageFindBar: View {
    static let height: CGFloat = 34
    @ObservedObject var store: BrowserStore
    @ObservedObject var finder: WebKitAdapter.FindController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                GolzheimIcon(icon: .search, size: 12).foregroundStyle(.secondary)
                OmnibarTextField(
                    text: $finder.query, submit: { finder.search() }, move: { finder.search(backwards: $0 < 0) },
                    cancel: { close() }, complete: { finder.search() }, placeholder: "find on page", fontSize: 12,
                    tracksOmnibar: false
                ).frame(minWidth: 100, maxWidth: .infinity).frame(height: 22).id(store.findFocusID)
                if !finder.query.isEmpty {
                    Text(finder.count == 0 && !finder.searching ? "no matches" : finder.status).font(
                        .system(size: 10).monospacedDigit()
                    )
                    .foregroundStyle(finder.count == 0 && !finder.searching ? Color.red : Color.secondary)
                    .lineLimit(1).fixedSize().accessibilityLabel(finder.status)
                    Button {
                        finder.reset(clearQuery: true)
                    } label: {
                        GolzheimIcon(icon: .close, size: 10).frame(width: 16, height: 20)
                    }
                    .buttonStyle(.plain).accessibilityLabel("clear find text")
                }
            }.padding(.horizontal, 4).frame(height: 24)
                .frame(minWidth: 180, idealWidth: 300, maxWidth: 380)
            Toggle(isOn: $finder.caseSensitive) { Text("Aa").font(.system(size: 12, weight: .medium)) }
                .toggleStyle(.button).accessibilityLabel("match case").help("match uppercase and lowercase exactly")
            HStack(spacing: 0) {
                IconButton(icon: .disclosureUp, label: "previous match (⇧↵)") { finder.search(backwards: true) }
                IconButton(icon: .disclosureDown, label: "next match (↵)") { finder.search() }
            }.disabled(finder.query.isEmpty || finder.count == 0)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            Spacer(minLength: 0)
            IconButton(icon: .close, label: "close find (esc)") { close() }
        }.padding(.horizontal, 12).frame(height: Self.height).background(
            store.profile.privateMode ? PrivateChrome.surface : Color(nsColor: .windowBackgroundColor)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
        .opacity(appeared ? 1 : 0).offset(y: reduceMotion || appeared ? 0 : -5).blur(
            radius: reduceMotion || appeared ? 0 : 2
        )
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { appeared = true } }
        .task(id: finder.query) {
            do {
                try await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                finder.search()
            } catch {}
        }
        .onDisappear { finder.reset() }
        .onChange(of: finder.caseSensitive) { _, _ in finder.search() }
    }
    private func close() {
        finder.reset()
        store.findVisible = false
    }
}

struct PasswordPromptSurface<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content
    var body: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                content.padding(16).frame(width: 292)
                    .background {
                        RoundedRectangle(cornerRadius: 12).fill(
                            reduceTransparency
                                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                : AnyShapeStyle(.regularMaterial))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 4).padding(18)
            }
            Spacer(minLength: 0)
        }.zIndex(4)
    }
}

struct PasswordSavePrompt: View {
    @ObservedObject var store: BrowserStore
    let offer: PasswordOffer
    @State private var saving = false
    @State private var replacing = false
    @State private var authentication: LAContext?
    var body: some View {
        PasswordPromptSurface {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    GolzheimIcon(icon: .key, size: 18)
                    Text(replacing ? "update this password?" : "save this password?").font(
                        .system(size: 13, weight: .medium))
                    Spacer()
                    IconButton(icon: .close, label: "dismiss password save") { store.passwordOffer = nil }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(offer.username).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(offer.origin).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(
                    "save after signing in successfully. stored in the local Keychain for "
                        + store.profileFor(offer.profileID).name + "."
                ).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("not now") { store.passwordOffer = nil }.disabled(saving)
                    Spacer()
                    Button(saving ? "saving…" : replacing ? "update" : "save") { save() }.buttonStyle(
                        .borderedProminent
                    ).disabled(saving)
                }
                Button("never for this website") { store.neverSavePasswords(for: offer) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).disabled(saving)
            }
        }.onAppear {
            replacing = PasswordVault.contains(
                profileID: offer.profileID, origin: offer.origin, username: offer.username)
        }
        .onDisappear {
            authentication?.invalidate()
            authentication = nil
        }
    }
    private func save() {
        let profile = offer.profileID
        let id = offer.id
        guard store.selectedProfileID == profile, !store.profileFor(profile).privateMode, store.passwordOffer?.id == id
        else { return }
        saving = true
        Task {
            let context = LAContext()
            authentication = context
            defer {
                context.invalidate()
                authentication = nil
                saving = false
            }
            do {
                guard
                    try await context.evaluatePolicy(
                        .deviceOwnerAuthentication, localizedReason: "save a password in loaf"),
                    store.selectedProfileID == profile, !store.profileFor(profile).privateMode,
                    store.passwordOffer?.id == id, store.preferences.savePasswords,
                    store.profileFor(profile).siteSettings?[offer.origin]?.savePasswords != false
                else { return }
                var saved = offer
                if replacing {
                    let previous = try PasswordVault.readSecret(
                        profileID: profile, origin: offer.origin, username: offer.username)
                    saved.notes = previous.notes
                    saved.title =
                        PasswordVault.entries(profileID: profile).first {
                            $0.origin == offer.origin && $0.username == offer.username
                        }?.title ?? ""
                }
                try PasswordVault.save(saved, replaceExisting: replacing)
                store.passwordOffer = nil
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            } catch {
                replacing = PasswordVault.contains(profileID: profile, origin: offer.origin, username: offer.username)
                store.error = "couldn’t save this password. try again."
            }
        }
    }
}

import AuthenticationServices
import LocalAuthentication
import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @State private var section: String
    @State private var query = ""
    @State private var headingPassed = false
    @State private var headingPresented = false
    @State private var headingRemoval: Task<Void, Never>?
    @State private var selectedSetting: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var city = ""
    @State private var importVisible = false
    @State private var editing: UUID?
    @State private var extensionAddress = ""
    @State private var appearanceDemo: AppearancePreviewOption?
    @AppStorage("loaf.appearance") private var appearance = "system"
    @ObservedObject private var systemAppearance = LoafAppearance.shared
    private var sidebarInk: Color { systemAppearance.colorScheme(for: appearance) == .dark ? .white : .black }
    private let sections = SettingsNavigation.sections
    init(store: BrowserStore, initialSection: String = "general") {
        self.store = store
        _section = State(
            initialValue: SettingsNavigation.sections.contains(initialSection) ? initialSection : "general")
    }
    private func icon(_ section: String) -> LoafIcon {
        switch section {
        case "general": .settings
        case "appearance": .sun
        case "search": .search
        case "profiles": .profiles
        case "websites": .globe
        case "privacy": .shield
        case "passwords": .key
        case "extensions": .extensionPuzzle
        default: .advanced
        }
    }
    private var subtitle: String {
        switch section {
        case "general": "startup and browsing preferences"
        case "appearance": "color, surfaces and window controls"
        case "search": "what appears when you search or surf"
        case "profiles": "separate spaces, shared across your windows"
        case "websites": "decisions you've made for individual sites"
        case "privacy": "blocking, cookies and browsing data"
        case "passwords": "credentials stored locally in Keychain"
        case "extensions": "installation and website access"
        default: "browser identity and developer tools"
        }
    }
    private func optional<Value>(_ key: WritableKeyPath<BrowserPreferences, Value?>, fallback: Value) -> Binding<Value>
    {
        Binding(
            get: { store.preferences[keyPath: key] ?? fallback },
            set: {
                store.preferences[keyPath: key] = $0
                store.persistSoon()
            })
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    GolzheimIcon(icon: .search, size: 14).foregroundStyle(.secondary)
                    TextField("search settings", text: $query).textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let result = SettingsSearch.results(for: query).first { select(result) } }
                        .onExitCommand { query = "" }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            GolzheimIcon(icon: .close, size: 12)
                        }.buttonStyle(.plain).accessibilityLabel("clear search")
                    }
                }.font(.system(size: 13)).padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).padding(
                        .horizontal, 10
                    ).padding(.vertical, 6)
                List(selection: Binding<String?>(get: { section }, set: { if let value = $0 { chooseSection(value) } }))
                {
                    ForEach(Array(sections.enumerated()), id: \.element) { index, item in
                        Label {
                            Text(item).font(.system(size: 13)).foregroundStyle(sidebarInk)
                        } icon: {
                            GolzheimIcon(icon: icon(item), size: 16, weight: 220).foregroundStyle(
                                sidebarInk.opacity(0.7)
                            ).frame(width: 20)
                        }
                        .padding(.vertical, 4).tag(item).help(index < 9 ? item + " (⌘\(index + 1))" : item)
                    }
                }.id(appearance + String(describing: systemAppearance.systemScheme)).listStyle(.sidebar)
                    .scrollContentBackground(.hidden).contentMargins(.top, 0, for: .scrollContent)
                    .accessibilityElement(children: .contain).accessibilityLabel("settings sections")
                    .focusable(interactions: .edit).focusEffectDisabled().focused($sidebarFocused)
                    .onKeyPress(.upArrow) {
                        if let next = SettingsNavigation.adjacent(to: section, direction: -1) { chooseSection(next) }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if let next = SettingsNavigation.adjacent(to: section, direction: 1) { chooseSection(next) }
                        return .handled
                    }
                    .onKeyPress(.home) {
                        chooseSection(sections[0])
                        return .handled
                    }
                    .onKeyPress(.end) {
                        chooseSection(sections[sections.count - 1])
                        return .handled
                    }
                Spacer(minLength: 24)
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.switchProfile(profile.id)
                        } label: {
                            if profile.id == store.selectedProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        EmojiIcon(glyph: store.profile.emoji, size: 16)
                        Text(store.profile.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        GolzheimIcon(icon: .disclosureDown, size: 12)
                    }.padding(10).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).padding(6)
                    .accessibilityLabel("switch profile").accessibilityValue(store.profile.name)
            }.navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 240)
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        SettingsSidebarMaterial().ignoresSafeArea()
                    }
                }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            sectionHeading
                            let matches = SettingsSearch.results(for: query)
                            if matches.isEmpty { Text("no settings found").foregroundStyle(.secondary).padding(16) }
                            ForEach(matches) { result in
                                Button {
                                    select(result)
                                } label: {
                                    HStack(spacing: 12) {
                                        GolzheimIcon(icon: icon(result.section), size: 20).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.title)
                                            Text(result.section).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        GolzheimIcon(icon: .forward, size: 12).foregroundStyle(.secondary)
                                    }.padding(12).contentShape(Rectangle())
                                        .background(
                                            Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }.scrollIndicators(.hidden).coordinateSpace(name: "settings-scroll")
                } else {
                    if section == "appearance" {
                        sectionHeading.padding(.horizontal, 24)
                        appearancePreviews.padding(.horizontal, 24).padding(.bottom, 16)
                            .background(SettingsPreviewScrollRelay())
                    }
                    ScrollViewReader { proxy in
                        Form {
                            if section != "appearance" {
                                Section {
                                    EmptyView()
                                } header: {
                                    sectionHeading.padding(.top, -20)
                                }
                            }
                            switch section {
                            case "general": general
                            case "appearance": appearanceSettings
                            case "search": search
                            case "profiles": profiles
                            case "websites": websites
                            case "privacy": privacy
                            case "passwords": PasswordSettingsView(store: store)
                            case "extensions": extensions
                            default: advanced
                            }
                        }.coordinateSpace(name: "settings-scroll").formStyle(.grouped).font(.system(size: 13))
                            .scrollIndicators(.hidden).scrollContentBackground(.hidden).contentMargins(
                                .top, 0, for: .scrollContent
                            )
                            .listRowBackground(Color(nsColor: .controlBackgroundColor))
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .padding(.horizontal, 8).frame(maxWidth: 780).frame(
                                maxWidth: .infinity, maxHeight: .infinity
                            )
                            .onAppear {
                                if let selectedSetting {
                                    DispatchQueue.main.async { proxy.scrollTo(selectedSetting, anchor: .center) }
                                }
                            }
                            .onChange(of: selectedSetting) { _, id in
                                if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                            }
                    }.id(section)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
                .background(
                    SettingsTitlebarState(
                        title: headingPassed ? (query.isEmpty ? section : "search results") : "settings",
                        promoted: headingPassed))
        }.navigationSplitViewStyle(.balanced)
            .onChange(of: section) { _, _ in headingPassed = false }
            .onChange(of: query) { _, _ in headingPassed = false }
            .onChange(of: headingPassed) { _, passed in
                headingRemoval?.cancel()
                if passed {
                    headingPresented = true
                } else {
                    headingRemoval = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 180)) } catch { return }
                        headingPresented = false
                    }
                }
            }
            .toolbar {
                if headingPresented {
                    if #available(macOS 26, *) {
                        ToolbarItem(id: "loaf.settings.sectionTitle", placement: .principal) { compactHeading }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(id: "loaf.settings.sectionTitle", placement: .principal) { compactHeading }
                    }
                }
            }
            .background(NativeWindowAppearance(scheme: systemAppearance.colorScheme(for: appearance)))
            .preferredColorScheme(systemAppearance.colorScheme(for: appearance))
            .onAppear {
                city = store.preferences.weatherCity
                searchFocused = true
            }.onDisappear { store.persistSoon() }
            .background(
                SettingsKeyboardAnchor { shortcut in
                    switch shortcut {
                    case .search:
                        sidebarFocused = false
                        searchFocused = true
                    case .section(let section): chooseSection(section)
                    }
                }
            )
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing { ProfileEditor(store: store, profileID: editing) }
            }
            .sheet(isPresented: $importVisible) { ProfileImportView(store: store) }
    }
    private var compactHeading: some View {
        SettingsCompactHeading(title: query.isEmpty ? section : "search results", visible: headingPassed)
    }
    private var sectionHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(query.isEmpty ? section : "search results").font(.system(size: 21, weight: .semibold))
                .background(SettingsHeadingObserver { headingPassed = $0 })
            Text(query.isEmpty ? subtitle : "find a setting by name or what it does").font(.system(size: 12))
                .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 8)
    }
    private func chooseSection(_ value: String) {
        section = value
        query = ""
        selectedSetting = nil
        searchFocused = false
        sidebarFocused = true
    }
    private func select(_ result: SettingsSearchResult) {
        section = result.section
        selectedSetting = result.id
        query = ""
        searchFocused = false
        sidebarFocused = true
    }
    private var general: some View {
        Group {
            Section("tabs & startup") {
                Picker("pinned tabs", selection: optional(\.pinnedLayout, fallback: "grid")) {
                    Text("grid").tag("grid")
                    Text("list").tag("list")
                }.id("pinned-layout")
                Toggle("restore windows and tabs on launch", isOn: optional(\.restoreSession, fallback: true)).id(
                    "restore")
                Toggle("sleep idle tabs", isOn: optional(\.sleepIdleTabs, fallback: false)).id("sleep-tabs")
                Picker("sleep after", selection: optional(\.tabSleepMinutes, fallback: 30)) {
                    ForEach([5, 10, 15, 30, 60, 120, 240], id: \.self) { minutes in
                        Text(
                            minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")"
                        ).tag(minutes)
                    }
                }.settingDisabled(store.preferences.sleepIdleTabs != true)
                TextField("custom new tab URL", text: optional(\.customNewTabURL, fallback: "")).id("custom-new-tab")
                Text("leave empty to use loaf’s start page").font(.caption).foregroundStyle(.secondary)
                Toggle("group links into browsing trails", isOn: optional(\.linkTabGroups, fallback: false)).id(
                    "link-groups")
                Text(
                    "sleeping reloads a page when you return. forms, media, frames, private tabs and active downloads stay awake."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Section("power & time") {
                Toggle("power saver", isOn: optional(\.powerSaver, fallback: false)).id("power-saver").onChange(
                    of: store.preferences.powerSaver
                ) { _, _ in store.application.resources.refreshBattery() }
                Picker("enable on battery below", selection: optional(\.powerSaverThreshold, fallback: 0)) {
                    Text("never").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                }.onChange(of: store.preferences.powerSaverThreshold) { _, _ in
                    store.application.resources.refreshBattery()
                }
                Text("reduces background activity and sleeps eligible idle tabs after five minutes.").font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("save local browsing time", isOn: optional(\.tracksScreenTime, fallback: false)).id(
                    "browsing-time")
                Text("records focused-page and playing-media time by site, on this Mac. private browsing is excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("delete browsing-time data", role: .destructive) {
                    store.application.resources.deleteTrackingData()
                }
            }
            Section("everyday browsing") {
                Button("show welcome to loaf…") { store.application.onboardingVisible = true }
                Toggle("warn before quitting", isOn: optional(\.warnBeforeQuitting, fallback: false)).id("quit-warning")
                Toggle("trackpad haptics", isOn: optional(\.haptics, fallback: true)).id("haptics")
                Button("make loaf the default browser…") {
                    Task {
                        do {
                            try await NSWorkspace.shared.setDefaultApplication(
                                at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
                            try await NSWorkspace.shared.setDefaultApplication(
                                at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                        } catch { store.error = error.localizedDescription }
                    }
                }.id("default-browser")
            }
            Section("weather") {
                Toggle(
                    "show weather in sidebar",
                    isOn: Binding(
                        get: { store.profile.personalization?.sidebarWeather != false },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.sidebarWeather = value
                            }
                        }))
                Toggle(
                    "compact weather widget",
                    isOn: Binding(
                        get: { store.profile.personalization?.compactSidebarWeather == true },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.compactSidebarWeather = value
                            }
                        }))
                HStack {
                    TextField("city", text: $city).onSubmit { applyWeatherCity() }
                    Button("apply") { applyWeatherCity() }.settingDisabled(
                        city.trimmingCharacters(in: .whitespacesAndNewlines) == store.preferences.weatherCity)
                }.id("weather")
                Picker("temperature", selection: $store.preferences.fahrenheit) {
                    Text("Fahrenheit · °F").tag(true)
                    Text("Celsius · °C").tag(false)
                }.onChange(of: store.preferences.fahrenheit) { _, _ in refreshWeather() }
                Picker("provider", selection: optional(\.weatherProvider, fallback: "automatic")) {
                    Text("automatic").tag("automatic")
                    Text("Open-Meteo").tag("open-meteo")
                }.onChange(of: store.preferences.weatherProvider) { _, _ in refreshWeather() }
                Text(
                    "automatic uses Apple Weather when available, with Open-Meteo as a fallback. forecasts refresh at most every 30 minutes; changing units uses the saved forecast. city lookup never uses your device location."
                ).font(.caption).foregroundStyle(.secondary)
                Link(store.weather.attribution, destination: store.weather.attributionURL)
            }
        }
    }
    private var appearancePreviews: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach([false, true], id: \.self) { dark in
                    ProfileThemePreview(
                        height: 144, color: profileTint(store.profile),
                        strength: store.profile.personalization?.tintStrength ?? 0.06, dark: dark,
                        transparency: store.profile.personalization?.windowTransparency ?? 0,
                        settings: AppearancePreviewSettings(store.preferences), demonstration: appearanceDemo)
                }
            }.id(appearanceDemo).transition(.opacity)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appearanceDemo).allowsHitTesting(false)
    }
    private var appearanceSettings: some View {
        Group {
            Section("window") {
                Picker("theme", selection: $appearance) {
                    Text("system").tag("system")
                    Text("light").tag("light")
                    Text("dark").tag("dark")
                }.pickerStyle(.segmented).id("appearance")
                Toggle(
                    "sidebar-only titlebar",
                    isOn: Binding(
                        get: { store.usesSidebarOnlyChrome },
                        set: { value in
                            store.preferences.sidebarOnlyChrome = value
                            if !value { store.preferences.insetCollapsedPage = false }
                            store.persistSoon()
                        })
                ).modifier(AppearancePreviewHover(option: .titlebar, selection: $appearanceDemo)).id(
                    "sidebar-only-chrome")
                Text(
                    "hide the titlebar and toolbar. window controls appear as tinted dots in the sidebar and reveal their native buttons on hover."
                ).font(.caption).foregroundStyle(.secondary)
                Toggle("keep page margins when sidebar is hidden", isOn: optional(\.insetCollapsedPage, fallback: true))
                    .settingDisabled(!store.usesSidebarOnlyChrome).modifier(
                        AppearancePreviewHover(
                            option: .pageMargins, selection: $appearanceDemo, enabled: store.usesSidebarOnlyChrome)
                    ).id("page-margins")
            }
            Section("page transitions") {
                Toggle("soften sidebar resizing", isOn: optional(\.resizeTransition, fallback: true)).modifier(
                    AppearancePreviewHover(option: .resizing, selection: $appearanceDemo)
                ).id("resize-transition")
                Toggle("tint wonderbar with profile color", isOn: optional(\.tintWonderbar, fallback: false)).modifier(
                    AppearancePreviewHover(option: .wonderbarTint, selection: $appearanceDemo)
                ).id("tint-wonderbar")
            }
            Section("\(store.profile.name) · profile color") {
                ProfileThemeControls(
                    tint: Binding(
                        get: { store.profile.tint }, set: { value in store.updateCurrent { $0.tint = value } }),
                    customTint: Binding(
                        get: { store.profile.personalization?.customTint },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.customTint = value
                            }
                        }),
                    strength: Binding(
                        get: { store.profile.personalization?.tintStrength ?? 0.06 },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.tintStrength = ProfileColor.surfaceStrength(value)
                            }
                        }),
                    transparency: Binding(
                        get: { store.profile.personalization?.windowTransparency ?? 0 },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.windowTransparency = ProfileTransparency.bounded(value)
                            }
                        }), showsPreviews: false, compact: true, previewHeight: 144,
                    previewSettings: AppearancePreviewSettings(store.preferences), demonstration: appearanceDemo
                )
                .id("profile-color")
            }
        }
    }
    private func applyWeatherCity() {
        store.preferences.weatherCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        store.persistSoon()
        refreshWeather()
    }
    private func refreshWeather() {
        Task {
            await store.weather.fetch(
                city: store.preferences.weatherCity, fahrenheit: store.preferences.fahrenheit,
                preferredProvider: store.preferences.weatherProvider ?? "automatic")
        }
    }
    private func redirectBinding<Value>(_ key: WritableKeyPath<SearchRedirect, Value>) -> Binding<Value> {
        Binding(
            get: { (store.preferences.alternateSearch ?? SearchRedirect())[keyPath: key] },
            set: { value in
                var redirect = store.preferences.alternateSearch ?? SearchRedirect()
                redirect[keyPath: key] = value
                store.preferences.alternateSearch = redirect
                store.persistSoon()
            })
    }
    @ViewBuilder private var search: some View {
        Section("search engine") {
            Picker("search engine", selection: optional(\.searchEngine, fallback: .google)) {
                ForEach(SearchEngine.available, id: \.self) { Text($0.title).tag($0) }
            }
            if store.preferences.searchEngine == .custom {
                TextField("HTTPS search URL with {query}", text: optional(\.customSearchTemplate, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                if store.searchAddress("loaf") == nil {
                    Text("include one {query} placeholder in the path or query of an HTTPS URL").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section("wonderbar") {
            Text("local tabs, history, favorites, and the bundled site catalog are always available").foregroundStyle(
                .secondary)
            Toggle("search suggestions", isOn: $store.preferences.googleSuggestions).id("google-suggestions")
            Picker("suggestion provider", selection: optional(\.suggestionProvider, fallback: .google)) {
                ForEach(SuggestionProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("remote site discovery", isOn: optional(\.remoteSites, fallback: false)).id("site-discovery")
            Text(
                "search text is sent to your selected provider for suggestions. remote suggestions and discovery are off in private sessions; url-like input is kept local."
            ).font(.caption).foregroundStyle(.secondary)
        }
        Section("alternate search") {
            Toggle("enable alternate search shortcut", isOn: redirectBinding(\.enabled)).id("alternate-search")
            Picker("provider", selection: redirectBinding(\.provider)) {
                ForEach(
                    SearchRedirect.availableProviders.filter {
                        $0 != .appleIntelligence || AppleIntelligence.visibleProviders.contains(.onDevice)
                    }, id: \.self
                ) {
                    Text(
                        $0 == .chatgpt
                            ? "ChatGPT"
                            : $0 == .appleIntelligence
                                ? "Apple Intelligence"
                                : { (provider: SearchRedirect.Provider) in
                                    var value = SearchRedirect()
                                    value.provider = provider
                                    return value.title
                                }($0)
                    ).tag($0)
                }
            }.settingDisabled(!(store.preferences.alternateSearch ?? SearchRedirect()).enabled)
            Picker("shortcut", selection: redirectBinding(\.shortcut)) {
                ForEach(SearchRedirect.Shortcut.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.settingDisabled(!(store.preferences.alternateSearch ?? SearchRedirect()).enabled)
            if store.preferences.alternateSearch?.provider == .custom {
                TextField("HTTPS URL with {query}", text: redirectBinding(\.customTemplate)).textFieldStyle(
                    .roundedBorder)
                if !(store.preferences.alternateSearch ?? SearchRedirect()).valid {
                    Text("use an https url with one {query} placeholder in its path or query").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.preferences.alternateSearch?.provider == .chatgpt {
                Text("this shortcut uses ChatGPT, regardless of the answer provider below.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "the shortcut searches your wonderbar text with this provider. return keeps its usual behavior. queries are sent only when you submit."
            ).font(.caption).foregroundStyle(.secondary)
        }
        Section("answers in loaf") {
            Toggle(
                "AI features",
                isOn: Binding(
                    get: { store.preferences.aiFeaturesEnabled != false },
                    set: { store.application.setAIFeaturesEnabled($0) })
            ).id("ai-features")
            Picker("answer provider", selection: optional(\.aiProvider, fallback: .chatgpt)) {
                ForEach(AppleIntelligence.visibleProviders, id: \.self) { Text($0.title).tag($0) }
            }
            .settingDisabled(store.preferences.aiFeaturesEnabled == false)
            if let reason = AppleIntelligence.unavailableReason(for: store.preferences.aiProvider ?? .chatgpt) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "this provider answers questions inside loaf. the alternate search shortcut uses its own provider above. Apple Intelligence retrieves Google results and summarizes them on this Mac. ChatGPT searches through OpenAI. Queries are sent only when submitted."
            ).font(.caption).foregroundStyle(.secondary)
        }
        if store.preferences.aiFeaturesEnabled != false
            && (store.preferences.aiProvider == nil || store.preferences.aiProvider == .chatgpt
                || store.preferences.alternateSearch?.provider == .chatgpt)
        {
            Section("ChatGPT connection") {
                ChatGPTConnectionView(account: store.application.chatGPTAccount)
                    .onAppear { store.application.chatGPTAccount.refreshCatalog() }
            }
        }
    }
    private var profiles: some View {
        Section("profiles") {
            ForEach(store.profiles) { profile in
                HStack(spacing: 12) {
                    EmojiIcon(glyph: profile.emoji, size: 24)
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(
                            profile.privateMode
                                ? "temporary" : "cookies, favorites, extensions and passwords are isolated"
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("edit") { editing = profile.id }
                    Button("new window") { store.application.coordinator?.newWindow(profileID: profile.id) }
                }
            }
            Button("add profile…") {
                store.addProfile(name: "untitled", emoji: "🌱")
                editing = store.selectedProfileID
            }.settingDisabled(store.profiles.count >= 8).id("profiles")
            Button("import browsing data…") { importVisible = true }.settingDisabled(store.profile.privateMode).id(
                "import-data")
            Text("windows of the same profile share website data and favorites, with independent tabs.").font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    private var websites: some View {
        Group {
            Section("website interaction") {
                Toggle(
                    "ask before downloading from a new site", isOn: optional(\.asksBeforeDownloading, fallback: true)
                )
                .id("download-permissions")
                Text(
                    "choices apply to each exact site and profile. private choices last only for the private session. saved blocks still apply when prompts are off."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("allow website notifications", isOn: optional(\.webNotifications, fallback: true)).id(
                    "web-notifications")
                Text(
                    "sites must ask permission after a click. notifications work while a page is open; background push isn’t supported."
                ).font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "allow websites to capture the pointer",
                    isOn: Binding(
                        get: { store.preferences.allowsPointerCapture != false },
                        set: { allowed in
                            store.preferences.allowsPointerCapture = allowed
                            for window in store.application.windows {
                                window.cancelPointerLock()
                            }
                            for runtime in store.application.runtimes.values {
                                for tab in runtime.tabs.values { WebKitAdapter.applyPointerLockPolicy(tab) }
                            }
                            store.persistSoon()
                        })
                ).id("pointerCapture")
                Text(
                    "games capture the pointer automatically while their page is active. escape releases it. individual sites can be blocked or set to ask using the lock beside their address."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Section("\(store.profile.name) · saved website decisions") {
                if (store.profile.siteSettings ?? [:]).isEmpty {
                    Text("use the lock beside an address to set permissions, zoom, javascript and browser identity.")
                        .foregroundStyle(.secondary)
                }
                ForEach((store.profile.siteSettings ?? [:]).keys.sorted(), id: \.self) { origin in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            WebsiteIcon(url: URL(string: origin), store: store)
                            Text(BrowserAddress.visible(origin)).font(.system(size: 13, weight: .medium))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("reset") { store.updateCurrent { $0.siteSettings?.removeValue(forKey: origin) } }
                                .controlSize(.small)
                        }
                        Toggle("downloads", isOn: Binding(
                            get: { store.profile.siteSettings?[origin]?.downloads != false },
                            set: { allowed in store.updateCurrent { $0.siteSettings?[origin]?.downloads = allowed } }
                        )).toggleStyle(.switch).controlSize(.small)
                        if let settings = store.profile.siteSettings?[origin] {
                            Text("JavaScript \(settings.javascript ? "on" : "off") · zoom \(Int(settings.zoom * 100))% · \(settings.userAgent.title)")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 4)

                }
                Text("macOS permissions remain authoritative for camera and microphone access.").font(.caption)
                    .foregroundStyle(.secondary)
            }.id("websites")
        }
    }
    private var privacy: some View {
        Group {
            Section("\(store.profile.name) · content blocking") {
                Toggle(
                    "block ads and trackers",
                    isOn: Binding(
                        get: { store.profile.blockerEnabled },
                        set: { enabled in
                            store.updateCurrent { $0.blockerEnabled = enabled }
                            store.applyBlocker()
                        })
                ).id("blocker")
                Text(
                    "\(store.blocker.domainCount.formatted()) AdGuard domains. network blocking doesn’t cover cosmetic placeholders or every video ad."
                ).font(.caption).foregroundStyle(.secondary)
                Button(store.blocker.updating ? "updating…" : "update filters") {
                    Task {
                        await store.blocker.update()
                        store.applyBlocker()
                    }
                }.settingDisabled(store.blocker.updating).id("filters")
                ForEach(store.profile.allowedSites, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("remove exception") {
                            store.updateCurrent { $0.allowedSites.removeAll { $0 == host } }
                            store.applyBlocker()
                        }
                    }
                }
            }
            Section("cookies") {
                Toggle(
                    "allow cookies in this profile",
                    isOn: Binding(
                        get: { store.profile.blocksCookies != true },
                        set: { allowed in
                            let runtime = store.runtime
                            store.updateCurrent { $0.blocksCookies = !allowed }
                            Task {
                                await runtime.dataStore.httpCookieStore.setCookiePolicy(allowed ? .allow : .disallow)
                            }
                        }))
                Text("choose whether sites can save cookies in this profile. remove existing cookies below.").font(
                    .caption
                ).foregroundStyle(.secondary)
                Button("manage cookies…") { store.showPage(.cookies); store.application.coordinator?.activateBrowser() }.id("cookies")
            }
            Section("clear data") { ClearingView(store: store).id("clear") }

        }
    }
    private var extensions: some View {
        Section("extensions · \(store.profile.name)") {
            ForEach(store.profile.extensions) { record in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(record.name)
                        Spacer()
                        Toggle(
                            "enabled",
                            isOn: Binding(
                                get: { record.enabled },
                                set: { enabled in Task { await store.runtime.extensions.setEnabled(record, enabled) } })
                        ).labelsHidden()
                        Button("remove") { store.runtime.extensions.remove(record) }
                    }
                    Text(record.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    if let status = record.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    ForEach(record.diagnostics ?? [], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("load unpacked folder…") { Task { await store.runtime.extensions.install(owner: store) } }
                .settingDisabled(store.profile.privateMode || store.runtime.extensions.installing).id(
                    "install-extension")
            HStack {
                TextField("Chrome Web Store URL or extension ID", text: $extensionAddress)
                Button("install…") {
                    Task { await store.runtime.extensions.installStore(extensionAddress, owner: store) }
                }.settingDisabled(store.profile.privateMode || store.runtime.extensions.installing)
            }
            Text("extensions can request access to sites and browsing data. review access before installing.").font(
                .caption
            ).foregroundStyle(.secondary)
        }.id("extensions")
    }
    private var advanced: some View {
        Group {
            Section("development") {
                Toggle("allow JavaScript from AppleScript", isOn: optional(\.allowsScriptJavaScript, fallback: false))
                    .id("applescript")
                Toggle("show developer menu and enable inspection", isOn: optional(\.developerMenu, fallback: false))
                    .id("developer").onChange(of: store.preferences.developerMenu) { _, enabled in
                        for runtime in store.runtimes.values {
                            for tab in runtime.tabs.values {
                                if let view = tab.existingWebView {
                                    WebKitAdapter.setInspectionEnabled(view, enabled == true)
                                }
                            }
                        }
                    }
                Picker("web inspector", selection: optional(\.inspectorMode, fallback: .inline)) {
                    Text("separate window").tag(InspectorMode.detached)
                    Text("inline").tag(InspectorMode.inline)
                }.settingDisabled(store.preferences.developerMenu != true).id("inspector-mode")
                Text("choose where the inspector opens.").font(.caption).foregroundStyle(.secondary)
                Picker("default browser identity", selection: optional(\.userAgentMode, fallback: .desktop)) {
                    ForEach(UserAgentMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.id("identity")
                if store.preferences.userAgentMode == .custom {
                    TextField("custom user agent", text: optional(\.customUserAgent, fallback: ""))
                        .textFieldStyle(.roundedBorder)
                }
                Text(
                    Golzheim.available
                        ? "\(PersonalIcon.catalog.count) personalization icons"
                        : "personalization icon font unavailable"
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private struct SettingsSidebarMaterial: NSViewRepresentable {
    final class Surface: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = Surface()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SettingsCompactHeading: View {
    let title: String
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .opacity(visible && appeared ? 1 : 0)
            .offset(y: visible && appeared || reduceMotion ? 0 : -6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: visible && appeared)
            .onAppear { appeared = true }
    }
}

private struct SettingsTitlebarState: NSViewRepresentable {
    let title: String
    let promoted: Bool
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.title = title
        view.promoted = promoted
        view.register()
    }
    final class Anchor: NSView {
        var title = "settings"
        var promoted = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            register()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            register()
        }
        func register() {
            if let window = window as? LoafSettingsWindow {
                window.title = title
                window.titlebarContentAnchor = self
                window.updateTitlebarMaterial()
                window.setTitlebarPromoted(promoted)
            }
        }
    }
}

private struct SettingsHeadingObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.changed = changed
        view.connectSoon()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }
    final class Anchor: NSView {
        var changed: ((Bool) -> Void)?
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        private var previous: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { connectSoon() }
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            connectSoon()
        }
        func connectSoon() { DispatchQueue.main.async { [weak self] in self?.connect() } }
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedClip = nil
            previous = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        private func connect() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            if observedClip !== clip {
                stop()
                observedClip = clip
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.measure() } }
            }
            measure()
        }
        private func measure() {
            guard let clip = observedClip, bounds.height > 0 else { return }
            let rect = convert(bounds, to: clip)
            let passed = clip.isFlipped ? rect.maxY < clip.bounds.minY : rect.minY > clip.bounds.maxY
            guard previous != passed else { return }
            previous = passed
            changed?(passed)
        }
    }
}

private struct DisabledSetting: ViewModifier {
    let disabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.disabled(disabled).textRenderer(DisabledSettingRenderer(progress: disabled ? 1 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: disabled)
    }
}

struct DisabledSettingRenderer: TextRenderer {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            context.draw(line)
            guard progress > 0 else { continue }
            let bounds = line.typographicBounds.rect
            var strike = Path()
            strike.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
            strike.addLine(to: CGPoint(x: bounds.minX + bounds.width * min(1, max(0, progress)), y: bounds.midY))
            context.stroke(strike, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }
}
private extension View {
    func settingDisabled(_ disabled: Bool) -> some View { modifier(DisabledSetting(disabled: disabled)) }
}

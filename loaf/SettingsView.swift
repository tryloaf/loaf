import AuthenticationServices
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var resourceMonitor: ResourceMonitor
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    @State private var section: String
    @State private var query = ""
    @State private var headingPassed = false
    @State private var selectedSetting: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var sidebarFocused: Bool
    @FocusState private var websiteSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var city = ""
    @State private var importVisible = false
    @State private var startPageCustomizationVisible = false
    @State private var editing: UUID?
    @State private var confirmTrackingDeletion = false
    @State private var extensionDeletion: InstalledExtension?
    @State private var extensionDeletionProfileID: UUID?
    @State private var extensionDeletionProfileName = ""
    @State private var draggedProfileID: UUID?
    @State private var profileDropPosition: ProfileDropPosition?
    @State private var extensionAddress = ""
    @State private var websiteSearch = ""
    @State private var expandedWebsites: Set<String> = []
    @State private var expandedExtensions: Set<UUID> = []
    @State private var appearanceDemo: AppearancePreviewOption?
    @AppStorage("loaf.appearance") private var appearance = "system"
    @ObservedObject private var systemAppearance = LoafAppearance.shared
    private var sidebarInk: Color { systemAppearance.colorScheme(for: appearance) == .dark ? .white : .black }
    private let sections = SettingsNavigation.sections
    init(store: BrowserStore, initialSection: String = "general") {
        self.store = store
        _resourceMonitor = ObservedObject(wrappedValue: store.application.resources)
        _section = State(
            initialValue: SettingsNavigation.sections.contains(initialSection) ? initialSection : "general")
    }
    private func icon(_ section: String) -> LoafIcon {
        switch section {
        case "sync": .globe
        case "general": .settings
        case "appearance": .sun
        case "sidebar": .sidebar
        case "search": .search
        case "intelligence": .intelligence
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
        case "sync": "your profiles, pins and preferences across Macs"
        case "general": "startup and browsing preferences"
        case "appearance": "color, surfaces and window controls"
        case "sidebar": "sidebar weather and forecasts"
        case "search": "what appears when you search or surf"
        case "intelligence": "models, connections and page summaries"
        case "profiles": "separate spaces, shared across your windows"
        case "websites": "website permissions and app links"
        case "privacy": "blocking, cookies and browsing data"
        case "passwords": "credentials stored locally in Keychain"
        case "extensions": "installation and website access"
        default: "power, browsing time and developer tools"
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    GolzheimIcon(icon: .search, size: 14).foregroundStyle(.secondary)
                    TextField("search settings", text: $query).textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let result = settingsSearchResults.first { select(result) } }
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element) { index, item in
                            Button {
                                chooseSection(item)
                            } label: {
                                HStack(spacing: 8) {
                                    GolzheimIcon(icon: icon(item), size: 16, weight: 220)
                                        .opacity(0.7).frame(width: 20)
                                    Text(item).font(.system(size: 13, weight: item == section ? .semibold : .regular))
                                }
                                .foregroundStyle(item == section ? .white : sidebarInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(
                                    item == section ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).focusable(false)
                            .accessibilityAddTraits(item == section ? .isSelected : [])
                            .help(index < 9 ? item + " (⌘\(index + 1))" : item)
                        }
                    }.padding(.horizontal, 10)
                }.scrollIndicators(.hidden)
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
                        ProfileIcon(profile: store.profile, size: 16)
                        Text(store.profile.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        GolzheimIcon(icon: .disclosureDown, size: 12)
                    }.padding(10).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).padding(6)
                    .accessibilityLabel("switch profile").accessibilityValue(store.profile.name)
            }.frame(width: 208)
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        SettingsSidebarMaterial().ignoresSafeArea(.container, edges: [.top, .bottom])
                    }
                }
            Divider().ignoresSafeArea(.container, edges: [.top, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            sectionHeading
                            let matches = settingsSearchResults
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
                            case "sync": ICloudSyncSettingsView(store: store)
                            case "general": general
                            case "appearance": appearanceSettings
                            case "sidebar": sidebarSettings
                            case "search": search
                            case "intelligence":
                                AISettingsView(
                                    store: store, account: store.application.chatGPTAccount,
                                    claude: store.application.claudeAccount)
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
                            .listRowInsets(
                                EdgeInsets(
                                    top: section == "websites" || section == "extensions" ? 5 : 12, leading: 16,
                                    bottom: section == "websites" || section == "extensions" ? 5 : 12, trailing: 16)
                            )
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(.container, edges: .top))
                .background(
                    SettingsTitlebarState(
                        title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? section : "search results",
                        promoted: headingPassed))
        }
        .onChange(of: section) { _, _ in headingPassed = false }
        .onChange(of: query) { _, _ in headingPassed = false }
        .onChange(of: websiteSearchFocused) { _, focused in
            if focused {
                sidebarFocused = false
                searchFocused = false
            }
        }
        .onChange(of: store.selectedProfileID) { _, _ in
            websiteSearch = ""
            expandedWebsites.removeAll()
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
                    if section == "websites", query.isEmpty {
                        searchFocused = false
                        websiteSearchFocused = true
                    } else {
                        websiteSearchFocused = false
                        searchFocused = true
                    }
                case .section(let section): chooseSection(section)
                }
            }
        )
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { ProfileEditor(store: store, profileID: editing) }
        }
        .sheet(isPresented: $importVisible) { ProfileImportView(store: store) }
        .sheet(isPresented: $startPageCustomizationVisible) {
            VStack(spacing: 0) {
                HStack {
                    Text("start page · " + store.profile.name).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("done") { startPageCustomizationVisible = false }.keyboardShortcut(.defaultAction)
                }.padding(16)
                StartPage(store: store, editing: true).frame(width: 760, height: 560)
            }
        }
        .destructiveConfirmationDialog(
            "delete browsing-time data?", isPresented: $confirmTrackingDeletion, titleVisibility: .visible
        ) {
            Button("delete browsing-time data", role: .destructive) {
                store.application.resources.deleteTrackingData()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("This deletes recorded browsing time for every profile on this Mac. It cannot be undone.")
        }
        .destructiveConfirmationDialog(
            "remove \(extensionDeletion?.name ?? "extension")?",
            isPresented: Binding(get: { extensionDeletion != nil }, set: { if !$0 { extensionDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("remove extension", role: .destructive) {
                guard let record = extensionDeletion, let id = extensionDeletionProfileID,
                    store.profiles.contains(where: { $0.id == id })
                else { return }
                store.runtime(for: id).extensions.remove(record)
                extensionDeletion = nil
            }
            Button("cancel", role: .cancel) { extensionDeletion = nil }
        } message: {
            Text(
                "This removes the extension and its saved data from \(extensionDeletionProfileName). You can disable it to keep its data."
            )
        }
    }
    private var savedWebsiteOrigins: [String] {
        Array((store.profile.siteSettings ?? [:]).keys).sorted()
    }
    private var settingsSearchResults: [SettingsSearchResult] {
        SettingsSearch.results(
            for: query, websiteOrigins: savedWebsiteOrigins,
            hasInternalBattery: store.application.resources.hasInternalBattery,
            applicationNames: store.externalAppLinkPreferences.values.map(\.name))
    }
    private var sectionHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(query.isEmpty ? section : "search results")
                    .font(.system(size: 21, weight: .semibold))
                Spacer()
                if query.isEmpty && ["general", "search", "intelligence", "advanced", "sync"].contains(section) {
                    Text("all profiles").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.background(SettingsHeadingObserver { headingPassed = $0 })
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
        if let origin = result.websiteOrigin {
            websiteSearch = ""
            expandedWebsites.insert(origin)
        }
        query = ""
        searchFocused = false
        sidebarFocused = true
    }
    private var general: some View {
        Group {
            Section("tabs & startup") {
                Toggle("add new tabs at the top", isOn: optional(\.newTabsAtTop, fallback: true)).id("new-tabs-at-top")
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
            Section("start page · this profile") {
                Button("customize start page…") {
                    startPageCustomizationVisible = true
                }.id("start-page")
                Text("use edit on the start page to add, arrange and resize widgets, or choose a background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("updates") {
                Toggle("check for updates automatically", isOn: $updates.automaticallyChecksForUpdates).id(
                    "automatic-update-checks")
                Toggle("download and install updates automatically", isOn: $updates.automaticallyInstallsUpdates).id(
                    "automatic-updates")
                Text("checks every six hours. available updates appear at the bottom of the window.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("check for updates now") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
            }
            Section("downloads") {
                Picker("remove cached transfers after", selection: optional(\.downloadCacheDays, fallback: 7)) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("never").tag(0)
                    Text("custom…").tag(
                        [0, 1, 7, 30].contains(store.preferences.downloadCacheDays ?? 7)
                            ? 14 : store.preferences.downloadCacheDays ?? 14)
                }.id("download-cache").onChange(of: store.preferences.downloadCacheDays) { _, days in
                    store.downloads.cleanupCache(olderThanDays: days ?? 7)
                }
                if let days = store.preferences.downloadCacheDays, ![0, 1, 7, 30].contains(days) {
                    HStack {
                        Text("days to keep cached transfers")
                        Spacer()
                        TextField(
                            "days",
                            value: Binding(
                                get: { store.preferences.downloadCacheDays ?? 14 },
                                set: {
                                    store.preferences.downloadCacheDays = min(36500, max(1, $0))
                                    store.persistSoon()
                                }), format: .number
                        ).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                }
                Text("only unfinished cached transfers are removed. saved files stay in their chosen folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("everyday browsing") {
                Button("show welcome to loaf…") { store.application.onboardingVisible = true }
                Toggle(
                    "warn before closing tabs in other profiles",
                    isOn: optional(\.warnBeforeClosingOtherProfiles, fallback: true)
                ).id("other-profile-close-warning")
                Toggle("warn before quitting", isOn: optional(\.warnBeforeQuitting, fallback: false)).id("quit-warning")
                Toggle("show link preview on hover", isOn: optional(\.showLinkPreview, fallback: true))
                    .id("link-preview")
                Toggle("trackpad haptics", isOn: optional(\.haptics, fallback: true)).id("haptics")
                Button("make loaf the default browser…") {
                    Task {
                        do {
                            try await DefaultBrowser.makeDefault()
                        } catch { store.error = error.localizedDescription }
                    }
                }.id("default-browser")
            }
        }
    }
    private var sidebarSettings: some View {
        Group {
            Section("sidebar · this profile") {
                Toggle(
                    "show weather in sidebar",
                    isOn: Binding(
                        get: { store.profile.personalization?.sidebarWeather != false },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.sidebarWeather = value
                            }
                        })
                ).id("sidebar-weather")
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
            }
            Section("weather · all profiles") {
                Toggle(
                    "use current location",
                    isOn: Binding(
                        get: { store.preferences.weatherUsesCurrentLocation == true },
                        set: { value in
                            store.preferences.weatherUsesCurrentLocation = value
                            store.persistSoon()
                            store.application.weatherLocation.setEnabled(value)
                            refreshWeather()
                        })
                )
                .id("weather-current-location")
                HStack {
                    TextField("city", text: $city).onSubmit { applyWeatherCity() }
                    Button("apply") { applyWeatherCity() }.settingDisabled(
                        city.trimmingCharacters(in: .whitespacesAndNewlines) == store.preferences.weatherCity)
                }.settingDisabled(store.preferences.weatherUsesCurrentLocation == true).id("weather")
                Picker("temperature", selection: $store.preferences.fahrenheit) {
                    Text("Fahrenheit · °F").tag(true)
                    Text("Celsius · °C").tag(false)
                }.onChange(of: store.preferences.fahrenheit) { _, _ in refreshWeather() }
                Picker("provider", selection: optional(\.weatherProvider, fallback: "automatic")) {
                    Text("automatic").tag("automatic")
                    Text("Open-Meteo").tag("open-meteo")
                }.onChange(of: store.preferences.weatherProvider) { _, _ in refreshWeather() }
                Text(
                    "automatic uses Apple Weather when available, with Open-Meteo as a fallback. forecasts refresh at most every 15 minutes. current location is optional; significant moves can refresh immediately up to three times per day."
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
            Section("\(store.profile.name) · profile color") {
                if store.profile.privateMode {
                    Toggle("use profile color in private browsing", isOn: Binding(
                        get: { store.profile.personalization?.privateUsesProfileColor == true },
                        set: { value in
                            store.updateCurrent {
                                $0.personalization = $0.personalization ?? Personalization()
                                $0.personalization?.privateUsesProfileColor = value
                            }
                        }))
                    Text("appearance changes last until this private session ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
            Section("window · all profiles") {
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
            Section("page transitions · all profiles") {
                Toggle("soften sidebar resizing", isOn: optional(\.resizeTransition, fallback: true))
                    .id("resize-transition")
                Text("briefly blur the page when resizing or showing the sidebar. window resizing stays sharp.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("tint wonderbar with profile color", isOn: optional(\.tintWonderbar, fallback: false)).modifier(
                    AppearancePreviewHover(option: .wonderbarTint, selection: $appearanceDemo)
                ).id("tint-wonderbar")
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
            if store.preferences.weatherUsesCurrentLocation == true {
                await store.application.weatherLocation.refreshWeather()
            } else {
                await store.weather.fetch(
                    city: store.preferences.weatherCity, fahrenheit: store.preferences.fahrenheit,
                    preferredProvider: store.preferences.weatherProvider ?? "automatic")
            }
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
                    .textFieldStyle(.roundedBorder).focusRingPadding()
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
                        ($0 != .appleIntelligence || AppleIntelligence.visibleProviders.contains(.onDevice))
                            && (store.preferences.aiFeaturesEnabled != false
                                || ![.chatgpt, .claude, .appleIntelligence, .perplexity, .googleAIOverview].contains($0))
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
                    .roundedBorder
                ).focusRingPadding()
                if !(store.preferences.alternateSearch ?? SearchRedirect()).valid {
                    Text("use an https url with one {query} placeholder in its path or query").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.preferences.alternateSearch?.provider == .chatgpt {
                Text("this shortcut uses ChatGPT, regardless of the answer provider in intelligence settings.").font(
                    .caption
                )
                .foregroundStyle(.secondary)
            }
            Text(
                "the shortcut searches your wonderbar text with this provider. return keeps its usual behavior. queries are sent only when you submit."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var profiles: some View {
        Section("profiles") {
            ForEach(store.profiles) { profile in
                ProfileReorderRow(
                    profile: profile, application: store.application,
                    draggedID: $draggedProfileID, position: $profileDropPosition
                ) {
                    HStack(spacing: 12) {
                        ProfileIcon(profile: profile, size: 24)
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
            Section("\(store.profile.name) · saved website decisions") {
                HStack(spacing: 8) {
                    GolzheimIcon(icon: .search, size: 14).foregroundStyle(.secondary)
                    TextField("", text: $websiteSearch, prompt: Text("search saved websites"))
                        .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                        .focused($websiteSearchFocused)
                        .accessibilityLabel("search saved websites")
                        .onExitCommand { websiteSearch = "" }
                    if !websiteSearch.isEmpty {
                        Button {
                            websiteSearch = ""
                        } label: {
                            GolzheimIcon(icon: .close, size: 12)
                        }.buttonStyle(.plain).accessibilityLabel("clear website search")
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                if (store.profile.siteSettings ?? [:]).isEmpty {
                    Text("use the lock beside an address to set permissions, zoom, javascript and browser identity.")
                        .foregroundStyle(.secondary)
                } else if filteredWebsiteOrigins.isEmpty {
                    Text("no saved websites found").foregroundStyle(.secondary)
                }
                ForEach(filteredWebsiteOrigins, id: \.self) { origin in
                    SavedWebsiteSettingsRow(
                        store: store, origin: origin,
                        expanded: Binding(
                            get: { expandedWebsites.contains(origin) },
                            set: { expanded in
                                if expanded { expandedWebsites.insert(origin) } else { expandedWebsites.remove(origin) }
                            })
                    ).id(origin)
                }
                Text("macOS permissions remain authoritative for camera and microphone access.").font(.caption)
                    .foregroundStyle(.secondary)
            }.id("websites")
            Section(store.profile.privateMode ? "app links · private session" : "app links · all profiles") {
                if store.externalAppLinkPreferences.isEmpty {
                    Text("apps appear here when a website asks to open them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(externalAppIdentities, id: \.self) { identity in
                    ExternalAppLinkSettingsRow(store: store, identity: identity)
                }
                Button("add app…") { addExternalApp() }
                Text(store.profile.privateMode
                    ? "new choices last for this private session. app-wide blocks and ask settings still apply."
                    : "changing an app here applies to all profiles on this Mac. website and app blocks or explicit ask settings take priority over automatic opening.")
                    .font(.caption).foregroundStyle(.secondary)
            }.id("external-app-links")
            Section("website interaction · all profiles") {
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
        }
    }
    private var filteredWebsiteOrigins: [String] {
        let query = websiteSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return (store.profile.siteSettings ?? [:]).keys.sorted().filter {
            query.isEmpty || BrowserAddress.visible($0).localizedStandardContains(query)
                || $0.localizedStandardContains(query)
        }
    }
    private func addExternalApp() {
        let profileID = store.selectedProfileID
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "add app"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url,
                store.application.profiles.contains(where: { $0.id == profileID }) else { return }
            let identity = ExternalAppLinkPreference.identity(for: url)
            guard store.externalAppLinkPreference(identity: identity, profileID: profileID) == nil else { return }
            let name = FileManager.default.displayName(atPath: url.path)
            store.setExternalAppLinkPreference(
                .init(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                    applicationPath: url.path, policy: .inherit), identity: identity, profileID: profileID)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private var externalAppIdentities: [String] {
        store.externalAppLinkPreferences.keys.sorted {
            let apps = store.externalAppLinkPreferences
            let left = apps[$0]?.name ?? $0
            let right = apps[$1]?.name ?? $1
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
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
                SettingsActionButton("update filters", busy: store.blocker.updating) {
                    Task {
                        await store.blocker.update()
                        store.applyBlocker()
                    }
                }.id("filters")
                if let error = store.blocker.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
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
            Section("cookies · this profile") {
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
                Button("manage cookies…") {
                    store.showPage(.cookies)
                    store.application.coordinator?.activateBrowser()
                }.id("cookies")
            }
            Section("clear data · this profile") { ClearingView(store: store).id("clear") }

        }
    }
    private var extensions: some View {
        Section("extensions · \(store.profile.name)") {
            if store.profile.extensions.isEmpty {
                Text("no installed extensions").foregroundStyle(.secondary)
            }
            ForEach(store.profile.extensions) { record in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedExtensions.contains(record.id) },
                        set: {
                            if $0 { expandedExtensions.insert(record.id) } else { expandedExtensions.remove(record.id) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !record.hosts.isEmpty {
                            Text(record.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let status = record.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        let diagnostics = record.diagnostics ?? []
                        let previous = diagnostics.filter { $0.hasPrefix("Previous runtime · ") }
                        ForEach(diagnostics.filter { !$0.hasPrefix("Previous runtime · ") }, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        if !previous.isEmpty {
                            DisclosureGroup("previous runtime diagnostics · \(previous.count)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(previous, id: \.self) { diagnostic in
                                        Text(String(diagnostic.dropFirst("Previous runtime · ".count)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.top, 6)
                            }.font(.caption)
                        }
                        HStack {
                            Toggle(
                                "enabled",
                                isOn: Binding(
                                    get: { record.enabled },
                                    set: { enabled in
                                        Task { await store.runtime.extensions.setEnabled(record, enabled) }
                                    }))
                            Spacer()
                            Button("remove…", role: .destructive) {
                                extensionDeletionProfileID = store.selectedProfileID
                                extensionDeletionProfileName = store.profile.name
                                extensionDeletion = record
                            }
                        }
                    }.padding(.top, 8).controlSize(.small)
                } label: {
                    HStack(spacing: 10) {
                        GolzheimIcon(icon: .extensionPuzzle, size: 16).foregroundStyle(.secondary)
                        Text(record.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if !record.enabled {
                            Text("disabled").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            }
            SettingsActionButton(
                "load unpacked folder…", busy: store.runtime.extensions.installing,
                disabled: store.profile.privateMode
            ) {
                Task { await store.runtime.extensions.install(owner: store) }
            }.id("install-extension")
            HStack {
                TextField("Chrome Web Store URL or extension ID", text: $extensionAddress)
                SettingsActionButton(
                    "install…", busy: store.runtime.extensions.installing,
                    disabled: store.profile.privateMode
                ) {
                    Task { await store.runtime.extensions.installStore(extensionAddress, owner: store) }
                }
            }
            Text("extensions can request access to sites and browsing data. review access before installing.").font(
                .caption
            ).foregroundStyle(.secondary)
        }.id("extensions")
    }
    private var advanced: some View {
        Group {
            Section("performance") {
                Picker("performance indicator", selection: optional(\.performanceIndicatorVisibility, fallback: .whenActive)) {
                    ForEach(PerformanceIndicatorVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }.id("performance-indicator")
                if store.application.resources.hasInternalBattery {
                    Toggle("power saver", isOn: Binding(
                        get: { store.preferences.gameMode != true && resourceMonitor.saverEnabled },
                        set: { optional(\.powerSaver, fallback: false).wrappedValue = $0 }))
                        .disabled(store.preferences.gameMode == true || resourceMonitor.automaticSaverRequested).id("power-saver")
                    Picker("enable on battery below", selection: optional(\.powerSaverThreshold, fallback: 0)) {
                        Text("never").tag(0)
                        ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Text(store.preferences.gameMode == true
                        ? "off while game mode is on. your power saver choice resumes afterward."
                        : "reduces background activity and sleeps eligible idle tabs after five minutes. also follows macOS Low Power Mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("game mode", isOn: optional(\.gameMode, fallback: false)).id("game-mode")
                Text("prioritizes foreground browsing and suspends background pages while loaf is active. uses more power.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("macOS Low Power Mode and temperature limits can still reduce frame rates. turn off Low Power Mode in System Settings for the best performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("browsing time") {
                Toggle("save local browsing time", isOn: optional(\.tracksScreenTime, fallback: false)).id(
                    "browsing-time")
                Text("records focused-page and playing-media time by site, on this Mac. private browsing is excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("delete browsing-time data…", role: .destructive) { confirmTrackingDeletion = true }
            }
            Section("menus") {
                Toggle("capitalize menu labels", isOn: optional(\.capitalizeMenus, fallback: true))
                    .id("capitalize-menus")
            }
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
                Picker("default browser identity", selection: optional(\.userAgentMode, fallback: .automatic)) {
                    ForEach(UserAgentMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.id("identity")
                if store.preferences.userAgentMode == .custom {
                    TextField("custom user agent", text: optional(\.customUserAgent, fallback: ""))
                        .textFieldStyle(.roundedBorder).focusRingPadding()
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
                window.setTitlebarPromoted(promoted, title: title)
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

private struct SavedWebsiteSettingsRow: View {
    @ObservedObject var store: BrowserStore
    let origin: String
    @Binding var expanded: Bool
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var actionProfileID: UUID?
    @State private var actionProfileName = ""
    @State private var clearing = false

    private var settings: SiteSettings { store.profile.siteSettings?[origin] ?? SiteSettings() }
    private var host: String? { URL(string: origin)?.host }

    private func binding<Value>(_ key: WritableKeyPath<SiteSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { update(key, $0) })
    }

    private func optionalPermission(_ key: WritableKeyPath<SiteSettings, String?>, fallback: String) -> Binding<String>
    {
        Binding(get: { settings[keyPath: key] ?? fallback }, set: { update(key, $0) })
    }

    private func update<Value>(_ key: WritableKeyPath<SiteSettings, Value>, _ value: Value) {
        store.updateCurrent { profile in
            guard var settings = profile.siteSettings?[origin] else { return }
            settings[keyPath: key] = value
            profile.siteSettings?[origin] = settings
        }
        applyToOpenTabs()
    }

    private func applyToOpenTabs() {
        for tab in store.runtime.tabs.values {
            guard let url = tab.url, BrowserAddress.websiteOrigin(url) == origin else { continue }
            tab.applySiteSettings(url)
            WebKitAdapter.applyPointerLockPolicy(tab)
        }
    }

    private func reset() {
        let hadBlockerException = host.map { store.profile.allowedSites.contains($0) } ?? false
        store.updateCurrent { profile in
            profile.siteSettings?.removeValue(forKey: origin)
            if let host { profile.allowedSites.removeAll { $0 == host } }
        }
        applyToOpenTabs()
        if hadBlockerException {
            store.applyBlocker()
            for tab in store.runtime.tabs.values where tab.url?.host == host { tab.reload() }
        }
    }

    private func toggleBlocker(_ blocked: Bool) {
        guard let host else { return }
        store.updateCurrent { profile in
            profile.allowedSites.removeAll { $0 == host }
            if !blocked { profile.allowedSites.append(host) }
        }
        store.applyBlocker()
        for tab in store.runtime.tabs.values where tab.url?.host == host { tab.reload() }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                heading("privacy")
                SiteControlToggle(
                    "block ads and trackers",
                    isOn: Binding(
                        get: {
                            store.profile.blockerEnabled
                                && !(host.map { store.profile.allowedSites.contains($0) } ?? true)
                        }, set: { toggleBlocker($0) })
                )
                .disabled(!store.profile.blockerEnabled)
                SiteControlToggle(
                    "offer to save passwords",
                    isOn: Binding(
                        get: { settings.savePasswords != false }, set: { update(\.savePasswords, $0) })
                )
                .disabled(!store.preferences.savePasswords)

                Divider().padding(.vertical, 8)
                heading("permissions")
                SiteControlToggle(
                    "allow downloads",
                    isOn: Binding(
                        get: { settings.downloads != false }, set: { update(\.downloads, $0) }))
                ExternalAppLinkSitePicker(selection: binding(\.externalAppLinks))
                SiteControlPicker("camera", selection: binding(\.camera)) { permissionChoices }
                SiteControlPicker("microphone", selection: binding(\.microphone)) { permissionChoices }
                SiteControlPicker("location", selection: optionalPermission(\.location, fallback: "deny")) {
                    permissionChoices
                }
                SiteControlPicker("notifications", selection: optionalPermission(\.notifications, fallback: "ask")) {
                    permissionChoices
                }
                SiteControlPicker("pointer capture", selection: optionalPermission(\.pointerLock, fallback: "allow")) {
                    permissionChoices
                }.disabled(store.preferences.allowsPointerCapture == false)
                SiteControlToggle(
                    "automatic pop-ups",
                    isOn: Binding(
                        get: { settings.automaticPopups == true }, set: { update(\.automaticPopups, $0) })
                )
                .disabled(!WebKitAdapter.supportsSitePopups)

                Divider().padding(.vertical, 8)
                heading("page preferences")
                HStack {
                    Text("zoom")
                    Spacer()
                    Text("\(Int((settings.zoom * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button("reset") { update(\.zoom, 1.0) }
                }
                Slider(value: binding(\.zoom), in: 0.5...3, step: 0.1)
                    .accessibilityLabel("website zoom")
                SiteControlToggle("javascript", isOn: binding(\.javascript))
                SiteControlToggle("autoplay", isOn: binding(\.autoplay))
                    .disabled(!WebKitAdapter.supportsSiteAutoplay)
                SiteControlPicker("browser identity", selection: binding(\.userAgent)) {
                    Text("desktop Safari").tag(UserAgentMode.desktop)
                    Text("automatic").tag(UserAgentMode.automatic)
                }
                Text("reload to apply javascript, autoplay and pop-up changes")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                HStack {
                    Button("reset website overrides…", role: .destructive) {
                        actionProfileID = store.selectedProfileID
                        actionProfileName = store.profile.name
                        confirmReset = true
                    }
                    Spacer()
                    SettingsActionButton(
                        "clear website data…", busy: clearing,
                        disabled: store.application.busyProfileIDs.contains(store.selectedProfileID), role: .destructive
                    ) {
                        actionProfileID = store.selectedProfileID
                        actionProfileName = store.profile.name
                        confirmClear = true
                    }
                }
            }
            .padding(.top, 10)
            .controlSize(.small)
            .toggleStyle(.switch)
        } label: {
            HStack(spacing: 10) {
                WebsiteIcon(url: URL(string: origin), store: store)
                VStack(alignment: .leading, spacing: 3) {
                    Text(BrowserAddress.visible(origin))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .destructiveConfirmationDialog("clear website data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("clear data", role: .destructive) {
                guard let url = URL(string: origin), let profileID = actionProfileID,
                    store.profiles.contains(where: { $0.id == profileID })
                else { return }
                clearing = true
                Task {
                    await store.clearSite(url, profileID: profileID)
                    clearing = false
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this can sign you out of this site and its subdomains in \(actionProfileName). It cannot be undone.")
        }
        .destructiveConfirmationDialog("reset website overrides?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("reset overrides", role: .destructive) {
                guard actionProfileID == store.selectedProfileID else { return }
                reset()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("This restores default permissions and page preferences for this website in \(actionProfileName).")
        }
    }

    private var summary: String {
        var details: [String] = []
        if settings.downloads == false { details.append("downloads blocked") }
        if settings.camera != "ask" { details.append("camera " + (settings.camera == "allow" ? "allowed" : "blocked")) }
        if settings.microphone != "ask" {
            details.append("microphone " + (settings.microphone == "allow" ? "allowed" : "blocked"))
        }
        if let location = settings.location, location != "deny" { details.append("location " + location) }
        if let notifications = settings.notifications, notifications != "ask" {
            details.append("notifications " + notifications)
        }
        if settings.pointerLock == "deny" { details.append("pointer blocked") }
        if let policy = settings.externalAppLinks, policy != .inherit {
            details.append(policy == .block ? "app links blocked" : policy == .ask ? "app links ask" : "app links automatic")
        }
        if !settings.javascript { details.append("javascript off") }
        if settings.zoom != 1 { details.append("\(Int((settings.zoom * 100).rounded()))% zoom") }
        if settings.savePasswords == false { details.append("password saving off") }
        if details.isEmpty { return "" }
        return details.joined(separator: " · ")
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var permissionChoices: some View {
        Text("ask").tag("ask")
        Text("allow").tag("allow")
        Text("deny").tag("deny")
    }
}

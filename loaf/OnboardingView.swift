import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @AppStorage("loaf.appearance") private var appearance = "system"
    @State private var step = 0
    @State private var name = "personal"
    @State private var previewDark = false
    @State private var icon = "🌱"
    @State private var importVisible = false
    @State private var appearanceDemo: AppearancePreviewOption?
    init(store: BrowserStore, initialStep: Int = 0) {
        self.store = store
        _step = State(initialValue: min(4, max(0, initialStep)))
    }
    private func personalized<Value>(_ key: WritableKeyPath<Personalization, Value>) -> Binding<Value> {
        Binding(
            get: { (store.profile.personalization ?? Personalization())[keyPath: key] },
            set: { value in
                store.updateCurrent {
                    $0.personalization = $0.personalization ?? Personalization()
                    $0.personalization?[keyPath: key] = value
                }
            })
    }
    private func preference<Value>(_ key: WritableKeyPath<BrowserPreferences, Value?>, fallback: Value) -> Binding<
        Value
    > {
        Binding(
            get: { store.preferences[keyPath: key] ?? fallback },
            set: {
                store.preferences[keyPath: key] = $0
                store.persistSoon()
            })
    }
    private func headerFont(_ size: CGFloat) -> Font {
        if let font = Golzheim.iconFont(size: size, weight: 400) { return Font(font) }
        return .system(size: size, weight: .medium)
    }
    private var profileNameIssue: String? {
        Self.profileNameIssue(name, profiles: store.profiles, editing: store.selectedProfileID)
    }
    static func profileNameIssue(_ name: String, profiles: [Profile], editing id: UUID) -> String? {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if value.isEmpty { return "give your profile a name" }
        if profiles.contains(where: {
            $0.id != id && $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return "another profile already uses this name"
        }
        return nil
    }
    private func option<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control().labelsHidden().accessibilityLabel(title)
        }.frame(minHeight: 28)
    }
    private var themeColorControls: some View {
        ProfileThemeControls(
            tint: Binding(get: { store.profile.tint }, set: { value in store.updateCurrent { $0.tint = value } }),
            customTint: personalized(\.customTint),
            strength: personalized(\.tintStrength),
            transparency: Binding(
                get: { store.profile.personalization?.windowTransparency ?? 0 },
                set: { value in
                    store.updateCurrent {
                        $0.personalization = $0.personalization ?? Personalization()
                        $0.personalization?.windowTransparency = ProfileTransparency.bounded(value)
                    }
                }), showsPreviews: false, compact: true
        )
        .font(.system(size: 12)).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
    private var themePreviews: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("preview", selection: $previewDark) {
                Text("light").tag(false)
                Text("dark").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            ProfileThemePreview(
                height: 154, color: profileTint(store.profile),
                strength: store.profile.personalization?.tintStrength ?? 0.06, dark: previewDark,
                transparency: store.profile.personalization?.windowTransparency ?? 0,
                settings: AppearancePreviewSettings(store.preferences), demonstration: appearanceDemo
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("appearance").fontWeight(.medium)
            Picker("appearance", selection: $appearance) {
                Text("system").tag("system")
                Text("light").tag("light")
                Text("dark").tag("dark")
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            option("sidebar-only titlebar") {
                Toggle(
                    "sidebar-only titlebar",
                    isOn: Binding(
                        get: { store.usesSidebarOnlyChrome },
                        set: { value in
                            store.preferences.sidebarOnlyChrome = value
                            if !value { store.preferences.insetCollapsedPage = false }
                            store.persistSoon()
                        }))
            }.modifier(AppearancePreviewHover(option: .titlebar, selection: $appearanceDemo))
            Divider()
            option("soften sidebar resizing") {
                Toggle("soften sidebar resizing", isOn: preference(\.resizeTransition, fallback: true))
            }
            .modifier(AppearancePreviewHover(option: .resizing, selection: $appearanceDemo))
            Divider()
            option("tint wonderbar") { Toggle("tint wonderbar", isOn: preference(\.tintWonderbar, fallback: false)) }
                .modifier(AppearancePreviewHover(option: .wonderbarTint, selection: $appearanceDemo))
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private func themeSetup(stacked: Bool) -> some View {
        if stacked {
            VStack(spacing: 20) {
                themeColorControls
                themePreviews
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 24) {
                themeColorControls
                themePreviews.frame(width: 350)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private var browsingSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("search").fontWeight(.medium).foregroundStyle(ink.opacity(0.65))
            option("search engine") {
                OnboardingSearchEnginePicker(selection: preference(\.searchEngine, fallback: .google)).frame(
                    width: 180, height: 24, alignment: .leading)
            }
            Divider()
            if store.preferences.searchEngine == .custom {
                TextField("HTTPS search URL with {query}", text: preference(\.customSearchTemplate, fallback: ""))
                    .textFieldStyle(.roundedBorder)
                if store.searchAddress("loaf") == nil {
                    Text("include one {query} placeholder in an HTTPS URL").font(.system(size: 11)).foregroundStyle(
                        .secondary)
                }
            }
            option("search suggestions") { Toggle("search suggestions", isOn: $store.preferences.googleSuggestions) }
            Text(
                """
                off by default. turn on to send what you type to your suggestion provider. \
                private browsing keeps them off.
                """
            ).font(
                .system(size: 11)
            ).foregroundStyle(ink.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("privacy & startup").fontWeight(.medium).foregroundStyle(ink.opacity(0.65))
            option("block ads and trackers") {
                Toggle(
                    "block ads and trackers",
                    isOn: Binding(
                        get: { store.profile.blockerEnabled },
                        set: { value in
                            store.updateCurrent { $0.blockerEnabled = value }
                            store.applyBlocker()
                        }))
            }
            Divider()
            option("restore tabs on launch") {
                Toggle("restore tabs on launch", isOn: preference(\.restoreSession, fallback: true))
            }
            Divider()
            option("AI features") {
                Toggle(
                    "AI features",
                    isOn: Binding(
                        get: { store.preferences.aiFeaturesEnabled != false },
                        set: { store.application.setAIFeaturesEnabled($0) }))
            }
            option("AI provider") {
                Picker(
                    "AI provider",
                    selection: Binding<AIProvider?>(
                        get: { store.preferences.aiProvider },
                        set: {
                            store.preferences.aiProvider = $0
                            store.persistSoon()
                        })
                ) {
                    Text("none").tag(Optional<AIProvider>.none)
                    ForEach(AppleIntelligence.visibleProviders, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 200)
            }
            .disabled(store.preferences.aiFeaturesEnabled == false)
            Text(
                store.preferences.aiFeaturesEnabled == false
                    ? "AI features are off. your regular search engine still works."
                    : store.preferences.aiProvider == nil
                        ? "no AI provider selected. alternate search will stay off."
                        : AppleIntelligence.unavailableReason(for: store.preferences.aiProvider ?? .chatgpt)
                            ?? "AI is optional and only runs when you ask. connect ChatGPT later in search settings."
            ).font(.system(size: 11)).foregroundStyle(ink.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13)).toggleStyle(.switch).controlSize(.small).padding(22).background(
            ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
    private var paper: Color {
        scheme == .dark ? Color(red: 0.12, green: 0.115, blue: 0.10) : Color(red: 0.98, green: 0.957, blue: 0.91)
    }
    private var ink: Color {
        scheme == .dark ? Color(red: 0.96, green: 0.925, blue: 0.85) : Color(red: 0.22, green: 0.18, blue: 0.14)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Image("loaf-lockup").resizable().scaledToFit().frame(width: 110, height: 34).accessibilityLabel(
                        "loaf")
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<5) { index in
                            Capsule().fill(ink.opacity(index == step ? 0.7 : 0.15)).frame(
                                width: index == step ? 24 : 6, height: 6)
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel("step \(step + 1) of 5")
                }.padding(.horizontal, 38).padding(.top, 60).padding(.bottom, 16)
                FocusRingSafeScrollView {
                    VStack(alignment: .leading, spacing: step == 2 ? 20 : 24) {
                        if step == 0 {
                            Image("loaf-lockup").resizable().scaledToFit().frame(width: 240, height: 88)
                                .accessibilityHidden(true).padding(.bottom, 8)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text(
                                [
                                    "welcome to loaf", "create your profile", "choose your appearance",
                                    "search and privacy", "ready to browse",
                                ][step]
                            )
                            .font(headerFont(step == 2 || step == 3 ? 26 : 32)).tracking(-0.5).fixedSize(
                                horizontal: false, vertical: true)
                            Text(
                                [
                                    "set up your profile, appearance, and browsing preferences.",
                                    "profiles keep bookmarks, history, and website data separate.",
                                    "preview your color in light and dark mode.",
                                    "choose how you search and what loaf remembers. you can change these later.",
                                    "use these shortcuts to get around.",
                                ][step]
                            )
                            .font(.system(size: 14)).foregroundStyle(ink.opacity(0.65)).lineSpacing(3).fixedSize(
                                horizontal: false, vertical: true)
                        }
                        if step == 0 {
                            HStack(alignment: .top, spacing: 10) {
                                GolzheimIcon(icon: .lock, size: 15)
                                Text("passwords in Keychain. browsing data on your Mac.").font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.foregroundStyle(ink.opacity(0.6)).padding(.top, 6)
                        } else if step == 1 {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("profile name").font(.system(size: 12, weight: .medium)).foregroundStyle(
                                    ink.opacity(0.65))
                                TextField("profile name", text: $name).textFieldStyle(.roundedBorder).controlSize(
                                    .large
                                ).accessibilityLabel("profile name")
                                if let issue = profileNameIssue {
                                    Text(issue).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                                Text("profile icon").font(.system(size: 12, weight: .medium)).foregroundStyle(
                                    ink.opacity(0.65))
                                GolzheimPicker(selection: $icon, gridHeight: 128)
                            }.padding(22).background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.08)))
                        } else if step == 2 {
                            themeSetup(stacked: geometry.size.width < 820)
                        } else if step == 3 {
                            browsingSetup
                        } else {
                            VStack(spacing: 18) {
                                shortcut("⌘L", "open the wonderbar")
                                shortcut("⇧↵", "open a result in a new tab")
                                shortcut("⌘S", "show or hide the sidebar")
                            }.padding(22).background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.08)))
                            Button("import from another browser…") { importVisible = true }
                                .controlSize(.large)
                            Text("choose installed browsers, profiles and Arc spaces. importing is optional.")
                                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.6))
                            Text("settings are available from the loaf menu.").font(.system(size: 12)).foregroundStyle(
                                ink.opacity(0.6))
                        }
                    }.frame(maxWidth: step == 2 ? 840 : 460, alignment: .leading).frame(
                        maxWidth: .infinity, minHeight: max(0, geometry.size.height - 224), alignment: .center
                    )
                    .padding(.horizontal, 40).padding(.vertical, 12).id(step).transition(
                        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                }.scrollIndicators(.hidden)
                HStack {
                    if step > 0 { Button("back") { move(-1) }.buttonStyle(.plain).foregroundStyle(ink.opacity(0.6)) }
                    Spacer()
                    Button(step == 4 ? "start browsing" : "continue") { advance() }
                        .buttonStyle(OnboardingContinueStyle(ink: ink, paper: paper)).keyboardShortcut(.defaultAction)
                        .disabled(
                            (step == 1 && profileNameIssue != nil)
                                || (step == 3 && store.preferences.searchEngine == .custom
                                    && store.searchAddress("loaf") == nil)
                        )
                }.frame(maxWidth: 460).padding(.horizontal, 40).frame(height: 90).frame(maxWidth: .infinity)
            }.foregroundStyle(ink).background(paper).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.overlay(alignment: .topLeading) {
            if store.usesSidebarOnlyChrome {
                SidebarWindowControls(floating: false, tint: NSColor(ink)).frame(width: 76, height: 32)
            }
        }.onAppear {
            name = store.profile.name
            icon = store.profile.emoji
            previewDark = scheme == .dark
            if store.preferences.onboardingCompleted == nil { store.preferences.onboardingCompleted = false }
            store.omnibarVisible = false
            store.findVisible = false
            store.application.coordinator?.fitOnboardingWindow(store)
        }
        .onChange(of: store.selectedProfileID) { _, _ in
            name = store.profile.name
            icon = store.profile.emoji
        }.sheet(isPresented: $importVisible) { ProfileImportView(store: store) }
    }
    private func advance() {
        if step == 1 {
            guard profileNameIssue == nil else { return }
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateCurrent {
                $0.name = String(value.prefix(40))
                $0.emoji = icon
            }
        }
        if step < 4 {
            move(1)
        } else {
            store.preferences.configureOnboardingAlternateSearch()
            store.preferences.onboardingCompleted = true
            store.application.onboardingVisible = false
            store.persistSoon()
            store.openOmnibar(query: "")
        }
    }
    private func move(_ offset: Int) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .smooth(duration: 0.24)) { step += offset }
    }
    private func shortcut(_ key: String, _ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 13))
            Spacer()
            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingContinueStyle: ButtonStyle {
    let ink: Color
    let paper: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(paper)
            .padding(.horizontal, 22).padding(.vertical, 12).background(ink, in: RoundedRectangle(cornerRadius: 10))
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1).scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.985 : 1
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct OnboardingSearchEnginePicker: NSViewRepresentable {
    @Binding var selection: SearchEngine
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24), pullsDown: false)
        button.addItems(withTitles: SearchEngine.available.map(\.title))
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        (button.cell as? NSPopUpButtonCell)?.alignment = .left
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("search engine")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if let index = SearchEngine.available.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        (button.cell as? NSPopUpButtonCell)?.alignment = .left
    }
    final class Coordinator: NSObject {
        var selection: Binding<SearchEngine>
        init(selection: Binding<SearchEngine>) { self.selection = selection }
        @objc func changed(_ button: NSPopUpButton) {
            guard SearchEngine.available.indices.contains(button.indexOfSelectedItem) else { return }
            selection.wrappedValue = SearchEngine.available[button.indexOfSelectedItem]
        }
    }
}

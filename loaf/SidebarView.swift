import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension UTType { static let loafTab = UTType(exportedAs: "app.tryloaf.loaf.tab", conformingTo: .data) }
nonisolated struct TabDrag: Codable {
    let window: UUID
    let profile: UUID
    let tab: UUID
}
struct TabDropPosition: Equatable {
    let target: UUID
    let after: Bool
}
struct PinDropPreview: Equatable {
    let row: Bool
    let position: TabDropPosition?
}

struct ExtensionStripLayout {
    let sidebarWidth: CGFloat

    var pinnedCapacity: Int { max(1, Int((sidebarWidth - 64) / 32)) }
    var overflowColumns: Int { max(1, Int((sidebarWidth - 38) / 34)) }
    func overflowRows(for count: Int) -> Int {
        min(4, (count + overflowColumns - 1) / overflowColumns)
    }
}

struct SidebarView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: BrowserStore
    var floating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profilePicker = false
    @State private var draggedProfileID: UUID?
    @State private var profileDropPosition: ProfileDropPosition?
    @State private var traySection: TraySection?
    @State private var trayProgress: CGFloat = 0
    @State private var trayBaseHeight: CGFloat = 48
    @State private var traySettleTask: Task<Void, Never>?
    @State private var extensionProgress: CGFloat = 0
    @State private var extensionTask: Task<Void, Never>?
    @State private var draggedExtensionID: UUID?
    @State private var extensionOrder: [UUID] = []
    @State private var extensionOverflow = false
    @State private var drop: TabDropPosition?
    @State private var profileMotionID: UUID?
    @State private var profileMotionOffset: CGFloat = 0
    @AppStorage("loaf.appearance") private var appearance = "system"
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    WindowDragArea().frame(maxWidth: .infinity, minHeight: 40)
                        .overlay {
                            GeometryReader { gap in
                                PerformanceIndicator(store: store)
                                    .position(
                                        x: PerformanceIndicatorPlacement.center(in: gap.size.width),
                                        y: store.chromeControlsCenterY - (floating ? 3 : 0))
                            }
                        }
                    HStack(spacing: 0) {
                        NavigationHistoryButton(store: store, backward: true).frame(width: 26, height: 26)
                        NavigationHistoryButton(store: store, backward: false).frame(width: 26, height: 26)
                        IconButton(icon: store.selectedTab?.loading == true ? .close : .reload, label: "reload (⌘R)") {
                            if store.selectedTab?.loading == true {
                                store.selectedTab?.webView.stopLoading()
                            } else {
                                store.selectedTab?.reload()
                            }
                        }.disabled(store.selectedTab?.canReload != true)
                    }.offset(y: store.chromeControlsCenterY - 20 - (floating ? 3 : 0))
                }.padding(.trailing, 8).frame(height: 40).fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) {
                        if store.usesSidebarOnlyChrome {
                            SidebarWindowControls(
                                floating: floating, centerY: store.chromeControlsCenterY,
                                tint: NSColor(profileTint(store.profile))
                            ).frame(
                                width: 76, height: 32)
                        }
                    }
                address.padding(.horizontal, 8)
                profileStrip
                VStack(spacing: 8) {
                    SidebarMediaPlayers(store: store, collection: store.sidebarMedia)
                    if store.preferences.hasWeatherLocation && store.profile.personalization?.sidebarWeather != false {
                        weather
                    }

                }.padding(.horizontal, 8).padding(.bottom, 8)
                Color.clear.frame(height: trayBaseHeight)

            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .overlay(alignment: .bottom) {
                tray(
                    availableHeight: max(0, geometry.size.height - 40),
                    sidebarWidth: geometry.size.width
                ).zIndex(3)
            }
        }
        .animation(nil, value: store.extensionsVisible)
        .animation(nil, value: extensionProgress)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2), value: store.profile.personalization?.compactSidebarWeather
        )
        .background {
            if floating {
                ProfileWindowSurface(
                    color: chromeBase, transparency: store.profileSwipeTransparency
                )
                .animation(reduceMotion ? nil : ProfileSwitchMotion.animation, value: store.selectedProfileID)
            }
        }
        .environment(
            \.colorScheme,
            store.profile.privateMode
                ? .dark
                : ProfileColor.surfaceScheme(
                    profileTint(store.profile), strength: store.profile.personalization?.tintStrength ?? 0.06,
                    dark: scheme == .dark)
        )
        .background(SidebarInteractions(store: store, traySection: $traySection, trayProgress: trayProgress))
        .overlay(alignment: .trailing) { SidebarDivider(store: store).frame(width: 8) }
        .onChange(of: store.selectedProfileID) { _, _ in
            cancelRebound()
            drop = nil
            traySection = nil
            trayProgress = 0
            extensionOrder = []
            draggedExtensionID = nil
            extensionOverflow = false
        }
        .task(id: store.profileTransitionID) {
            guard store.profileTransitionOrigin != nil else { return }
            let token = store.profileTransitionID
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                profileMotionID = token
                profileMotionOffset = reduceMotion ? 0 : store.profileTransitionStart
            }
            await Task.yield()
            guard !Task.isCancelled, store.profileTransitionID == token,
                store.profileTransitionOrigin != nil
            else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0)) {
                profileMotionOffset = 0
            }
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            guard !Task.isCancelled, store.profileTransitionID == token else { return }
            store.profileTransitionOrigin = nil
        }
        .onAppear { extensionProgress = store.extensionsVisible ? 1 : 0 }
        .onChange(of: store.extensionsVisible) { _, open in animateExtensions(open) }
        .onChange(of: store.trayToggleID) { _, _ in
            setTray(trayProgress > 0.5 ? nil : traySection ?? .downloads)
        }
        .onDisappear {
            cancelRebound()
            extensionTask?.cancel()
        }
        .onChange(of: store.draggedTabID) { _, value in if value == nil { drop = nil } }
        .onChange(of: store.draggedFolderID) { _, value in if value == nil { drop = nil } }
    }
    var profileTabs: some View {
        VStack(spacing: 0) {
            if !store.gridPinnedTabs.isEmpty || store.draggedTabID != nil {
                Color.clear.frame(
                    height: PinGridLayout.height(
                        for: max(
                            store.draggedTabID != nil ? 1 : 0,
                            store.gridPinnedTabs.count
                                + (store.pinDropPreview?.row == false && store.pinReplacementTarget == nil
                                    && !store.gridPinnedTabs.contains { $0.id == store.draggedTabID } ? 1 : 0)),
                        list: store.preferences.pinnedLayout == "list")
                )
                .overlay(PinnedTabGrid(store: store)).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                .overlay { PinDropZone(store: store).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4) }
            }
            TabListView(store: store, position: $drop)
                .padding(
                    .top,
                    store.gridPinnedTabs.isEmpty && store.draggedTabID == nil && !store.rowPinnedTabs.isEmpty ? 10 : 0
                )
        }
        .clipped()
    }
    private var profileStrip: some View {
        let width = store.preferences.sidebarWidth
        let arrival =
            reduceMotion || store.profileTransitionOrigin == nil
            ? 0
            : profileMotionID == store.profileTransitionID ? profileMotionOffset : store.profileTransitionStart
        let drag = reduceMotion ? 0 : store.profileSwipeDistance
        let offset = arrival - drag + store.profileResistance
        return ZStack(alignment: .topLeading) {
            if !reduceMotion, let origin = store.profileTransitionOrigin {
                ProfileSidebarPreview(store: store, profile: origin)
                    .environment(\.colorScheme, previewScheme(origin))
                    .offset(x: offset - CGFloat(store.profileDirection) * width).allowsHitTesting(false)
            }
            profileTabs
                .id(store.selectedProfileID)
                .transition(.identity)
                .transaction { transaction in
                    if store.profileTransitionOrigin != nil || store.profileSwipeDistance != 0 {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .offset(x: offset)
            if !reduceMotion, let target = store.profileSwipeTarget,
                target.id != store.profileTransitionOrigin?.id
            {
                ProfileSidebarPreview(store: store, profile: target)
                    .environment(\.colorScheme, previewScheme(target))
                    .offset(x: offset + (drag > 0 ? width : -width)).allowsHitTesting(false)
            }
        }.clipped()
    }
    private func previewScheme(_ profile: Profile) -> ColorScheme {
        let base = LoafAppearance.shared.colorScheme(for: appearance, privateMode: profile.privateMode)
        return profile.interfaceScheme(fallback: ProfileColor.surfaceScheme(
                profileTint(profile),
                strength: profile.personalization?.tintStrength ?? 0.06, dark: base == .dark))
    }
    private var address: some View {
        AddressFeedback(feedback: store.feedback, activate: { store.openOmnibar() }) {
            HStack(spacing: 0) {
                AddressSecurityButton(
                    icon: BrowserAddress.defaultSearchQuery(store.selectedTab?.url) != nil
                        ? .search : store.selectedTab?.secure == true ? .lock : .globe
                ) { store.toggleSiteSettings(from: .sidebar) }
                .background(SiteSettingsAnchor(store: store, source: .sidebar))
                .padding(.leading, 4)
                Button {
                    store.openOmnibar()
                } label: {
                    AddressLabel(
                        url: store.selectedTab?.url,
                        fallback: store.selectedTab?.page == .web
                            ? "search or surf..." : store.selectedTab?.page.address ?? "search or surf..."
                    )
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                    .frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("search or surf... (⌘L)").accessibilityLabel("address bar")
            }
        }.frame(height: 28).background(
            Color.white.opacity(scheme == .dark ? 0.08 : 0.18), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
        .contextMenu {
            Button("copy url") { store.copyCurrentAddress() }
            Button("add or remove favorite") { store.favoriteCurrent() }
            Button("website settings…") {
                store.siteSettingsTrigger = .sidebar
                store.siteSettingsVisible = true
            }
        }
    }
    private var weather: some View {
        Button {
            store.application.coordinator?.showSettings(for: store, section: "general")
        } label: {
            HStack(spacing: 8) {
                GolzheimIcon(
                    icon: store.weather.icon,
                    size: store.profile.personalization?.compactSidebarWeather == true ? 16 : 22
                ).fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.weather.city.isEmpty ? store.preferences.weatherLocationLabel : store.weather.city).font(
                        .system(size: 12)
                    ).lineLimit(1)
                    if store.profile.personalization?.compactSidebarWeather != true {
                        Text(
                            store.weather.error
                                ?? (store.weather.loading
                                    ? "loading weather…"
                                    : store.weather.condition.isEmpty ? "weather unavailable" : store.weather.condition)
                        ).font(
                            .system(size: 10)
                        ).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if let temp = store.weather.temperature {
                    Text("\(temp)°").font(
                        .system(
                            size: store.profile.personalization?.compactSidebarWeather == true ? 16 : 24, weight: .light
                        )
                    ).monospacedDigit().fixedSize()
                        .layoutPriority(1)
                }
            }.padding(store.profile.personalization?.compactSidebarWeather == true ? 6 : 8)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(LoafButtonStyle()).help("weather").modifier(WeatherRefresh(store: store))
    }
    private var chromeBase: Color {
        store.profileSwipeSurface(dark: scheme == .dark)
    }
    private var trayRadius: CGFloat { floating ? 5 : 8 }
    private func cancelRebound() {
        traySettleTask?.cancel()
        traySettleTask = nil
    }
    private func animateExtensions(_ open: Bool) {
        extensionTask?.cancel()
        let start = extensionProgress
        let target: CGFloat = open ? 1 : 0
        guard !reduceMotion else {
            extensionProgress = target
            return
        }

        extensionTask = Task { @MainActor in
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.2)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    extensionProgress = start + (target - start) * CGFloat(1 - pow(1 - t, 3))
                }
                if t == 1 { break }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    private func setTray(_ section: TraySection?, velocity: CGFloat = 0) {
        cancelRebound()
        if let section { traySection = section }
        let trajectory = TraySettle(start: trayProgress, open: section != nil, pointsPerSecond: velocity)
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) { trayProgress = trajectory.target }
            return
        }
        traySettleTask = Task { @MainActor in
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) { trayProgress = trajectory.value(at: elapsed) }
                if elapsed >= 0.65 { break }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    private func tray(availableHeight: CGFloat, sidebarWidth: CGFloat) -> some View {
        let layout = ExtensionStripLayout(sidebarWidth: sidebarWidth)
        return VStack(spacing: 0) {
            ScrollView {
                SidebarTrayContent(
                    store: store, section: Binding(get: { traySection ?? .downloads }, set: { traySection = $0 })
                ) { setTray(nil) }
                .frame(height: TrayMetrics.contentHeight).opacity(min(1, max(0, trayProgress)))
                .background(ChromeScrollbarsHidden())
            }
            .scrollIndicators(.hidden)
            .frame(
                height: min(max(0, availableHeight - trayBaseHeight), max(0, TrayMetrics.contentHeight * trayProgress)),
                alignment: .top
            ).clipped()
            .allowsHitTesting(trayProgress > 0.95).accessibilityHidden(trayProgress < 0.95)
            VStack(spacing: 0) {
                extensionStrip(layout: layout).opacity(extensionProgress)
                    .offset(y: 6 * (1 - extensionProgress))
                    .frame(height: extensionStripHeight(layout: layout) * extensionProgress, alignment: .top).clipped()
                    .allowsHitTesting(store.extensionsVisible).accessibilityHidden(!store.extensionsVisible)
                SoftwareUpdateReminder()
                footer.zIndex(1)
            }.onGeometryChange(for: CGFloat.self, of: { $0.size.height + 8 }) { trayBaseHeight = $0 }
        }
        .background {
            ProfileWindowSurface(
                color: chromeBase, transparency: store.profileSwipeTransparency
            )
            .clipShape(RoundedRectangle(cornerRadius: trayRadius))
            .overlay(
                RoundedRectangle(cornerRadius: trayRadius).fill(Color.primary.opacity(0.035 * max(0, trayProgress)))
            )
            .opacity(min(1, max(0, trayProgress)))
        }
        .overlay(
            RoundedRectangle(cornerRadius: trayRadius).strokeBorder(Color.primary.opacity(0.05 * max(0, trayProgress)))
        )
        .clipShape(RoundedRectangle(cornerRadius: trayRadius))
        .background(TrayGestureAnchor(store: store))
        .background(
            TrayScrollDriver(
                progress: trayProgress,
                changed: { value in
                    cancelRebound()
                    if traySection == nil { traySection = .downloads }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) { trayProgress = value }
                }, settled: { open, velocity in setTray(open ? traySection ?? .downloads : nil, velocity: velocity) },
                discreteChanged: { value in
                    cancelRebound()
                    if traySection == nil { traySection = .downloads }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { trayProgress = value }
                }
            ).id(store.selectedProfileID)
        )
        .padding(.horizontal, 8).padding(.bottom, 8)
        .animation(nil, value: store.extensionsVisible)
        .accessibilityElement(children: .contain).accessibilityLabel(trayProgress == 0 ? "sidebar controls" : "tray")
    }
    private var orderedExtensions: [InstalledExtension] {
        let enabled = store.profile.extensions.filter(\.enabled)
        let records = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        let order = extensionOrder.isEmpty ? enabled.map(\.id) : extensionOrder
        return order.compactMap { records[$0] } + enabled.filter { !order.contains($0.id) }
    }
    private func extensionStripHeight(layout: ExtensionStripLayout) -> CGFloat {
        let overflow = max(0, orderedExtensions.count - layout.pinnedCapacity)
        return 36 + (overflow > 0 ? 18 : 0)
            + (extensionOverflow && overflow > 0 ? CGFloat(layout.overflowRows(for: overflow)) * 32 + 8 : 0)
    }
    private func extensionStrip(layout: ExtensionStripLayout) -> some View {
        let enabled = orderedExtensions
        let pinned = Array(enabled.prefix(layout.pinnedCapacity))
        let overflow = Array(enabled.dropFirst(layout.pinnedCapacity))
        return VStack(spacing: 4) {
            if extensionOverflow, !overflow.isEmpty {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: layout.overflowColumns),
                        spacing: 4
                    ) {
                        ForEach(overflow) { extensionButton($0) }
                    }.padding(4)
                }.scrollIndicators(.hidden).frame(height: CGFloat(layout.overflowRows(for: overflow.count)) * 32 + 4)
            }
            if !overflow.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { extensionOverflow.toggle() }
                } label: {
                    GolzheimIcon(icon: extensionOverflow ? .disclosureDown : .disclosureUp, size: 12)
                        .frame(maxWidth: .infinity).frame(height: 14)
                }.buttonStyle(LoafButtonStyle()).help(
                    extensionOverflow ? "hide other extensions" : "show other extensions"
                )
                .accessibilityLabel(extensionOverflow ? "hide other extensions" : "show other extensions")
            }
            HStack(spacing: 0) {
                if enabled.isEmpty {
                    Text(store.profile.extensions.isEmpty ? "no installed extensions" : "no enabled extensions")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
                } else {
                    ForEach(pinned) { extensionButton($0) }
                    if pinned.count < layout.pinnedCapacity { Spacer(minLength: 0) }
                }
                Button {
                    store.showPage(.extensions)
                } label: {
                    GolzheimIcon(icon: .settings, size: 14).frame(width: 24, height: 28)
                }.buttonStyle(LoafButtonStyle()).help("manage extensions")
            }.padding(4)
        }.frame(height: extensionStripHeight(layout: layout))
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 8)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: enabled.map(\.id))
            .accessibilityElement(children: .contain).accessibilityLabel("extension tray")
    }
    private func extensionButton(_ record: InstalledExtension) -> some View {
        Button {
            store.runtime.extensions.perform(record)
        } label: {
            Group {
                if let context = store.runtime.extensions.contexts[record.id],
                    let image = context.webExtension.icon(for: CGSize(width: 18, height: 18))
                {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    GolzheimIcon(icon: .extensionPuzzle, size: 16)
                }
            }.frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(LoafButtonStyle()).help(record.name).accessibilityLabel(record.name)
            .opacity(draggedExtensionID == record.id ? 0.25 : 1)
            .overlay(
                ExtensionDragArea(
                    record: record, store: store,
                    began: {
                        extensionOrder = store.profile.extensions.filter(\.enabled).map(\.id)
                        draggedExtensionID = record.id
                    },
                    ended: {
                        draggedExtensionID = nil
                        extensionOrder = []
                    })
            )
            .onDrop(
                of: [.text],
                delegate: ExtensionReorderDrop(
                    store: store, target: record.id, dragged: $draggedExtensionID, order: $extensionOrder)
            )
            .contextMenu {
                if let index = store.profile.extensions.firstIndex(where: { $0.id == record.id }) {
                    Button("move to first pinned slot") {
                        store.updateCurrent { profile in
                            let extensionRecord = profile.extensions.remove(at: index)
                            profile.extensions.insert(extensionRecord, at: 0)
                        }
                        extensionOrder = []
                    }
                }
                Button("manage extensions…") { store.showPage(.extensions) }
            }
    }
    private var footer: some View {
        HStack(spacing: 0) {
            DownloadTrayButton(store: store, expansion: trayProgress) {
                setTray(trayProgress > 0.5 ? nil : .downloads)
            }
            Spacer(minLength: 4)
            Button {
                profilePicker.toggle()
            } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ProfileIcon(profile: store.profile, size: 14)
                        Text(store.profile.name).font(.system(size: 13)).lineLimit(1)
                    }
                    .id(store.selectedProfileID)
                    .transition(.identity)
                    HStack(spacing: 4) {
                        ForEach(store.profiles) { p in
                            Capsule().fill(store.profile.privateMode ? profileTint(store.profile) : profileTint(p))
                                .frame(
                                    width: p.id == store.selectedProfileID ? 20 : 8, height: 2
                                ).opacity(p.id == store.selectedProfileID ? 1 : 0.35)
                        }
                    }
                    .animation(reduceMotion ? nil : ProfileSwitchMotion.animation, value: store.selectedProfileID)
                }.frame(height: 36)
            }.buttonStyle(LoafButtonStyle()).help("switch profile").popover(isPresented: $profilePicker) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.profiles) { profile in
                        ProfileReorderRow(
                            profile: profile, application: store.application,
                            draggedID: $draggedProfileID, position: $profileDropPosition
                        ) {
                            Button {
                                store.switchProfile(profile.id)
                                profilePicker = false
                            } label: {
                                HStack(spacing: 8) {
                                    ProfileIcon(profile: profile, size: 20)
                                    Text(profile.name)
                                    Spacer()
                                    if profile.id == store.selectedProfileID { GolzheimIcon(icon: .check) }
                                }.padding(8).frame(width: 184)
                            }.buttonStyle(LoafButtonStyle())
                        }

                    }
                    Divider()
                    Button("edit profile…") {
                        store.editingProfileID = store.selectedProfileID
                        profilePicker = false
                    }.padding(8)
                }.padding(8)
            }
            Spacer(minLength: 4)
            Button {
                store.toggleExtensions()
            } label: {
                GolzheimIcon(icon: .extensionPuzzle, size: 20, weight: 100).frame(width: 26, height: 26)
                    .background(
                        Color.primary.opacity(0.08 * extensionProgress), in: RoundedRectangle(cornerRadius: 6)
                    )
            }.buttonStyle(LoafButtonStyle()).accessibilityLabel("extensions").accessibilityValue(
                store.extensionsVisible ? "expanded" : "collapsed"
            )
            .help(store.extensionsVisible ? "hide extensions (⌥⌘E)" : "show extensions (⌥⌘E)")
            .contextMenu { Button("manage extensions…") { store.showPage(.extensions) } }
        }.padding(.horizontal, 4).padding(.bottom, 4).padding(.top, 4)
    }
}

struct SidebarMediaPlayers: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var collection: SidebarMediaCollection
    var body: some View {
        let profileID = store.selectedProfileID
        let runtimeTabs = store.application.runtimes[profileID]?.tabs ?? [:]
        let tabs =
            collection.tabIDs.isEmpty
            ? []
            : (store.workspaces[profileID]?.tabs ?? []).compactMap { saved -> BrowserTab? in
                guard collection.tabIDs.contains(saved.id), let tab = runtimeTabs[saved.id], !tab.isDisposed else {
                    return nil
                }
                return tab
            }
        ForEach(tabs) { tab in TabMediaPlayers(tab: tab, store: store) }
    }
}

struct TabMediaPlayers: View {
    @ObservedObject var tab: BrowserTab
    let store: BrowserStore
    var body: some View {
        ForEach(tab.visibleMedia) { source in
            MediaMiniPlayer(
                tab: tab, source: source, store: store,
                initiallyExpanded: Bundle.main.bundleIdentifier == MarketingLaunch.bundleIdentifier)
        }
    }
}
func profileTint(_ index: Int) -> Color {
    if index == ProfileColor.systemAccentIndex { return Color(nsColor: .controlAccentColor) }
    return [
        Color(red: 241 / 255, green: 214 / 255, blue: 145 / 255), Color(red: 0.92, green: 0.66, blue: 0.2),
        Color(red: 0.59, green: 0.69, blue: 0.91), Color(red: 0.87, green: 0.54, blue: 0.59),
        Color(red: 0.43, green: 0.75, blue: 0.62), Color(red: 0.66, green: 0.58, blue: 0.84),
    ][((index % 6) + 6) % 6]
}

struct AddressLabel: View {
    let url: URL?
    var fallback = ""
    var palette: ChromePalette?
    var pageTitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var label: Text {
        let palette = palette ?? ChromePalette(dark: colorScheme == .dark)
        if let query = BrowserAddress.defaultSearchQuery(url) { return Text(query).foregroundColor(palette.primary) }
        guard let url, let host = url.host else { return Text(fallback).foregroundColor(palette.secondary) }
        let domain = PublicSuffixList.shared.registrableDomain(host)
        let prefix = host.hasSuffix(domain) ? String(host.dropLast(domain.count)) : ""
        let port = url.port.map { ":\($0)" } ?? ""
        let path = pageTitle == nil ? (url.path == "/" ? "" : url.path) : CollapsedAddress.directoryPath(url)
        let query = pageTitle == nil ? url.query.map { "?" + $0 } ?? "" : ""
        let fragment = pageTitle == nil ? url.fragment.map { "#" + $0 } ?? "" : ""
        let title = pageTitle.map { CollapsedAddress.titleSuffix($0) } ?? ""
        let scheme = ["https", "http"].contains(url.scheme) ? "" : (url.scheme ?? "loaf") + "://"
        return Text(
            "\(Text(scheme + prefix).foregroundColor(palette.secondary))\(Text(domain).foregroundColor(palette.primary))\(Text(port + path + query + fragment).foregroundColor(palette.secondary))\(Text(title).foregroundColor(palette.primary))"
        )
    }
    var body: some View {
        GeometryReader { proxy in
            label.fixedSize(horizontal: true, vertical: false).frame(height: proxy.size.height).frame(
                maxWidth: .infinity, alignment: .leading)
        }
        .clipped().mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0), .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
    }
}

enum CollapsedAddress {
    static func directoryPath(_ url: URL) -> String {
        let path = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
        return path == "/" ? "" : path
    }
    static func titleSuffix(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : " — " + value
    }
}
struct TabListContent: View {
    private struct MountedRow: Identifiable {
        let entry: SidebarEntry
        let index: Int
        let gap: CGFloat
        var id: UUID { entry.id }
    }
    @ObservedObject var store: BrowserStore
    @Binding var position: TabDropPosition?
    var visibleRange: Range<Int>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let entries = store.sidebarEntries
        let layout = store.sidebarInsertionLayout
        let first = min(entries.count, max(0, visibleRange?.lowerBound ?? 0))
        let last = min(entries.count, max(first, visibleRange?.upperBound ?? entries.count))

        let retained = Set([store.draggedTabID, store.draggedFolderID, store.editingGroupID].compactMap { $0 })
        let indices =
            retained.isEmpty
            ? Array(first..<last)
            : entries.indices.filter { (first..<last).contains($0) || retained.contains(entries[$0].id) }
        let mounted = indices.enumerated().map { local, index in
            MountedRow(
                entry: entries[index], index: index,
                gap: layout.offset(at: index) - layout.offset(at: local > 0 ? indices[local - 1] + 1 : 0))
        }
        let slot = layout.slot(for: position)
        VStack(spacing: 0) {
            ForEach(mounted) { row in
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(0, row.gap)).allowsHitTesting(false)
                    Group {
                        switch row.entry {
                        case .tab(let tab):
                            if let split = store.browserSplit, split.left == tab.id,
                                let right = store.tabs.first(where: { $0.id == split.right })
                            {
                                SplitTabRow(store: store, left: tab, right: right).padding(
                                    .leading, tab.groupID == nil ? 0 : 12)
                            } else {
                                TabRow(tab: tab, store: store).padding(.leading, tab.groupID == nil ? 0 : 12).opacity(
                                    store.draggedTabID == tab.id ? 0.5 : 1)
                            }
                        case .group(let group): TabGroupRow(group: group, store: store)
                        case .newTab:
                            Button {
                                _ = store.newTab()
                            } label: {
                                SidebarNewTabLabel(pinTarget: store.draggedTabID != nil)
                            }.buttonStyle(LoafButtonStyle())
                                .overlay { PinDropZone(store: store, row: true) }
                        }
                    }.offset(y: slot.map { row.index >= $0 ? SidebarTabMetrics.insertionGap : 0 } ?? 0)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: store.preferences.newTabsAtTop != false ? .top : .bottom)
                                        .combined(with: .opacity), removal: .identity)
                        )
                        .padding(.bottom, row.index < entries.count - 1 ? SidebarTabMetrics.spacing : 0)
                }
            }
            Color.clear.frame(height: max(0, layout.height - layout.offset(at: (indices.last ?? -1) + 1)))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if let slot {
                Capsule().fill(profileTint(store.profile)).frame(height: 2).padding(
                    .leading, store.draggedFolderID == nil && store.draggedGroupTargetID != nil ? 20 : 4
                ).padding(.trailing, 4)
                    .offset(y: layout.offset(at: slot) + 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, SidebarTabMetrics.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { store.clearSidebarSelection() }
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: slot)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: entries.map(\.id))
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: Bool { store.profile.selectedTab == tab.id || store.selectedSidebarTabIDs.contains(tab.id) }
    private var hasStatus: Bool { tab.loading || tab.media.contains(where: { !$0.paused }) }
    private var accessoriesVisible: Bool { hovered }
    private var accessoryWidth: CGFloat {
        (hasStatus ? 12 : 0)
            + (accessoriesVisible ? (store.isPersistentTab(tab) && !tab.pinned ? 46 : 20) + (hasStatus ? 8 : 0) : 0)
    }
    private var closeControl: some View {
        ZStack {
            if store.isOpenTab(tab) {
                Button {
                    store.closeFromPointer(tab)
                } label: {
                    GolzheimIcon(icon: .close, size: 16, weight: 180).foregroundStyle(.secondary).frame(
                        width: 20, height: 20)
                }
                .buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel("close \(tab.title)")
            } else {

                Color.clear.contentShape(Rectangle()).onTapGesture {}.accessibilityHidden(true)
            }
        }.frame(width: 20, height: 20)
    }
    var body: some View {
        HStack(spacing: 4) {
            Button {
                store.selectSidebarTab(tab, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            } label: {
                HStack(spacing: 4) {
                    EditableTabIcon(tab: tab, store: store, size: 16)
                    FadingTitle(text: BrowserAddress.visible(tab.sidebarTitle)).frame(height: 32)
                }.padding(.leading, 8).padding(.trailing, accessoryWidth + 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHidden(true)
                .opacity(pressed ? 0.65 : 1)
                .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
                .overlay {
                    TabDragArea(tab: tab, store: store, title: tab.sidebarTitle, selected: selected, pressed: $pressed)
                        .padding(.trailing, accessoriesVisible && store.isPersistentTab(tab) && !tab.pinned ? 54 : 28)
                }
        }.padding(.trailing, 4).frame(height: 32)
            .overlay(alignment: .trailing) {
                HStack(spacing: 8) {
                    if tab.loading {
                        ChromeLoadingIndicator().frame(width: 12, height: 20)
                    } else if tab.media.contains(where: { !$0.paused }) {
                        Button {
                            store.toggleMute(tab)
                        } label: {
                            GolzheimIcon(icon: tab.media.allSatisfy(\.muted) ? .muted : .volume, size: 12)
                                .foregroundStyle(.secondary).frame(width: 20, height: 20)
                        }.buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel(
                            tab.media.allSatisfy(\.muted) ? "unmute tab" : "mute tab")
                    }
                    if tab.sleeping {
                        GolzheimIcon(icon: .sleep, size: 12).foregroundStyle(.secondary).accessibilityLabel(
                            "sleeping tab")
                    }
                    if accessoriesVisible {
                        HStack(spacing: 6) {
                            if store.isPersistentTab(tab) {
                                Button {
                                    store.removePersistentTab(tab)
                                } label: {
                                    GolzheimIcon(icon: .trash, size: 14).foregroundStyle(.secondary).frame(
                                        width: 20, height: 20)
                                }.buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel(
                                    "unpin \(tab.sidebarTitle)"
                                ).help("remove shortcut").transition(.opacity)
                            }
                            if !tab.pinned {
                                closeControl.transition(.opacity)
                            }
                        }
                    }
                }.padding(.trailing, 8).animation(
                    reduceMotion ? nil : .smooth(duration: 0.16), value: accessoriesVisible)
            }
            .modifier(SidebarRowChrome(selected: selected, hovered: hovered))
            .onHover { hovered = $0 }
            .background(TabHoverAnchor(tab: tab, store: store))
            .background(TabClosingAnchor(tabID: tab.id))
            .contextMenu { TabActions(tab: tab, store: store) }
    }
}

private struct ExtensionReorderDrop: DropDelegate {
    let store: BrowserStore
    let target: UUID
    @Binding var dragged: UUID?
    @Binding var order: [UUID]
    func validateDrop(info: DropInfo) -> Bool { dragged != nil }
    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target, let from = order.firstIndex(of: dragged),
            let to = order.firstIndex(of: target)
        else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.16)) {
            let source = order.remove(at: from)
            order.insert(source, at: min(to, order.count))
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard dragged != nil else { return false }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        store.updateCurrent { profile in
            let enabled = profile.extensions.filter(\.enabled).sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
            profile.extensions = enabled + profile.extensions.filter { !$0.enabled }
        }
        dragged = nil
        order = []
        return true
    }
}

private struct ExtensionDragArea: NSViewRepresentable {
    let record: InstalledExtension
    let store: BrowserStore
    let began: () -> Void
    let ended: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.record = record
        view.store = store
        view.began = began
        view.ended = ended
    }
    final class DragView: NSView, NSDraggingSource {
        var record: InstalledExtension?
        weak var store: BrowserStore?
        var began: (() -> Void)?
        var ended: (() -> Void)?
        private var origin: NSPoint?
        private var dragging = false
        override func hitTest(_ point: NSPoint) -> NSView? {
            if NSApp.currentEvent?.type == .rightMouseDown
                || NSApp.currentEvent?.modifierFlags.contains(.control) == true
            {
                return nil
            }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
            dragging = false
        }
        override func mouseUp(with event: NSEvent) {
            defer { origin = nil }
            if !dragging, bounds.contains(convert(event.locationInWindow, from: nil)), let record {
                store?.runtime.extensions.perform(record)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let origin, let record,
                hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4
            else { return }
            let writer = NSPasteboardItem()
            writer.setString("loaf-extension:" + record.id.uuidString, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image =
                store?.runtime.extensions.contexts[record.id]?.webExtension.icon(for: CGSize(width: 24, height: 24))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 24, height: 24))
            let point = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), contents: image)
            dragging = true
            began?()
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        { context == .withinApplication ? .move : [] }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            origin = nil
            ended?()
        }
    }
}

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
    @State private var traySettleTask: Task<Void, Never>?
    @State private var extensionProgress: CGFloat = 0
    @State private var extensionTask: Task<Void, Never>?
    @State private var drop: TabDropPosition?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 40)
                HStack(spacing: 0) {
                    IconButton(icon: .back, label: "back (⌘[)") { store.selectedTab?.webView.goBack() }.disabled(
                        !(store.selectedTab?.canGoBack ?? false))
                    IconButton(icon: .forward, label: "forward (⌘])") { store.selectedTab?.webView.goForward() }
                        .disabled(!(store.selectedTab?.canGoForward ?? false))
                    IconButton(icon: store.selectedTab?.loading == true ? .close : .reload, label: "reload (⌘R)") {
                        if store.selectedTab?.loading == true {
                            store.selectedTab?.webView.stopLoading()
                        } else {
                            store.selectedTab?.reload()
                        }
                    }
                }.offset(y: store.chromeControlsCenterY - 20 - (floating ? 3 : 0))
            }.padding(.trailing, 8).frame(height: 40)
                .overlay(alignment: .topLeading) {
                    if store.usesSidebarOnlyChrome {
                        SidebarWindowControls(floating: floating, tint: NSColor(profileTint(store.profile))).frame(
                            width: 76, height: 32)
                    }
                }
            address.padding(.horizontal, 8)
            if !store.gridPinnedTabs.isEmpty || store.draggedTabID != nil {
                Color.clear.frame(
                    height: PinGridLayout.height(
                        for: max(
                            store.draggedTabID != nil ? 1 : 0,
                            store.gridPinnedTabs.count
                                + (store.pinDropPreview?.row == false
                                    && !store.gridPinnedTabs.contains { $0.id == store.draggedTabID } ? 1 : 0)),
                        list: store.preferences.pinnedLayout == "list")
                )
                .overlay(PinnedTabGrid(store: store)).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                .overlay { PinDropZone(store: store).padding(.horizontal, 8) }
            }
            TabListView(store: store, position: $drop).offset(x: store.profileResistance)
            VStack(spacing: 8) {
                SidebarMediaPlayers(store: store, collection: store.sidebarMedia)
                if !store.preferences.weatherCity.isEmpty && store.profile.personalization?.sidebarWeather != false {
                    weather
                }

            }.padding(.horizontal, 8).padding(.bottom, 8)
            tray

        }
        .animation(nil, value: store.extensionsVisible)
        .animation(nil, value: extensionProgress)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2), value: store.profile.personalization?.compactSidebarWeather
        )
        .background {
            if floating {
                ProfileWindowSurface(
                    color: chromeBase, transparency: store.profile.personalization?.windowTransparency ?? 0
                )
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.selectedProfileID)
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
            traySection = nil
            trayProgress = 0
        }
        .onAppear { extensionProgress = store.extensionsVisible ? 1 : 0 }
        .onChange(of: store.extensionsVisible) { _, open in animateExtensions(open) }
        .onDisappear {
            cancelRebound()
            extensionTask?.cancel()
        }
        .onChange(of: store.draggedTabID) { _, value in if value == nil { drop = nil } }
        .onChange(of: store.draggedFolderID) { _, value in if value == nil { drop = nil } }
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
                    Text(store.weather.city.isEmpty ? store.preferences.weatherCity : store.weather.city).font(
                        .system(size: 12)
                    ).lineLimit(1)
                    if store.profile.personalization?.compactSidebarWeather != true {
                        Text(store.weather.condition.isEmpty ? "weather unavailable" : store.weather.condition).font(
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
        store.profile.privateMode
            ? PrivateChrome.base
            : ProfileColor.surfaceColor(
                profileTint(store.profile), strength: store.profile.personalization?.tintStrength ?? 0.06,
                dark: scheme == .dark)
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
    private var tray: some View {
        VStack(spacing: 0) {
            SidebarTrayContent(
                store: store, section: Binding(get: { traySection ?? .downloads }, set: { traySection = $0 })
            ) { setTray(nil) }
            .frame(height: TrayMetrics.contentHeight).opacity(min(1, max(0, trayProgress)))
            .frame(height: max(0, TrayMetrics.contentHeight * trayProgress), alignment: .top).clipped()
            .allowsHitTesting(trayProgress > 0.95).accessibilityHidden(trayProgress < 0.95)
            extensionStrip.opacity(extensionProgress)
                .offset(y: 6 * (1 - extensionProgress))
                .frame(height: extensionStripHeight * extensionProgress, alignment: .top).clipped()
                .allowsHitTesting(store.extensionsVisible).accessibilityHidden(!store.extensionsVisible)
            SoftwareUpdateReminder().padding(.horizontal, 8)
            footer.zIndex(1)
        }
        .background {
            ProfileWindowSurface(
                color: chromeBase, transparency: store.profile.personalization?.windowTransparency ?? 0
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
    private var extensionColumns: Int { max(1, Int((store.preferences.sidebarWidth - 48) / 30)) }
    private var extensionStripHeight: CGFloat {
        let count = store.profile.extensions.filter(\.enabled).count + 1
        return CGFloat(min(5, max(1, (count + extensionColumns - 1) / extensionColumns))) * 32 + 4
    }
    private var extensionStrip: some View {
        let enabled = store.profile.extensions.filter(\.enabled)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: extensionColumns), spacing: 4)
            {
                ForEach(enabled) { record in
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
                }
                Button {
                    store.showPage(.extensions)
                } label: {
                    GolzheimIcon(icon: .settings, size: 14).frame(maxWidth: .infinity).frame(height: 28)
                }.buttonStyle(LoafButtonStyle()).help("manage extensions").accessibilityLabel("manage extensions")
            }.padding(4)
        }.scrollIndicators(.hidden).frame(height: extensionStripHeight)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("extension tray")
    }
    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                setTray(trayProgress > 0.5 ? nil : .downloads)
            } label: {
                GolzheimIcon(icon: .tray, size: 16, weight: 100).frame(width: 32, height: 32)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(trayProgress * 0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(trayProgress == 0 ? "open tray" : "close tray").accessibilityLabel(
                trayProgress == 0 ? "open tray" : "close tray")
            Spacer(minLength: 4)
            Button {
                profilePicker.toggle()
            } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        EmojiIcon(glyph: store.profile.emoji, size: 14)
                        Text(store.profile.name).font(.system(size: 13)).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        ForEach(store.profiles) { p in
                            Capsule().fill(store.profile.privateMode ? PrivateChrome.accent : profileTint(p)).frame(
                                width: p.id == store.selectedProfileID ? 20 : 8, height: 2
                            ).opacity(p.id == store.selectedProfileID ? 1 : 0.35)
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.selectedProfileID)
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
                                    EmojiIcon(glyph: profile.emoji, size: 20)
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
                store.extensionsVisible.toggle()
            } label: {
                GolzheimIcon(icon: .extensionPuzzle, size: 16).frame(width: 26, height: 26)
                    .background(
                        Color.primary.opacity(0.08 * extensionProgress), in: RoundedRectangle(cornerRadius: 6)
                    )
            }.buttonStyle(LoafButtonStyle()).accessibilityLabel("extensions").accessibilityValue(
                store.extensionsVisible ? "expanded" : "collapsed"
            )
            .help(store.extensionsVisible ? "hide extensions" : "show extensions")
            .contextMenu { Button("manage extensions…") { store.showPage(.extensions) } }
        }.padding(.horizontal, 8).padding(.bottom, 4).padding(.top, 4)
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
    [
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
        let layout = TabInsertionLayout(
            rows: entries.map { .init(id: $0.id, pinned: $0.tab == nil, height: $0.height) })
        let first = min(entries.count, max(0, visibleRange?.lowerBound ?? 0))
        let last = min(entries.count, max(first, visibleRange?.upperBound ?? entries.count))

        let retained = Set([store.draggedTabID, store.draggedFolderID, store.editingGroupID].compactMap { $0 })
        let indices = entries.indices.filter { (first..<last).contains($0) || retained.contains(entries[$0].id) }
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
                                HStack(spacing: 4) {
                                    GolzheimIcon(
                                        icon: store.draggedTabID == nil ? .plus : .favorite, size: 12, weight: 220
                                    )
                                    .frame(width: 16, height: 16)
                                    Text(store.draggedTabID == nil ? "new tab" : "pin as tab")
                                    Spacer()
                                    if store.draggedTabID == nil {
                                        Text("⌘T").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }
                                .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 32).background(
                                    Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(LoafButtonStyle()).padding(.top, 8).padding(.bottom, 4)
                                .overlay { PinDropZone(store: store, row: true) }
                        }
                    }.offset(y: slot.map { row.index >= $0 ? SidebarTabMetrics.insertionGap : 0 } ?? 0)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .identity))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: slot)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: entries.map(\.id))
        .id(store.selectedProfileID)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .offset(x: CGFloat(store.profileDirection) * 18).combined(with: .opacity),
                    removal: .offset(x: CGFloat(store.profileDirection) * -8).combined(with: .opacity))
        )
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: store.selectedProfileID)
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
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        selected ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(hovered ? 0.06 : 0.025)
                    )
                    .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 3, y: 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(selected ? 0.08 : 0.035))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
            }
            .onHover { hovered = $0 }
            .background(TabHoverAnchor(tab: tab, store: store))
            .background(TabClosingAnchor(tabID: tab.id))
            .contextMenu { TabActions(tab: tab, store: store) }
    }
}

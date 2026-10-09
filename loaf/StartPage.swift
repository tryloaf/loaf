import SwiftUI
import UniformTypeIdentifiers

struct StartPage: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var appearance = false
    @State private var gallery = false
    @State private var dragged: String?
    @State private var dropPosition: StartWidgetPosition?
    @State private var resizeSizes: [String: StartWidgetSize] = [:]
    @State private var backgroundImage: (url: URL, image: NSImage)?
    init(store: BrowserStore, editing: Bool = false) {
        self.store = store
        _editing = State(initialValue: editing)
    }
    private var backgroundURL: URL? {
        guard preferences.background.hasPrefix("image:") else { return nil }
        let name = String(preferences.background.dropFirst(6))
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".",
            name != ".."
        else { return nil }
        return store.directory.appendingPathComponent("Backgrounds").appendingPathComponent(name)
    }
    private var preferences: Personalization { store.profile.personalization ?? Personalization() }
    private var widgets: [String] { preferences.visibleStartWidgets }
    private func update(_ edit: (inout Personalization) -> Void) {
        store.updateCurrent { profile in
            var value = profile.personalization ?? Personalization()
            edit(&value)
            profile.personalization = value
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = min(760, max(0, geometry.size.width - 64))
            let liveSizes = (preferences.widgetSizes ?? [:]).merging(resizeSizes) { _, preview in preview }
            let baseLayout = StartWidgetLayout(
                widgets: widgets, sizes: liveSizes, positions: preferences.widgetPositions ?? [:], width: width)
            let livePositions = previewPositions(base: baseLayout.positions)
            let layout = StartWidgetLayout(
                widgets: widgets, sizes: liveSizes, positions: livePositions ?? preferences.widgetPositions ?? [:],
                width: width)
            let gridHeight = layout.height + (editing ? layout.gridStride.height * 2 : 0)
            ZStack {
                background.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 8) {
                            EmojiIcon(glyph: store.profile.emoji, size: 16)
                            Text(
                                store.profile.privateMode && store.profile.name == "private"
                                    ? "private browsing" : store.profile.name
                            ).font(.system(size: 13))
                            if store.profile.privateMode && store.profile.name != "private" {
                                Text("private").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if editing {
                                Button {
                                    gallery = true
                                } label: {
                                    Label {
                                        Text("add widget")
                                    } icon: {
                                        GolzheimIcon(icon: .plus, size: 12)
                                    }
                                }
                                .popover(isPresented: $gallery) { StartWidgetGallery(store: store) }
                                Button {
                                    appearance = true
                                } label: {
                                    GolzheimIcon(icon: .settings, size: 16)
                                }.help("start-page appearance")
                                    .popover(isPresented: $appearance) { StartCustomizer(store: store) }
                                Button("tidy widgets") { update { $0.widgetPositions = nil } }.disabled(
                                    preferences.widgetPositions?.isEmpty != false)
                            }
                            Button {
                                withAnimation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0)) {
                                    editing.toggle()
                                    dragged = nil
                                    dropPosition = nil
                                    resizeSizes = [:]
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    GolzheimIcon(icon: editing ? .check : .settings, size: 14)
                                    Text(editing ? "done" : "edit")
                                }.font(.system(size: 12))
                            }.help(editing ? "finish editing widgets" : "customize start page").accessibilityLabel(
                                editing ? "finish editing widgets" : "customize start page")
                        }.buttonStyle(.bordered).controlSize(.small)
                        Button {
                            store.openOmnibar(query: "")
                        } label: {
                            HStack(spacing: 12) {
                                GolzheimIcon(icon: .search, size: 20)
                                Text("search or surf...")
                                Spacer()
                                Text("⌘L").font(.system(size: 12)).foregroundStyle(.secondary)
                            }.font(.system(size: 16)).padding(16)
                                .background(
                                    Color(nsColor: .textBackgroundColor).opacity(0.72),
                                    in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(LoafButtonStyle())
                        if widgets.isEmpty {
                            VStack(spacing: 12) {
                                GolzheimIcon(icon: .plus, size: 28).foregroundStyle(.secondary)
                                Text("no widgets").font(.system(size: 14))
                                Button("add a widget") {
                                    editing = true
                                    gallery = true
                                }
                            }.frame(maxWidth: .infinity).padding(40)
                        }
                        StartWidgetGrid(layout: layout, width: width) { placement in
                            StartWidgetCard(
                                store: store, id: placement.id, editing: editing, columns: layout.columns,
                                columnWidth: layout.columnWidth, dragged: $dragged, resizeSizes: $resizeSizes
                            ) {
                                widgetView(placement.id)
                            }.environment(\.startWidgetDropCleanup, { dropPosition = nil }).frame(
                                width: placement.frame.width, height: placement.frame.height
                            )
                            .overlay {
                                if dragged == placement.id, dropPosition != nil {
                                    RoundedRectangle(cornerRadius: 16).strokeBorder(
                                        Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                                    ).allowsHitTesting(false)
                                }
                            }
                        }
                        .frame(height: gridHeight, alignment: .topLeading)
                        .background(StartWidgetGridBounds(windowID: store.id))
                        .background {
                            if editing {
                                StartWidgetPlacementGrid(layout: layout, height: gridHeight).allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                        .onDrop(
                            of: BrowserDragTypes.accepted(.loafWidget),
                            delegate: StartWidgetDropDelegate(
                                store: store, editing: editing, layout: baseLayout, positions: baseLayout.positions,
                                position: $dropPosition, dragged: $dragged)
                        )
                        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0), value: widgets)
                        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0), value: liveSizes)
                        .animation(
                            reduceMotion ? nil : .spring(duration: 0.18, bounce: 0),
                            value: livePositions ?? preferences.widgetPositions ?? [:])
                        if editing {
                            Text("drag to move · drag a corner to resize · drag outside the grid to remove").font(
                                .system(size: 11)
                            ).foregroundStyle(.secondary)
                        }
                        if store.profile.privateMode {
                            Text("history stays off. cookies disappear when this private session ends.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.frame(width: width).padding(.horizontal, 32).padding(.top, store.sidebarPresented ? 40 : 24)
                        .padding(.bottom, 32).frame(maxWidth: .infinity)
                }
            }.clipped()
        }.environment(
            \.colorScheme,
            preferences.background == "profile" && !store.profile.privateMode
                ? ProfileColor.surfaceScheme(
                    profileTint(store.profile), strength: preferences.tintStrength, dark: scheme == .dark) : scheme
        )
        .onChange(of: dragged) { _, value in
            if value == nil { dropPosition = nil }
        }
        .task(id: backgroundURL) {
            backgroundImage = nil
            guard let url = backgroundURL else { return }
            let image = await StartBackgroundCache.shared.image(for: url)
            if !Task.isCancelled, url == backgroundURL, let image { backgroundImage = (url, image) }
        }.onChange(of: store.selectedProfileID) { _, _ in
            editing = false
            gallery = false
            appearance = false
            dragged = nil
            dropPosition = nil
            resizeSizes = [:]
        }
    }
    private func previewPositions(base: [String: StartWidgetPosition]) -> [String: StartWidgetPosition]? {
        guard let dragged, let dropPosition else { return nil }
        var preview = preferences
        preview.placeWidget(dragged, at: dropPosition, currentPositions: base)
        return preview.widgetPositions
    }
    private var background: some View {
        Group {
            if store.profile.privateMode {
                LinearGradient(
                    colors: [PrivateChrome.surface, PrivateChrome.base], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            } else if let backgroundImage, backgroundImage.url == backgroundURL {
                Image(nsImage: backgroundImage.image).resizable().scaledToFill().overlay(
                    Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.35 : 0.15))
            } else {
                let tint =
                    preferences.background == "profile"
                    ? profileTint(store.profile) : Color(nsColor: .windowBackgroundColor)
                let strength =
                    preferences.background == "profile"
                    ? ProfileColor.surfaceOpacity(preferences.tintStrength) : (scheme == .dark ? 0.32 : 1)
                LinearGradient(
                    colors: [
                        tint.opacity(strength * (preferences.background == "profile" ? 0.94 : 0.65)),
                        tint.opacity(strength),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing
                ).background(
                    preferences.background == "profile"
                        ? Color(white: scheme == .dark ? 0.15 : 0.88) : Color(nsColor: .windowBackgroundColor))
            }
        }.clipped().opacity(
            ProfileTransparency.opacity(preferences.windowTransparency ?? 0, reduceTransparency: reduceTransparency)
        )
        .background {
            if !reduceTransparency && ProfileTransparency.bounded(preferences.windowTransparency ?? 0) > 0 {
                WindowBackdrop()
            }
        }
    }
    @ViewBuilder private func widgetView(_ widget: String) -> some View {
        let options = preferences.widgetOptions?[widget] ?? StartWidgetOptions()
        let compact = preferences.widgetSizes?[widget] == .square
        switch widget {
        case "clock":
            TimelineView(.periodic(from: .now, by: options.clockSeconds == true ? 1 : 30)) { time in
                VStack(alignment: .leading, spacing: 8) {
                    Text(clockText(time.date, options: options)).textCase(.lowercase).font(
                        .system(size: compact || options.clockSeconds == true ? 32 : 40, weight: .light)
                    ).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Text(time.date, format: .dateTime.weekday(.wide).month(.wide).day()).textCase(.lowercase).font(
                        .system(size: 13)
                    ).foregroundStyle(.secondary)
                }
            }
        case "battery": BatteryWidget(monitor: store.application.resources)
        case "browsingTime": BrowsingTimeWidget(store: store, monitor: store.application.resources)
        case "calendar": StartWeekView(compact: preferences.widgetSizes?["calendar"] == .square)
        case "checklist":
            StartChecklistWidget(store: store, options: options, showsHeader: !editing).id(store.selectedProfileID)
        case "worldClock": StartWorldClockWidget(options: options, showsHeader: !editing)
        case "weather":
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack(spacing: compact ? 8 : 12) {
                    GolzheimIcon(icon: store.weather.icon, size: compact ? 32 : 40)
                    Text(store.weather.temperature.map { "\($0)°" } ?? "—").font(
                        .system(size: compact ? 32 : 40, weight: .light))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.weather.city.isEmpty ? "select a city" : store.weather.city).font(.system(size: 13))
                        .lineLimit(store.weather.city.isEmpty && !compact ? 3 : 1).fixedSize(
                            horizontal: false, vertical: true)
                    Text(store.weather.condition).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !compact && !store.weather.hours.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(store.weather.hours) { hour in
                            VStack(spacing: 3) {
                                Text(hour.date, format: .dateTime.hour())
                                Text("\(hour.temperature)°").fontWeight(.medium)
                            }.font(.system(size: 10)).accessibilityElement(children: .combine)
                        }
                    }
                }
                if store.profile.privateMode {
                    Button {
                        NSWorkspace.shared.open(store.weather.attributionURL)
                    } label: {
                        Text(store.weather.attribution).font(.system(size: 10)).foregroundStyle(PrivateChrome.accent)
                    }.buttonStyle(.plain)
                } else {
                    Link(destination: store.weather.attributionURL) {
                        if let mark = scheme == .dark
                            ? store.weather.attributionMarkDark : store.weather.attributionMarkLight
                        {
                            Image(nsImage: mark).resizable().scaledToFit().frame(height: 16)
                        } else {
                            Text(store.weather.attribution).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .modifier(WeatherRefresh(store: store))
        case "notes":
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader(.book, "notes")
                TextEditor(
                    text: Binding(
                        get: { preferences.notes }, set: { value in update { $0.notes = String(value.prefix(10000)) } })
                ).font(.system(size: options.largerNotes == true ? 16 : 13)).scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden).frame(minHeight: 40).accessibilityLabel("local notes")
            }.frame(maxHeight: .infinity)
        case "recent":
            VStack(alignment: .leading, spacing: 12) {
                widgetHeader(.history, "recent tabs")
                ForEach(store.tabs.filter { $0.url != nil }.suffix(options.limit).reversed()) { tab in
                    Button {
                        store.select(tab)
                    } label: {
                        HStack(spacing: 8) {
                            SiteIcon(tab: tab, size: 16)
                            Text(BrowserAddress.visible(tab.sidebarTitle)).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                        }
                    }.buttonStyle(LoafButtonStyle())
                }
                if store.tabs.allSatisfy({ $0.url == nil }) {
                    Text("your open pages will appear here").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        case "downloads": StartDownloadsWidget(store: store, limit: options.limit)
        default:
            VStack(alignment: .leading, spacing: 12) {
                widgetHeader(.favorite, "favorites")
                if store.profile.favorites.isEmpty {
                    Text("save a favorite with ⌘D to keep it here").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if preferences.pinStyle == "tiles" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 12) {
                        ForEach(
                            Array(
                                store.profile.favorites.filter { $0.folderID == nil }.prefix(
                                    options.itemLimit == nil ? store.profile.favorites.count : options.limit))
                        ) { favorite in favoriteButton(favorite, style: "tiles") }
                    }
                } else if preferences.pinStyle == "chips" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112))], spacing: 8) {
                        ForEach(
                            Array(
                                store.profile.favorites.filter { $0.folderID == nil }.prefix(
                                    options.itemLimit == nil ? store.profile.favorites.count : options.limit))
                        ) { favorite in favoriteButton(favorite, style: "chips") }
                    }
                } else {
                    ForEach(
                        Array(
                            store.profile.favorites.filter { $0.folderID == nil }.prefix(
                                options.itemLimit == nil ? store.profile.favorites.count : options.limit))
                    ) { favorite in favoriteButton(favorite, style: "list") }
                }
            }
        }
    }
    private func clockText(_ date: Date, options: StartWidgetOptions) -> String {
        var style = Date.FormatStyle.dateTime.hour(
            options.clock24Hour == true ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)
        ).minute()
        if options.clock24Hour == true { style = style.locale(Locale(identifier: "en_GB")) }
        if options.clockSeconds == true { style = style.second() }
        return date.formatted(style)
    }
    @ViewBuilder private func widgetHeader(_ icon: LoafIcon, _ name: String) -> some View {
        if !editing {
            HStack(spacing: 8) {
                GolzheimIcon(icon: icon, size: 16)
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
    private func favoriteButton(_ favorite: Favorite, style: String) -> some View {
        Button {
            store.navigate(favorite.address)
        } label: {
            Group {
                if style == "tiles" {
                    VStack(spacing: 8) {
                        FavoriteIcon(favorite: favorite, store: store).frame(width: 48, height: 48).background(
                            Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        Text(BrowserAddress.visible(favorite.title)).font(.system(size: 11)).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 8) {
                        FavoriteIcon(favorite: favorite, store: store).frame(width: 20, height: 20)
                        Text(BrowserAddress.visible(favorite.title)).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(style == "chips" ? 8 : 0).background(
                        Color.primary.opacity(style == "chips" ? 0.04 : 0), in: Capsule())
                }
            }
        }.buttonStyle(LoafButtonStyle()).help(BrowserAddress.visible(favorite.address))
    }
}

struct StartWidgetPlacementGrid: View {
    let layout: StartWidgetLayout
    let height: CGFloat
    var body: some View {
        Canvas { context, _ in
            let side = StartWidgetSize.squareSide(columnWidth: layout.columnWidth)
            for row in 0..<max(1, Int(ceil(height / layout.gridStride.height))) {
                for column in 0..<layout.gridColumns {
                    let rect = CGRect(
                        x: CGFloat(column) * layout.gridStride.width, y: CGFloat(row) * layout.gridStride.height,
                        width: side, height: max(176, side))
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 16), with: .color(.primary.opacity(0.08)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
            }
        }.accessibilityHidden(true)
    }
}
struct StartWidgetDropDelegate: DropDelegate {
    let store: BrowserStore
    let editing: Bool
    let layout: StartWidgetLayout
    let positions: [String: StartWidgetPosition]
    @Binding var position: StartWidgetPosition?
    @Binding var dragged: String?
    func validateDrop(info: DropInfo) -> Bool {
        editing && dragged != nil && info.hasItemsConforming(to: BrowserDragTypes.accepted(.loafWidget))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard editing, let dragged else { return DropProposal(operation: .forbidden) }
        let size = store.profile.personalization?.widgetSizes?[dragged] ?? .small
        position = layout.position(at: info.location, size: size)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { position = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard editing, let expected = dragged,
            let provider = info.itemProviders(for: BrowserDragTypes.accepted(.loafWidget)).first,
            let type = BrowserDragTypes.accepted(.loafWidget).first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            })
        else { return false }
        let profileID = store.selectedProfileID
        let target = layout.position(
            at: info.location, size: store.profile.personalization?.widgetSizes?[expected] ?? .small)
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            Task { @MainActor in
                defer {
                    position = nil
                    dragged = nil
                }
                guard let data, data.count <= 2048,
                    let payload = try? JSONDecoder().decode(StartWidgetDrag.self, from: data),
                    payload.widget == expected, store.selectedProfileID == profileID,
                    payload.valid(
                        windowID: store.id, profileID: profileID,
                        visibleWidgets: (store.profile.personalization ?? Personalization()).visibleStartWidgets)
                else { return }
                store.updateCurrent { profile in
                    var preferences = profile.personalization ?? Personalization()
                    preferences.placeWidget(payload.widget, at: target, currentPositions: positions)
                    profile.personalization = preferences
                }
                LoafHaptics.perform(enabled: store.preferences.haptics != false)
            }
        }
        return true
    }
}

struct StartWidgetScrollContent<Content: View>: View {
    let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollDisabled(contentHeight <= viewportHeight + 1.5)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
    }
}

struct StartWidgetCard<Content: View>: View {
    @ObservedObject var store: BrowserStore
    let id: String
    let editing: Bool
    let columns: Int
    let columnWidth: CGFloat
    @Binding var dragged: String?
    @Binding var resizeSizes: [String: StartWidgetSize]
    @ViewBuilder let content: () -> Content
    @State private var resizePreview: StartWidgetSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.startWidgetDropCleanup) private var dropCleanup
    private var preferences: Personalization { store.profile.personalization ?? Personalization() }
    private var size: StartWidgetSize { preferences.widgetSizes?[id] ?? .small }
    private func update(_ edit: (inout Personalization) -> Void) {
        store.updateCurrent { profile in
            var value = profile.personalization ?? Personalization()
            edit(&value)
            profile.personalization = value
        }
    }
    private func option<Value>(_ key: WritableKeyPath<StartWidgetOptions, Value>) -> Binding<Value> {
        Binding(
            get: { (preferences.widgetOptions?[id] ?? StartWidgetOptions())[keyPath: key] },
            set: { value in
                update { p in
                    var options = p.widgetOptions?[id] ?? StartWidgetOptions()
                    options[keyPath: key] = value
                    p.widgetOptions = p.widgetOptions ?? [:]
                    p.widgetOptions?[id] = options
                }
            })
    }
    private func movePosition(columns dx: Int, rows dy: Int) {
        let width = CGFloat(columns) * columnWidth + CGFloat(columns - 1) * 16
        let layout = StartWidgetLayout(
            widgets: preferences.visibleStartWidgets, sizes: preferences.widgetSizes ?? [:],
            positions: preferences.widgetPositions ?? [:], width: width)
        guard var position = layout.positions[id] else { return }
        position.column += dx
        position.row += dy
        position = layout.position(
            at: CGPoint(
                x: CGFloat(position.column) * layout.gridStride.width,
                y: CGFloat(position.row) * layout.gridStride.height), size: size)
        update { $0.placeWidget(id, at: position, currentPositions: layout.positions) }
    }
    var body: some View {
        let payloadProfileID = store.selectedProfileID
        return VStack(alignment: .leading, spacing: 12) {
            if editing {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        GolzheimIcon(icon: .more, size: 14).rotationEffect(.degrees(90))
                        Text(StartWidgetKind(rawValue: id)?.title ?? id).font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .overlay {
                        StartWidgetDragHandle(
                            payload: StartWidgetDrag(window: store.id, profile: store.selectedProfileID, widget: id),
                            title: StartWidgetKind(rawValue: id)?.title ?? id, dragged: $dragged, ended: dropCleanup,
                            removed: {
                                let profileID = store.selectedProfileID
                                guard payloadProfileID == profileID else { return }
                                update { if !$0.hiddenWidgets.contains(id) { $0.hiddenWidgets.append(id) } }
                            })
                    }.help("drag to move \(id)")
                    Spacer(minLength: 4)
                    Menu {
                        settings
                        Divider()
                        Button("hide widget") {
                            update { if !$0.hiddenWidgets.contains(id) { $0.hiddenWidgets.append(id) } }
                        }
                    } label: {
                        GolzheimIcon(icon: .settings, size: 14).frame(width: 24, height: 24)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.primary)
                        .accessibilityLabel("\(id) widget settings")
                }
            }
            if id == "notes" {
                content().frame(maxHeight: .infinity)
            } else {
                StartWidgetScrollContent(content: content())
            }
        }.padding(16).padding(.bottom, editing ? 12 : 0)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(editing ? 0.12 : 0.03)))
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    HStack(spacing: 4) {
                        if let preview = resizePreview {
                            Text(preview.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        GolzheimIcon(icon: .expand, size: 12).frame(width: 24, height: 24)
                            .overlay {
                                StartWidgetResizeHandle(
                                    size: size, columnWidth: columnWidth, columns: columns,
                                    preview: { value in
                                        resizePreview = value
                                        resizeSizes[id] = value
                                    },
                                    ended: { value in
                                        if let value, value != size {
                                            update {
                                                $0.widgetSizes = $0.widgetSizes ?? [:]
                                                $0.widgetSizes?[id] = value
                                            }
                                            LoafHaptics.perform(enabled: store.preferences.haptics != false)
                                        }
                                        resizeSizes[id] = nil
                                        resizePreview = nil
                                    })
                            }.help("drag to resize \(id); use widget settings for keyboard controls")
                            .accessibilityLabel("resize \(id) widget")
                    }.padding(4)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipShape(
                RoundedRectangle(cornerRadius: 16)
            ).scaleEffect(dragged == id && !reduceMotion ? 0.985 : 1).animation(
                reduceMotion ? nil : .easeOut(duration: 0.12), value: dragged == id)
    }
    @ViewBuilder private var settings: some View {
        Picker(
            "size",
            selection: Binding(
                get: { size },
                set: { value in
                    update {
                        $0.widgetSizes = $0.widgetSizes ?? [:]
                        $0.widgetSizes?[id] = value
                    }
                })
        ) { ForEach(StartWidgetSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        if id == "clock" {
            Toggle(
                "24-hour time",
                isOn: Binding(
                    get: { preferences.widgetOptions?[id]?.clock24Hour == true },
                    set: { value in option(\.clock24Hour).wrappedValue = value }))
            Toggle(
                "show seconds",
                isOn: Binding(
                    get: { preferences.widgetOptions?[id]?.clockSeconds == true },
                    set: { value in option(\.clockSeconds).wrappedValue = value }))
        }
        if id == "pins" {
            Picker(
                "site style",
                selection: Binding(get: { preferences.pinStyle }, set: { value in update { $0.pinStyle = value } })
            ) {
                Text("tiles").tag("tiles")
                Text("chips").tag("chips")
                Text("list").tag("list")
            }
        }
        if id == "notes" {
            Toggle(
                "larger text",
                isOn: Binding(
                    get: { preferences.widgetOptions?[id]?.largerNotes == true },
                    set: { value in option(\.largerNotes).wrappedValue = value }))
        }
        if id == "checklist" {
            Toggle(
                "hide completed items",
                isOn: Binding(
                    get: { preferences.widgetOptions?[id]?.hideCompleted == true },
                    set: { value in option(\.hideCompleted).wrappedValue = value }))
        }
        if id == "worldClock" {
            StartWorldClockSettings(zones: option(\.timeZones))
            Toggle(
                "24-hour time",
                isOn: Binding(
                    get: { preferences.widgetOptions?[id]?.clock24Hour == true },
                    set: { value in option(\.clock24Hour).wrappedValue = value }))
        }
        if id == "recent" || id == "downloads" || id == "pins" || id == "checklist" {
            Picker(
                "items",
                selection: Binding(
                    get: { (preferences.widgetOptions?[id] ?? StartWidgetOptions()).limit },
                    set: { value in option(\.itemLimit).wrappedValue = value })
            ) { ForEach([2, 4, 8, 12], id: \.self) { Text(String($0)).tag($0) } }
        }
        if id == "weather" {
            Button("weather settings…") { store.application.coordinator?.showSettings(for: store, section: "general") }
        }
        Menu("move") {
            Button("left") { movePosition(columns: -1, rows: 0) }
            Button("right") { movePosition(columns: 1, rows: 0) }
            Button("up") { movePosition(columns: 0, rows: -1) }
            Button("down") { movePosition(columns: 0, rows: 1) }
        }
    }
}

struct StartWidgetGallery: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("add a widget").font(.system(size: 17, weight: .medium))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(StartWidgetKind.allCases) { kind in
                        let added = (store.profile.personalization ?? Personalization()).visibleStartWidgets.contains(
                            kind.rawValue)
                        Button {
                            store.updateCurrent { profile in
                                var preferences = profile.personalization ?? Personalization()
                                preferences.showWidget(kind.rawValue)
                                profile.personalization = preferences
                            }
                        } label: {
                            HStack(spacing: 12) {
                                EmojiIcon(glyph: kind.glyph, size: 28).frame(width: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(kind.title).font(.system(size: 13, weight: .medium))
                                    Text(kind.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                GolzheimIcon(icon: added ? .check : .plus, size: 14)
                            }.padding(12).background(
                                Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).disabled(added).accessibilityLabel(
                            added ? "\(kind.title), already added" : "add \(kind.title)")
                    }
                }
            }.scrollIndicators(.hidden)
        }.padding(20).frame(width: 360, height: 464)
    }
}

struct StartWeekView: View {
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            let start = calendar.dateInterval(of: .weekOfYear, for: context.date)?.start ?? context.date
            VStack(alignment: .leading, spacing: 12) {
                Text(context.date, format: .dateTime.month(.wide).day()).font(
                    .system(size: compact ? 20 : 24, weight: .light)
                ).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: compact ? 2 : 4) {
                    ForEach(0..<7, id: \.self) { offset in
                        let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                        VStack(spacing: 8) {
                            Text(date, format: .dateTime.weekday(.narrow)).font(.system(size: 10)).foregroundStyle(
                                .secondary)
                            Text(date, format: .dateTime.day()).font(.system(size: compact ? 10 : 12)).frame(
                                width: compact ? 16 : 24, height: compact ? 16 : 24
                            ).background(
                                calendar.isDateInToday(date) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
struct StartDownloadsWidget: View {
    @ObservedObject var store: BrowserStore
    let limit: Int
    var body: some View {
        StartDownloadsContent(
            manager: store.downloads, profileID: store.selectedProfileID, limit: limit,
            open: { store.showPage(.downloads) })
    }
}
private struct StartDownloadsContent: View {
    @ObservedObject var manager: DownloadManager
    let profileID: UUID
    let limit: Int
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack {
                    GolzheimIcon(icon: .download, size: 16)
                    Text("downloads").font(.system(size: 12, weight: .medium))
                    Spacer()
                    GolzheimIcon(icon: .forward, size: 12)
                }
            }.buttonStyle(.plain)
            let items = Array(manager.items.filter { $0.profileID == profileID }.prefix(limit))
            if items.isEmpty {
                Text("recent downloads will appear here").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(items) { item in StartDownloadItem(item: item) }
        }
    }
}
private struct StartDownloadItem: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        HStack(spacing: 8) {
            GolzheimIcon(icon: item.finished ? .check : .download, size: 12)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(item.finished ? "saved" : item.error ?? "\(Int(item.fraction * 100))%").font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct FavoriteIcon: View {
    let favorite: Favorite
    let store: BrowserStore
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4)).padding(8)
            } else {
                GolzheimIcon(icon: .favorite, size: 24)
            }
        }
        .task(id: favorite.address) {
            if let url = URL(string: favorite.address) {
                image = await store.application.favicons.image(
                    for: url, privateID: store.profile.privateMode ? store.selectedProfileID : nil)
            }
        }
    }
}
struct StartCustomizer: View {
    @ObservedObject var store: BrowserStore
    private var preferences: Personalization { store.profile.personalization ?? Personalization() }
    private func binding<Value>(_ key: WritableKeyPath<Personalization, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: key] },
            set: { value in
                store.updateCurrent {
                    $0.personalization = $0.personalization ?? Personalization()
                    $0.personalization?[keyPath: key] = value
                }
            })
    }
    var body: some View {
        Form {
            Section("appearance · \(store.profile.name)") {
                Picker("background", selection: binding(\.background)) {
                    Text("profile tint").tag("profile")
                    Text("plain").tag("plain")
                    if preferences.background.hasPrefix("image:") { Text("your image").tag(preferences.background) }
                }
                Button("choose background image…") { chooseImage() }.disabled(store.profile.privateMode)
            }
            Section {
                Button("reset widget layout") {
                    store.updateCurrent {
                        let old = $0.personalization ?? Personalization()
                        $0.personalization = Personalization(
                            customTint: old.customTint, sidebarWeather: old.sidebarWeather,
                            compactSidebarWeather: old.compactSidebarWeather,
                            tintStrength: old.tintStrength, windowTransparency: old.windowTransparency,
                            background: old.background, notes: old.notes)
                    }
                }
                Text("keeps your notes, profile color and background").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 360, height: 280)
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        let profileID = store.selectedProfileID
        store.application.coordinator?.enqueueSheet(for: store, cancel: {}) { done in
            guard let window = store.nativeWindow else {
                done()
                return
            }
            panel.beginSheetModal(for: window) { response in
                defer { done() }
                guard response == .OK, let source = panel.url,
                    store.application.profiles.contains(where: { $0.id == profileID && !$0.privateMode })
                else { return }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: source)
                    guard data.count <= 20_000_000, NSImage(data: data) != nil else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let folder = store.directory.appendingPathComponent("Backgrounds")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = UUID().uuidString + "." + source.pathExtension
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    store.updateProfile(profileID) {
                        $0.personalization = $0.personalization ?? Personalization()
                        $0.personalization?.background = "image:" + name
                    }
                    store.persistSoon()
                } catch { store.error = error.localizedDescription }
            }
        }
    }
}

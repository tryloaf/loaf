import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct LibraryHeader: View {
    let title: String
    let icon: LoafIcon
    var body: some View {
        HStack(spacing: 8) {
            GolzheimIcon(icon: icon, size: 18)
            Text(title).font(.system(size: 18, weight: .medium))
            Spacer()
            WindowDragArea().frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16).frame(height: 40).overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var presentation: HistoryPresentation
    @State private var selection = HistorySelection()
    @State private var clearVisible = false
    @State private var cookieVisible = false
    @State private var cookies: [HTTPCookie] = []
    @FocusState private var listFocused: Bool
    init(store: BrowserStore) {
        self.store = store
        _presentation = StateObject(wrappedValue: HistoryPresentation(store: store))
    }
    var body: some View {
        let ordered = presentation.ordered
        return VStack(spacing: 0) {
            LibraryHeader(title: "history", icon: .history)
            HStack(spacing: 8) {
                TextField("search history…", text: $presentation.query).textFieldStyle(.roundedBorder)
                ZStack {
                    if presentation.isBusy {
                        ProgressView().controlSize(.mini).accessibilityLabel(
                            presentation.isPreparing ? "loading history" : "searching history")
                    }
                }.frame(width: 12, height: 12)
                Button("select all") {
                    guard !presentation.isBusy else { return }
                    selection.all(presentation.ordered)
                    listFocused = true
                }.controlSize(.small).disabled(ordered.isEmpty || presentation.isBusy)
                    .help("select all visits matching this search")
                Button {
                    cookieVisible = true
                } label: {
                    Label {
                        Text("cookies")
                    } icon: {
                        GolzheimIcon(icon: .cookie, size: 12)
                    }
                }.controlSize(.small)
                Button("clear data…") { clearVisible = true }.controlSize(.small)
                if !selection.ids.isEmpty {
                    Button("delete \(selection.ids.count)") { deleteSelection() }.controlSize(.small).disabled(
                        presentation.isBusy)
                }
            }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.vertical, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if ordered.isEmpty {
                        if presentation.isBusy {
                            Text(presentation.isPreparing ? "loading history…" : "searching history…").font(
                                .system(size: 12)
                            ).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 65)
                        } else {
                            emptyLibrary(
                                icon: .history,
                                title: presentation.query.isEmpty ? "nothing here yet" : "no matching visits",
                                detail: presentation.query.isEmpty
                                    ? (store.profile.privateMode
                                        ? "private sessions don’t save browsing history."
                                        : "pages you visit in this profile will appear here.")
                                    : "try another title or address.")
                        }
                    }
                    ForEach(presentation.sections) { section in
                        Text(section.title).font(.system(size: 12, weight: .medium)).padding(.top, 8)
                        ForEach(section.sessions) { session in
                            Text(session.title).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 10)
                                .padding(.bottom, 3)
                            ForEach(session.summaries) { summary in
                                historyRow(summary.row, visitIDs: summary.visitIDs).disabled(presentation.isBusy)
                            }
                        }
                    }
                }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden).background(
                LibraryDeleteKey(enabled: !presentation.isBusy && !selection.ids.isEmpty, delete: deleteSelection)
            )
            .focusable().focusEffectDisabled().focused($listFocused)
            .onKeyPress(.return) {
                guard !presentation.isBusy else { return .ignored }
                guard
                    let row = presentation.sections.lazy.flatMap(\.rows).first(where: { selection.ids.contains($0.id) })
                else { return .ignored }
                openVisit(row)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard !presentation.isBusy, !selection.ids.isEmpty else { return .ignored }
                deleteSelection()
                return .handled
            }
            .onKeyPress(keys: ["a"]) { press in
                guard !presentation.isBusy, press.modifiers.contains(.command) else { return .ignored }
                selection.all(presentation.ordered)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.ids.isEmpty else { return .ignored }
                selection.clear()
                return .handled
            }
            .onChange(of: ordered) { _, ids in selection.retain(ids) }
        }.task(id: store.selectedProfileID) {
            selection.clear()
            cookies = []
            presentation.replaceCookies([], profile: store.selectedProfileID)
            await refreshCookies()
        }
        .sheet(isPresented: $clearVisible) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("clear data · " + store.profile.name).font(.title3)
                    Spacer()
                    Button("done") { clearVisible = false }
                }
                ClearingView(store: store)
            }.padding(24).frame(width: 480)
        }
        .sheet(isPresented: $cookieVisible, onDismiss: { Task { await refreshCookies() } }) {
            VStack {
                HStack {
                    Text("cookies · " + store.profile.name).font(.title3)
                    Spacer()
                    Button("done") { cookieVisible = false }
                }
                ScrollView { CookieManagerView(store: store) }
            }.padding(24).frame(width: 640, height: 520)
        }
    }
    private func historyRow(_ row: HistoryPresentation.Row, visitIDs: Set<UUID>) -> some View {
        let title = row.title
        let selected = !selection.ids.isDisjoint(with: visitIDs)
        func selectSummary(_ modifiers: NSEvent.ModifierFlags? = nil, toggle: Bool = false) {
            select(row.id, toggle: toggle, modifiers: modifiers)
            selection.expand(visitIDs, for: row.id)
        }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in selectSummary(toggle: true) })).toggleStyle(
                .checkbox
            ).labelsHidden().accessibilityLabel("select " + title)
            HStack(spacing: 10) {
                WebsiteIcon(url: row.url, store: store, size: 16)
                Text(title).font(.system(size: 13)).lineLimit(1)
                if visitIDs.count > 1 {
                    Text("×\(visitIDs.count)").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(row.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(
                    maxWidth: 180, alignment: .trailing)
            }.contentShape(Rectangle())
                .overlay(HistoryRowHitTarget(select: { selectSummary($0) }, open: { openVisit(row) }))
                .accessibilityElement(children: .combine).accessibilityAddTraits(
                    selected ? [.isButton, .isSelected] : .isButton
                )
                .accessibilityLabel(title + (visitIDs.count > 1 ? ", \(visitIDs.count) visits" : ""))
                .accessibilityAction { selectSummary() }
                .accessibilityAction(named: "open in new tab") { openVisit(row) }
        }.padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button("open in new tab") { openVisit(row) }
                if selected, selection.ids.count > visitIDs.count {
                    Button("delete \(selection.ids.count) visits") { deleteSelection() }
                } else {
                    Button(visitIDs.count > 1 ? "delete \(visitIDs.count) visits" : "delete visit") {
                        guard canAct(on: row.id) else { return }
                        store.updateCurrent { $0.history.removeAll { visitIDs.contains($0.id) } }
                    }
                }
            }
    }
    private func canAct(on id: UUID) -> Bool {
        !presentation.isBusy && presentation.profileID == store.selectedProfileID && presentation.ordered.contains(id)
    }
    private func openVisit(_ row: HistoryPresentation.Row) {
        if canAct(on: row.id) { store.navigate(row.visit.address, inNewTab: true) }
    }
    private func select(_ id: UUID, toggle: Bool = false, modifiers: NSEvent.ModifierFlags? = nil) {
        guard canAct(on: id) else { return }
        let modifiers = modifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        selection.select(
            id, ordered: presentation.ordered, command: toggle || modifiers.contains(.command),
            shift: modifiers.contains(.shift))
        listFocused = true
    }
    private func deleteSelection() {
        guard !presentation.isBusy else { return }
        let ids = selection.ids
        store.updateCurrent { $0.history.removeAll { ids.contains($0.id) } }
        selection.clear()
    }
    private func refreshCookies() async {
        let id = store.selectedProfileID
        let all = await store.runtime.dataStore.httpCookieStore.allCookies()
        if id == store.selectedProfileID {
            cookies = all
            presentation.replaceCookies(all, profile: id)
        }
    }
    private func deleteCookies(host: String) {
        let rt = store.runtime
        let id = store.selectedProfileID
        Task {
            for cookie in cookies where BrowserAddress.domain(cookie.domain, belongsTo: host) {
                await rt.dataStore.httpCookieStore.deleteCookie(cookie)
            }
            if id == store.selectedProfileID { await refreshCookies() }
        }
    }
}

struct FavoritesView: View {
    @ObservedObject var store: BrowserStore
    @State private var folderID: UUID?
    private var bookmarks: [Favorite] { store.profile.favorites.filter { $0.folderID == folderID } }
    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(title: "bookmarks", icon: .favorite)
            BookmarkFolderBar(store: store, selectedID: $folderID)
            HStack {
                Text("\(bookmarks.count) " + (bookmarks.count == 1 ? "bookmark" : "bookmarks")).font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("add website…") { store.editBookmark(folderID: folderID) }.controlSize(.small)
            }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.top, 12).frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if bookmarks.isEmpty {
                        emptyLibrary(
                            icon: .favorite, title: "no bookmarks", detail: "add a website here or press ⌘D on a page.")
                    }
                    ForEach(bookmarks) { favorite in
                        HStack(spacing: 9) {
                            WebsiteIcon(url: URL(string: favorite.address), store: store)
                            Button {
                                store.navigate(favorite.address, inNewTab: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(BrowserAddress.visible(favorite.title)).font(.system(size: 13))
                                    Text(BrowserAddress.display(URL(string: favorite.address))).font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(LoafButtonStyle())
                            IconButton(icon: .trash, label: "remove favorite") {
                                store.updateCurrent { $0.favorites.removeAll { $0.id == favorite.id } }
                            }
                        }.padding(11).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                            .contextMenu {
                                Menu("move to folder") {
                                    Button {
                                        store.moveBookmark(favorite.id, to: nil)
                                    } label: {
                                        Label("favorites", systemImage: "star")
                                    }
                                    ForEach(store.profile.bookmarkFolders ?? []) { folder in
                                        Button {
                                            store.moveBookmark(favorite.id, to: folder.id)
                                        } label: {
                                            Label(folder.name, systemImage: "folder")
                                        }
                                    }
                                }
                                Button(role: .destructive) {
                                    store.updateCurrent { $0.favorites.removeAll { $0.id == favorite.id } }
                                } label: {
                                    Label("delete bookmark", systemImage: "trash")
                                }
                            }
                    }
                    if !store.profile.privateMode {
                        HStack {
                            Button("import bookmarks…") { importFavorites() }
                            Button("export json…") { exportFavorites() }
                            Spacer()
                        }.controlSize(.small).padding(.top, 8)
                    }
                }.frame(maxWidth: 600).padding(28).frame(maxWidth: .infinity)
            }
        }.onChange(of: store.selectedProfileID) { _, _ in folderID = nil }
            .onChange(of: store.profile.bookmarkFolders?.map(\.id)) { _, ids in
                if let folderID, ids?.contains(folderID) != true { self.folderID = nil }
            }
    }
    private func importFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .html]
        panel.message = "import HTML bookmarks or loaf bookmarks JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let archive = try? JSONDecoder().decode(BookmarkArchive.self, from: data)
            let imported =
                url.pathExtension.lowercased() == "json"
                ? try archive?.bookmarks ?? JSONDecoder().decode([Favorite].self, from: data)
                : try BookmarkImport.html(String(decoding: data, as: UTF8.self))
            store.updateCurrent { p in
                var mapping: [UUID: UUID] = [:]
                if let archive, archive.version == 1 {
                    for folder in archive.folders {
                        let new = BookmarkFolder(name: folder.name)
                        mapping[folder.id] = new.id
                        p.bookmarkFolders = (p.bookmarkFolders ?? []) + [new]
                    }
                }
                for var item in imported
                where ["http", "https"].contains(URL(string: item.address)?.scheme)
                    && !p.favorites.contains(where: { $0.address == item.address })
                {
                    item.id = UUID()
                    item.folderID = folderID ?? item.folderID.flatMap { mapping[$0] }
                    p.favorites.append(item)
                }
            }
        } catch { store.error = error.localizedDescription }
    }
    private func exportFavorites() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "loaf-favorites.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JSONEncoder().encode(
                BookmarkArchive(bookmarks: store.profile.favorites, folders: store.profile.bookmarkFolders ?? [])
            ).write(to: url, options: .atomic)
        } catch { store.error = error.localizedDescription }
    }
}

struct DownloadsView: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(title: "downloads", icon: .download)
            HStack {
                Text(store.profile.name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("open downloads folder") {
                    if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(folder)
                    }
                }.controlSize(.small)
            }.frame(maxWidth: 600).padding(.horizontal, 28).padding(.top, 16).frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 8) {
                    if store.downloads.items.filter({ $0.profileID == store.selectedProfileID }).isEmpty {
                        emptyLibrary(
                            icon: .download, title: "no downloads", detail: "loaf asks where to save each file.")
                    }
                    ForEach(store.downloads.items.filter { $0.profileID == store.selectedProfileID }) { item in
                        DownloadRow(item: item, manager: store.downloads, store: store)
                    }
                }.frame(maxWidth: 600).padding(28).frame(maxWidth: .infinity)
            }
        }
    }
}

struct CookiePage: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(title: "cookies", icon: .cookie)
            ScrollView { CookieManagerView(store: store).frame(maxWidth: 680).padding(24).frame(maxWidth: .infinity) }
        }
    }
}
struct AboutPage: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(title: "about loaf", icon: .info)
            AboutLoafView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        _ = store.newTab(url: url, showOmnibar: false)
                        return .handled
                    })
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let manager: DownloadManager
    var store: BrowserStore? = nil
    var body: some View {
        HStack(spacing: 10) {
            GolzheimIcon(icon: .download, size: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 13))
                if let error = item.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if item.finished {
                    Text("saved").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: item.fraction).frame(maxWidth: 300)
                }
            }
            Spacer()
            if item.finished, let destination = item.destination {
                IconButton(icon: .folder, label: "show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } else if item.canRetrySave, let store {
                Button("save again…") { manager.retrySave(item, in: store) }.controlSize(.small)
            } else if item.resumeData != nil, let store {
                Button("resume") { manager.resume(item, in: store) }.controlSize(.small)
            } else if item.error == nil {
                IconButton(icon: .pause, label: "pause download") { manager.pause(item) }
                IconButton(icon: .close, label: "cancel download") { manager.cancel(item) }
            }
        }.padding(12).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }
}

func emptyLibrary(icon: LoafIcon, title: String, detail: String) -> some View {
    VStack(spacing: 12) {
        GolzheimIcon(icon: icon, size: 34).foregroundStyle(.secondary)
        Text(title).font(.system(size: 18, weight: .medium))
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.vertical, 65)
}

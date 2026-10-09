import SwiftUI
import UniformTypeIdentifiers

struct ProfileImportView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var browsers: [ImportBrowser] = []
    @State private var selectedBrowser: ImportBrowser?
    @State private var scanning = false
    @State private var importAll = false
    @State private var previews: [ProfileImportPreview] = []
    @State private var selected = 0
    @State private var name = ""
    @State private var step = 0
    @State private var busy = false
    @State private var error: String?
    @State private var newProfile = true
    @State private var history = true
    @State private var bookmarks = true
    @State private var cookies = false
    @State private var requestingAccess = false
    @State private var checkingAccess = false
    @State private var dataAccess: BrowserImportDiscovery.DataAccess?
    init(store: BrowserStore, initialPreview: ProfileImportPreview? = nil) {
        self.store = store
        if let initialPreview {
            _previews = State(initialValue: [initialPreview])
            _name = State(initialValue: initialPreview.name)
            _step = State(initialValue: 1)
            _history = State(initialValue: !initialPreview.history.isEmpty)
            _bookmarks = State(initialValue: !initialPreview.bookmarks.isEmpty)
        }
    }
    private var importSources: [ProfileImportPreview] { importAll ? previews : preview.map { [$0] } ?? [] }
    private var historyCount: Int { importSources.reduce(0) { $0 + $1.history.count } }
    private var bookmarkCount: Int { importSources.reduce(0) { $0 + $1.bookmarks.count } }
    private var cookieCount: Int { importSources.reduce(0) { $0 + $1.cookies.count } }
    private var tabCount: Int { importSources.reduce(0) { $0 + $1.tabs.count } }
    private var preview: ProfileImportPreview? { previews.indices.contains(selected) ? previews[selected] : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                if let icon = LoafAppIcon.image {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 54, height: 54)
                        .accessibilityHidden(true)
                }
                Spacer()
                if !busy {
                    Button {
                        dismiss()
                    } label: {
                        GolzheimIcon(icon: .close, size: 14)
                    }.buttonStyle(.plain).accessibilityLabel("close import")
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= step ? profileTint(store.profile) : Color.primary.opacity(0.08)).frame(
                        width: 26, height: 4)
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel("import step \(step + 1) of 3")
            VStack(alignment: .leading, spacing: 8) {
                Text(step == 0 ? "import browsing data" : step == 1 ? "choose what to import" : "import complete").font(
                    .system(size: 27, weight: .semibold, design: .rounded))
                Text(
                    step == 0
                        ? "bring your history, bookmarks, tabs and cookies into loaf. choose a browser to preview its profiles."
                        : step == 1
                            ? "choose what to bring into loaf. your source data stays where it is."
                            : "your selected data is saved in this profile."
                ).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                if step == 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("installed browsers").font(.system(size: 12, weight: .medium))
                            Spacer()
                            if scanning { ProgressView().controlSize(.small) }
                            Button("scan again") { discover() }.controlSize(.small).disabled(scanning || busy)
                        }
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                                ForEach(browsers) { browser in
                                    Button { chooseBrowser(browser) } label: {
                                        VStack(spacing: 8) {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.applicationURL.path))
                                                .resizable().scaledToFit().frame(width: 44, height: 44)
                                            Text(browser.name).font(.system(size: 12)).lineLimit(2)
                                        }.frame(maxWidth: .infinity).frame(height: 90)
                                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                            .contentShape(RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(LoafButtonStyle()).disabled(busy)
                                }
                            }
                        }.frame(maxHeight: 210)
                        if browsers.isEmpty && !scanning {
                            Text("no browsers found. you can still choose a profile folder or an export.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text("close the source browser first. protected data needs Full Disk Access. after enabling it, quit and reopen loaf before importing.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Full Disk Access…") {
                                requestAccess()
                            }.controlSize(.small)
                            Spacer()
                            Button("choose file or folder…") { chooseSource() }.controlSize(.small).disabled(busy)
                        }
                    }
                } else if step == 1, let preview {
                    VStack(alignment: .leading, spacing: 12) {
                        if previews.count > 1 {
                            Picker("source profile", selection: $selected) {
                                ForEach(previews.indices, id: \.self) { index in Text(previews[index].name).tag(index) }
                            }.onChange(of: selected) { _, _ in
                                name = self.preview?.name ?? "imported"
                                history = self.preview?.history.isEmpty == false
                                bookmarks = self.preview?.bookmarks.isEmpty == false
                                cookies = false
                            }
                        }
                        if previews.count > 1 {
                            Toggle("import every profile / space", isOn: $importAll)
                                .disabled(previews.count > 8 - store.profiles.count)
                                .onChange(of: importAll) { _, _ in history = historyCount > 0; bookmarks = bookmarkCount > 0; cookies = false }
                            if previews.count > 8 - store.profiles.count {
                                Text("choose one profile at a time; loaf has room for \(max(0, 8 - store.profiles.count)) more.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("create a new profile", isOn: $newProfile).disabled(importAll || store.profiles.count >= 8)
                        if newProfile && !importAll {
                            TextField("profile name", text: $name).textFieldStyle(.roundedBorder)
                        } else if !importAll {
                            Text("importing into \(store.profile.name)").font(.system(size: 12)).foregroundStyle(
                                .secondary)
                        }
                        Divider()
                        importRow(
                            "history",
                            detail:
                                "\(historyCount.formatted()) \(historyCount == 1 ? "visit" : "visits")",
                            icon: "clock", selection: $history, enabled: historyCount > 0)
                        importRow(
                            "bookmarks",
                            detail:
                                "\(bookmarkCount.formatted()) \(bookmarkCount == 1 ? "bookmark" : "bookmarks")",
                            icon: "star", selection: $bookmarks, enabled: bookmarkCount > 0)
                        importRow(
                            "cookies",
                            detail:
                                "\(cookieCount.formatted()) readable \(cookieCount == 1 ? "cookie" : "cookies")",
                            icon: "circle.dotted", selection: $cookies, enabled: cookieCount > 0)
                        if tabCount > 0 {
                            Text("\(tabCount.formatted()) tabs will open in the imported profile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let selectedBrowser, preview.warnings.contains(where: { $0.contains("protected cookies") }) {
                            Button("unlock encrypted cookies…") { unlockCookies(selectedBrowser) }.controlSize(.small)
                        }
                        if cookies {
                            Text("cookies can keep you signed in to websites in this profile.").font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(preview.warnings, id: \.self) {
                            Text($0).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if preview.warnings.contains(where: { $0.contains("permission") || $0.contains("Full Disk Access") }) {
                            Button("allow access to protected data…") { requestAccess() }.controlSize(.small)
                        }
                    }.disabled(busy)
                } else if step == 2 {
                    Label("ready in \(store.profile.name)", systemImage: "checkmark.circle.fill").font(
                        .system(size: 16)
                    ).foregroundStyle(profileTint(store.profile)).padding(.vertical, 24)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden).transition(.opacity)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).accessibilityLabel("import error: " + error)
            }
            Spacer(minLength: 0)
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(step == 0 ? "reading your data…" : "bringing it over…").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if step == 1 {
                    Button("back") { transition(to: 0) }.buttonStyle(.plain)
                }
                Spacer()
                if step == 1 {
                    Button("import selected data") { performImport() }.buttonStyle(.borderedProminent).controlSize(
                        .large
                    )
                    .disabled(busy || !canImport).keyboardShortcut(.defaultAction)
                } else if step == 2 {
                    Button("done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(
                        .defaultAction)
                }
            }
        }.padding(32).frame(width: 560, height: 700).background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(busy).onAppear { newProfile = store.profiles.count < 8; discover() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if step == 0 { discover() }
                if requestingAccess { checkAccess() }
            }
            .sheet(isPresented: $requestingAccess) { accessRequest }
    }
    private var accessRequest: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                Text("allow browser data access").font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            Text("macOS protects Safari and other browser data. allow loaf to read it for this local import in System Settings.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. open Privacy & Security → Full Disk Access.")
                Text("2. add loaf with the + button, or drag its icon above into the list. turn loaf on.")
                Text("3. quit and reopen loaf, then return to importing.").fontWeight(.semibold)
            }
            Text("you must restart loaf after enabling access. scanning again without restarting won’t apply the permission.")
                .font(.callout).foregroundStyle(.secondary)
            if checkingAccess { ProgressView().controlSize(.small) }
            else if dataAccess == .readable {
                Label("the selected browser’s data is readable", systemImage: "checkmark.circle").font(.callout)
            } else if dataAccess == .denied {
                Text("macOS is currently blocking the selected browser’s data.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("show loaf in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Spacer()
                Button("open System Settings") {
                    if let selectedBrowser {
                        UserDefaults.standard.set(selectedBrowser.id, forKey: "importBrowserAfterAccessRestart")
                    }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
                }.buttonStyle(.borderedProminent)
            }
            Divider()
            HStack {
                Button("not now") { requestingAccess = false }
                Spacer()
                Button("check access") { checkAccess() }.disabled(checkingAccess)
                Button("quit loaf") { NSApp.terminate(nil) }
            }
        }.font(.system(size: 13)).padding(28).frame(width: 510)
            .onAppear { checkAccess() }
    }
    private func requestAccess() {
        if selectedBrowser == nil { selectedBrowser = browsers.first { $0.id == "com.apple.Safari" } }
        dataAccess = nil
        requestingAccess = true
    }
    private func checkAccess() {
        guard !checkingAccess, let browser = selectedBrowser else { return }
        checkingAccess = true
        Task {
            dataAccess = await Task.detached(priority: .userInitiated) { BrowserImportDiscovery.requestDataAccess(browser) }.value
            checkingAccess = false
        }
    }
    private var canImport: Bool {
        guard let preview else { return false }
        return (importAll || !newProfile || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (tabCount > 0 || history && historyCount > 0 || bookmarks && bookmarkCount > 0
                || cookies && cookieCount > 0)
    }
    private func importRow(_ title: String, detail: String, icon: String, selection: Binding<Bool>, enabled: Bool)
        -> some View
    {
        Toggle(isOn: selection) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.disabled(!enabled).toggleStyle(.checkbox)
    }
    private func transition(to step: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { self.step = step }
    }
    private func discover() {
        guard !scanning else { return }
        scanning = true
        Task {
            browsers = await Task.detached(priority: .userInitiated) { BrowserImportDiscovery.installed() }.value
            scanning = false
            if selectedBrowser == nil,
                let id = UserDefaults.standard.string(forKey: "importBrowserAfterAccessRestart"),
                let browser = browsers.first(where: { $0.id == id }) {
                chooseBrowser(browser)
            }
        }
    }
    private func chooseBrowser(_ browser: ImportBrowser, password: Data? = nil) {
        selectedBrowser = browser
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BrowserImportDiscovery.preview(browser, cookiePassword: password)
                }.value
                acceptPreviews(result)
                UserDefaults.standard.removeObject(forKey: "importBrowserAfterAccessRestart")
            } catch {
                self.error = error.localizedDescription
                let access = await Task.detached(priority: .userInitiated) { BrowserImportDiscovery.requestDataAccess(browser) }.value
                if access == .denied { dataAccess = access; requestingAccess = true }
            }
            busy = false
        }
    }
    private func unlockCookies(_ browser: ImportBrowser) {
        busy = true; error = nil
        Task {
            do {
                let password = try await Task.detached(priority: .userInitiated) {
                    try BrowserImportDiscovery.cookiePassword(browser)
                }.value
                chooseBrowser(browser, password: password)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    private func acceptPreviews(_ result: [ProfileImportPreview]) {
        previews = result; selected = 0; importAll = false
        name = result[0].name; cookies = false
        history = !result[0].history.isEmpty; bookmarks = !result[0].bookmarks.isEmpty
        transition(to: 1)
    }
    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "choose a profile folder or browsing-data export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedBrowser = nil
        busy = true
        error = nil
        Task {
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let result = try await Task.detached(priority: .userInitiated) { try ProfileImport.preview(url) }.value
                guard !result.isEmpty else {
                    throw ProfileImport.Failure(message: "No regular profiles found in this export.")
                }
                acceptPreviews(result)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func performImport() {
        guard canImport, let preview else { return }
        busy = true
        error = nil
        Task {
            do {
                let sources = importAll ? previews : [preview]
                guard !importAll || sources.count <= 8 - store.profiles.count else {
                    throw ProfileImport.Failure(message: "There isn’t room for every profile. Choose one to import.")
                }
                for source in sources {
                    try await store.importProfile(source, name: importAll ? source.name : name,
                        newProfile: importAll || newProfile, history: history, bookmarks: bookmarks, cookies: cookies)
                }
                transition(to: 2)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

private final class ImportWindowReference {
    weak var window: NSWindow?
}

private struct ImportWindowReader: NSViewRepresentable {
    let reference: ImportWindowReference
    final class View: NSView {
        var reference: ImportWindowReference?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
    func makeNSView(context: Context) -> View {
        let view = View()
        view.reference = reference
        return view
    }
    func updateNSView(_ view: View, context: Context) { reference.window = view.window }
}

struct ProfileImportView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var browsers: [ImportBrowser] = []
    @State private var selectedBrowser: ImportBrowser?
    @State private var scanning = false
    @State private var active = false
    @State private var importAll = false
    @State private var previews: [ProfileImportPreview] = []
    @State private var selected = 0
    @State private var name = ""
    @State private var step = 0
    @State private var busy = false
    @State private var committing = false
    @State private var confirmImport = false
    @State private var operationID = UUID()
    @State private var destinationID: UUID
    @State private var completedNames: [String] = []
    @State private var error: String?
    @State private var newProfile = true
    @State private var history = true
    @State private var bookmarks = true
    @State private var cookies = false
    @State private var tabs = false
    @State private var requestingAccess = false
    @State private var checkingAccess = false
    @State private var selectedFolderURL: URL?
    @State private var authorizedFolderURLs: [URL] = []
    @State private var dataAccess: BrowserImportDiscovery.DataAccess?
    @State private var sourcePanel: NSOpenPanel?
    @State private var contentHeight: CGFloat = 360
    @State private var advancedAccessHelp = false
    @State private var importerWindow = ImportWindowReference()
    init(store: BrowserStore, initialPreview: ProfileImportPreview? = nil, preferNewProfile: Bool = true) {
        self.store = store
        _destinationID = State(initialValue: store.selectedProfileID)
        _newProfile = State(initialValue: preferNewProfile && store.profiles.count < 8)
        if let initialPreview {
            let initialPreview = ProfileImport.sanitize(initialPreview)
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
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Capsule().fill(index <= step ? profileTint(store.profile) : Color.primary.opacity(0.08))
                            .frame(width: 24, height: 3)
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel("import step \(step + 1) of 3")
                Spacer()
                Button {
                    cancelImport()
                } label: {
                    GolzheimIcon(icon: .close, size: 14)
                }
                .buttonStyle(.plain).accessibilityLabel("close import").disabled(committing || sourcePanel != nil)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    step == 0
                        ? selectedBrowser.map { "import from " + $0.name } ?? "import browsing data"
                        : step == 1 ? "choose what to import" : "import complete"
                ).font(
                    .system(size: 24, weight: .semibold))
                Text(
                    step == 0
                        ? selectedBrowser == nil
                            ? "choose a browser, then review what comes over."
                            : "read your browsing data, then choose what to bring over."
                        : step == 1
                            ? "choose what to bring into loaf. your source data stays where it is."
                            : "your selected data is saved in loaf."
                ).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FocusRingSafeScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if step == 0, let selectedBrowser {
                        browserSource(selectedBrowser)
                    } else if step == 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("installed browsers").font(.system(size: 12, weight: .medium))
                                Spacer()
                                if scanning { ProgressView().controlSize(.small) }
                                Button("scan again") { discover() }.controlSize(.small).disabled(scanning || busy)
                            }
                            VStack(spacing: 6) {
                                ForEach(browsers) { browser in
                                    Button {
                                        chooseBrowser(browser)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(
                                                nsImage: NSWorkspace.shared.icon(forFile: browser.applicationURL.path)
                                            )
                                            .resizable().scaledToFit().frame(width: 36, height: 36)
                                            Text(browser.name).font(.system(size: 14, weight: .medium))
                                            Spacer()
                                            if busy && selectedBrowser?.id == browser.id {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                GolzheimIcon(icon: .forward, size: 14)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }.padding(.horizontal, 14).padding(.vertical, 11)
                                            .background(
                                                Color.primary.opacity(selectedBrowser?.id == browser.id ? 0.07 : 0.035),
                                                in: RoundedRectangle(cornerRadius: 10)
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(LoafButtonStyle()).disabled(
                                        busy || requestingAccess || sourcePanel != nil)
                                }
                            }
                            if browsers.isEmpty && !scanning {
                                Text("no browsers found. choose a profile folder or bookmarks export below.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Divider().padding(.vertical, 4)
                            Button("choose file or folder…") { chooseSource() }.disabled(busy || sourcePanel != nil)
                            Text(
                                "close the source browser before importing. your data stays on this Mac; source files stay untouched."
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                                horizontal: false, vertical: true)
                        }
                    } else if step == 1, let preview {
                        VStack(alignment: .leading, spacing: 12) {
                            if previews.count > 1 {
                                Picker("source profile", selection: $selected) {
                                    ForEach(previews.indices, id: \.self) { index in
                                        Text(previews[index].name).tag(index)
                                    }
                                }.onChange(of: selected) { _, _ in
                                    name = self.preview?.name ?? "imported"
                                    history = self.preview?.history.isEmpty == false
                                    bookmarks = self.preview?.bookmarks.isEmpty == false
                                    cookies = false
                                    tabs = false
                                }
                            }
                            if previews.count > 1 {
                                Toggle("import every profile / space", isOn: $importAll)
                                    .disabled(previews.count > 8 - store.profiles.count)
                                    .onChange(of: importAll) { _, _ in
                                        history = historyCount > 0
                                        bookmarks = bookmarkCount > 0
                                        cookies = false
                                        tabs = false
                                    }
                                if previews.count > 8 - store.profiles.count {
                                    Text(
                                        "choose one profile at a time; loaf has room for \(max(0, 8 - store.profiles.count)) more."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Toggle("create a new profile", isOn: $newProfile).disabled(
                                importAll || store.profiles.count >= 8)
                                .onChange(of: newProfile) { _, value in if !value && !importAll { cookies = false } }
                            if newProfile && !importAll {
                                TextField("profile name", text: $name).textFieldStyle(.roundedBorder)
                            } else if !importAll {
                                Text("importing into \(store.profileFor(destinationID).name)").font(.system(size: 12)).foregroundStyle(
                                    .secondary)
                            }
                            Divider()
                            importRow(
                                "history",
                                detail:
                                    "\(historyCount.formatted()) \(historyCount == 1 ? "visit" : "visits")",
                                icon: .history, selection: $history, enabled: historyCount > 0)
                            importRow(
                                "bookmarks",
                                detail:
                                    "\(bookmarkCount.formatted()) \(bookmarkCount == 1 ? "bookmark" : "bookmarks")",
                                icon: .favorite, selection: $bookmarks, enabled: bookmarkCount > 0)
                            importRow(
                                "cookies",
                                detail:
                                    "\(cookieCount.formatted()) readable \(cookieCount == 1 ? "cookie" : "cookies")",
                                icon: .cookie, selection: $cookies, enabled: cookieCount > 0 && (importAll || newProfile))
                            if cookieCount > 0 && !importAll && !newProfile {
                                Text("create a new profile to import cookies and keep existing sign-ins untouched.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            importRow(
                                "import saved tabs",
                                detail:
                                    "\(tabCount.formatted()) tabs · \(importSources.flatMap(\.tabs).filter(\.pinned).count) pinned",
                                icon: .profiles,
                                selection: $tabs, enabled: tabCount > 0)
                            if tabs {
                                Text("opening tabs contacts those websites.").font(.system(size: 11)).foregroundStyle(
                                    .secondary)
                            }
                            if let selectedBrowser,
                                preview.warnings.contains(where: { $0.contains("protected cookies") })
                            {
                                Button("unlock encrypted cookies…") { unlockCookies(selectedBrowser) }.controlSize(
                                    .small)
                            }
                            if cookies {
                                Text("cookies can sign you in to websites in the new profile.").font(
                                    .system(size: 11)
                                )
                                .foregroundStyle(.secondary)
                            }
                            ForEach(Array(Set(importSources.flatMap(\.warnings))).sorted(), id: \.self) {
                                Text($0).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if selectedBrowser != nil
                                && preview.warnings.contains(where: {
                                    $0.contains("permission") || $0.contains("Full Disk Access")
                                        || $0.contains("blocked")
                                })
                            {
                                Button("choose another data folder…") {
                                    if let selectedBrowser { chooseBrowserFolder(selectedBrowser) }
                                }.controlSize(.small)
                            }
                        }.disabled(busy)
                    } else if step == 2 {
                        Label("ready in " + completedNames.joined(separator: ", "), systemImage: "checkmark.circle.fill").font(
                            .system(size: 16)
                        ).foregroundStyle(profileTint(store.profile)).padding(.vertical, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight = $0
                    }
            }.frame(height: min(contentHeight, 430)).scrollIndicators(.hidden)
                .id(step == 0 ? selectedBrowser?.id ?? "sources" : "step\(step)")
                .transition(.opacity)
            if let error, step != 0 || selectedBrowser == nil {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).accessibilityLabel("import error: " + error)
            }
            HStack {
                    if busy {
                        ProgressView().controlSize(.small)
                        Text(step == 0 ? "reading your data…" : "bringing it over…").font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if step == 1 || (step == 0 && selectedBrowser != nil) {
                        Button("back") { resetSource() }.buttonStyle(.plain)
                    }
                    Spacer()
                    if step < 2 {
                        Button("cancel") { cancelImport() }.keyboardShortcut(.cancelAction)
                            .disabled(committing || sourcePanel != nil)
                    }
                    if step == 1 {
                        Button("import selected data…") { confirmImport = true }.buttonStyle(.borderedProminent).controlSize(
                            .large
                        )
                        .disabled(busy || !canImport).keyboardShortcut(.defaultAction)
                    } else if step == 2 {
                        Button("done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(
                                .defaultAction)
                    }
                }
        }.padding(24).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
            .background(ImportWindowReader(reference: importerWindow))
            .interactiveDismissDisabled(committing || sourcePanel != nil).onAppear {
                active = true
                if store.profiles.count >= 8 { newProfile = false }
                discover()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if step == 0 { discover() }
                if requestingAccess { checkAccess() }
            }
            .confirmationDialog("import selected data?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("import data") { performImport() }
                Button("cancel", role: .cancel) {}
            } message: {
                Text(importSummary)
            }
            .onDisappear {
                active = false
                operationID = UUID()
                sourcePanel?.cancel(nil)
                sourcePanel = nil
                releaseFolderAccess()
            }
            .sheet(isPresented: $requestingAccess) { accessRequest }
    }
    private func browserSource(_ browser: ImportBrowser) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: browser.applicationURL.path))
                    .resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(browser.name).font(.system(size: 15, weight: .medium))
                    Text(busy ? "reading browsing data…" : "choose a data folder")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if !busy {
                if dataAccess == .denied {
                    Text("allow folder access").font(.system(size: 14, weight: .medium))
                    Text(
                        "macOS blocked this source. choose \(browser.name)’s data folder to allow access for this import."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text(error ?? "choose the browser’s profile folder or a bookmarks export.")
                        .foregroundStyle(.secondary)
                }
                Text("loaf reads the folder you choose. your source files stay untouched; passwords aren’t included.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("choose data folder…") { chooseBrowserFolder(browser) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(sourcePanel != nil).keyboardShortcut(.defaultAction)
                HStack {
                    Button("choose an export…") { chooseSource() }.disabled(sourcePanel != nil)
                    if selectedFolderURL != nil && dataAccess == .denied {
                        Button("macOS access help…") { requestAccess() }
                    }
                }
            }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
    private func resetSource() {
        releaseFolderAccess()
        selectedBrowser = nil
        dataAccess = nil
        error = nil
        advancedAccessHelp = false
        transition(to: 0)
    }
    private var accessRequest: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("access to \(selectedBrowser?.name ?? "browser data")")
                .font(.system(size: 22, weight: .semibold))
            Text(
                "choose the browser’s data folder to allow access for this import. passwords aren’t included in this importer."
            )
            .foregroundStyle(.secondary)
            if let browser = selectedBrowser {
                Button("choose \(browser.name) data folder…") { chooseBrowserFolder(browser) }
                    .buttonStyle(.borderedProminent)
            }
            if selectedFolderURL != nil && (dataAccess == .denied || dataAccess == .partial) {
                DisclosureGroup("other macOS access options", isExpanded: $advancedAccessHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "macOS still blocks some of these source files. Full Disk Access may help with protected locations; it isn’t required for every import and doesn’t unlock passwords."
                        )
                        .foregroundStyle(.secondary)
                        Text("if you enable it, add this copy of loaf, quit and reopen it, then retry.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
                                .resizable().scaledToFit().frame(width: 32, height: 32)
                                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                            Text(Bundle.main.bundleURL.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("show this copy in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            Button("System Settings…") {
                                if let selectedBrowser {
                                    UserDefaults.standard.set(
                                        selectedBrowser.id, forKey: "importBrowserAfterAccessRestart")
                                }
                                NSWorkspace.shared.open(
                                    URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
                                    )!)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            if checkingAccess {
                ProgressView().controlSize(.small)
            } else if let dataAccess {
                Text(accessDescription(dataAccess)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("cancel") { requestingAccess = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("check source access") { checkAccess() }.disabled(checkingAccess || busy)
                if dataAccess == .readable || dataAccess == .partial, let browser = selectedBrowser {
                    Button("continue") {
                        requestingAccess = false
                        chooseBrowser(browser, authorizedFolder: selectedFolderURL)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }
        }.font(.system(size: 13)).padding(28).frame(width: 510)
            .onAppear { checkAccess() }
    }
    private func accessDescription(_ access: BrowserImportDiscovery.DataAccess) -> String {
        switch access {
        case .readable: "this browser’s source files are readable"
        case .partial: "some source files are readable; other locations are blocked"
        case .denied: "macOS denied access to this browser’s source files"
        case .noData: "no supported source files found in this location"
        case .unreadable: "source files couldn’t be read; this does not indicate Full Disk Access is off"
        }
    }
    private func requestAccess() {
        guard selectedBrowser != nil else { return }
        requestingAccess = true
    }
    private func checkAccess() {
        guard !checkingAccess, let browser = selectedBrowser else { return }
        checkingAccess = true
        let operation = operationID
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BrowserImportDiscovery.requestDataAccess(browser)
            }.value
            guard active, operationID == operation else { checkingAccess = false; return }
            dataAccess = result
            checkingAccess = false
        }
    }
    private func releaseFolderAccess() {
        for folder in authorizedFolderURLs { folder.stopAccessingSecurityScopedResource() }
        authorizedFolderURLs = []
        selectedFolderURL = nil
    }
    private func chooseBrowserFolder(_ browser: ImportBrowser) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = browser.suggestedFolder
        panel.message =
            browser.isSafari
            ? "choose the Safari folder in your home Library for history and bookmarks. cookies are read separately from Safari’s container."
            : "choose \(browser.name)’s data folder or a profile inside it. loaf reads this folder only for importing."
        panel.prompt = "allow and preview"
        presentSourcePanel(panel) { folder in
            guard let folder else { return }
            requestingAccess = false
            chooseBrowser(browser.selectingFolder(folder), authorizedFolder: folder)
        }
    }
    private func presentSourcePanel(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        guard sourcePanel == nil else { return }

        var presentingWindow = importerWindow.window ?? NSApp.keyWindow ?? store.nativeWindow

        while let sheet = presentingWindow?.attachedSheet { presentingWindow = sheet }
        let presenter = presentingWindow
        let returnWindow = importerWindow.window ?? presenter
        sourcePanel = panel
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            guard sourcePanel === panel else { return }
            sourcePanel = nil
            completion(response == .OK ? panel.url : nil)
            DispatchQueue.main.async {
                let target = presenter?.isVisible == true ? presenter : returnWindow
                guard let target, target.isVisible, NSApp.isActive else { return }
                target.sheetParent?.makeKeyAndOrderFront(nil)
                target.makeKeyAndOrderFront(nil)
            }
        }
        if let presenter, presenter.isVisible {
            panel.beginSheetModal(for: presenter, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
    private var canImport: Bool {
        guard preview != nil, store.profiles.contains(where: { $0.id == destinationID && !$0.privateMode }),
              !store.application.busyProfileIDs.contains(destinationID),
              !(importAll || newProfile) || importSources.count <= 8 - store.profiles.count else { return false }
        return (!cookies || importAll || newProfile)
            && (importAll || !newProfile || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (tabs && tabCount > 0 || history && historyCount > 0 || bookmarks && bookmarkCount > 0
                || cookies && cookieCount > 0)
    }
    private var importSummary: String {
        let target = importAll ? "\(importSources.count) new profiles" : newProfile ? "a new profile named \(name)" : store.profileFor(destinationID).name
        var text = "Import into \(target). Existing bookmarks, history and sign-in cookies are kept. Source files stay untouched."
        if cookies { text += " Imported cookies may sign you in to websites." }
        if tabs { text += " This opens \(tabCount) tabs and contacts those websites." }
        return text
    }
    private func cancelImport() {
        guard !committing else { return }
        operationID = UUID()
        dismiss()
    }
    private func importRow(_ title: String, detail: String, icon: LoafIcon, selection: Binding<Bool>, enabled: Bool)
        -> some View
    {
        Toggle(isOn: selection) {
            HStack(spacing: 10) {
                GolzheimIcon(icon: icon, size: 16).frame(width: 20)
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
            let result = await Task.detached(priority: .userInitiated) { BrowserImportDiscovery.installed() }.value
            guard active else { return }
            browsers = result
            scanning = false
            if step == 0, selectedBrowser == nil,
                let id = UserDefaults.standard.string(forKey: "importBrowserAfterAccessRestart"),
                let browser = browsers.first(where: { $0.id == id })
            {
                chooseBrowser(browser)
            }
        }
    }
    private func chooseBrowser(_ browser: ImportBrowser, password: Data? = nil, authorizedFolder: URL? = nil) {
        guard active, !busy else { return }
        if selectedFolderURL != authorizedFolder {

            if !browser.isSafari || selectedBrowser?.id != browser.id || authorizedFolder == nil {
                releaseFolderAccess()
            }
            if let authorizedFolder {
                if !authorizedFolderURLs.contains(authorizedFolder), authorizedFolder.startAccessingSecurityScopedResource() {
                    authorizedFolderURLs.append(authorizedFolder)
                }
                selectedFolderURL = authorizedFolder
            }
        }
        selectedBrowser = browser
        dataAccess = nil
        advancedAccessHelp = false
        busy = true
        error = nil
        transition(to: 0)
        let operation = UUID()
        operationID = operation
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BrowserImportDiscovery.preview(browser, cookiePassword: password)
                }.value
                guard operationID == operation else { return }
                acceptPreviews(result)
                UserDefaults.standard.removeObject(forKey: "importBrowserAfterAccessRestart")
            } catch {
                let message = error.localizedDescription
                let access = await Task.detached(priority: .userInitiated) {
                    BrowserImportDiscovery.requestDataAccess(browser)
                }.value
                guard operationID == operation else { return }
                dataAccess = access
                self.error = message
            }
            if operationID == operation { busy = false }
        }
    }
    private func unlockCookies(_ browser: ImportBrowser) {
        guard !busy else { return }
        let operation = UUID()
        operationID = operation
        busy = true
        error = nil
        Task {
            do {
                let password = try await Task.detached(priority: .userInitiated) {
                    try BrowserImportDiscovery.cookiePassword(browser)
                }.value
                guard operationID == operation else { return }
                busy = false
                chooseBrowser(browser, password: password, authorizedFolder: selectedFolderURL)
            } catch {
                guard operationID == operation else { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
    private func acceptPreviews(_ result: [ProfileImportPreview]) {
        let result = result.map(ProfileImport.sanitize).filter { !$0.isEmpty }
        guard let first = result.first else {
            error = "No readable browsing data found. Choose another source."
            return
        }
        previews = result
        selected = 0
        importAll = false
        name = first.name
        cookies = false
        tabs = false
        history = !first.history.isEmpty
        bookmarks = !first.bookmarks.isEmpty
        transition(to: 1)
    }
    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "choose a profile folder or browsing-data export"
        presentSourcePanel(panel) { url in
            guard let url else { return }
            readSource(url)
        }
    }
    private func readSource(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let path = url.standardizedFileURL.path
            let matches = browsers.filter { browser in
                browser.roots.contains { root in
                    let source = root.standardizedFileURL.path
                    return source == path || source.hasPrefix(path + "/") || path.hasPrefix(source + "/")
                }
            }
            if matches.count == 1, let browser = matches.first {
                chooseBrowser(browser.selectingFolder(url), authorizedFolder: url)
                return
            }
        }
        releaseFolderAccess()
        selectedBrowser = nil
        dataAccess = nil
        busy = true
        error = nil
        let operation = UUID()
        operationID = operation
        Task {
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let result = try await Task.detached(priority: .userInitiated) { try ProfileImport.preview(url) }.value
                guard result.contains(where: { !$0.isEmpty }) else {
                    throw ProfileImport.Failure(message: "No browsing data found in this source.")
                }
                guard operationID == operation else { return }
                acceptPreviews(result)
            } catch {
                guard operationID == operation else { return }
                self.error = error.localizedDescription
            }
            if operationID == operation { busy = false }
        }
    }
    private func performImport() {
        guard !busy, canImport, let preview else { return }
        let sources = importAll ? previews : [preview]
        let names = importAll ? sources.map(\.name) : [name]
        let createProfiles = importAll || newProfile
        busy = true
        committing = true
        error = nil
        Task {
            defer { busy = false; committing = false }
            do {
                let ids = try await store.importProfiles(sources, names: names, newProfile: createProfiles,
                    history: history, bookmarks: bookmarks, cookies: cookies, tabs: tabs, destinationID: destinationID)
                completedNames = ids.map { store.profileFor($0).name }
                transition(to: 2)
            } catch { self.error = error.localizedDescription }
        }
    }
}

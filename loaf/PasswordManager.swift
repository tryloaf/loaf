import AppKit
import Combine
import LocalAuthentication
import Security
import UniformTypeIdentifiers

struct PasswordDraft: Identifiable {
    let id = UUID()
    var original: PasswordEntry?
    var title = ""
    var website = "https://"
    var username = ""
    var password = ""
    var notes = ""
    var valid: Bool {
        PasswordImport.origin(website) != nil && PasswordImport.validUsername(username)
            && PasswordImport.validPassword(password) && notes.utf8.count <= 16_384
    }
}

@MainActor final class PasswordManager: ObservableObject {
    @Published private(set) var entries: [PasswordEntry] = []
    @Published private(set) var unlocked = false
    @Published private(set) var authenticating = false
    @Published private(set) var busy = false
    @Published var search = ""
    @Published var selectedID: String?
    @Published var revealed: String?
    @Published var draft: PasswordDraft?
    @Published var review: PasswordImportReview?
    @Published var error: String?
    @Published var status: String?
    private(set) var profileID: UUID
    private(set) var privateMode: Bool
    private var generation = UUID()
    private var context: LAContext?
    private var expiry: Task<Void, Never>?
    private var revealExpiry: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var changes: AnyCancellable?

    private let authenticate: (@MainActor () async throws -> Bool)?
    private let applicationIsActive: @MainActor () -> Bool
    private let sessionLifetime: Duration
    private let revealLifetime: Duration

    init(
        profileID: UUID, privateMode: Bool = false, sessionLifetime: Duration = .seconds(300),
        revealLifetime: Duration = .seconds(30),
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        authenticate: (@MainActor () async throws -> Bool)? = nil
    ) {
        self.profileID = profileID
        self.privateMode = privateMode
        self.authenticate = authenticate
        self.applicationIsActive = applicationIsActive
        self.sessionLifetime = sessionLifetime
        self.revealLifetime = revealLifetime
        changes = NotificationCenter.default.publisher(for: PasswordVault.didChange)
            .sink { [weak self] notification in
                guard let self, notification.object as? UUID == self.profileID, self.unlocked, !self.busy else {
                    return
                }
                self.hide()
                self.refresh()
            }
    }
    var filtered: [PasswordEntry] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? entries : entries.filter { $0.searchText.localizedStandardContains(term) }
    }
    var selected: PasswordEntry? { entries.first { $0.id == selectedID } }
    var matchingImportCount: Int {
        let ids = Set(entries.map(\.id))
        return review?.entries.filter { ids.contains($0.id) }.count ?? 0
    }
    func configure(profileID: UUID, privateMode: Bool) {
        guard self.profileID != profileID || self.privateMode != privateMode else { return }
        lock()
        self.profileID = profileID
        self.privateMode = privateMode
        search = ""
        status = nil
        error = nil
    }
    func lock() {
        generation = UUID()
        context?.invalidate()
        context = nil
        expiry?.cancel()
        revealExpiry?.cancel()
        importTask?.cancel()
        unlocked = false
        authenticating = false
        busy = false
        revealed = nil
        draft = nil
        review = nil
        entries = []
        selectedID = nil
        PasswordClipboard.clearIfOwned()
    }
    func applicationDidResignActive() {

        if authenticating && !unlocked {
            PasswordClipboard.clearIfOwned()
            return
        }
        lock()
    }
    @discardableResult func unlock() async -> Bool {
        guard !privateMode else { return false }
        if unlocked { return true }
        guard !authenticating else { return false }
        let token = generation
        authenticating = true
        error = nil
        do {
            let accepted: Bool
            if let authenticate {
                accepted = try await authenticate()
            } else {
                let context = LAContext()
                self.context = context
                accepted = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: "unlock your loaf passwords")
                context.invalidate()
            }
            guard generation == token, !privateMode else { return false }
            context = nil
            guard accepted else {
                authenticating = false
                return false
            }

            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            await Task.yield()
            while !applicationIsActive(), generation == token, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard generation == token, !privateMode else { return false }
            authenticating = false
            guard applicationIsActive() else { return false }
            unlocked = true
            refresh()
            expiry?.cancel()
            expiry = Task { [weak self, lifetime = self.sessionLifetime] in
                do {
                    try await Task.sleep(for: lifetime)
                    self?.lock()
                } catch {}
            }
            return true
        } catch {
            guard generation == token else { return false }
            context = nil
            authenticating = false
            if let failure = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(failure.code) {
                return false
            }
            self.error = "couldn’t unlock passwords. try again."
            return false
        }
    }
    func refresh() {
        guard unlocked, !privateMode else { return }
        do {
            entries = try PasswordVault.list(profileID: profileID).sorted {
                ($0.displayTitle.lowercased(), $0.username) < ($1.displayTitle.lowercased(), $1.username)
            }
        } catch {
            self.error = "couldn’t read saved accounts from Keychain."
            entries = []
        }
        if !entries.contains(where: { $0.id == selectedID }) {
            hide()
            selectedID = entries.first?.id
        }
    }
    func select(_ entry: PasswordEntry) {
        hide()
        selectedID = entry.id
    }
    func hide() {
        revealExpiry?.cancel()
        revealed = nil
    }
    func reveal(_ entry: PasswordEntry) {
        guard unlocked, !privateMode, entry.id == selectedID else { return }
        if revealed != nil {
            hide()
            return
        }
        do {
            revealed = try PasswordVault.read(profileID: profileID, origin: entry.origin, username: entry.username)
            revealExpiry = Task { [weak self, lifetime = self.revealLifetime] in
                do {
                    try await Task.sleep(for: lifetime)
                    self?.revealed = nil
                } catch {}
            }
        } catch { self.error = "couldn’t read this password." }
    }
    func copy(_ entry: PasswordEntry) {
        guard unlocked, !privateMode, entry.id == selectedID else { return }
        do {
            PasswordClipboard.copy(
                try PasswordVault.read(profileID: profileID, origin: entry.origin, username: entry.username))
            status = "password copied · clipboard clears in 30 seconds"
        } catch { self.error = "couldn’t copy this password." }
    }
    func edit(_ entry: PasswordEntry? = nil) {
        guard unlocked, !privateMode else { return }
        hide()
        error = nil
        do {
            if let entry {
                let secret = try PasswordVault.readSecret(
                    profileID: profileID, origin: entry.origin, username: entry.username)
                draft = PasswordDraft(
                    original: entry, title: entry.title, website: entry.origin, username: entry.username,
                    password: secret.password, notes: secret.notes)
            } else {
                draft = PasswordDraft()
            }
        } catch { self.error = "couldn’t open this password." }
    }
    func saveDraft() {
        guard unlocked, !privateMode, let draft, draft.valid, let origin = PasswordImport.origin(draft.website) else {
            return
        }
        do {
            try PasswordVault.save(
                PasswordOffer(
                    profileID: profileID, origin: origin, username: draft.username, password: draft.password,
                    title: draft.title, notes: draft.notes), replaceExisting: draft.original != nil)
            self.draft = nil
            refresh()
            selectedID = origin + "\n" + draft.username
            status = "password saved"
        } catch let failure as NSError
            where failure.domain == NSOSStatusErrorDomain && failure.code == Int(errSecDuplicateItem)
        {
            error = "this account already exists. edit the saved login instead."
        } catch { self.error = "couldn’t save this password." }
    }
    func delete(_ entry: PasswordEntry) {
        guard unlocked, !privateMode, entries.contains(where: { $0.id == entry.id }) else { return }
        do {
            try PasswordVault.delete(entry, profileID: profileID)
            hide()
            refresh()
            status = "password deleted"
        } catch { self.error = "couldn’t delete this password." }
    }
    func chooseImport() {
        guard unlocked, !privateMode, !busy else { return }
        let token = generation
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "review import"
        panel.title = "import passwords"
        panel.message = "Choose a passwords CSV."
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url, self.generation == token, self.unlocked else {
                return
            }
            self.loadImport(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    func loadImport(_ url: URL) {
        guard unlocked, !privateMode, !busy else { return }
        let token = generation
        busy = true
        error = nil
        importTask = Task { [weak self] in
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: PasswordImport.maximumBytes + 1) ?? Data()
                    return try PasswordImport.parse(data)
                }.value
                guard let self, !Task.isCancelled, self.generation == token, self.unlocked else { return }
                self.busy = false
                self.review = review
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.busy = false
                self.error =
                    (error as? PasswordImportError)?.errorDescription ?? "couldn’t open this CSV. nothing was imported."
            }
        }
    }
    func commitImport(replaceExisting: Bool) {
        guard unlocked, !privateMode, !busy, let review else { return }
        let token = generation
        let profile = profileID
        busy = true
        error = nil
        self.review = nil
        importTask = Task { [weak self] in
            var saved = 0
            var skipped = 0
            var failed = 0
            for (index, entry) in review.entries.enumerated() {
                guard let self, !Task.isCancelled, self.generation == token, self.unlocked, self.profileID == profile
                else { return }
                do {
                    try PasswordVault.save(
                        PasswordOffer(
                            profileID: profile, origin: entry.origin, username: entry.username,
                            password: entry.password, title: entry.title, notes: entry.notes),
                        replaceExisting: replaceExisting)
                    saved += 1
                } catch let failure as NSError
                    where failure.domain == NSOSStatusErrorDomain && failure.code == Int(errSecDuplicateItem)
                { skipped += 1 } catch { failed += 1 }
                if index % 16 == 0 { await Task.yield() }
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.busy = false
            self.refresh()
            self.status =
                "\(saved) imported · \(skipped) already saved" + (failed > 0 ? " · \(failed) couldn’t be saved" : "")
            if failed > 0 {
                self.error =
                    "some accounts couldn’t be saved. you can retry the import; existing accounts are skipped by default."
            }
        }
    }
}

@MainActor enum PasswordClipboard {
    private static var ownedChange: Int?
    private static var ownedBoard: NSPasteboard?
    private static var expiry: Task<Void, Never>?
    static func copy(_ password: String, pasteboard: NSPasteboard = .general, lifetime: Duration = .seconds(30)) {
        clearIfOwned()
        let item = NSPasteboardItem()
        item.setString(password, forType: .string)

        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        let board = pasteboard
        ownedBoard = board
        board.prepareForNewContents(with: .currentHostOnly)
        board.writeObjects([item])
        ownedChange = board.changeCount
        expiry = Task {
            do {
                try await Task.sleep(for: lifetime)
                clearIfOwned()
            } catch {}
        }
    }
    static func clearIfOwned() {
        expiry?.cancel()
        if let ownedChange, let board = ownedBoard, board.changeCount == ownedChange { board.clearContents() }
        ownedChange = nil
        ownedBoard = nil
    }
}

import AppKit
import AuthenticationServices
import SwiftUI

struct PasswordSettingsView: View {
    @ObservedObject var store: BrowserStore
    @StateObject private var vault: PasswordManager
    @State private var deletion: PasswordEntry?
    init(store: BrowserStore, vault: PasswordManager? = nil) {
        self.store = store
        _vault = StateObject(
            wrappedValue: vault
                ?? PasswordManager(profileID: store.selectedProfileID, privateMode: store.profile.privateMode))
    }
    var body: some View {
        Group {
            Section {
                PasswordVaultPanel(vault: vault, profileName: store.profile.name, requestDelete: { deletion = $0 })
                if let error = vault.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let status = vault.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.id("saved-passwords")
            Section("autofill") {
                Toggle("offer to save login passwords", isOn: $store.preferences.savePasswords).id("save-passwords")
                    .onChange(of: store.preferences.savePasswords) { _, _ in store.applyPasswordPreference() }
                Toggle(
                    "suggest saved logins",
                    isOn: Binding(
                        get: { store.preferences.autofillPasswords != false },
                        set: {
                            store.preferences.autofillPasswords = $0
                            store.applyPasswordPreference()
                            store.persistSoon()
                        })
                ).id("autofill")
                Text(
                    "fills require macOS authentication and stay on the exact HTTPS site. loaf never submits a form. changes apply to newly loaded pages."
                ).font(.caption).foregroundStyle(.secondary)
            }

        }
        .onAppear { vault.configure(profileID: store.selectedProfileID, privateMode: store.profile.privateMode) }
        .onChange(of: store.selectedProfileID) { _, id in
            deletion = nil
            vault.configure(profileID: id, privateMode: store.profile.privateMode)
        }
        .onChange(of: store.profile.privateMode) { _, mode in
            deletion = nil
            vault.configure(profileID: store.selectedProfileID, privateMode: mode)
        }
        .onDisappear { vault.lock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            vault.applicationDidResignActive()
            deletion = nil
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
        { _ in
            vault.lock()
            deletion = nil
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            vault.lock()
            deletion = nil
        }
        .sheet(item: $vault.draft, onDismiss: { vault.draft = nil }) { _ in PasswordEditorView(vault: vault) }
        .sheet(isPresented: Binding(get: { vault.review != nil }, set: { if !$0 { vault.review = nil } })) {
            PasswordImportView(vault: vault)
        }
        .confirmationDialog(
            "delete this saved login?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("delete password", role: .destructive) {
                if let deletion { vault.delete(deletion) }
                deletion = nil
            }
        } message: {
            if let deletion { Text(deletion.username + "\n" + deletion.origin) }
        }
    }
}

struct PasswordVaultPanel: View {
    @ObservedObject var vault: PasswordManager
    let profileName: String
    var requestDelete: (PasswordEntry) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                GolzheimIcon(icon: .key, size: 18)
                Text("saved passwords").font(.system(size: 14, weight: .medium))
                Text(profileName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if vault.busy { ProgressView().controlSize(.small).accessibilityLabel("importing passwords") }
                if vault.unlocked {
                    IconButton(icon: .download, label: "import passwords from CSV") { vault.chooseImport() }.disabled(
                        vault.busy)
                    IconButton(icon: .plus, label: "add a password") { vault.edit() }.disabled(vault.busy)
                    IconButton(icon: .lock, label: "lock passwords") { vault.lock() }
                }
            }
            if !vault.unlocked {
                locked
            } else {
                HStack(spacing: 7) {
                    GolzheimIcon(icon: .search, size: 13).foregroundStyle(.secondary)
                    TextField("search passwords", text: $vault.search).textFieldStyle(.plain).font(.system(size: 12))
                    if !vault.search.isEmpty { IconButton(icon: .close, label: "clear search") { vault.search = "" } }
                    Text("\(vault.filtered.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(.horizontal, 9).frame(height: 32).background(
                    Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                if vault.entries.isEmpty {
                    empty
                } else {
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(vault.filtered) { entry in
                                    Button {
                                        vault.select(entry)
                                    } label: {
                                        HStack(spacing: 9) {
                                            PasswordSiteMark(title: entry.displayTitle, size: 27)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(entry.displayTitle).font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                                Text(entry.username).font(.system(size: 10)).foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                Color.primary.opacity(vault.selectedID == entry.id ? 0.075 : 0),
                                                in: RoundedRectangle(cornerRadius: 7)
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).accessibilityLabel(entry.displayTitle + ", " + entry.username)
                                        .accessibilityAddTraits(vault.selectedID == entry.id ? [.isSelected] : [])
                                }
                                if vault.filtered.isEmpty {
                                    Text("no matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
                                }
                            }.padding(.trailing, 10)
                        }.frame(width: 190)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                        if let entry = vault.selected, vault.filtered.contains(where: { $0.id == entry.id }) {
                            details(entry).padding(.leading, 20)
                        } else {
                            Text("select a login").font(.system(size: 12)).foregroundStyle(.secondary).frame(
                                maxWidth: .infinity)
                        }
                    }.frame(height: 290)
                }
                HStack(spacing: 6) {
                    GolzheimIcon(icon: .shield, size: 12)
                    Text("local Keychain · locks after 5 minutes or when loaf loses focus").font(.system(size: 10))
                }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 4)
    }
    private var locked: some View {
        VStack(spacing: 13) {
            GolzheimIcon(icon: vault.privateMode ? .privateMode : .lock, size: 36).foregroundStyle(.secondary)
            VStack(spacing: 5) {
                Text(vault.privateMode ? "passwords aren’t available in private mode" : "your passwords are locked")
                    .font(.system(size: 14, weight: .medium))
                Text(
                    vault.privateMode
                        ? "switch to a regular profile to manage saved logins."
                        : "unlock with Touch ID or your Mac password."
                ).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !vault.privateMode {
                Button(vault.authenticating ? "unlocking…" : "unlock passwords") { Task { await vault.unlock() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(vault.authenticating)
                Text("import a passwords CSV after unlocking").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }.frame(maxWidth: .infinity).frame(height: 240)
    }
    private var empty: some View {
        VStack(spacing: 13) {
            GolzheimIcon(icon: .key, size: 34).foregroundStyle(.secondary)
            Text("no saved passwords yet").font(.system(size: 14, weight: .medium))
            Text("import your saved logins from a CSV,\nor add an account here.").font(.system(size: 12))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("import CSV…") { vault.chooseImport() }.buttonStyle(.borderedProminent)
                Button("add password") { vault.edit() }
            }.disabled(vault.busy)
        }.frame(maxWidth: .infinity).frame(height: 245)
    }
    private func details(_ entry: PasswordEntry) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top, spacing: 10) {
                PasswordSiteMark(title: entry.displayTitle, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayTitle).font(.system(size: 16, weight: .medium)).lineLimit(2)
                    Text(entry.origin).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("username").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(entry.username).font(.system(size: 12)).textSelection(.enabled).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("password").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(vault.revealed ?? "••••••••••••").font(.system(size: 12, design: .monospaced)).textSelection(
                        .enabled
                    ).lineLimit(2)
                        .accessibilityLabel(vault.revealed == nil ? "password hidden" : "revealed password")
                    Spacer(minLength: 4)
                    IconButton(
                        icon: vault.revealed == nil ? .eye : .privateMode,
                        label: vault.revealed == nil ? "reveal password for 30 seconds" : "hide password"
                    ) { vault.reveal(entry) }
                    IconButton(icon: .copy, label: "copy password for 30 seconds") { vault.copy(entry) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button {
                    vault.edit(entry)
                } label: {
                    HStack(spacing: 5) {
                        GolzheimIcon(icon: .edit, size: 12)
                        Text("edit")
                    }
                }
                Spacer()
                IconButton(icon: .trash, label: "delete saved login") { requestDelete(entry) }
            }.disabled(vault.busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.vertical, 7)
    }
}

struct PasswordSiteMark: View {
    let title: String
    let size: CGFloat
    var body: some View {
        Text(String(title.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .medium, design: .rounded))
            .frame(width: size, height: size).background(
                Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: size * 0.24)
            ).accessibilityHidden(true)
    }
}

private struct PasswordEditorView: View {
    @ObservedObject var vault: PasswordManager
    @State private var showing = false
    @State private var length = 24
    @State private var symbols = true
    private func value(_ key: WritableKeyPath<PasswordDraft, String>) -> Binding<String> {
        Binding(get: { vault.draft?[keyPath: key] ?? "" }, set: { vault.draft?[keyPath: key] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                GolzheimIcon(icon: .key, size: 22)
                Text(vault.draft?.original == nil ? "add a password" : "edit password").font(
                    .system(size: 18, weight: .medium))
            }
            Form {
                TextField("title", text: value(\.title), prompt: Text("optional"))
                TextField("website", text: value(\.website)).disabled(vault.draft?.original != nil)
                TextField("username", text: value(\.username)).disabled(vault.draft?.original != nil)
                LabeledContent("password") {
                    HStack(spacing: 5) {
                        Group {
                            if showing {
                                TextField("password", text: value(\.password))
                            } else {
                                SecureField("password", text: value(\.password))
                            }
                        }.labelsHidden().accessibilityLabel("password")
                        IconButton(
                            icon: showing ? .privateMode : .eye, label: showing ? "hide password" : "show password"
                        ) { showing.toggle() }
                    }
                }
                LabeledContent("generate") {
                    HStack(spacing: 7) {
                        Picker("length", selection: $length) {
                            ForEach([16, 20, 24, 32, 48, 64], id: \.self) { Text("\($0)").tag($0) }
                        }.labelsHidden().frame(width: 70).accessibilityLabel("password length")
                        Toggle("symbols", isOn: $symbols).toggleStyle(.checkbox)
                        Button {
                            do {
                                vault.draft?.password = try PasswordGenerator.generate(length: length, symbols: symbols)
                            } catch { vault.error = "couldn’t generate a password." }
                        } label: {
                            HStack(spacing: 5) {
                                GolzheimIcon(icon: .dice, size: 14)
                                Text("generate")
                            }
                        }
                    }
                }
                TextField("notes", text: value(\.notes), axis: .vertical).lineLimit(3...5)
            }.textFieldStyle(.roundedBorder)
            Text("use an HTTPS website. login matching includes its full host and port.").font(.caption)
                .foregroundStyle(.secondary)
            if let error = vault.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("cancel") { vault.draft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("save password") { vault.saveDraft() }.buttonStyle(.borderedProminent).keyboardShortcut(
                    .defaultAction
                ).disabled(vault.draft?.valid != true || !vault.unlocked)
            }
        }.padding(26).frame(width: 485)
            .onAppear { vault.error = nil }
            .task(id: showing) {
                guard showing else { return }
                do {
                    try await Task.sleep(for: .seconds(30))
                    showing = false
                } catch {}
            }
    }
}

private struct PasswordImportView: View {
    @ObservedObject var vault: PasswordManager
    @State private var replace = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                GolzheimIcon(icon: .download, size: 24)
                Text("import passwords").font(.system(size: 18, weight: .medium))
            }
            if let review = vault.review {
                Text("\(review.entries.count) accounts ready for this profile").font(.system(size: 13, weight: .medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(review.entries) { entry in
                            HStack(spacing: 10) {
                                PasswordSiteMark(
                                    title: entry.title.isEmpty ? entry.origin.dropFirst(8).description : entry.title,
                                    size: 27)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.origin).font(.system(size: 12))
                                    Text(entry.username).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }.padding(12)
                }.frame(height: 200).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    if review.skipped > 0 {
                        Text("\(review.skipped) invalid, insecure or conflicting accounts excluded")
                    }
                    if review.duplicates > 0 { Text("\(review.duplicates) duplicate rows removed") }
                    if review.unsupportedCodes > 0 { Text("\(review.unsupportedCodes) verification codes excluded") }
                    if review.conflicting > 0 {
                        Text("conflicting copies of an account are excluded; resolve them in the source CSV.")
                    }
                    Text("passkeys aren’t included in password exports.")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if vault.matchingImportCount > 0 {
                    Toggle("replace \(vault.matchingImportCount) matching saved accounts", isOn: $replace).toggleStyle(
                        .checkbox)
                    Text(
                        replace
                            ? "their passwords, titles and notes will be replaced."
                            : "existing accounts will be skipped."
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    "the CSV contains readable passwords. delete the export after importing. loaf doesn’t keep a copy or sync with iCloud."
                ).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("cancel") { vault.review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(
                        "import \(replace ? review.entries.count : review.entries.count - vault.matchingImportCount) accounts"
                    ) { vault.commitImport(replaceExisting: replace) }.buttonStyle(.borderedProminent).keyboardShortcut(
                        .defaultAction
                    ).disabled(review.entries.isEmpty || !vault.unlocked)
                }
            }
        }.padding(26).frame(width: 490)
    }
}

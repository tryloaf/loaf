import SwiftUI
import UniformTypeIdentifiers

struct ProfileImportView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        ? "choose a profile folder or an exported file. you’ll see what’s inside before importing."
                        : step == 1
                            ? "choose what to bring into loaf. your source data stays where it is."
                            : "your selected data is saved in this profile."
                ).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if step == 0 {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("history, bookmarks and readable cookies", systemImage: "tray.and.arrow.down").font(
                            .system(size: 13))
                        Text(
                            "select a profile folder, loaf session JSON, bookmarks HTML or JSON, or cookies JSON. close the source app first. protected folders may require Full Disk Access in macOS System Settings."
                        ).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("choose data…") { chooseSource() }.controlSize(.large).disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(
                        Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
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
                        Toggle("create a new profile", isOn: $newProfile).disabled(store.profiles.count >= 8)
                        if newProfile {
                            TextField("profile name", text: $name).textFieldStyle(.roundedBorder)
                        } else {
                            Text("importing into \(store.profile.name)").font(.system(size: 12)).foregroundStyle(
                                .secondary)
                        }
                        Divider()
                        importRow(
                            "history",
                            detail:
                                "\(preview.history.count.formatted()) \(preview.history.count == 1 ? "visit" : "visits")",
                            icon: "clock", selection: $history, enabled: !preview.history.isEmpty)
                        importRow(
                            "bookmarks",
                            detail:
                                "\(preview.bookmarks.count.formatted()) \(preview.bookmarks.count == 1 ? "bookmark" : "bookmarks")",
                            icon: "star", selection: $bookmarks, enabled: !preview.bookmarks.isEmpty)
                        importRow(
                            "cookies",
                            detail:
                                "\(preview.cookies.count.formatted()) readable \(preview.cookies.count == 1 ? "cookie" : "cookies")",
                            icon: "circle.dotted", selection: $cookies, enabled: !preview.cookies.isEmpty)
                        if cookies {
                            Text("cookies can keep you signed in to websites in this profile.").font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(preview.warnings, id: \.self) {
                            Text($0).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.disabled(busy)
                } else if step == 2 {
                    Label("ready in \(store.profile.name)", systemImage: "checkmark.circle.fill").font(
                        .system(size: 16)
                    ).foregroundStyle(profileTint(store.profile)).padding(.vertical, 24)
                }
            }.transition(.opacity)
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
        }.padding(32).frame(width: 520, height: 620).background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(busy).onAppear { newProfile = store.profiles.count < 8 }
    }
    private var canImport: Bool {
        guard let preview else { return false }
        return (!newProfile || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (history && !preview.history.isEmpty || bookmarks && !preview.bookmarks.isEmpty
                || cookies && !preview.cookies.isEmpty)
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
    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "choose a profile folder or browsing-data export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
                previews = result
                selected = 0
                name = result[0].name
                cookies = false
                history = !result[0].history.isEmpty
                bookmarks = !result[0].bookmarks.isEmpty
                transition(to: 1)
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
                try await store.importProfile(
                    preview, name: name, newProfile: newProfile, history: history, bookmarks: bookmarks,
                    cookies: cookies)
                transition(to: 2)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

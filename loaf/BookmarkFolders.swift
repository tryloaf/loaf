import AppKit
import SwiftUI

nonisolated struct BookmarkFolder: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
}

extension BrowserWindowState {
    func deleteBookmarkFolder(_ id: UUID) {
        updateCurrent { profile in
            profile.bookmarkFolders?.removeAll { $0.id == id }
            for index in profile.favorites.indices where profile.favorites[index].folderID == id {
                profile.favorites[index].folderID = nil
            }
        }
    }
    func nameBookmarkFolder(_ id: UUID? = nil) {
        let profileID = selectedProfileID
        let alert = NSAlert()
        alert.messageText = id == nil ? "new bookmarks folder" : "rename folder"
        let field = NSTextField(string: profile.bookmarkFolders?.first { $0.id == id }?.name ?? "")
        field.placeholderString = "folder name"
        field.frame.size = CGSize(width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "save")
        alert.addButton(withTitle: "cancel")
        application.coordinator?.alert(alert, for: self) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, self.selectedProfileID == profileID, response == .alertFirstButtonReturn, !name.isEmpty
            else { return }
            self.updateCurrent { profile in
                if let id {
                    if let index = profile.bookmarkFolders?.firstIndex(where: { $0.id == id }) {
                        profile.bookmarkFolders?[index].name = String(name.prefix(80))
                    }
                } else {
                    profile.bookmarkFolders =
                        (profile.bookmarkFolders ?? []) + [BookmarkFolder(name: String(name.prefix(80)))]
                }
            }
        }
    }
    func moveBookmark(_ id: UUID, to folderID: UUID?) {
        guard folderID == nil || profile.bookmarkFolders?.contains(where: { $0.id == folderID }) == true else { return }
        updateCurrent { profile in
            if let index = profile.favorites.firstIndex(where: { $0.id == id }) {
                profile.favorites[index].folderID = folderID
            }
        }
    }
}

struct BookmarkFolderBar: View {
    @ObservedObject var store: BrowserStore
    @Binding var selectedID: UUID?
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    selectedID = nil
                } label: {
                    Label("favorites", systemImage: "star")
                }
                ForEach(store.profile.bookmarkFolders ?? []) { folder in
                    Button {
                        selectedID = folder.id
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            } label: {
                Label(
                    store.profile.bookmarkFolders?.first { $0.id == selectedID }?.name ?? "favorites",
                    systemImage: selectedID == nil ? "star" : "folder")
            }
            Spacer()
            if let selectedID {
                Button {
                    store.nameBookmarkFolder(selectedID)
                } label: {
                    Label("rename", systemImage: "pencil")
                }
                Button {
                    store.deleteBookmarkFolder(selectedID)
                    self.selectedID = nil
                } label: {
                    Label("delete folder", systemImage: "trash")
                }
                .help("moves this folder’s bookmarks to favorites")
            }
            Button {
                store.nameBookmarkFolder()
            } label: {
                Label("new folder", systemImage: "folder.badge.plus")
            }
        }.controlSize(.small).padding(.horizontal, 28).padding(.vertical, 10)
    }
}

struct BookmarkDraft: Identifiable {
    let id = UUID()
    let profileID: UUID
    var title = ""
    var address = ""
    var folderID: UUID?
}

extension BrowserWindowState {
    func editBookmark(tab: BrowserTab? = nil, folderID: UUID? = nil) {
        guard folderID == nil || profile.bookmarkFolders?.contains(where: { $0.id == folderID }) == true else { return }
        if let tab {
            guard tab.store === self, !tab.isDisposed, tab.profileID == selectedProfileID, let url = tab.url,
                ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil
            else { return }
            let existing = profile.favorites.first {
                Self.bookmarkURL($0.address) == Self.bookmarkURL(url.absoluteString)
            }
            bookmarkDraft = BookmarkDraft(
                profileID: selectedProfileID, title: existing?.title ?? tab.sidebarTitle,
                address: url.absoluteString, folderID: existing?.folderID ?? folderID)
        } else {
            bookmarkDraft = BookmarkDraft(profileID: selectedProfileID, folderID: folderID)
        }
    }
    static func bookmarkURL(_ address: String) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let explicit = text.contains("://")
        guard let url = URL(string: explicit ? text : "https://" + text),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, (explicit || host.contains(".") || BrowserAddress.isLocalHost(host)),
            url.user == nil, url.password == nil, url.port.map({ (1...65535).contains($0) }) != false
        else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.path.isEmpty { components.path = "/" }
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        return components.url
    }
    @discardableResult func saveBookmark(title: String, address: String, folderID: UUID?, profileID: UUID) -> Bool {
        guard profileID == selectedProfileID, profiles.contains(where: { $0.id == profileID }),
            folderID == nil || profile.bookmarkFolders?.contains(where: { $0.id == folderID }) == true,
            let url = Self.bookmarkURL(address),
            ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil
        else { return false }
        let name = String(
            title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).prefix(200))
        updateCurrent { profile in
            if let index = profile.favorites.firstIndex(where: { Self.bookmarkURL($0.address) == url }) {
                profile.favorites[index].address = url.absoluteString
                profile.favorites[index].title = name.isEmpty ? url.host ?? url.absoluteString : name
                profile.favorites[index].folderID = folderID
            } else {
                profile.favorites.append(
                    Favorite(
                        title: name.isEmpty ? url.host ?? url.absoluteString : name, address: url.absoluteString,
                        folderID: folderID))
            }
        }
        return true
    }
}

struct BookmarkEditor: View {
    @ObservedObject var store: BrowserStore
    @State var draft: BookmarkDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("save bookmark").font(.system(size: 18, weight: .medium))
            Form {
                TextField("address", text: $draft.address).focused($addressFocused)
                TextField("name", text: $draft.title)
                Picker("folder", selection: $draft.folderID) {
                    Text("favorites").tag(Optional<UUID>.none)
                    ForEach(store.profile.bookmarkFolders ?? []) { folder in Text(folder.name).tag(Optional(folder.id))
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("save") {
                    if store.saveBookmark(
                        title: draft.title, address: draft.address, folderID: draft.folderID, profileID: draft.profileID
                    ) {
                        dismiss()
                    } else {
                        error = "enter a valid website address and choose an existing folder"
                    }
                }.keyboardShortcut(.defaultAction).disabled(
                    draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420).onAppear { addressFocused = true }
    }
}

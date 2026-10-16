import CoreText
import SwiftUI
import UniformTypeIdentifiers

struct PersonalIcon: Identifiable {
    let glyph: String
    let name: String
    let category: String
    let searchEntry: IconVocabulary.Entry
    init(glyph: String, name: String, category: String) {
        self.glyph = glyph
        self.name = name
        self.category = category
        searchEntry = IconVocabulary.Entry(glyph: glyph, unicodeName: name + " " + category)
    }
    var id: String { glyph }
    var searchTerms: String {
        searchEntry.searchTerms
    }
    static func eligible(_ scalar: UnicodeScalar) -> Bool {
        let code = scalar.value
        let name = scalar.properties.name ?? ""
        if [0xA9, 0xAE].contains(code) || (0x2100...0x214F).contains(code) || name.contains("ARROW")
            || name.contains("DOLLAR SIGN") || (0x1F100...0x1F2FF).contains(code)
        {
            return false
        }

        if (0x2460...0x2473).contains(code) || (0x24EA...0x24FF).contains(code) || (0x2776...0x2793).contains(code) {
            return true
        }
        if (0x25A0...0x25FF).contains(code) { return true }
        guard [.otherSymbol].contains(scalar.properties.generalCategory) else { return false }
        return scalar.properties.isEmoji || (0x2600...0x27BF).contains(code) && !(0x2794...0x27BF).contains(code)
    }
    static let catalog: [PersonalIcon] = {
        guard let font = Golzheim.iconFont(size: 20) else { return [] }
        let characters = CTFontCopyCharacterSet(font)
        var result: [PersonalIcon] = []
        for code in Array(0x21...0x7E) + Array(0xA1...0xFF) + Array(0x2000...0x2BFF) + Array(0x1F000...0x1FFFF) {
            guard let scalar = UnicodeScalar(code), CFCharacterSetIsLongCharacterMember(characters, UInt32(code)) else {
                continue
            }
            guard eligible(scalar) else { continue }
            let glyph = String(scalar)

            let group: String
            switch code {
            case 0x1F600...0x1F64F, 0x1F900...0x1F92F: group = "faces"
            case 0x1F330...0x1F43F: group = "nature"
            case 0x1F300...0x1F32F, 0x2600...0x2604: group = "weather"
            case 0x1F440...0x1F4FF: group = "people & objects"
            case 0x1F680...0x1F6FF: group = "places & transport"
            case 0x1F000...0x1FFFF: group = "objects & activities"
            default: group = "symbols"
            }
            result.append(
                PersonalIcon(
                    glyph: glyph, name: scalar.properties.name?.lowercased() ?? "symbol \(code)", category: group))
        }
        let order = [
            "faces", "nature", "weather", "people & objects", "places & transport", "objects & activities", "symbols",
        ]
        return result.sorted {
            let left = order.firstIndex(of: $0.category) ?? order.count
            let right = order.firstIndex(of: $1.category) ?? order.count
            return left == right ? $0.glyph < $1.glyph : left < right
        }
    }()
}
struct GolzheimPicker: View {
    @Binding var selection: String
    var gridHeight: CGFloat = 240
    @State private var query = ""
    @State private var category = "all"
    private var categories: [String] { ["all"] + Set(PersonalIcon.catalog.map(\.category)).sorted() }
    private var filtered: [PersonalIcon] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PersonalIcon.catalog.filter { category == "all" || $0.category == category }
        }
        return PersonalIcon.catalog.compactMap { icon -> (PersonalIcon, Int)? in
            guard category == "all" || icon.category == category,
                let score = icon.searchEntry.score(query: query)
            else { return nil }
            return (icon, score)
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.map(\.0)
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("search icons", text: $query).textFieldStyle(.roundedBorder)
                Picker("category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 160)
            }
            FocusRingSafeScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 48))], spacing: 8) {
                    ForEach(filtered) { icon in
                        Button {
                            selection = icon.glyph
                        } label: {
                            EmojiIcon(glyph: icon.glyph, size: 28).frame(width: 40, height: 40).background(
                                selection == icon.glyph
                                    ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(LoafButtonStyle()).help(icon.name).accessibilityLabel(icon.name)
                    }
                }
            }.frame(height: gridHeight)
            Text("\(filtered.count) available icons").font(.caption).foregroundStyle(.secondary)
            if !Golzheim.available { Text("personalization icon font unavailable").foregroundStyle(.secondary) }
        }
    }
}
struct ProfileEditor: View {
    @ObservedObject var store: BrowserStore
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "🌱"
    @State private var customIconPNG: Data?
    @State private var choosingIcon = false
    @State private var importingIcon = false
    @State private var iconError: String?
    @State private var tint = 0
    @State private var strength = 0.06
    @State private var transparency = 0.0
    @State private var privateUsesProfileColor = false
    @State private var customTint: ProfileColor?
    @State private var confirmDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProfileIcon(glyph: icon, customIconPNG: customIconPNG, size: 32)
                TextField("profile name", text: $name).font(.system(size: 24)).textFieldStyle(.plain)
                Spacer()
            }
            FocusRingSafeScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.profileFor(profileID).privateMode {
                        Toggle("use profile color in private browsing", isOn: $privateUsesProfileColor)
                        Text("appearance changes last until this private session ends.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProfileThemeControls(
                        tint: $tint, customTint: $customTint, strength: $strength, transparency: $transparency)
                    Divider()
                    Text("profile icon").fontWeight(.medium)
                    HStack {
                        Button(customIconPNG == nil ? "import PNG or SVG…" : "replace image…") {
                            choosingIcon = true
                        }
                        if customIconPNG != nil {
                            Button("remove image") { customIconPNG = nil }
                        }
                        if importingIcon { ProgressView().controlSize(.small) }
                    }.disabled(importingIcon)
                    if let iconError { Text(iconError).font(.callout).foregroundStyle(.red) }
                    GolzheimPicker(
                        selection: Binding(
                            get: { icon },
                            set: {
                                icon = $0
                                customIconPNG = nil
                                iconError = nil
                            })
                    ).disabled(importingIcon)
                }
            }.frame(maxHeight: 580)
            if let deletionError { Text(deletionError).font(.callout).foregroundStyle(.red) }
            HStack {
                if !store.profileFor(profileID).privateMode {
                    Button("delete profile…", role: .destructive) { confirmDeletion = true }
                        .disabled(!store.application.canDeleteProfile(profileID))
                        .help(
                            store.application.canDeleteProfile(profileID)
                                ? "delete this profile and its local browsing data"
                                : "keep at least one regular profile"
                        )

                        .tint(.red)
                }
                if deleting { ProgressView().controlSize(.small) }
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("save") {
                    store.updateProfile(profileID) {
                        $0.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                        $0.emoji = icon
                        $0.customIconPNG = customIconPNG
                        $0.tint = tint
                        $0.personalization = $0.personalization ?? Personalization()
                        $0.personalization?.tintStrength = ProfileColor.surfaceStrength(strength)
                        $0.personalization?.customTint = customTint
                        $0.personalization?.privateUsesProfileColor = privateUsesProfileColor
                        $0.personalization?.windowTransparency = ProfileTransparency.bounded(transparency)
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
                    importingIcon || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.disabled(deleting).padding(24).frame(width: 520).interactiveDismissDisabled(deleting)
            .fileImporter(isPresented: $choosingIcon, allowedContentTypes: [.png, .svg]) { result in
                guard case .success(let url) = result else {
                    if case .failure(let error) = result { iconError = error.localizedDescription }
                    return
                }
                importingIcon = true
                iconError = nil
                Task { @MainActor in
                    defer { importingIcon = false }
                    do { customIconPNG = try await ProfileIconAsset.importPNG(from: url) } catch {
                        iconError =
                            "Couldn’t read this icon. Use a PNG up to 1 MB or a self-contained SVG up to 128 KB."
                    }
                }
            }
            .destructiveConfirmationDialog(
                "delete \(store.profileFor(profileID).name)?", isPresented: $confirmDeletion, titleVisibility: .visible
            ) {
                Button("delete profile", role: .destructive) {
                    deleting = true
                    Task {
                        do {
                            try await store.application.deleteProfile(profileID)
                            dismiss()
                        } catch {
                            if store.application.profiles.contains(where: { $0.id == profileID }) {
                                deletionError = error.localizedDescription
                            } else {
                                store.error =
                                    "The profile was deleted, but some data cleanup is pending: \(error.localizedDescription)"
                                dismiss()
                            }
                        }
                        deleting = false
                    }
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text(
                    (store.application.cloudSync.enabled
                        ? "Deleting this synced profile also removes it from your other syncing Macs. " : "")
                        + "This deletes this profile’s tabs, history, bookmarks, cookies, saved passwords, and extensions from this Mac. It cannot be undone. Downloaded files stay where they are."
                )
            }.onAppear {
                let profile = store.profileFor(profileID)
                name = profile.name
                icon = profile.emoji
                customIconPNG = profile.customIconPNG
                tint = profile.tint
                strength = profile.personalization?.tintStrength ?? 0.06
                customTint = profile.personalization?.customTint
                privateUsesProfileColor = profile.personalization?.privateUsesProfileColor == true
                transparency = ProfileTransparency.bounded(profile.personalization?.windowTransparency ?? 0)
            }
    }
}

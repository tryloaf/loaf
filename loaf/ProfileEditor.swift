import CoreText
import SwiftUI

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
        guard let font = Golzheim.font else { return [] }
        let characters = CTFontCopyCharacterSet(CTFontCreateWithName(font.fontName as CFString, 20, nil))
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
            ScrollView {
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
    @State private var tint = 0
    @State private var strength = 0.06
    @State private var transparency = 0.0
    @State private var customTint: ProfileColor?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                EmojiIcon(glyph: icon, size: 32)
                TextField("profile name", text: $name).font(.system(size: 24)).textFieldStyle(.plain)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProfileThemeControls(
                        tint: $tint, customTint: $customTint, strength: $strength, transparency: $transparency)
                    Divider()
                    Text("profile icon").fontWeight(.medium)
                    GolzheimPicker(selection: $icon)
                }
            }.frame(maxHeight: 580)
            HStack {
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("save") {
                    store.updateProfile(profileID) {
                        $0.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                        $0.emoji = icon
                        $0.tint = tint
                        $0.personalization = $0.personalization ?? Personalization()
                        $0.personalization?.tintStrength = ProfileColor.surfaceStrength(strength)
                        $0.personalization?.customTint = customTint
                        $0.personalization?.windowTransparency = ProfileTransparency.bounded(transparency)
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520).onAppear {
            let profile = store.profileFor(profileID)
            name = profile.name
            icon = profile.emoji
            tint = profile.tint
            strength = profile.personalization?.tintStrength ?? 0.06
            customTint = profile.personalization?.customTint
            transparency = ProfileTransparency.bounded(profile.personalization?.windowTransparency ?? 0)
        }
    }
}

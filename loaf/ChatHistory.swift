import SwiftUI

nonisolated struct ChatHistorySection: Identifiable {
    let id: String
    let chats: [SavedChat]
    static func sections(_ chats: [SavedChat], profileID: UUID, query: String, now: Date = .now, calendar: Calendar = .current) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let filtered = chats.filter {
            $0.profileID == profileID && (query.isEmpty || $0.turns.contains { $0.query.localizedStandardContains(query) })
        }.sorted { $0.updatedAt > $1.updatedAt }
        return [
            Self(id: "today", chats: filtered.filter { $0.updatedAt >= today }),
            Self(id: "yesterday", chats: filtered.filter { $0.updatedAt >= yesterday && $0.updatedAt < today }),
            Self(id: "earlier", chats: filtered.filter { $0.updatedAt < yesterday }),
        ].filter { !$0.chats.isEmpty }
    }
}

struct SavedChatHistory: View {
    @ObservedObject var archive: ChatArchive
    let profileID: UUID
    let selectedID: UUID
    let open: (SavedChat) -> Void
    let delete: (SavedChat) -> Void
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GolzheimIcon(icon: .search, size: 14).foregroundStyle(.secondary)
                TextField("search saved chats", text: $query).textFieldStyle(.plain)
            }.padding(14)
            Divider()
            let sections = ChatHistorySection.sections(archive.chats, profileID: profileID, query: query)
            if sections.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "no saved chats" : "no matching chats").fontWeight(.medium)
                    Text(query.isEmpty ? "your conversations will appear here." : "try a different search.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sections) { section in
                            Text(section.id).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 10)
                            ForEach(section.chats) { chat in
                                Button { open(chat) } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(chat.title).lineLimit(2).multilineTextAlignment(.leading)
                                            HStack(spacing: 5) {
                                                Text(chat.updatedAt, style: section.id == "earlier" ? .date : .time)
                                                Text("·")
                                                Text("\(chat.turns.count) \(chat.turns.count == 1 ? "message" : "messages")")
                                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        if chat.id == selectedID { GolzheimIcon(icon: .check, size: 12) }
                                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(chat.id == selectedID ? Color.primary.opacity(0.055) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(LoafButtonStyle())
                                    .contextMenu { Button("delete chat…", role: .destructive) { delete(chat) } }
                            }
                        }
                    }.padding(8)
                }.frame(maxHeight: 380)
            }
        }.font(.system(size: 12)).frame(width: 310)
    }
}

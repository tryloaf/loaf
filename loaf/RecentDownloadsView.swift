import SwiftUI

struct RecentDownloadsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    init(store: BrowserStore) {
        self.store = store
        manager = store.downloads
    }
    var body: some View {
        let items = Array(manager.items.filter { $0.profileID == store.selectedProfileID }.prefix(6))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GolzheimIcon(icon: .download, size: 20)
                Text("recent downloads").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("show all") {
                    dismiss()
                    store.showPage(.downloads)
                }.controlSize(.small)
            }
            if items.isEmpty {
                Text("saved and interrupted downloads appear here").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in DownloadRow(item: item, manager: manager, store: store) }
                    }
                }
                .frame(height: min(320, CGFloat(items.count) * 76)).scrollIndicators(.hidden)
            }
        }.padding(16).frame(width: 360).accessibilityElement(children: .contain).accessibilityLabel(
            "downloads for " + store.profile.name)
    }
}

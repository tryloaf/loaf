import SwiftUI

struct ICloudSyncSettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var sync: ICloudSync
    @State private var confirmRemoval = false
    @State private var confirmCacheReset = false
    init(store: BrowserStore) {
        self.store = store
        sync = store.application.cloudSync
    }
    var body: some View {
        Section("iCloud sync · experimental") {
            Toggle("sync with iCloud", isOn: Binding(
                get: { sync.enabled }, set: { value in Task { await sync.setEnabled(value) } }
            )).disabled(sync.busy && !sync.enabled).id("icloud-sync")
            disclaimers([
                "turn this on in loaf on each Mac signed in to the same Apple Account.",
                "experimental. sync across Macs is still being validated.",
            ])
            HStack(spacing: 8) {
                if sync.busy { ProgressView().controlSize(.small) }
                Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if sync.enabled {
                    Button("sync now") { Task { await sync.refresh() } }.disabled(sync.busy)
                }
            }.accessibilityElement(children: .combine).accessibilityLabel("sync status: " + sync.status)
            if sync.needsCacheRepair {
                Button("reset local sync cache…") { confirmCacheReset = true }.disabled(sync.busy)
            }
            if let date = sync.lastSync, sync.enabled {
                Text("last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("what syncs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("profile names, icons, colors and order; pinned tabs and groups; start-page appearance; and browser preferences.")
                disclaimers([
                    "open website tabs appear below under other Macs. opening one creates a local tab in its profile. closing it here leaves the original tab on the other Mac.",
                    "private profiles, history, bookmarks, passwords, sign-ins, extensions, website permissions, notes, checklists, custom background images and local files stay on this Mac. network opt-ins, location access, download locations and device-specific settings also stay local.",
                    "sync uses your private iCloud database and CloudKit encrypted fields. loaf has no sync account or developer-operated sync server.",
                    "turning sync off keeps your local data and the existing iCloud copy. deleting a synced profile removes it from your other syncing Macs too.",
                ])
                Link("privacy policy", destination: BrowserBrand.website.appendingPathComponent("privacy"))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if sync.enabled {
            Section("other Macs") {
                if sync.otherMacs.isEmpty {
                    Text("tabs from your other Macs appear here once they sync.").foregroundStyle(.secondary)
                }
                ForEach(sync.otherMacs) { mac in
                    DisclosureGroup {
                        if mac.tabs.isEmpty { Text("no open website tabs").font(.caption).foregroundStyle(.secondary) }
                        ForEach(mac.tabs) { tab in
                            Button {
                                guard let address = ICloudSyncProjection.address(tab.address), let url = URL(string: address),
                                    store.application.profiles.contains(where: { $0.id == tab.profileID && !$0.privateMode })
                                else { return }
                                store.newTab(url: url, profileID: tab.profileID, showOmnibar: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tab.title.isEmpty ? tab.address : tab.title).lineLimit(1)
                                    Text((store.application.profiles.first { $0.id == tab.profileID }?.name ?? "profile")
                                         + " · " + BrowserAddress.display(URL(string: tab.address)))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 3)
                                .disabled(!store.application.profiles.contains { $0.id == tab.profileID && !$0.privateMode })
                        }
                    } label: {
                        HStack {
                            Text(mac.name)
                            Spacer()
                            Text(mac.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section("iCloud data") {
            Button("remove loaf data from iCloud…", role: .destructive) { confirmRemoval = true }.disabled(sync.busy || sync.needsCacheRepair)
            Text("removes synced data from iCloud and turns sync off. local profiles, tabs and settings are kept on every Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.confirmationDialog("reset the local sync cache?", isPresented: $confirmCacheReset, titleVisibility: .visible) {
            Button("reset cache") { Task { await sync.resetLocalCache() } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("your local profiles, tabs and settings and the iCloud copy are kept. the old cache is saved as a private backup on this Mac. turn sync on again to reconnect.")
        }.confirmationDialog("remove loaf data from iCloud?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("remove iCloud data", role: .destructive) { Task { await sync.removeCloudData() } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this removes the iCloud copy for all your Macs. each Mac keeps its local data. turn sync on again on a Mac to start a new copy.")
        }
    }

    private func disclaimers(_ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(points, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").accessibilityHidden(true)
                    Text(point).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

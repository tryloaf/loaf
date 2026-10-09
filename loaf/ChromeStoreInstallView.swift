import SwiftUI

struct ChromeStoreInstallView: View {
    @ObservedObject var store: BrowserStore
    let extensionID: String
    @ObservedObject private var manager: ExtensionManager
    init(store: BrowserStore, extensionID: String) {
        self.store = store
        self.extensionID = extensionID
        manager = store.runtime.extensions
    }
    var body: some View {
        let installed = store.profile.extensions.first { $0.storeID == extensionID }
        HStack(spacing: 12) {
            GolzheimIcon(icon: .extensionPuzzle, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(installed == nil ? "chrome web store" : installed!.name).font(.system(size: 12, weight: .medium))
                Text(
                    store.profile.privateMode
                        ? "install in a regular profile"
                        : manager.installing
                            ? "fetching and verifying package…"
                            : installed?.enabled == true
                                ? "installed in " + store.profile.name
                                : installed != nil ? "installed · disabled" : "compatibility varies by extension"
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if installed != nil {
                Button("manage") { store.showPage(.extensions) }.controlSize(.small)
            } else {
                Button("add to loaf") { Task { await manager.installStore(extensionID, owner: store) } }.buttonStyle(
                    .borderedProminent
                ).controlSize(.small).disabled(manager.installing || store.profile.privateMode)
            }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

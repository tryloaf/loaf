import SwiftUI

struct SidebarPerformanceControl: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var monitor: ResourceMonitor
    @State private var presented = false
    init(store: BrowserStore) {
        self.store = store
        _monitor = ObservedObject(wrappedValue: store.application.resources)
    }
    private var gameMode: Bool { store.preferences.gameMode == true }
    private var active: Bool { gameMode || monitor.saverEnabled }
    private var status: String {
        gameMode ? "game mode on" : monitor.saverEnabled ? "power saver on" : "standard"
    }
    private func setting(_ key: WritableKeyPath<BrowserPreferences, Bool?>) -> Binding<Bool> {
        Binding(get: { store.preferences[keyPath: key] == true }, set: { value in
            store.preferences[keyPath: key] = value
            store.persistSoon()
        })
    }
    var body: some View {
        Button { presented.toggle() } label: {
            GolzheimIcon(icon: monitor.saverEnabled ? .powerSaver : .gameMode, size: 16, weight: 160)
                .foregroundStyle(active ? profileTint(store.profile) : Color.secondary)
                .frame(width: 26, height: 28)
                .background(Color.primary.opacity(active || presented ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if active {
                        Capsule().fill(profileTint(store.profile)).frame(width: 8, height: 2).padding(.bottom, 1)
                    }
                }
        }.buttonStyle(LoafButtonStyle())
            .help("performance · " + status)
            .accessibilityLabel("performance controls").accessibilityValue(status)
            .popover(isPresented: $presented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: setting(\.gameMode)) {
                        Label { Text("game mode") } icon: { GolzheimIcon(icon: .gameMode, size: 16) }
                    }
                    Text("prioritizes the page you’re using and suspends background pages.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if monitor.hasInternalBattery {
                        Divider()
                        Toggle(isOn: setting(\.powerSaver)) {
                            Label { Text("power saver") } icon: { GolzheimIcon(icon: .powerSaver, size: 16) }
                        }.disabled(gameMode)
                        Text(saverDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch).controlSize(.small).padding(16).frame(width: 268)
            }
    }
    private var saverDetail: String {
        if gameMode { return "paused while game mode is on." }
        if monitor.saverEnabled && store.preferences.powerSaver != true {
            return monitor.systemLowPower ? "on automatically with macOS Low Power Mode."
                : "on automatically at your battery threshold."
        }
        return "reduces background activity and sleeps eligible idle tabs sooner."
    }
}

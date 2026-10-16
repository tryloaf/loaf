import SwiftUI

nonisolated enum PerformanceIndicatorVisibility: String, Codable, CaseIterable, Sendable {
    case whenActive, always, never
    var title: String {
        switch self {
        case .whenActive: "when active"
        case .always: "always"
        case .never: "never"
        }
    }
    func showsIndicator(active: Bool) -> Bool {
        switch self {
        case .whenActive: active
        case .always: true
        case .never: false
        }
    }
}

nonisolated enum PerformanceIndicatorPlacement {
    static func center(in leadingWidth: CGFloat) -> CGFloat {
        let controlsWidth: CGFloat = 76
        let indicatorWidth: CGFloat = 26
        let spacing: CGFloat = 8
        return min(controlsWidth + spacing + indicatorWidth / 2, (controlsWidth + leadingWidth) / 2)
    }
}

struct PerformanceIndicator: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var monitor: ResourceMonitor
    @State private var presented = false
    init(store: BrowserStore) {
        self.store = store
        _monitor = ObservedObject(wrappedValue: store.application.resources)
    }
    private var gameMode: Bool { store.preferences.gameMode == true }
    private var active: Bool { gameMode || monitor.saverEnabled }
    private var visible: Bool {
        (store.preferences.performanceIndicatorVisibility ?? .whenActive).showsIndicator(active: active)
    }
    private var icon: LoafIcon {
        if gameMode { return .gameMode }
        return monitor.saverEnabled ? .powerSaver : .gameMode
    }
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
        Group {
            if visible {
                Button { presented.toggle() } label: {
                    GolzheimIcon(icon: icon, size: 15, weight: 320)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(LoafButtonStyle())
                    .help(active ? status : "performance controls · standard")
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
                            Toggle(isOn: Binding(
                                get: { !gameMode && monitor.saverEnabled },
                                set: { setting(\.powerSaver).wrappedValue = $0 })) {
                                Label { Text("power saver") } icon: { GolzheimIcon(icon: .powerSaver, size: 16) }
                            }.disabled(gameMode || monitor.automaticSaverRequested)
                            Text(saverDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.switch).controlSize(.small).padding(16).frame(width: 268)
                }
            }
        }.onChange(of: visible) { _, visible in
            if !visible { presented = false }
        }
    }
    private var saverDetail: String {
        if gameMode { return store.preferences.powerSaver == true
                ? "off while game mode is on. your power saver choice resumes afterward."
                : "off while game mode is on." }
        if monitor.saverEnabled && monitor.automaticSaverRequested {
            return monitor.systemLowPower ? "on automatically with macOS Low Power Mode."
                : "on automatically at your battery threshold."
        }
        return "reduces background activity and sleeps eligible idle tabs sooner."
    }
}

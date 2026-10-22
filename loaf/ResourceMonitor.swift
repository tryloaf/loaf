import AppKit
import Combine
import IOKit.ps
import SwiftUI
import WebKit

nonisolated struct BrowsingTimeRecord: Codable {
    let day: String
    let profileID: UUID
    let host: String
    var seconds: Double
}

@MainActor final class ResourceMonitor: ObservableObject {
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var charging = false
    @Published private(set) var hasInternalBattery = false
    @Published private(set) var saverEnabled = false
    @Published private(set) var systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var records: [BrowsingTimeRecord] = []
    private weak var application: BrowserApplication?
    private var timer: Timer?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var ticks = 0
    private var observers = Set<AnyCancellable>()
    private var powerSource: CFRunLoopSource?
    private var gameActivity: NSObjectProtocol?
    var gameActivityActive: Bool { gameActivity != nil }
    init(application: BrowserApplication) {
        self.application = application
        if let data = try? Data(contentsOf: application.directory.appendingPathComponent("browsing-time.json")),
            let saved = try? JSONDecoder().decode([BrowsingTimeRecord].self, from: data)
        {
            records = Array(saved.suffix(5_000))
        }
        refreshBattery()
        powerSource = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<ResourceMonitor>.fromOpaque(context).takeUnretainedValue().refreshBattery()
                }
            }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        for name in [
            Notification.Name.NSProcessInfoPowerStateDidChange,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in

                Task { @MainActor [weak self] in self?.refreshBattery() }
            }.store(in: &observers)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func refreshBattery() {
        var battery: [String: Any]?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        {
            battery = sources.compactMap {
                IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
            }.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        }
        let current = battery?[kIOPSCurrentCapacityKey] as? Int
        let maximum = battery?[kIOPSMaxCapacityKey] as? Int
        let percent = current.flatMap { value in
            maximum.flatMap { $0 > 0 ? min(100, max(0, value * 100 / $0)) : nil }
        }
        let internalBattery = battery != nil
        let onAC = battery?[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if hasInternalBattery != internalBattery { hasInternalBattery = internalBattery }
        if batteryPercent != percent { batteryPercent = percent }
        if charging != onAC { charging = onAC }
        if systemLowPower != lowPower { systemLowPower = lowPower }
        applyPowerPolicy()
    }
    var automaticSaverRequested: Bool {
        let threshold = application?.preferences.powerSaverThreshold ?? 0
        return hasInternalBattery
            && (systemLowPower
                || (!charging && threshold > 0 && batteryPercent.map { $0 <= threshold } == true))
    }
    func applyPowerPolicy() {
        guard let application else { return }
        let policy = BrowsingPowerPolicy(
            preferences: application.preferences, hasInternalBattery: hasInternalBattery,
            onACPower: charging, batteryPercent: batteryPercent, systemLowPower: systemLowPower)
        if saverEnabled != policy.batterySaver { saverEnabled = policy.batterySaver }
        let foregroundTabs = Set(
            application.windows.filter {
                $0.nativeWindow?.isVisible == true && $0.nativeWindow?.isMiniaturized == false
            }.flatMap { window in
                window.tabs.filter {
                    !$0.isDisposed && $0.page == .web
                        && (window.selectedTab?.id == $0.id || window.visibleSplit?.contains($0.id) == true)
                }.map(\.id)
            })
        let focused = NSApp.isActive ? application.windows.first { $0.nativeWindow?.isKeyWindow == true } : nil
        let wantsActivity = policy.gameMode && focused?.tabs.contains { foregroundTabs.contains($0.id) } == true
        if wantsActivity && gameActivity == nil {
            gameActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "loaf game mode foreground browsing")
        } else if !wantsActivity, let gameActivity {
            ProcessInfo.processInfo.endActivity(gameActivity)
            self.gameActivity = nil
        }
        for runtime in application.runtimes.values {
            for tab in runtime.tabs.values {
                guard let preferences = tab.existingWebView?.configuration.preferences else { continue }
                let foreground = foregroundTabs.contains(tab.id)
                WebKitAdapter.setHighRefreshRendering(preferences, enabled: policy.highRefreshRendering(foreground: foreground && focused?.id == tab.windowID))
                let scheduling = policy.schedulingPolicy(foreground: foreground)
                if preferences.inactiveSchedulingPolicy != scheduling {
                    preferences.inactiveSchedulingPolicy = scheduling
                }
            }
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousTick
        previousTick = now
        ticks += 1
        if ticks % 6 == 0 { refreshBattery() }
        guard let application, application.preferences.tracksScreenTime == true, elapsed > 0, elapsed <= 10 else {
            return
        }
        let focused = application.coordinator?.focused
        let tabs = application.runtimes.values.flatMap { $0.tabs.values }.filter { tab in
            guard tab.page == .web, !tab.isDisposed,
                application.profiles.first(where: { $0.id == tab.profileID })?.privateMode == false
            else { return false }
            return NSApp.isActive && focused?.selectedTab?.id == tab.id
                || tab.media.contains { !$0.paused && ($0.pictureInPicture || !$0.muted && $0.volume > 0) }
        }
        let day = Self.localDay()

        var updatedRecords = records
        var recorded = Set<String>()
        for tab in tabs {
            guard let host = tab.url?.host, recorded.insert(tab.profileID.uuidString + host).inserted else { continue }
            if let index = updatedRecords.firstIndex(where: {
                $0.day == day && $0.profileID == tab.profileID && $0.host == host
            }) {
                updatedRecords[index].seconds += elapsed
            } else {
                updatedRecords.append(.init(day: day, profileID: tab.profileID, host: host, seconds: elapsed))
            }
        }
        if !recorded.isEmpty {
            records = Array(updatedRecords.suffix(5_000))
        }
        if ticks % 6 == 0 { save() }
    }
    func minutesToday(profileID: UUID) -> Int {
        let day = Self.localDay()
        return Int(records.filter { $0.day == day && $0.profileID == profileID }.reduce(0) { $0 + $1.seconds } / 60)
    }
    func topSitesToday(profileID: UUID, limit: Int = 3) -> [(host: String, seconds: Double)] {
        let day = Self.localDay()
        let today = records.filter { $0.day == day && $0.profileID == profileID }
        var totals: [String: Double] = [:]
        for record in today { totals[record.host, default: 0] += record.seconds }
        let sorted = totals.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
        return sorted.prefix(max(0, min(8, limit))).map { (host: $0.key, seconds: $0.value) }
    }
    func save() {
        guard let application, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(
            to: application.directory.appendingPathComponent("browsing-time.json"),
            options: [.atomic, .completeFileProtection])
    }
    private static func localDay() -> String {
        let date = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
    }
    func deleteTrackingData() {
        records = []
        save()
    }
    deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        if let gameActivity { ProcessInfo.processInfo.endActivity(gameActivity) }
    }
}

struct BatteryWidget: View {
    @ObservedObject var monitor: ResourceMonitor
    var showsHeader = true
    private var percentage: Int? { MarketingLaunch.isStudio ? 100 : monitor.batteryPercent }
    private var charging: Bool { MarketingLaunch.isStudio ? false : monitor.charging }
    private var saving: Bool { MarketingLaunch.isStudio ? false : monitor.saverEnabled }
    static func icon(percentage: Int?, charging: Bool) -> LoafIcon {
        if charging { return .batteryCharging }
        guard let percentage else { return .batteryFull }
        return percentage <= 25 ? .batteryLow : percentage <= 65 ? .batteryHalf : .batteryFull
    }
    var body: some View {
        GeometryReader { geometry in
            let metrics = StartWidgetMetrics(size: geometry.size)
            VStack(alignment: .leading, spacing: 12) {
                if showsHeader && !metrics.tiny {
                    Label {
                        Text("battery")
                    } icon: {
                        GolzheimIcon(icon: Self.icon(percentage: percentage, charging: charging), size: 18)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: metrics.expanded ? 14 : 8) {
                    HStack(spacing: 8) {
                        Text(percentage.map { "\($0)%" } ?? "plugged in")
                            .font(
                                .system(
                                    size: metrics.numberSize(maximum: 84, characters: percentage == nil ? 9 : 3.4),
                                    weight: .light)
                            )
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        if metrics.tiny {
                            GolzheimIcon(icon: Self.icon(percentage: percentage, charging: charging), size: 16)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let percentage, geometry.size.height >= 220 || geometry.size.width >= 280 {
                        GeometryReader { track in
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(Color.primary.opacity(0.28)).frame(
                                width: track.size.width * Double(min(100, max(0, percentage))) / 100)
                        }.frame(maxWidth: 240).frame(height: 5).accessibilityLabel("\(percentage) percent charge")
                    }
                    if geometry.size.height >= 70 {
                        Text(
                            saving
                                ? "battery saver is on"
                                : charging
                                    ? "connected to power" : percentage == nil ? "no battery in this Mac" : "on battery"
                        )
                        .font(.system(size: metrics.expanded ? 13 : 11)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct BrowsingTimeWidget: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        GeometryReader { geometry in
            let metrics = StartWidgetMetrics(size: geometry.size)
            VStack(alignment: .leading, spacing: 12) {
                if store.preferences.tracksScreenTime == true {
                    Text("\(monitor.minutesToday(profileID: store.selectedProfileID)) min")
                        .font(.system(size: metrics.numberSize(maximum: 76, characters: 5), weight: .light))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Text("today in this profile").font(.system(size: 11)).foregroundStyle(.secondary)
                    if metrics.tall {
                        let sites = monitor.topSitesToday(profileID: store.selectedProfileID)
                        if !sites.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(sites, id: \.host) { site in
                                    HStack {
                                        Text(site.host).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        Text(site.seconds < 60 ? "<1 min" : "\(Int(site.seconds / 60)) min")
                                            .monospacedDigit()
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 10)
                        }
                    }
                } else {
                    Text(
                        "save time spent on focused pages and playing media. site totals stay on this Mac; private browsing is excluded."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("enable local time tracking") {
                        store.preferences.tracksScreenTime = true
                        store.persistSoon()
                    }.controlSize(.small)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

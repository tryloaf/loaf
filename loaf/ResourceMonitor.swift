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
    @Published private(set) var saverEnabled = false
    @Published private(set) var records: [BrowsingTimeRecord] = []
    private weak var application: BrowserApplication?
    private var timer: Timer?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var ticks = 0
    init(application: BrowserApplication) {
        self.application = application
        if let data = try? Data(contentsOf: application.directory.appendingPathComponent("browsing-time.json")),
            let saved = try? JSONDecoder().decode([BrowsingTimeRecord].self, from: data)
        {
            records = Array(saved.suffix(5_000))
        }
        refreshBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func refreshBattery() {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        {
            let battery = sources.compactMap {
                IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
            }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
            let current = battery?[kIOPSCurrentCapacityKey] as? Int
            let maximum = battery?[kIOPSMaxCapacityKey] as? Int
            batteryPercent = current.flatMap { value in
                maximum.flatMap { $0 > 0 ? min(100, max(0, value * 100 / $0)) : nil }
            }
            charging = battery?[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        } else {
            batteryPercent = nil
            charging = false
        }
        guard let application else { return }
        let threshold = application.preferences.powerSaverThreshold ?? 0
        let enabled =
            application.preferences.powerSaver == true
            || (!charging && threshold > 0 && batteryPercent.map { $0 <= threshold } == true)
        if saverEnabled != enabled { saverEnabled = enabled }
        for runtime in application.runtimes.values {
            for tab in runtime.tabs.values {
                tab.existingWebView?.configuration.preferences.inactiveSchedulingPolicy = enabled ? .suspend : .throttle
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

        var recorded = Set<String>()
        for tab in tabs {
            guard let host = tab.url?.host, recorded.insert(tab.profileID.uuidString + host).inserted else { continue }
            if let index = records.firstIndex(where: {
                $0.day == day && $0.profileID == tab.profileID && $0.host == host
            }) {
                records[index].seconds += elapsed
            } else {
                records.append(.init(day: day, profileID: tab.profileID, host: host, seconds: elapsed))
            }
        }
        if records.count > 5_000 { records.removeFirst(records.count - 5_000) }
        if ticks % 6 == 0 { save() }
    }
    func minutesToday(profileID: UUID) -> Int {
        let day = Self.localDay()
        return Int(records.filter { $0.day == day && $0.profileID == profileID }.reduce(0) { $0 + $1.seconds } / 60)
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
    deinit { timer?.invalidate() }
}

struct BatteryWidget: View {
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("battery", systemImage: monitor.charging ? "battery.100percent.bolt" : "battery.75percent").font(
                .system(size: 13))
            Text(monitor.batteryPercent.map { "\($0)%" } ?? "plugged in").font(.system(size: 32, weight: .light))
                .monospacedDigit()
            Text(
                monitor.saverEnabled
                    ? "power saver is on"
                    : monitor.charging
                        ? "connected to power" : monitor.batteryPercent == nil ? "no battery in this Mac" : "on battery"
            ).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct BrowsingTimeWidget: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.preferences.tracksScreenTime == true {
                Text("\(monitor.minutesToday(profileID: store.selectedProfileID)) min").font(
                    .system(size: 32, weight: .light)
                ).monospacedDigit()
                Text("today in this profile").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(
                    "save time spent on focused pages and playing media. site totals stay on this Mac; private browsing is excluded."
                ).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("enable local time tracking") {
                    store.preferences.tracksScreenTime = true
                    store.persistSoon()
                }.controlSize(.small)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

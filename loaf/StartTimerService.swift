import AppKit
import Combine

nonisolated struct StartCountdown: Codable, Equatable, Sendable {
    var duration: TimeInterval = 25 * 60
    var remaining: TimeInterval = 25 * 60
    var deadline: Date?
    var finished = false

    func seconds(at date: Date) -> TimeInterval {
        max(0, deadline.map { $0.timeIntervalSince(date) } ?? remaining)
    }
    mutating func start(at date: Date) {
        guard deadline == nil else { return }
        if finished || remaining <= 0 { remaining = duration }
        finished = false
        deadline = date.addingTimeInterval(remaining)
    }
    mutating func pause(at date: Date) {
        guard deadline != nil else { return }
        remaining = seconds(at: date)
        deadline = nil
        finished = remaining <= 0
    }
    mutating func reset() {
        deadline = nil
        remaining = duration
        finished = false
    }
    mutating func setDuration(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        duration = min(24 * 60 * 60, max(1, seconds))
        reset()
    }
    @discardableResult mutating func finishIfNeeded(at date: Date) -> Bool {
        guard let deadline, date >= deadline else { return false }
        self.deadline = nil
        remaining = 0
        finished = true
        return true
    }
}

nonisolated struct StartStopwatch: Codable, Equatable, Sendable {
    var accumulated: TimeInterval = 0
    var started: Date?
    func seconds(at date: Date) -> TimeInterval {
        accumulated + max(0, started.map { date.timeIntervalSince($0) } ?? 0)
    }
    mutating func toggle(at date: Date) {
        if started != nil {
            accumulated = seconds(at: date)
            started = nil
        } else {
            started = date
        }
    }
}

nonisolated enum StartTimeDisplay {
    static func string(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        let value = seconds.isFinite ? min(359_999, max(0, seconds)) : 0
        let total = Int(roundingUp ? ceil(value) : floor(value))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@MainActor final class StartTimerService: ObservableObject {
    nonisolated struct Record: Codable, Equatable, Sendable {
        var countdown = StartCountdown()
        var stopwatch = StartStopwatch()
    }
    @Published private(set) var records: [UUID: Record] = [:]
    @Published private(set) var saveError: String?
    private var privateProfiles = Set<UUID>()
    private let file: URL
    private let now: () -> Date
    private let onFinish: @MainActor (UUID) -> Void
    private let automatic: Bool
    private var ticker: Task<Void, Never>?

    init(
        file: URL, validProfiles: Set<UUID>, now: @escaping () -> Date = { .now }, automatic: Bool = true,
        onFinish: @escaping @MainActor (UUID) -> Void = { _ in
            NSSound(named: "Glass")?.play()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    ) {
        self.file = file
        self.now = now
        self.automatic = automatic
        self.onFinish = onFinish
        if let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([UUID: Record].self, from: data)
        {
            records = saved.filter { validProfiles.contains($0.key) }.mapValues { record in
                var record = record
                record.countdown.duration = min(86400, max(1, record.countdown.duration))
                record.countdown.remaining = min(record.countdown.duration, max(0, record.countdown.remaining))
                record.stopwatch.accumulated = max(0, record.stopwatch.accumulated)
                return record
            }
        }

        for id in Array(records.keys) { records[id]?.countdown.finishIfNeeded(at: now()) }
        save()
        schedule()
    }
    deinit { ticker?.cancel() }

    func record(for profile: UUID) -> Record { records[profile] ?? Record() }
    func edit(_ profile: UUID, privateMode: Bool, _ change: (inout Record, Date) -> Void) {
        if privateMode { privateProfiles.insert(profile) }
        var record = record(for: profile)
        let date = now()
        let completed = record.countdown.finishIfNeeded(at: date)
        change(&record, date)
        records[profile] = record
        save()
        schedule()
        if completed { onFinish(profile) }
    }
    func forgetProfile(_ profile: UUID) {
        records.removeValue(forKey: profile)
        privateProfiles.remove(profile)
        save()
        schedule()
    }
    func checkDeadlines() {
        let date = now()
        var updated = records
        var finished: [UUID] = []
        for id in Array(updated.keys) {
            if updated[id]?.countdown.finishIfNeeded(at: date) == true { finished.append(id) }
        }
        guard !finished.isEmpty else { return }
        records = updated
        save()
        for id in finished { onFinish(id) }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = records.filter { !privateProfiles.contains($0.key) }
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            saveError = nil
        } catch { saveError = "timers couldn’t be saved on this Mac" }
    }
    private func schedule() {
        ticker?.cancel()
        ticker = nil
        guard automatic, records.values.contains(where: { $0.countdown.deadline != nil }) else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.checkDeadlines()
                if !self.records.values.contains(where: { $0.countdown.deadline != nil }) { return }
            }
        }
    }
}

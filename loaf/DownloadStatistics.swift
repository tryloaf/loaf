import Foundation

nonisolated struct DownloadStatistics: Codable, Equatable, Sendable {
    var receivedBytes: Int64 = 0
    var totalBytes: Int64?
    var elapsed: TimeInterval = 0
    var bytesPerSecond: Double?

    var estimatedRemaining: TimeInterval? {
        guard let totalBytes, totalBytes > receivedBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let seconds = Double(totalBytes - receivedBytes) / bytesPerSecond
        return seconds.isFinite ? seconds : nil
    }
    var sizeText: String {
        let received = Self.bytes(receivedBytes)
        return totalBytes.map { received + " of " + Self.bytes($0) } ?? received + " · total size unknown"
    }
    var rateText: String {
        bytesPerSecond.map { Self.bytes(Int64(min(Double(Int64.max / 2), max(0, $0)))) + "/s" } ?? "calculating speed…"
    }
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
    static func duration(_ value: TimeInterval) -> String {
        let seconds = Int(min(315_360_000, max(0, value.isFinite ? value.rounded(.up) : 0)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

// A short rolling sample avoids lifetime-average estimates after a speed change.
// Monotonic time excludes save dialogs and paused/interrupted periods.
nonisolated struct DownloadTransferClock {
    private var started: TimeInterval?
    private var previousElapsed: TimeInterval = 0
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    mutating func begin(_ statistics: DownloadStatistics, at time: TimeInterval) {
        guard started == nil else { return }
        started = time
        previousElapsed = statistics.elapsed
        samples = [(time, statistics.receivedBytes)]
    }
    mutating func sample(_ statistics: DownloadStatistics, received: Int64, total: Int64?, at time: TimeInterval)
        -> DownloadStatistics
    {
        guard let started else { return statistics }
        var next = statistics
        next.receivedBytes = max(0, received)
        next.totalBytes =
            total.flatMap { $0 > 0 ? max($0, next.receivedBytes, statistics.totalBytes ?? 0) : nil }
            ?? statistics.totalBytes
        next.elapsed = previousElapsed + max(0, time - started)
        if let last = samples.last, received < last.bytes {
            samples = [(time, next.receivedBytes)]
        } else {
            samples.append((time, next.receivedBytes))
            while samples.count > 2 && samples[1].time <= time - 4 { samples.removeFirst() }
        }
        if let first = samples.first, time - first.time >= 0.5 {
            next.bytesPerSecond = Double(max(0, next.receivedBytes - first.bytes)) / (time - first.time)
        } else {
            next.bytesPerSecond = nil
        }
        return next
    }
    mutating func stop(_ statistics: DownloadStatistics, at time: TimeInterval) -> DownloadStatistics {
        var next = statistics
        if let started { next.elapsed = previousElapsed + max(0, time - started) }
        next.bytesPerSecond = nil
        started = nil
        samples = []
        return next
    }
}

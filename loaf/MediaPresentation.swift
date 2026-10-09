import AppKit
import Combine
import SwiftUI

@MainActor final class SidebarMediaCollection: ObservableObject {
    @Published private(set) var tabIDs = Set<UUID>()
    private struct Watch {
        weak var tab: BrowserTab?
        let subscription: AnyCancellable
    }
    private var watches: [UUID: Watch] = [:]
    private var pending = Set<UUID>()
    private var refreshPending = false

    func observe(_ tab: BrowserTab) {
        guard watches[tab.id] == nil else { return }
        let subscription = tab.$media.map { !$0.isEmpty }.removeDuplicates().sink { [weak self, id = tab.id] _ in
            self?.refreshLater(id)
        }
        watches[tab.id] = Watch(tab: tab, subscription: subscription)
    }

    func remove(_ id: UUID) {
        guard watches.removeValue(forKey: id) != nil else { return }
        refreshLater(id)
    }

    private func refreshLater(_ id: UUID) {
        pending.insert(id)
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            let changed = self.pending
            self.pending.removeAll()
            var next = self.tabIDs
            for id in changed {
                if let tab = self.watches[id]?.tab, !tab.isDisposed, !tab.media.isEmpty {
                    next.insert(id)
                } else {
                    next.remove(id)
                }
            }
            if next != self.tabIDs { self.tabIDs = next }
        }
    }
}

@MainActor enum TitleTextMetrics {
    private static let widths: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        cache.totalCostLimit = 1_048_576
        return cache
    }()

    static func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        let key = "\(fontSize):\(text)" as NSString
        if let cached = widths.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        widths.setObject(NSNumber(value: Double(width)), forKey: key, cost: key.length * 2 + 32)
        return width
    }
}

nonisolated enum MediaFormatting {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "--:--" }
        let value = Int(seconds)
        let hours = value / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite, range.upperBound > range.lowerBound
        else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    static func marqueeOffset(elapsed: Double, overflow: Double) -> Double {
        guard elapsed.isFinite, overflow.isFinite, overflow > 0 else { return 0 }
        let speed = 18.0
        let pause = 3.0
        let travel = overflow / speed
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: travel * 2 + pause * 2)
        if phase < pause { return 0 }
        if phase < pause + travel { return (phase - pause) * speed }
        if phase < pause * 2 + travel { return overflow }
        return max(0, overflow - (phase - pause * 2 - travel) * speed)
    }
}

struct TitleViewport: View {
    let text: String
    var fontSize: CGFloat = 13
    let width: CGFloat
    let height: CGFloat
    var offset: CGFloat = 0
    var fadeWidth: CGFloat = 12
    var trailingInset: CGFloat = 0
    private var textWidth: CGFloat { TitleTextMetrics.width(text, fontSize: fontSize) }
    var body: some View {
        let edge = min(max(0, fadeWidth), max(0, width) / 3)
        let leadingFade = offset > 0.5
        let trailingFade = textWidth - max(0, offset) > width - trailingInset + 0.5
        ZStack(alignment: .leading) {
            Text(text).font(.system(size: fontSize)).fixedSize(horizontal: true, vertical: false).offset(
                x: -max(0, offset))
        }.frame(width: max(0, width), height: max(0, height), alignment: .leading).clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: leadingFade ? [.clear, .black] : [.black, .black], startPoint: .leading,
                        endPoint: .trailing
                    ).frame(width: edge)
                    Color.black
                    LinearGradient(
                        colors: trailingFade ? [.black, .clear] : [.black, .black], startPoint: .leading,
                        endPoint: .trailing
                    ).frame(width: edge)
                    Color.clear.frame(width: max(0, trailingInset))
                }.frame(width: max(0, width), height: max(0, height))
            }.accessibilityLabel(text)
    }
}
struct FadingTitle: View {
    let text: String
    var fontSize: CGFloat = 13
    var body: some View {
        GeometryReader { geometry in
            TitleViewport(text: text, fontSize: fontSize, width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct MarqueeTitle: View {
    @State private var started = Date()
    let text: String
    let active: Bool
    var trailingInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let width = TitleTextMetrics.width(text, fontSize: 13)
            let overflow = max(0, width - geometry.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion || overflow == 0)) {
                time in
                let offset =
                    active && !reduceMotion
                    ? MediaFormatting.marqueeOffset(elapsed: time.date.timeIntervalSince(started), overflow: overflow)
                    : 0
                TitleViewport(
                    text: text, width: geometry.size.width, height: geometry.size.height, offset: offset,
                    trailingInset: trailingInset)
            }.onChange(of: active) { _, _ in started = Date() }.onChange(of: text) { _, _ in started = Date() }
        }.accessibilityLabel(text)
    }
}

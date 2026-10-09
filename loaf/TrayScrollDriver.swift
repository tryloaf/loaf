import AppKit
import SwiftUI

enum TrayMetrics { static let contentHeight: CGFloat = 226 }

struct TraySettle {
    let start: CGFloat
    let target: CGFloat
    let velocity: CGFloat
    init(start: CGFloat, open: Bool, pointsPerSecond: CGFloat) {
        self.start = min(1.06, max(0, start))
        target = open ? 1 : 0
        velocity = pointsPerSecond.isFinite ? min(2, max(-2, pointsPerSecond / TrayMetrics.contentHeight)) : 0
    }
    func value(at time: TimeInterval) -> CGFloat {
        guard time < 0.65 else { return target }
        let t = max(0, time)
        let decay = 13.0
        let frequency = 10.0
        let displacement = Double(start - target)
        let wave =
            displacement * cos(frequency * t) + (Double(velocity) + decay * displacement) / frequency
            * sin(frequency * t)
        let value = target + CGFloat(exp(-decay * t) * wave)
        return target == 0 ? max(0, value) : value
    }
}

private struct TrayScrollSample: Sendable {
    let windowNumber: Int, point: NSPoint, timestamp: TimeInterval
    let phase: UInt, momentum: UInt
    let deltaX: CGFloat, deltaY: CGFloat
    let precise: Bool, inverted: Bool
    nonisolated init(_ event: NSEvent) {
        windowNumber = event.windowNumber
        point = event.locationInWindow
        timestamp = event.timestamp
        phase = event.phase.rawValue
        momentum = event.momentumPhase.rawValue
        deltaX = event.scrollingDeltaX
        deltaY = event.scrollingDeltaY
        precise = event.hasPreciseScrollingDeltas
        inverted = event.isDirectionInvertedFromDevice
    }
}

struct TrayPullGesture {
    private(set) var progress: CGFloat = 0
    private var lastTime: TimeInterval?
    private var speed: CGFloat = 0
    mutating func begin(at value: CGFloat) {
        progress = min(1, max(0, value))
        lastTime = nil
        speed = 0
    }
    mutating func update(points: CGFloat, time: TimeInterval) -> CGFloat {
        guard points.isFinite, time.isFinite else { return progress }
        if let lastTime, time > lastTime { speed = points / CGFloat(max(1.0 / 120, time - lastTime)) }
        lastTime = time
        progress = min(1, max(0, progress + points / TrayMetrics.contentHeight))
        return progress
    }
    func releaseVelocity(at time: TimeInterval) -> CGFloat {
        guard let lastTime, time.isFinite, time >= lastTime, time - lastTime <= 0.20 else { return 0 }
        return min(3500, max(-3500, speed))
    }
    func opensOnRelease(at time: TimeInterval) -> Bool {
        progress + min(0.35, max(-0.35, releaseVelocity(at: time) * 0.13 / TrayMetrics.contentHeight)) >= 0.5
    }
    var opensOnRelease: Bool { progress + min(0.35, max(-0.35, speed * 0.13 / TrayMetrics.contentHeight)) >= 0.5 }
}

struct TrayScrollDriver: NSViewRepresentable {
    let progress: CGFloat
    let changed: (CGFloat) -> Void
    let settled: (Bool, CGFloat) -> Void
    var discreteChanged: ((CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) {
        view.progress = progress
        view.changed = changed
        view.settled = settled
        view.discreteChanged = discreteChanged
    }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }
    final class ScrollView: NSView {
        var progress: CGFloat = 0
        var changed: ((CGFloat) -> Void)?
        var settled: ((Bool, CGFloat) -> Void)?
        var discreteChanged: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var gesture = TrayPullGesture()
        private var captured = false
        private var settlingFlick = false
        private var swallowingMomentum = false
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var rejectedPull = false
        private var idleEnd: DispatchWorkItem?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let sample = TrayScrollSample(event)
                let consumed = MainActor.assumeIsolated { self?.consume(sample) == true }
                return consumed ? nil : event
            }
        }
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            idleEnd?.cancel()
            captured = false
            swallowingMomentum = false
            settlingFlick = false
            horizontal = 0
            vertical = 0
            rejectedPull = false
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            idleEnd?.cancel()
        }
        private func finish(cancelled: Bool = false, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            idleEnd?.cancel()
            idleEnd = nil
            guard captured else { return }
            captured = false
            swallowingMomentum = true
            settled?(
                cancelled ? progress >= 0.5 : gesture.opensOnRelease(at: time),
                cancelled ? 0 : gesture.releaseVelocity(at: time))
        }
        func consume(_ event: NSEvent) -> Bool { consume(TrayScrollSample(event)) }
        private func consume(_ event: TrayScrollSample) -> Bool {
            let phase = NSEvent.Phase(rawValue: event.phase)
            let momentum = NSEvent.Phase(rawValue: event.momentum)
            guard event.windowNumber == window?.windowNumber, window?.isKeyWindow == true, window?.attachedSheet == nil
            else { return false }
            if momentum != [] {
                if swallowingMomentum {
                    if momentum.contains(.ended) { swallowingMomentum = false }
                    return true
                }
                return false
            }
            if phase.contains(.began) {

                if captured { finish(cancelled: true, time: event.timestamp) }
                swallowingMomentum = false
                settlingFlick = false
                horizontal = 0
                vertical = 0
                rejectedPull = false
            }
            if settlingFlick {
                if phase.contains(.ended) || phase.contains(.cancelled) {
                    settlingFlick = false
                    swallowingMomentum = true
                }
                return true
            }
            let point = convert(event.point, from: nil)
            let fromBottom = isFlipped ? bounds.maxY - point.y : point.y - bounds.minY
            let delta = (event.inverted ? -event.deltaY : event.deltaY) * (event.precise ? 1 : 12)
            if !captured {

                guard !phase.contains(.ended), !phase.contains(.cancelled) else { return false }
                if event.precise {
                    guard !rejectedPull else { return false }
                    horizontal += event.deltaX
                    vertical += event.deltaY
                    if abs(horizontal) > 12, abs(horizontal) > abs(vertical) * 1.2 {
                        rejectedPull = true
                        return false
                    }

                    guard abs(vertical) > abs(horizontal) * 1.2 else { return false }
                }
                guard bounds.contains(point), fromBottom < (progress > 0 ? bounds.height : 48),
                    abs(event.deltaY) > abs(event.deltaX) * 1.2, delta != 0,
                    (delta > 0 && progress < 1) || (delta < 0 && progress > 0)
                else { return false }
                gesture.begin(at: progress)
                captured = true
                swallowingMomentum = false
            }
            if phase.contains(.cancelled) {
                finish(cancelled: true, time: event.timestamp)
                return true
            }
            if phase.contains(.ended) {
                finish(time: event.timestamp)
                return true
            }
            let value = gesture.update(points: delta, time: event.timestamp)
            let velocity = gesture.releaseVelocity(at: event.timestamp)
            if event.precise, abs(velocity) >= 1200 {

                idleEnd?.cancel()
                captured = false
                settlingFlick = true
                swallowingMomentum = true
                settled?(delta > 0, velocity)
                return true
            }
            if !event.precise, let discreteChanged { discreteChanged(value) } else { changed?(value) }

            idleEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.finish() }
            if phase == [] {
                idleEnd = end
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: end)
            }
            return true
        }
    }
}

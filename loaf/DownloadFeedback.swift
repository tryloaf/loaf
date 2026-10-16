import AppKit
import Combine
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DownloadClickOrigin {
    let screenPoint: CGPoint
    var time = ProcessInfo.processInfo.systemUptime
    var recent: Self? {
        let elapsed = ProcessInfo.processInfo.systemUptime - time
        return elapsed >= 0 && elapsed <= 8 ? self : nil
    }
}

struct DownloadProgressSummary: Equatable {
    var count = 0
    var fraction = 0.0
    var indeterminate = false
    init(items: [DownloadItem]) {
        count = items.count
        guard count > 0 else { return }
        indeterminate = items.contains { ($0.download?.progress.totalUnitCount ?? -1) <= 0 }
        let total = items.reduce(0.0) { $0 + Double(max(0, $1.download?.progress.totalUnitCount ?? 0)) }
        let completed = items.reduce(0.0) { $0 + Double(max(0, $1.download?.progress.completedUnitCount ?? 0)) }
        let value = total > 0 ? completed / total : items.map(\.fraction).reduce(0, +) / Double(count)
        fraction = value.isFinite ? min(1, max(0, value)) : 0
    }
    var status: String {
        guard count > 0 else { return "" }
        let label = count == 1 ? "1 download" : "\(count) downloads"
        return indeterminate ? label + " in progress" : label + ", \(Int(fraction * 100))%"
    }
}

@MainActor final class DownloadProgressState: ObservableObject {
    @Published private(set) var profiles: [UUID: DownloadProgressSummary] = [:]
    func update(_ active: [DownloadItem]) {
        let next = Dictionary(grouping: active, by: \.profileID).mapValues { DownloadProgressSummary(items: $0) }
        if next != profiles { profiles = next }
    }
    func summary(for profileID: UUID) -> DownloadProgressSummary {
        profiles[profileID] ?? DownloadProgressSummary(items: [])
    }
}

@MainActor final class DownloadFeedback: ObservableObject {
    @Published private(set) var arrivals = 0
    @Published private(set) var completions = 0
    weak var trayAnchor: NSView?
    weak var overlay: DownloadFlightOverlay.FlightView?
    private var launches: [UUID: Task<Void, Never>] = [:]
    private var revealTask: Task<Void, Never>?
    private var temporarilyRevealed = false

    func completed() { completions += 1 }

    func launch(from origin: DownloadClickOrigin?, name: String, profileID: UUID, owner: BrowserStore) {
        guard owner.nativeWindow?.isVisible == true, launches.count < 8 else { return }
        let id = UUID()
        let reveal = !owner.sidebarPresented && !owner.hoveredSidebar
        if reveal {
            owner.hoveredSidebar = true
            temporarilyRevealed = true
        }
        if temporarilyRevealed {
            revealTask?.cancel()
            revealTask = Task { @MainActor [weak self, weak owner] in
                do { try await Task.sleep(for: .milliseconds(1800)) } catch { return }
                self?.temporarilyRevealed = false
                guard let owner, !owner.sidebarVisible, let window = owner.nativeWindow else { return }
                let point = window.mouseLocationOutsideOfEventStream

                if point.x > owner.preferences.sidebarWidth || point.x < 0 || point.y < 0
                    || point.y > (window.contentView?.bounds.height ?? 0) {
                    owner.hoveredSidebar = false
                }
            }
        }
        launches[id] = Task { @MainActor [weak self, weak owner] in
            defer { self?.launches.removeValue(forKey: id) }

            if reveal {
                do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            }
            guard !Task.isCancelled, let self, let owner, owner.nativeWindow?.isVisible == true,
                owner.selectedProfileID == profileID else { return }
            if let origin, let overlay = self.overlay, let anchor = self.trayAnchor,
                anchor.window === overlay.window, !anchor.isHiddenOrHasHiddenAncestor {
                overlay.fly(from: origin.screenPoint, to: anchor, name: name, tint: NSColor(profileTint(owner.profile))) { [weak self, weak owner] in
                    guard owner?.selectedProfileID == profileID else { return }
                    self?.arrivals += 1
                }
            } else {
                self.arrivals += 1
            }
        }
    }

    func stop() {
        for task in launches.values { task.cancel() }
        launches.removeAll()
        revealTask?.cancel()
        revealTask = nil
        temporarilyRevealed = false
        overlay?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
}

struct DownloadFlightOverlay: NSViewRepresentable {
    let feedback: DownloadFeedback
    func makeNSView(context: Context) -> FlightView {
        let view = FlightView()
        feedback.overlay = view
        return view
    }
    func updateNSView(_ view: FlightView, context: Context) { feedback.overlay = view }
    static func dismantleNSView(_ view: FlightView, coordinator: ()) {
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    final class FlightView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        static func controlPoint(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGPoint {
            CGPoint(x: (start.x + end.x) / 2,
                y: max(bounds.minY + 24, min(start.y, end.y) - min(180, max(64, abs(start.x - end.x) * 0.24))))
        }

        func fly(
            from screenPoint: CGPoint, to anchor: NSView, name: String, tint: NSColor = .controlAccentColor,
            reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            arrived: @escaping () -> Void
        ) {
            guard !reduceMotion, let window, window.isVisible, let layer,
                (layer.sublayers?.count ?? 0) < 8, bounds.width > 0, bounds.height > 0 else {
                arrived()
                return
            }
            let source = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            let start = CGPoint(x: min(bounds.maxX - 18, max(bounds.minX + 18, source.x)),
                y: min(bounds.maxY - 18, max(bounds.minY + 18, source.y)))
            let end = convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), from: anchor)
            guard bounds.contains(end) else { arrived(); return }
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: Self.controlPoint(from: start, to: end, bounds: bounds))
            let group = CALayer()
            group.frame = bounds
            layer.addSublayer(group)

            let paper = CALayer()
            paper.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data
            let icon = NSWorkspace.shared.icon(for: type)
            paper.backgroundColor = tint.cgColor
            let mask = CALayer()
            mask.frame = paper.bounds
            mask.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            mask.contentsGravity = .resizeAspect
            mask.contentsScale = window.backingScaleFactor
            paper.mask = mask
            group.addSublayer(paper)
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.path = path
            travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.7, 1.12, 1, 0.2]; scale.keyTimes = [0, 0.18, 0.65, 1]
            let rotate = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            rotate.values = [-0.18, 0.14, 0]; rotate.keyTimes = [0, 0.55, 1]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]; opacity.keyTimes = [0, 0.08, 0.86, 1]
            for animation in [travel, scale, rotate, opacity] { animation.duration = 0.72 }
            let flight = CAAnimationGroup()
            flight.animations = [travel, scale, rotate, opacity]
            flight.duration = 0.72
            paper.position = end
            paper.opacity = 0
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak group] in
                MainActor.assumeIsolated {
                    group?.removeFromSuperlayer()
                    if self?.window?.isVisible == true { arrived() }
                }
            }
            paper.add(flight, forKey: "download")
            CATransaction.commit()
        }
    }
}

private struct DownloadTrayAnchor: NSViewRepresentable {
    let feedback: DownloadFeedback
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        feedback.trayAnchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { feedback.trayAnchor = view }
    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct DownloadTrayButton: View {
    let store: BrowserStore
    let expansion: CGFloat
    let action: () -> Void
    @ObservedObject private var progress: DownloadProgressState
    @ObservedObject private var feedback: DownloadFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    init(store: BrowserStore, expansion: CGFloat, action: @escaping () -> Void) {
        self.store = store
        self.expansion = expansion
        self.action = action
        progress = store.downloads.progress
        feedback = store.downloadFeedback
    }
    private struct Bounce {
        var offset: CGFloat = 0
        var scale: CGFloat = 1
    }
    var body: some View {
        let summary = progress.summary(for: store.selectedProfileID)
        let tint = profileTint(store.profile)
        Button(action: action) {
            GolzheimIcon(icon: .tray, size: 16, weight: 100)
                .keyframeAnimator(initialValue: Bounce(), trigger: feedback.arrivals) { content, value in
                    content.offset(y: reduceMotion ? 0 : value.offset).scaleEffect(reduceMotion ? 1 : value.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.offset) {
                        CubicKeyframe(2, duration: 0.08)
                        SpringKeyframe(-3, duration: 0.16)
                        SpringKeyframe(0, duration: 0.26)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.15, duration: 0.1)
                        SpringKeyframe(1, duration: 0.4)
                    }
                }
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(tint.opacity(flash ? 0.18 : 0))
                }
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(expansion * 0.12),
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if summary.count > 0 {
                        DownloadTrayProgress(summary: summary, tint: tint).frame(width: 22, height: 3).padding(.bottom, 1)
                    }
                }
                .background(DownloadTrayAnchor(feedback: feedback))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(expansion == 0 ? "open tray (⌥⌘T)" : "close tray (⌥⌘T)")
            .accessibilityLabel(expansion == 0 ? "open tray" : "close tray")
            .accessibilityValue(summary.status)
            .task(id: feedback.arrivals + feedback.completions) {
                guard feedback.arrivals + feedback.completions > 0 else { return }
                withAnimation(.easeOut(duration: 0.1)) { flash = true }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                withAnimation(.easeOut(duration: 0.25)) { flash = false }
            }
    }
}

private struct DownloadTrayProgress: View {
    let summary: DownloadProgressSummary
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if summary.indeterminate && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let phase = (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
                track(fraction: 0.3, offset: phase * 0.7)
            }
        } else {
            track(fraction: summary.indeterminate ? 0.4 : summary.fraction, offset: 0)
        }
    }
    private func track(fraction: Double, offset: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(2, geometry.size.width * fraction))
                        .offset(x: geometry.size.width * offset)
                }
        }.accessibilityHidden(true)
    }
}

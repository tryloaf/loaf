import AppKit
import SwiftUI

struct MediaMiniPlayer: View {
    @ObservedObject var tab: BrowserTab
    let source: MediaSource
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hovered = false
    @State private var seekPreview: Double?
    @State private var volumePreview: Double?
    init(
        tab: BrowserTab, source: MediaSource, store: BrowserStore, initiallyExpanded: Bool = false,
        initiallyVolumeOpen: Bool = false, initiallyHovered: Bool = false
    ) {
        self.tab = tab
        self.source = source
        self.store = store
        _expanded = State(initialValue: initiallyExpanded)
        _volumeOpen = State(initialValue: initiallyVolumeOpen)
        _hovered = State(initialValue: initiallyHovered)
    }
    private var hasDuration: Bool { source.duration.isFinite && source.duration > 0 }
    @State private var volumeOpen = false
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if hovered { tab.dismissedMedia.insert(source.id) } else { store.select(tab) }
                } label: {
                    ZStack {
                        SiteIcon(tab: tab, size: 14).clipShape(RoundedRectangle(cornerRadius: 3)).opacity(
                            hovered ? 0 : 1)
                        GolzheimIcon(icon: .close, size: 12).opacity(hovered ? 1 : 0)
                    }.frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(hovered ? "close miniplayer" : "open " + source.title)
                    .accessibilityAction(named: Text("close miniplayer")) { tab.dismissedMedia.insert(source.id) }
                Button {
                    store.select(tab)
                } label: {
                    HStack(spacing: 6) {
                        MarqueeTitle(
                            text: source.title, active: store.nativeWindow?.isKeyWindow == true && !source.paused,
                            trailingInset: !expanded && hovered ? 26 : 0
                        )
                        .frame(height: 18).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(source.title).accessibilityLabel("open " + source.title)
                    .overlay(alignment: .trailing) {
                        if !expanded {
                            playbackButton.opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(
                                !hovered
                            )
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                        }
                    }
                playerButton(
                    expanded ? .collapse : .expand, label: expanded ? "collapse player" : "expand player", size: 12,
                    target: 20
                ) {
                    volumeOpen = false
                    expanded.toggle()
                    LoafHaptics.perform(enabled: store.preferences.haptics != false)
                }
            }.frame(height: 22)
            if expanded {
                VStack(spacing: 4) {
                    FadingTitle(text: metadata, fontSize: 10).foregroundStyle(.secondary).frame(height: 10)
                    if hasDuration {
                        VStack(spacing: 0) {
                            seekBar
                            HStack {
                                elapsedTime
                                Spacer(minLength: 4)
                                Text("−" + MediaFormatting.time(max(0, source.duration - shownPosition))).fixedSize()
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 10).monospacedDigit()).frame(height: 12)
                        }
                    }
                    ZStack {
                        HStack(spacing: 8) {
                            playerButton(.rewind, label: "back 15 seconds", size: 20, target: 24) {
                                tab.control(source, action: "skip", value: -15)
                            }.disabled(!hasDuration)
                            playbackButton
                            playerButton(.fastForward, label: "forward 15 seconds", size: 20, target: 24) {
                                tab.control(source, action: "skip", value: 15)
                            }.disabled(!hasDuration)
                        }
                        HStack {
                            Spacer(minLength: 0)
                            playerButton(
                                source.muted ? .muted : .volume, label: volumeOpen ? "hide volume" : "show volume",
                                size: 14, target: 24
                            ) { volumeOpen.toggle() }
                        }
                    }.frame(height: 28)
                    if volumeOpen {
                        MediaVolumeControls(tab: tab, source: source, preview: $volumePreview).transition(.opacity)
                    }
                }.transition(.opacity)
            }
        }.transaction { $0.animation = nil }
            .padding(.horizontal, 8).padding(.vertical, expanded ? 8 : 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: expanded)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: volumeOpen)
            .onHover { hovered = $0 }
            .contextMenu {
                Button(expanded ? "compact player" : "expanded player") {
                    volumeOpen = false
                    expanded.toggle()
                }
                Button(source.muted ? "unmute" : "mute") { tab.control(source, action: "mute") }
                if source.supportsAirPlay { Button("airplay…") { tab.control(source, action: "airplay") } }
                Button("hide miniplayer") { tab.dismissedMedia.insert(source.id) }
            }
    }
    private var metadata: String {
        let detail = source.artist.isEmpty ? (tab.url?.host ?? "playing in this tab") : source.artist
        return hasDuration ? detail : detail + " · live"
    }
    private var shownPosition: Double { seekPreview ?? source.position }
    private var elapsedTime: some View {
        Text(MediaFormatting.time(shownPosition)).fixedSize().foregroundStyle(.secondary)
    }
    private var seekBar: some View {
        MediaScrubber(
            value: source.position, range: 0...source.duration,
            label: "playback position",
            valueLabel: { MediaFormatting.time($0) + " of " + MediaFormatting.time(source.duration) },
            preview: $seekPreview
        ) {
            tab.control(source, action: "seek", value: $0)
        }
    }
    private var playbackButton: some View {
        Button {
            tab.control(source, action: "toggle")
        } label: {
            GolzheimIcon(icon: source.paused ? .play : .pause, size: expanded ? 20 : 16, weight: 200, filled: true)
                .frame(width: expanded ? 28 : 20, height: expanded ? 28 : 20)
        }.buttonStyle(PlayerActionStyle(outline: false))
            .accessibilityLabel(source.paused ? "play" : "pause").help(source.paused ? "play" : "pause")
    }
    private func playerButton(
        _ icon: LoafIcon, label: String, size: CGFloat = 16, target: CGFloat = 24, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            GolzheimIcon(icon: icon, size: size, weight: 180, filled: false).frame(width: target, height: target)
        }
        .buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel(label).help(label)
    }
}

struct MediaVolumeControls: View {
    @ObservedObject var tab: BrowserTab
    let source: MediaSource
    @Binding var preview: Double?
    var body: some View {
        VStack(spacing: 0) {
            MediaScrubber(
                value: source.muted ? 0 : source.volume, range: 0...1, continuous: true,
                label: "volume", valueLabel: { "\(Int(($0 * 100).rounded()))%" }, preview: $preview
            ) {
                tab.control(source, action: "volume", value: $0)
            }
            HStack {
                Button {
                    tab.control(source, action: "mute")
                } label: {
                    GolzheimIcon(icon: source.muted ? .muted : .volume, size: 12).frame(width: 24, height: 24)
                }.buttonStyle(PlayerActionStyle(outline: false)).accessibilityLabel(source.muted ? "unmute" : "mute")
                    .help(source.muted ? "unmute" : "mute")
                Spacer(minLength: 4)
                Text("\(Int(((preview ?? (source.muted ? 0 : source.volume)) * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).fixedSize().layoutPriority(1)
            }.frame(height: 24)
        }
    }
}

struct PlayerActionStyle: ButtonStyle {
    var outline = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HoverAction(
            label: configuration.label, pressed: configuration.isPressed, enabled: enabled, reduceMotion: reduceMotion,
            outline: outline)
    }
    private struct HoverAction: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let enabled: Bool
        let reduceMotion: Bool
        let outline: Bool
        @State private var hovered = false
        var body: some View {
            label.contentShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    Color.primary.opacity(enabled && hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        Color.primary.opacity(outline && enabled && hovered ? 0.1 : 0))
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .opacity(enabled ? pressed ? 0.6 : 1 : 0.3)
                .scaleEffect(enabled && pressed && !reduceMotion ? 0.92 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
                .onHover { hovered = $0 }
        }
    }
}

struct MediaScrubber: View {
    let value: Double
    let range: ClosedRange<Double>
    var continuous = false
    let label: String
    let valueLabel: (Double) -> String
    @Binding var preview: Double?
    let commit: (Double) -> Void
    @State private var dragging = false
    @State private var settling: Task<Void, Never>?
    private var shown: Double { preview ?? value }
    private func send(_ value: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        preview = clamped
        commit(clamped)
        settling?.cancel()
        settling = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if !dragging { preview = nil }
        }
    }
    var body: some View {
        CapsuleMediaSlider(
            value: Binding(
                get: { shown },
                set: { latest in
                    preview = latest
                    if !dragging || continuous { send(latest) }
                }), range: range,
            onEditingChanged: { editing in
                dragging = editing
                if editing { settling?.cancel() } else { send(shown) }
            }
        )
        .frame(height: 16).accessibilityLabel(label).accessibilityValue(valueLabel(shown))
        .onChange(of: value) { _, latest in
            if !dragging, let preview, abs(latest - preview) < 0.001 {
                self.preview = nil
                settling?.cancel()
            }
        }.onDisappear {
            settling?.cancel()
            preview = nil
        }

    }
}

struct CapsuleMediaSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Control {
        let slider = Control()
        slider.cell = CapsuleCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.change(_:))
        slider.focusRingType = .none
        slider.controlSize = .small
        return slider
    }
    func updateNSView(_ slider: Control, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.editing = onEditingChanged
    }
    final class Coordinator: NSObject {
        var parent: CapsuleMediaSlider
        init(_ parent: CapsuleMediaSlider) { self.parent = parent }
        @objc func change(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    final class Control: NSSlider {
        var editing: ((Bool) -> Void)?
        override func mouseDown(with event: NSEvent) {
            editing?(true)
            super.mouseDown(with: event)
            editing?(false)
        }
    }
    final class CapsuleCell: NSSliderCell {
        override func knobRect(flipped: Bool) -> NSRect {
            let original = super.knobRect(flipped: flipped)
            return NSRect(x: original.midX - 3, y: original.midY - 7, width: 6, height: 14)
        }
        override func drawKnob(_ knobRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(isEnabled ? 0.80 : 0.3).setFill()
            NSBezierPath(roundedRect: knobRect, xRadius: 3, yRadius: 3).fill()
        }
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let bar = NSRect(x: rect.minX + 3, y: rect.midY - 1.5, width: max(0, rect.width - 6), height: 3)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            let fill = NSRect(
                x: bar.minX, y: bar.minY, width: min(bar.width, max(0, knobRect(flipped: flipped).midX - bar.minX)),
                height: bar.height)
            NSColor.labelColor.withAlphaComponent(isEnabled ? 0.65 : 0.25).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

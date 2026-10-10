import AppKit
import SwiftUI

nonisolated enum ProfileTransparency {
    static func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    static func opacity(_ value: Double, reduceTransparency: Bool = false) -> Double {
        reduceTransparency ? 1 : 1 - bounded(value) * 0.72
    }
    static func value(at x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite else { return 0 }
        return bounded((x - ProfileColorPadPosition.inset) / max(1, width - ProfileColorPadPosition.inset * 2))
    }
    static func position(_ value: Double, width: CGFloat) -> CGFloat {
        ProfileColorPadPosition.inset + bounded(value) * max(1, width - ProfileColorPadPosition.inset * 2)
    }
}

struct ProfileTransparencyControl: View {
    @Binding var value: Double
    var height: CGFloat = 88
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var dragging = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("window transparency").fontWeight(.medium)
                Spacer()
                Text("\(Int((ProfileTransparency.bounded(value) * 100).rounded()))%")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let marker = CGPoint(
                    x: ProfileTransparency.position(value, width: geometry.size.width), y: geometry.size.height / 2)
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045))
                    LinearGradient(
                        colors: [Color.primary.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                    ProfileColorPadDots(
                        marker: marker, ink: scheme == .dark ? .white : .black, expansion: dragging ? 1 : 0, rowCount: 3
                    )
                    Circle().fill(.white).frame(width: dragging ? 30 : 18, height: dragging ? 30 : 18)
                        .shadow(color: .black.opacity(0.18), radius: dragging ? 8 : 3, y: 2).position(marker)
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14).strokeBorder(
                            Color.primary.opacity(focused ? 0.35 : 0.1), lineWidth: focused ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        CursorRegion(cursor: .openHand) { point, active in
                            dragging = active
                            focused = true
                            value = ProfileTransparency.value(at: point.x, width: geometry.size.width)
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: dragging)
            }.frame(height: height)
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    shift(-0.025)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    shift(0.025)
                    return .handled
                }
                .onKeyPress(.home) {
                    value = 0
                    return .handled
                }
                .onKeyPress(.end) {
                    value = 1
                    return .handled
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("window transparency")
                .accessibilityValue("\(Int((ProfileTransparency.bounded(value) * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: shift(0.025)
                    case .decrement: shift(-0.025)
                    @unknown default: break
                    }
                }
                .disabled(reduceTransparency).opacity(reduceTransparency ? 0.5 : 1)
            HStack {
                Text("solid")
                Spacer()
                Text("frosted")
            }.font(.caption).foregroundStyle(.secondary)
            if reduceTransparency {
                Text("reduce transparency is enabled in macOS").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func shift(_ amount: Double) { value = ProfileTransparency.bounded(value + amount) }
}

struct ProfileWindowSurface: View {
    var color: Color
    var transparency: Double
    var withinWindow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let opacity = ProfileTransparency.opacity(transparency, reduceTransparency: reduceTransparency)
        ZStack {
            if opacity < 1 { WindowBackdrop(withinWindow: withinWindow) }
            color.opacity(opacity)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WindowBackdrop: NSViewRepresentable {
    var withinWindow = false
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.material = .sidebar
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.state = .active
        view.identifier = .init("loaf.window.backdrop")
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: BackdropView, context: Context) {
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
    }
    final class BackdropView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit
import Combine
import SwiftUI

struct BrowserNotice: Identifiable {
    enum Kind { case zoom, favorite, pointer, copied, info }
    let id: UUID
    let kind: Kind
    let icon: LoafIcon
    let text: String
    var numericValue: Double? {
        guard kind == .zoom else { return nil }
        return Double(text.filter { $0.isNumber || $0 == "." })
    }
}

@MainActor final class BrowserFeedback: ObservableObject {
    @Published private(set) var notice: BrowserNotice?
    private var expiry: Task<Void, Never>?
    func show(_ kind: BrowserNotice.Kind, icon: LoafIcon, text: String, duration: Duration = .seconds(2)) {
        expiry?.cancel()
        let id = notice?.id ?? UUID()
        notice = BrowserNotice(id: id, kind: kind, icon: icon, text: text)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled, self?.notice?.id == id else { return }
            self?.notice = nil
        }
    }
    func clear() {
        expiry?.cancel()
        expiry = nil
        notice = nil
    }
    deinit { expiry?.cancel() }
}

struct AddressFeedback<Content: View>: View {
    @ObservedObject var feedback: BrowserFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activate: () -> Void
    var horizontalInset: CGFloat = 8
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().opacity(feedback.notice == nil ? 1 : 0)
            .blur(radius: reduceMotion || feedback.notice == nil ? 0 : 4)
            .offset(y: reduceMotion || feedback.notice == nil ? 0 : 8)
            .allowsHitTesting(feedback.notice == nil).accessibilityHidden(feedback.notice != nil)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: feedback.notice != nil)
            .overlay(alignment: .leading) {
                if let notice = feedback.notice {
                    Button(action: activate) {
                        HStack(spacing: 8) {
                            GolzheimIcon(icon: notice.icon, size: 12)
                            if let value = notice.numericValue {
                                HStack(spacing: 4) {
                                    Text("zoom ·")
                                    Text("\(Int(value))%").monospacedDigit()
                                        .contentTransition(reduceMotion ? .identity : .numericText(value: value))
                                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: value)
                                }.font(.system(size: 12)).lineLimit(1)
                            } else {
                                Text(notice.text).font(.system(size: 12)).lineLimit(1)
                                    .contentTransition(reduceMotion ? .identity : .opacity)
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: notice.text)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, horizontalInset).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).id(notice.id)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .modifier(
                                        active: AddressNoticeMotion(y: -8, blur: 4, opacity: 0),
                                        identity: AddressNoticeMotion(y: 0, blur: 0, opacity: 1)),
                                    removal: .modifier(
                                        active: AddressNoticeMotion(y: 8, blur: 4, opacity: 0),
                                        identity: AddressNoticeMotion(y: 0, blur: 0, opacity: 1)))
                        )
                        .accessibilityLabel(notice.text + ", address bar").help("search or surf...")
                }
            }.clipped().animation(
                reduceMotion ? .easeOut(duration: 0.1) : .smooth(duration: 0.26), value: feedback.notice?.id)
    }
}

private struct AddressNoticeMotion: ViewModifier {
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).offset(y: y)
    }
}

@MainActor enum LoafHaptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment, enabled: Bool) {
        guard enabled, NSApp.isActive else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

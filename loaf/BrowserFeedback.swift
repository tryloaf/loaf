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




struct BrowserNotificationToast: NSViewRepresentable {
    @ObservedObject var feedback: BrowserFeedback
    var enabled = true
    var transparency: Double = 0
    var topInset: CGFloat = 12
    var trailingInset: CGFloat = 12
    @Environment(\.self) private var environment
    func makeNSView(context: Context) -> Container { Container() }
    func updateNSView(_ view: Container, context: Context) {
        view.configure(
            notice: enabled ? feedback.notice : nil, environment: environment, transparency: transparency,
            topInset: topInset, trailingInset: trailingInset, dismiss: { feedback.clear() })
    }
    static func dismantleNSView(_ view: Container, coordinator: ()) { view.stopMotion() }

    final class Container: NSView {
        let host = BrowserNotificationCardView()
        let surface = NSView()
        private var shown = false
        private var text: String?
        private var topInset: CGFloat = 0
        private var trailingInset: CGFloat = 12
        private var reduceMotion = false
        private var pendingEntry = false
        private var pendingUpdate = false
        private var link: CADisplayLink?
        private var started: CFTimeInterval = 0
        private var duration: CFTimeInterval = 0.24
        private var offset: CGFloat = 0
        private var startOffset: CGFloat = 0
        private var targetOffset: CGFloat = 0
        private var startOpacity: CGFloat = 0
        private var targetOpacity: CGFloat = 1
        private final class TickTarget: NSObject {
            weak var view: Container?
            init(_ view: Container) { self.view = view }
            @objc func update(_ sender: CADisplayLink) {
                if let view { view.tick() } else { sender.invalidate() }
            }
        }
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            surface.wantsLayer = true
            surface.isHidden = true
            surface.addSubview(host)
            addSubview(surface)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func stopMotion() {
            link?.invalidate()
            link = nil
        }
        deinit { link?.invalidate() }
        func configure(
            notice: BrowserNotice?, environment: EnvironmentValues, transparency: Double = 0,
            topInset: CGFloat, trailingInset: CGFloat, dismiss: @escaping () -> Void
        ) {
            self.topInset = topInset
            self.trailingInset = trailingInset
            reduceMotion = environment.accessibilityReduceMotion
            if let notice {
                pendingEntry = pendingEntry || !shown
                pendingUpdate = pendingUpdate || (shown && text != notice.text)
                shown = true
                text = notice.text
                host.configure(
                    notice: notice, dark: environment.colorScheme == .dark, transparency: transparency,
                    reduceTransparency: environment.accessibilityReduceTransparency, dismiss: dismiss)
                surface.isHidden = false
                needsLayout = true
            } else if shown {
                shown = false
                pendingEntry = false
                pendingUpdate = false
                animate(entering: false)
            }
        }
        override func layout() {
            super.layout()
            guard !surface.isHidden, shown else { return }
            let size = host.fittingSize
            surface.frame = NSRect(
                x: max(0, bounds.width - trailingInset - size.width),
                y: topInset + offset, width: size.width, height: size.height)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if pendingEntry { animate(entering: true) } else if pendingUpdate { animate(entering: true, update: true) }
            pendingEntry = false
            pendingUpdate = false
        }
        private func animate(entering: Bool, update: Bool = false) {
            stopMotion()
            if entering {
                if update {
                    surface.alphaValue = 0.55
                } else if surface.alphaValue == 1 || surface.isHidden {
                    offset = reduceMotion ? 0 : -8
                    surface.alphaValue = 0
                }
            }
            startOffset = offset
            targetOffset = entering || reduceMotion ? 0 : 8
            startOpacity = surface.alphaValue
            targetOpacity = entering ? 1 : 0
            duration = reduceMotion ? 0.1 : update ? 0.18 : 0.26
            started = CACurrentMediaTime()
            position(offset: offset, opacity: startOpacity)
            let link = displayLink(target: TickTarget(self), selector: #selector(TickTarget.update(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        private func position(offset: CGFloat, opacity: CGFloat) {
            self.offset = offset
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.setFrameOrigin(NSPoint(x: surface.frame.minX, y: topInset + offset))
            surface.alphaValue = opacity
            CATransaction.commit()
        }
        private func tick() {
            let progress = min(1, max(0, (CACurrentMediaTime() - started) / duration))
            let eased =
                progress >= 1 || reduceMotion
                ? progress : Spring.smooth(duration: duration).value(target: 1.0, time: progress * duration)
            position(
                offset: startOffset + (targetOffset - startOffset) * eased,
                opacity: startOpacity + (targetOpacity - startOpacity) * eased)
            if progress >= 1 {
                stopMotion()
                if !shown {
                    surface.isHidden = true
                    host.clear()
                    text = nil
                }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard shown, !surface.isHidden else { return nil }
            let local = convert(point, from: superview)
            guard surface.frame.contains(local) else { return nil }
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMotion() }
        }
    }
}




final class BrowserNotificationCardView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let backdrop = NSVisualEffectView()
    let fill = NSView()
    private let icon = NSImageView()
    let dismissButton = NSButton()
    private var dismiss: (() -> Void)?
    private var measuredSize = NSSize.zero
    private var textWidth: CGFloat = 0
    private var textHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { measuredSize }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        backdrop.material = .sidebar
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.setAccessibilityElement(false)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 10
        fill.layer?.cornerCurve = .continuous
        fill.setAccessibilityElement(false)
        addSubview(backdrop)
        addSubview(fill)
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.lineBreakMode = .byWordWrapping
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.image =
            Golzheim.image(LoafIcon.close.rawValue, size: 9)
            ?? NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.focusRingType = .none
        dismissButton.target = self
        dismissButton.action = #selector(dismissNotice)
        dismissButton.setAccessibilityLabel("dismiss notification")
        addSubview(icon)
        addSubview(label)
        addSubview(dismissButton)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(
        notice: BrowserNotice, dark: Bool, transparency: Double = 0,
        reduceTransparency: Bool = false, dismiss: @escaping () -> Void
    ) {
        self.dismiss = dismiss
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        icon.image =
            Golzheim.image(notice.icon.rawValue, size: 13)
            ?? NSImage(systemSymbolName: notice.icon.fallback, accessibilityDescription: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let text = NSAttributedString(
            string: notice.text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        label.setAccessibilityLabel(notice.text)
        label.attributedStringValue = text

        textWidth = min(309, max(1, ceil(text.size().width) + 4))
        let measured = text.boundingRect(
            with: NSSize(width: max(1, textWidth - 4), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let cellHeight =
            label.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100_000)
            ).height ?? 0
        textHeight = ceil(max(measured.height, cellHeight))
        measuredSize = NSSize(width: 71 + textWidth, height: max(32, textHeight + 16))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let opacity = ProfileTransparency.opacity(transparency, reduceTransparency: reduceTransparency)
        backdrop.isHidden = opacity == 1
        fill.layer?.backgroundColor = NSColor(white: dark ? 0.16 : 0.97, alpha: opacity).cgColor
        layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.16 : 0.1).cgColor
        CATransaction.commit()
        needsLayout = true
    }
    func clear() {
        dismiss = nil
        label.stringValue = ""
        measuredSize = .zero
    }
    override func layout() {
        super.layout()
        backdrop.frame = bounds
        fill.frame = bounds
        icon.frame = NSRect(x: 12, y: 9, width: 15, height: 15)
        label.frame = NSRect(x: 35, y: 8, width: textWidth, height: textHeight)
        dismissButton.frame = NSRect(x: bounds.width - 28, y: 8, width: 16, height: 16)
        layer?.shadowPath = RoundedRectangle(cornerRadius: 10, style: .continuous).path(in: bounds).cgPath
    }
    @objc private func dismissNotice() { dismiss?() }
}

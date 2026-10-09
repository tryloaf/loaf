import AppKit
import Combine
import SwiftUI
import WebKit

struct PasswordFieldAnchor: Equatable {
    let rect: CGRect
    let viewport: CGSize

    init?(_ value: Any?) {
        guard let value = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, abs(number.doubleValue) < 1_000_000
            else { return nil }
            return CGFloat(number.doubleValue)
        }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
            let viewportWidth = number("viewportWidth"), let viewportHeight = number("viewportHeight"),
            width >= 2, height >= 2, viewportWidth >= 2, viewportHeight >= 2
        else { return nil }
        rect = CGRect(x: x, y: y, width: width, height: height)
        viewport = CGSize(width: viewportWidth, height: viewportHeight)
        guard rect.intersects(CGRect(origin: .zero, size: viewport)) else { return nil }
    }

    func rect(in view: NSView, webView: WKWebView) -> CGRect {
        let scale = webView.pageZoom * webView.magnification
        let top = WebKitAdapter.chromeInset(webView) ?? 0
        let scaled = CGRect(
            x: rect.minX * scale, y: top + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let native = CGRect(
            x: webView.bounds.minX + scaled.minX,
            y: webView.isFlipped ? webView.bounds.minY + scaled.minY : webView.bounds.maxY - scaled.maxY,
            width: scaled.width, height: scaled.height)
        return view.convert(native, from: webView)
    }
}

@MainActor final class PasswordSuggestionState: ObservableObject {
    @Published var anchor: PasswordFieldAnchor?
    @Published var query = ""
    @Published var selection = -1
    static func filtered(_ usernames: [String], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? usernames : usernames.filter { $0.localizedStandardContains(query) }
    }
}

struct PasswordSuggestionPlacement: Equatable {
    let frame: CGRect
    let above: Bool
    static func layout(field: CGRect, visible: CGRect, count: Int) -> Self? {
        guard count > 0, !visible.isEmpty, field.intersects(visible), visible.width >= 160 else { return nil }
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let width = min(max(field.width, 280), 360, bounds.width)
        let preferredHeight: CGFloat = 64 + CGFloat(min(count, 4)) * 42
        let below = max(0, bounds.maxY - field.maxY - gap)
        let above = max(0, field.minY - bounds.minY - gap)
        let flip = below < preferredHeight && above > below
        let height = min(preferredHeight, flip ? above : below)

        guard height >= 106 else { return nil }
        let x = min(max(field.minX, bounds.minX), bounds.maxX - width)
        let y = flip ? field.minY - gap - height : field.maxY + gap
        return Self(frame: CGRect(x: x, y: y, width: width, height: height), above: flip)
    }
}

struct PasswordSuggestionOverlay: NSViewRepresentable {
    let store: BrowserStore
    let tab: BrowserTab
    let offer: PasswordFillOffer?
    func makeNSView(context: Context) -> Surface { Surface(store: store, tab: tab) }
    func updateNSView(_ view: Surface, context: Context) { view.update(offer) }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stop() }

    final class Surface: NSView {
        override var isFlipped: Bool { true }
        weak var store: BrowserStore?
        weak var tab: BrowserTab?
        private(set) var placement: PasswordSuggestionPlacement?
        private var offer: PasswordFillOffer?
        private var card: NSHostingView<PasswordSuggestionCard>?
        private var observation: AnyCancellable?
        private var windowObservation: AnyCancellable?
        private var removal: DispatchWorkItem?
        private var showing = false
        private var keyboardTarget: String?
        private var renderedID: UUID?
        private var renderedUsers: [String] = []
        private var renderedSelection = -2
        private var renderedAbove = false

        init(store: BrowserStore, tab: BrowserTab) {
            self.store = store
            self.tab = tab
            super.init(frame: .zero)
            observation = Publishers.CombineLatest3(
                tab.passwordSuggestions.$anchor, tab.passwordSuggestions.$query, tab.passwordSuggestions.$selection
            )
            .sink { [weak self] anchor, query, selection in

                self?.position(anchor: anchor, query: query, selection: selection)
            }
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard showing, let card, card.frame.contains(convert(point, from: superview)) else { return nil }
            return card.hitTest(convert(point, from: superview))
        }
        override func layout() {
            super.layout()
            guard let state = tab?.passwordSuggestions else { return }
            position(anchor: state.anchor, query: state.query, selection: state.selection)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservation?.cancel()
            if let window {
                windowObservation = Publishers.MergeMany(
                    [
                        NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                        NSWindow.didChangeScreenNotification,
                    ].map {
                        NotificationCenter.default.publisher(for: $0, object: window)
                    }
                ).sink { [weak self] _ in self?.needsLayout = true }
            }
            needsLayout = true
        }

        private func tracking(_ action: String, _ target: String) {
            tab?.existingWebView?.callAsyncJavaScript(
                "globalThis.__loafPasswordSuggestions?.[action](targetID)",
                arguments: ["action": action, "targetID": target], in: nil, in: PageScripts.passwordWorld
            ) { _ in }
        }
        func stop() {
            if let target = offer?.targetID { tracking("deactivate", target) }
            offer = nil
            observation?.cancel()
            observation = nil
            windowObservation?.cancel()
            windowObservation = nil
            removal?.cancel()
            removal = nil
            card?.removeFromSuperview()
            card = nil
            showing = false
        }
        func update(_ newOffer: PasswordFillOffer?) {
            let newOffer = newOffer?.tabID == tab?.id ? newOffer : nil
            if offer?.id != newOffer?.id {
                if let target = offer?.targetID { tracking("deactivate", target) }
                offer = newOffer
                if let target = newOffer?.targetID { tracking("activate", target) }
            }
            if newOffer == nil { hide() }
            needsLayout = true
        }
        private func hide() {
            placement = nil
            if let target = keyboardTarget {
                visibility(false, target: target)
                keyboardTarget = nil
            }
            guard showing, let card else { return }
            showing = false
            removal?.cancel()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                card.removeFromSuperview()
                self.card = nil
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 0
            }
            let work = DispatchWorkItem { [weak self, weak card] in
                guard let self, !self.showing, self.card === card else { return }
                card?.removeFromSuperview()
                self.card = nil
                self.removal = nil
            }
            removal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
        }
        private func visibility(_ visible: Bool, target: String) {
            tab?.existingWebView?.callAsyncJavaScript(
                "globalThis.__loafPasswordSuggestions?.visibility(targetID, visible)",
                arguments: ["targetID": target, "visible": visible], in: nil, in: PageScripts.passwordWorld
            ) { _ in }
        }
        private func position(anchor: PasswordFieldAnchor?, query: String, selection: Int) {
            guard let offer, let store, let tab, let web = tab.existingWebView, let anchor, window != nil,
                web.window === window,
                PasswordVault.canFill(tab: tab, origin: offer.origin, navigationID: offer.navigationID),
                web.fullscreenState == .notInFullscreen
            else {
                hide()
                return
            }
            let users = PasswordSuggestionState.filtered(offer.usernames, query: query)
            let field = anchor.rect(in: self, webView: web)
            var visible = bounds.intersection(convert(web.visibleRect, from: web))
            if let window {
                let screenField = window.convertToScreen(convert(field, to: nil))
                let center = CGPoint(x: screenField.midX, y: screenField.midY)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? window.screen {
                    visible = visible.intersection(convert(window.convertFromScreen(screen.visibleFrame), from: nil))
                }
            }
            let inset = WebKitAdapter.chromeInset(web) ?? 0
            let webTop = convert(web.bounds, from: web).minY + inset
            visible = visible.intersection(
                CGRect(
                    x: visible.minX, y: max(visible.minY, webTop), width: visible.width,
                    height: max(0, visible.maxY - max(visible.minY, webTop))))
            guard let placement = PasswordSuggestionPlacement.layout(field: field, visible: visible, count: users.count)
            else {
                hide()
                return
            }
            let root = PasswordSuggestionCard(
                store: store, offer: offer, usernames: users, selection: selection, above: placement.above)
            removal?.cancel()
            removal = nil
            if let card {
                if renderedID != offer.id || renderedUsers != users || renderedSelection != selection
                    || renderedAbove != placement.above
                {
                    card.rootView = root
                }
            } else {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                host.wantsLayer = true
                addSubview(host)
                card = host
            }
            guard let card else { return }
            renderedID = offer.id
            renderedUsers = users
            renderedSelection = selection
            renderedAbove = placement.above
            if let target = offer.targetID, keyboardTarget != target {
                visibility(true, target: target)
                keyboardTarget = target
            }
            let appearing = !showing
            if appearing { card.layer?.removeAllAnimations() }
            showing = true
            self.placement = placement

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.frame = placement.frame
            card.alphaValue = 1
            CATransaction.commit()
            if appearing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = 0
                opacity.toValue = 1
                opacity.duration = 0.16
                let slide = CABasicAnimation(keyPath: "transform.translation.y")
                slide.fromValue = placement.above ? 4 : -4
                slide.toValue = 0
                slide.duration = 0.18
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.layer?.add(opacity, forKey: "loaf.password.appear")
                card.layer?.add(slide, forKey: "loaf.password.slide")
            }
        }
    }
}

struct PasswordSuggestionCard: View {
    let store: BrowserStore
    let offer: PasswordFillOffer
    let usernames: [String]
    let selection: Int
    let above: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                GolzheimIcon(icon: .key, size: 13).foregroundStyle(.secondary)
                Text(URL(string: offer.origin)?.host ?? offer.origin).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    store.passwordFillOffer = nil
                } label: {
                    GolzheimIcon(icon: .close, size: 11).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false).foregroundStyle(.secondary).accessibilityLabel(
                    "dismiss saved logins")
            }.padding(.horizontal, 12).frame(height: 32)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(usernames.enumerated()), id: \.element) { index, username in
                            Button {
                                guard let tab = store.selectedTab, tab.id == offer.tabID,
                                    store.passwordFillOffer?.id == offer.id
                                else { return }
                                PasswordVault.fill(
                                    tab: tab, username: username, origin: offer.origin,
                                    navigationID: offer.navigationID, targetID: offer.targetID)
                            } label: {
                                HStack(spacing: 9) {
                                    GolzheimIcon(icon: .profile, size: 14).foregroundStyle(.secondary).frame(
                                        width: 28, height: 28
                                    )
                                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                                    Text(username).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(
                                        .middle
                                    ).frame(maxWidth: .infinity, alignment: .leading)
                                    GolzheimIcon(icon: .forward, size: 11).foregroundStyle(.secondary).opacity(
                                        hovered == username || selection == index ? 1 : 0.35)
                                }.padding(.horizontal, 8).frame(height: 42)
                                    .background(
                                        Color.primary.opacity(hovered == username || selection == index ? 0.075 : 0),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).focusable(false).id(index)
                                .onHover { hovered = $0 ? username : nil }
                                .accessibilityLabel("fill login for " + username)
                                .accessibilityAddTraits(selection == index ? .isSelected : [])
                        }
                    }.padding(.horizontal, 4)
                }.scrollIndicators(.hidden)
                    .onChange(of: selection) { _, value in if value >= 0 { reader.scrollTo(value, anchor: .center) } }
            }
            HStack(spacing: 5) {
                GolzheimIcon(icon: .lock, size: 10)
                Text("unlock to fill").font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 32)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
                reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.085)))
        .shadow(color: .black.opacity(0.13), radius: 12, y: above ? -3 : 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .contain).accessibilityLabel("saved logins for " + offer.origin)
    }
}

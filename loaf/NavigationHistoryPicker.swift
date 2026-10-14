import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class NavigationHistorySelection: ObservableObject {
    weak var tab: BrowserTab?
    let entries: [WKBackForwardListItem]
    let backward: Bool
    @Published var index = 0
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool) {
        self.tab = tab; self.entries = entries; self.backward = backward
    }
    func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        index = min(entries.count - 1, max(0, index + delta))
    }
    var tint: Color {
        guard let tab, let store = tab.store else { return .accentColor }
        return profileTint(store.profileFor(tab.profileID))
    }
}

@MainActor final class NavigationHistoryPresenter: NSObject, NSPopoverDelegate {
    let selection: NavigationHistorySelection
    private let popover = NSPopover()
    private var observations = Set<AnyCancellable>()
    var onClose: (() -> Void)?
    init(tab: BrowserTab, entries: [WKBackForwardListItem], backward: Bool) {
        selection = NavigationHistorySelection(tab: tab, entries: entries, backward: backward)
        super.init()
        selection.choose = { [weak self] in self?.chooseSelection() }
        selection.dismiss = { [weak self] in self?.close() }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let rowHeights = entries.map { entry -> CGFloat in
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url.host ?? "page"
            let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            let height = text.boundingRect(with: NSSize(width: 208, height: 30), options: .usesLineFragmentOrigin).height
            return max(40, min(54, ceil(height) + 24))
        }
        let size = NSSize(width: 260, height: min(360, rowHeights.reduce(10, +) + CGFloat(max(0, entries.count - 1)) * 3))
        let host = NSHostingView(rootView: NavigationHistoryPicker(selection: selection))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let controller = NSViewController()
        controller.view = host
        popover.contentViewController = controller
        popover.contentSize = size
        tab.$isDisposed.dropFirst().sink { [weak self] disposed in if disposed { self?.close() } }.store(in: &observations)
        tab.store?.objectWillChange.sink { [weak self, weak tab] in
            DispatchQueue.main.async {
                guard let self else { return }
                if tab?.store?.selectedTab !== tab { self.close() }
            }
        }.store(in: &observations)
    }
    var isShown: Bool { popover.isShown }
    func show(anchor: NSView, rect: NSRect? = nil) {
        popover.appearance = anchor.effectiveAppearance
        popover.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func close() { popover.performClose(nil) }
    func move(by delta: Int) { selection.move(by: delta) }
    func chooseSelection() {
        guard let tab = selection.tab, selection.entries.indices.contains(selection.index) else { close(); return }
        NavigationHistory.go(tab, to: selection.entries[selection.index])
        close()
    }
    func popoverDidClose(_ notification: Notification) { observations.removeAll(); onClose?() }
}

struct NavigationHistoryPicker: View {
    @ObservedObject var selection: NavigationHistorySelection
    @Namespace private var bubble
    @State private var appeared = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.73) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(selection.entries.indices, id: \.self) { index in
                            let entry = selection.entries[index]
                            Button { selection.index = index; selection.choose?() } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    historyIcon(entry).padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url.host ?? "page")
                                            .font(.system(size: 12, weight: .medium)).lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(entry.url.host ?? entry.url.scheme ?? "page")
                                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 9).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        if selection.index == index {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(selection.tint.opacity(0.16))
                                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection.tint.opacity(0.28)))
                                                .matchedGeometryEffect(id: "selection", in: bubble)
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(LoafButtonStyle()).id(index)
                                .onHover { inside in if inside { withAnimation(motion) { selection.index = index } } }
                                .accessibilityValue(selection.index == index ? "selected" : "")
                        }
                    }.padding(5).animation(motion, value: selection.index)
                }.scrollIndicators(.hidden)
                    .onChange(of: selection.index) { _, index in withAnimation(motion) { proxy.scrollTo(index) } }
            }
        }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; withAnimation(motion) { appeared = true } }
        .onKeyPress(.upArrow) { withAnimation(motion) { selection.move(by: -1) }; return .handled }
        .onKeyPress(.downArrow) { withAnimation(motion) { selection.move(by: 1) }; return .handled }
        .onKeyPress(.return) { selection.choose?(); return .handled }
        .onKeyPress(.escape) { selection.dismiss?(); return .handled }
    }
    @ViewBuilder private func historyIcon(_ entry: WKBackForwardListItem) -> some View {
        if let tab = selection.tab, let store = tab.store,
            let image = store.application.favicons.cachedImage(for: entry.url,
                privateID: store.profileFor(tab.profileID).privateMode ? tab.profileID : nil) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
        } else { GolzheimIcon(icon: .globe, size: 16).foregroundStyle(.secondary) }
    }
}

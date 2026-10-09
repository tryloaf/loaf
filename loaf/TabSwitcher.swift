import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor final class TabSwitcher: ObservableObject {
    weak var store: BrowserWindowState?
    @Published private(set) var visible = false
    @Published private(set) var selectedID: UUID?
    private(set) var ids: [UUID] = []
    private var profileID: UUID?
    private var reveal: Task<Void, Never>?
    private var active = false
    init(store: BrowserWindowState) { self.store = store }
    var tabs: [BrowserTab] {
        guard let store, let profileID, profileID == store.selectedProfileID,
            let runtime = store.application.runtimes[profileID]
        else { return [] }
        let current = Set((store.workspaces[profileID]?.tabs ?? []).map(\.id))
        let live = runtime.tabs
        return ids.compactMap { id in
            guard current.contains(id), let tab = live[id], tab.windowID == store.id, !tab.isDisposed else {
                return nil
            }
            return tab
        }
    }
    var displayedTabs: [BrowserTab] { displayedTabs(from: tabs) }
    func displayedTabs(from all: [BrowserTab]) -> [BrowserTab] {
        guard all.count > 16 else { return all }
        let selected = all.firstIndex { $0.id == selectedID } ?? 0
        let start = min(max(0, selected - 7), all.count - 16)
        return Array(all[start..<start + 16])
    }
    func step(_ direction: Int) {
        guard let store, store.application.profiles.contains(where: { $0.id == store.selectedProfileID }) else {
            return
        }
        let current = store.tabs
        guard current.count > 1 else { return }
        if !active {
            ids = current.map(\.id)
            profileID = store.selectedProfileID
            selectedID = store.selectedTab?.id
            active = true
            reveal = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !Task.isCancelled, self.active, self.profileID == self.store?.selectedProfileID else {
                    return
                }
                if let tab = self.store?.selectedTab { self.store?.application.tabPreviews.capture(tab) }
                self.visible = true
            }
        }
        guard profileID == store.selectedProfileID else {
            finish(commit: false)
            return
        }
        let currentIDs = Set(current.map(\.id))
        ids = ids.filter { currentIDs.contains($0) }
        guard !ids.isEmpty else {
            finish(commit: false)
            return
        }
        let index = ids.firstIndex(of: selectedID ?? ids[0]) ?? 0
        selectedID = ids[(index + direction + ids.count) % ids.count]

    }
    func finish(commit: Bool) {
        reveal?.cancel()
        reveal = nil
        if commit, profileID == store?.selectedProfileID, let tab = tabs.first(where: { $0.id == selectedID }) {
            store?.select(tab)
        }
        visible = false
        active = false
        selectedID = nil
        ids = []
        profileID = nil
    }
    func closeSelected() {
        guard visible, let store, let tab = tabs.first(where: { $0.id == selectedID }) else { return }
        let index = ids.firstIndex(of: tab.id) ?? 0
        ids.removeAll { $0 == tab.id }
        selectedID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
        store.close(tab)
        if ids.isEmpty { finish(commit: false) }
    }
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if active && !event.modifierFlags.contains(.control) {
                finish(commit: true)
            }
            return false
        }
        guard event.type == .keyDown else { return false }
        if active, event.keyCode == 53 {
            finish(commit: false)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.control, .shift, .command, .option])
        guard modifiers == [.control] || modifiers == [.control, .shift],
            (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true
        else { return false }
        if event.keyCode == 48 {
            step(modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        if event.keyCode == 13, visible {
            closeSelected()
            return true
        }
        return false
    }
    deinit { reveal?.cancel() }
}

struct TabSwitcherView: View {
    @ObservedObject var switcher: TabSwitcher
    @ObservedObject var previews: TabPreviewCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            if switcher.visible {
                let all = switcher.tabs
                let displayed = switcher.displayedTabs(from: all)
                let available = min(geometry.size.width - 32, 620)
                let columns = min(max(1, displayed.count), TabSwitcherMetrics.columns(available: available))
                let width = min(available, CGFloat(columns) * 140 + CGFloat(columns - 1) * 8 + 24)
                let rows = max(1, Int(ceil(Double(displayed.count) / Double(columns))))
                let previewHeight = max(0, min(64, (geometry.size.height - 130) / CGFloat(rows) - 42))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("tabs").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("release ⌃ to open · ⌃W close").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8)
                    {
                        ForEach(displayed) { tab in
                            card(tab, previewHeight: previewHeight).id(tab.id)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(tab.id == switcher.selectedID ? .isSelected : [])
                        }
                    }.transaction { $0.animation = nil }
                    if all.count > 16 {
                        Text("\(all.count) tabs · showing 16 around your selection").font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }.padding(12).frame(width: width)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
            }
        }.animation(
            reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.18, bounce: 0), value: switcher.visible)
    }
    private func card(_ tab: BrowserTab, previewHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: tab.existingWebView?.underPageBackgroundColor ?? .windowBackgroundColor)
                if let image = previews.image(for: tab) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    GolzheimIcon(icon: tab.page == .web ? .globe : .book, size: 20).foregroundStyle(.tertiary)
                }
            }.frame(height: previewHeight).clipped()
                .overlay(alignment: .topLeading) {
                    if let group = switcher.store?.tabGroups.first(where: { $0.id == tab.groupID }) {
                        HStack(spacing: 4) {
                            EmojiIcon(glyph: group.icon, size: 9)
                            Text(group.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(4).background(.regularMaterial).overlay(
                            (switcher.store?.profile.privateMode == true
                                ? PrivateChrome.accent : profileTint(group.color)).opacity(0.1)
                        ).allowsHitTesting(false)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    SiteIcon(tab: tab, size: 12).frame(width: 12, height: 12)
                    Text(tab.sidebarTitle).font(.system(size: 11)).lineLimit(1)
                }
                Text(TabSwitcherMetrics.baseURL(tab.url)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(
                    1)
            }.padding(7)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tab.id == switcher.selectedID ? Color.primary.opacity(0.08) : Color.primary.opacity(0.025))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: tab.id == switcher.selectedID)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(tab.id == switcher.selectedID ? 0.25 : 0.06), lineWidth: 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: tab.id == switcher.selectedID)
            }
    }
}

import AppKit
import SwiftUI

enum TraySection: String, CaseIterable {
    case downloads, history, favorites, more
    var icon: LoafIcon {
        switch self {
        case .downloads: .download
        case .history: .history
        case .favorites: .favorite
        case .more: .more
        }
    }
    var page: BrowserPage? {
        switch self {
        case .downloads: .downloads
        case .history: .history
        case .favorites: .favorites
        case .more: nil
        }
    }
}

@MainActor enum TrayPreview {
    static func history(_ profile: Profile) -> [Visit] { profile.privateMode ? [] : Array(profile.history.prefix(3)) }
    static func favorites(_ profile: Profile) -> [Favorite] {
        Array(profile.favorites.filter { $0.folderID == nil }.prefix(3))
    }
    static func downloads(_ manager: DownloadManager, profileID: UUID) -> [DownloadItem] {
        Array(manager.items.lazy.filter { $0.profileID == profileID }.prefix(3))
    }
}

struct SidebarTrayContent: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var downloads: DownloadManager
    @Binding var section: TraySection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let collapse: () -> Void
    init(store: BrowserStore, section: Binding<TraySection>, collapse: @escaping () -> Void) {
        self.store = store
        downloads = store.downloads
        _section = section
        self.collapse = collapse
    }
    var body: some View {
        VStack(spacing: 6) {
            TraySectionPicker(section: $section, swipeOffset: store.traySwipeDistance)
            ZStack(alignment: .top) {
                details

                    .transaction { $0.animation = nil }
                    .id(section)
                    .transition(reduceMotion ? .identity : .opacity)
            }.frame(height: 180, alignment: .top)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: section)
        }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .accessibilityElement(children: .contain).accessibilityLabel("tray contents")
    }
    private var details: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                GolzheimIcon(icon: section.icon, size: 16, weight: 220)
                Text(section.rawValue).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }.frame(height: 22).padding(.horizontal, 4)
            previews.frame(height: 122).frame(maxWidth: .infinity, alignment: .topLeading)
            if let page = section.page {
                Button {
                    store.showPage(page)
                    collapse()
                } label: {
                    HStack(spacing: 6) {
                        Text("all " + section.rawValue)
                        Spacer(minLength: 0)
                        GolzheimIcon(icon: .external, size: 12, weight: 220)
                    }
                    .font(.system(size: 11)).frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(TrayRowStyle()).help("open full " + section.rawValue + " view")
            } else {
                Button {
                    store.showPage(.about)
                    collapse()
                } label: {
                    HStack {
                        Text("about loaf")
                        Spacer(minLength: 0)
                        GolzheimIcon(icon: .external, size: 12)
                    }.font(.system(size: 11)).frame(height: 24)
                }.buttonStyle(TrayRowStyle())
            }
        }
    }
    @ViewBuilder private var previews: some View {
        switch section {
        case .history:
            let items = TrayPreview.history(store.profile)
            if items.isEmpty {
                empty(
                    store.profile.privateMode ? "private visits stay private" : "no recent visits",
                    detail: store.profile.privateMode
                        ? "history isn’t saved in this session." : "pages you visit appear here.")
            } else {
                VStack(spacing: 4) { ForEach(items) { item in siteRow(title: item.title, address: item.address) } }
            }
        case .favorites:
            let items = TrayPreview.favorites(store.profile)
            if items.isEmpty {
                empty("no favorites yet", detail: "save a site with ⌘D.")
            } else {
                VStack(spacing: 4) { ForEach(items) { item in siteRow(title: item.title, address: item.address) } }
            }
        case .downloads:
            let items = TrayPreview.downloads(downloads, profileID: store.selectedProfileID)
            if items.isEmpty {
                empty("no recent downloads", detail: "transfers in this profile appear here.")
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in TrayDownloadRow(item: item, manager: downloads, store: store) }
                }
            }
        case .more:
            VStack(spacing: 0) {
                utility(.cookie, "cookies and site data") {
                    store.showPage(.cookies)
                    collapse()
                }
                utility(.extensionPuzzle, "extensions") {
                    store.showPage(.extensions)
                    collapse()
                }
                utility(.settings, "settings…") {
                    store.application.coordinator?.showSettings(for: store)
                    collapse()
                }

            }
        }
    }
    private func siteRow(title: String, address: String) -> some View {
        Button {
            store.navigate(address, inNewTab: true)
        } label: {
            HStack(spacing: 8) {
                WebsiteIcon(url: URL(string: address), store: store, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrowserAddress.visible(title.isEmpty ? address : title)).font(.system(size: 11)).lineLimit(1)
                    Text(URL(string: address)?.host ?? BrowserAddress.visible(address)).font(.system(size: 10))
                        .foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 38).contentShape(Rectangle())
        }.buttonStyle(TrayRowStyle()).help(BrowserAddress.visible(address))
    }
    private func utility(_ icon: LoafIcon, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GolzheimIcon(icon: icon, size: 16)
                Text(title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                GolzheimIcon(icon: .external, size: 11)
            }.frame(height: 30)
        }.buttonStyle(TrayRowStyle())
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).fixedSize(
            horizontal: false, vertical: false)
    }
}

struct TraySectionPicker: View {
    @Binding var section: TraySection
    var swipeOffset: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let items = TraySection.allCases
            let width = max(0, (geometry.size.width - 6 - CGFloat(items.count - 1) * 2) / CGFloat(items.count))
            let index = items.firstIndex(of: section) ?? 0
            let travel = CGFloat(index) * (width + 2) + swipeOffset
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(width: width, height: 22)
                    .offset(x: 3 + min(CGFloat(items.count - 1) * (width + 2), max(0, travel)))
                    .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0), value: section)
                HStack(spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            section = item
                            focused = true
                        } label: {
                            GolzheimIcon(icon: item.icon, size: 16, weight: 220).frame(maxWidth: .infinity).frame(
                                height: 22
                            ).contentShape(Rectangle())
                        }.buttonStyle(.plain).focusable(false)
                            .help(item.rawValue).accessibilityLabel(item.rawValue)
                            .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }.padding(3)
            }.background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.frame(height: 28)
            .focusable(interactions: .edit).focused($focused).focusEffectDisabled()
            .accessibilityElement(children: .contain).accessibilityLabel("tray sections").accessibilityValue(
                section.rawValue
            )
            .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end], phases: [.down, .repeat]) { press in
                guard focused, press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return .ignored
                }
                let items = TraySection.allCases
                guard let index = items.firstIndex(of: section) else { return .ignored }
                let destination =
                    press.key == .home
                    ? 0
                    : press.key == .end
                        ? items.count - 1 : max(0, min(items.count - 1, index + (press.key == .rightArrow ? 1 : -1)))
                section = items[destination]
                return .handled
            }
    }
}

private struct TrayRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TrayRowSurface(content: configuration.label, pressed: configuration.isPressed)
    }
}
private struct TrayRowSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @State private var hovered = false
    var body: some View {
        content.padding(.horizontal, 4).background(
            Color.primary.opacity(pressed ? 0.09 : hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6)
        ).onHover { hovered = $0 }
    }
}
private struct TrayDownloadRow: View {
    @ObservedObject var item: DownloadItem
    let manager: DownloadManager
    let store: BrowserStore
    var body: some View {
        HStack(spacing: 6) {
            GolzheimIcon(icon: .download, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 11)).lineLimit(1).help(item.name)
                if item.finished || item.error != nil {
                    Text(item.finished ? "saved" : item.error ?? "interrupted").font(.system(size: 10)).foregroundStyle(
                        .secondary
                    ).lineLimit(1)
                } else {
                    ProgressView(value: item.fraction).progressViewStyle(.linear).controlSize(.mini).accessibilityLabel(
                        "download progress")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.finished, let destination = item.destination {
                IconButton(icon: .external, label: "show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } else if item.canRetrySave {
                IconButton(icon: .download, label: "save again…") { manager.retrySave(item, in: store) }
            } else if item.resumeData != nil {
                IconButton(icon: .reload, label: "resume download") { manager.resume(item, in: store) }
            } else if !item.finished && item.error == nil {
                IconButton(icon: .close, label: "cancel download") { manager.cancel(item) }
            }
        }.frame(height: 38).padding(.horizontal, 4)
    }
}

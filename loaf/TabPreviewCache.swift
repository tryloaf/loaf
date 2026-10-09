import AppKit
import Combine
import WebKit

@MainActor final class TabPreviewCache: ObservableObject {
    private struct Entry {
        let image: NSImage
        let profileID: UUID
        let navigationID: UUID
    }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var pending = Set<UUID>()
    let capacity = 12
    func image(for tab: BrowserTab) -> NSImage? {
        guard let entry = entries[tab.id], entry.navigationID == tab.navigationID, entry.profileID == tab.profileID
        else { return nil }
        return entry.image
    }
    func capture(_ tab: BrowserTab) {
        guard let view = tab.existingWebView, tab.page == .web, tab.url != nil,
            !view.isLoading, tab.navigationError == nil, view.window != nil,
            view.bounds.width > 0, view.bounds.height > 0,
            view.fullscreenState == .notInFullscreen, !pending.contains(tab.id)
        else { return }
        let id = tab.id
        let profileID = tab.profileID
        let token = tab.navigationID
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(
            x: 0, y: 0, width: view.bounds.width, height: min(view.bounds.height, view.bounds.width * 9 / 16))
        config.snapshotWidth = 360
        config.afterScreenUpdates = false
        pending.insert(id)
        view.takeSnapshot(with: config) { [weak self, weak tab, weak view] image, _ in
            guard let self else { return }
            self.pending.remove(id)
            guard let tab, let view, tab.existingWebView === view,
                tab.navigationID == token, let image
            else { return }
            self.entries[id] = Entry(image: image, profileID: profileID, navigationID: token)
            self.order.removeAll { $0 == id }
            self.order.append(id)
            while self.order.count > self.capacity { self.entries.removeValue(forKey: self.order.removeFirst()) }
            self.objectWillChange.send()
        }
    }
    func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
        pending.remove(id)
        objectWillChange.send()
    }
    func forgetProfile(_ id: UUID) { for key in entries.keys.filter({ entries[$0]?.profileID == id }) { remove(key) } }
    var count: Int { entries.count }
}

struct TabSwitcherMetrics {
    static func cardWidth(available: CGFloat) -> CGFloat { min(140, max(100, available - 24)) }
    static func columns(available: CGFloat) -> Int { max(1, min(4, Int((available - 24 + 8) / (100 + 8)))) }
    static func baseURL(_ url: URL?) -> String {
        guard let url else { return "new tab" }
        if let host = url.host { return host + (url.port.map { ":\($0)" } ?? "") }
        return BrowserAddress.display(url)
    }
}

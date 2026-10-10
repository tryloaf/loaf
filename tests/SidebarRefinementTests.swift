import AppKit
import NaturalLanguage
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@testable import loaf

@MainActor final class SidebarDropFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("loaf.refinement." + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@main struct SidebarRefinementTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let headless = Bundle.main.object(forInfoDictionaryKey: "LoafHeadless") as? Bool == true
        NSApp.setActivationPolicy(headless ? .prohibited : .regular)
        Task { @MainActor in
            do {
                if headless { try await checkMotionGeometry() } else { try await run() }
            } catch {
                print("FAIL:", error)
                exit(1)
            }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor static func checkMotionGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loaf-motion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = BrowserApplication(directory: directory, prepareServices: false)
        for _ in 0..<100 where !application.ready { try await Task.sleep(for: .milliseconds(10)) }
        let store = application.initialWindows()[0]
        defer { store.dispose() }
        let member = store.newTab(showOmnibar: false)
        let folder = store.createTabGroup(with: member)
        store.toggleGroupPin(folder)
        store.editingGroupID = nil
        store.close(member)
        let preview = store.sidebarEntries.compactMap(\.tab).first { $0.groupID == folder }!
        store.setPinPresentation(preview, row: true)
        guard store.rowPinnedTabs.contains(where: { !$0.isDisposed && $0.groupID == nil }),
            store.tabs.contains(where: { $0.pinned && $0.pinPresentation == "row" })
        else {
            throw NSError(
                domain: "Motion geometry", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "A closed folder member must open before becoming an independent pin"
                ])
        }
        print("CHECK: a closed folder member can become a row pin")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let viewport = PageViewport<Color>.Container(content: .init(content: .yellow, environment: .init()))
        viewport.frame = root.bounds
        root.addSubview(viewport)
        let dock = SidebarDockHost.ContainerView(pane: .init(store: store, scheme: .light, floating: false))
        dock.frame = NSRect(x: 0, y: 0, width: 252, height: 700)
        root.addSubview(dock)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let width: CGFloat = 220
        for shown in [true, false, true, false, true] {
            let previous = viewport.surface.frame.size
            viewport.configure(
                leading: shown ? width : 8, edge: 8, radius: 10,
                sidebarPresented: shown, reduceMotion: false)
            viewport.layoutSubtreeIfNeeded()
            dock.configure(
                width: width, shown: shown, duration: SidebarMotion.duration, reduceMotion: false,
                hiddenOffset: -width - 32)
            dock.layoutSubtreeIfNeeded()
            if previous.width > 0 {
                guard let clip = viewport.surface.layer?.animation(forKey: "sidebarBounds"),
                    let transform = viewport.contentSurface.layer?.animation(forKey: "sidebarContentScale")
                        as? CABasicAnimation,
                    let scale = transform.fromValue as? CATransform3D,
                    abs(scale.m11 - previous.width / viewport.surface.bounds.width) < 0.00001,
                    dock.moving && abs(clip.duration - dock.motionDuration) < 0.00001,
                    abs(clip.duration - transform.duration) < 0.00001,
                    dock.hostedSidebar.layer?.masksToBounds == true,
                    clip.beginTime == 0,
                    abs(clip.beginTime - transform.beginTime) < 0.00001
                else {
                    throw NSError(
                        domain: "Motion geometry", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Page, clip, and native sidebar must use the reference duration and continuous geometry"
                        ])
                }
                let contentLayer = viewport.contentSurface.layer!
                let position = contentLayer.animation(forKey: "sidebarContentPosition") as! CABasicAnimation
                let sourcePosition = position.fromValue as! CGPoint
                let destination = contentLayer.bounds.size
                for phase: CGFloat in [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1] {
                    let sx = scale.m11 + (1 - scale.m11) * phase
                    let sy = scale.m22 + (1 - scale.m22) * phase
                    let center = CGPoint(
                        x: sourcePosition.x + (contentLayer.position.x - sourcePosition.x) * phase,
                        y: sourcePosition.y + (contentLayer.position.y - sourcePosition.y) * phase)
                    let contents = CGRect(
                        x: center.x - contentLayer.anchorPoint.x * destination.width * sx,
                        y: center.y - contentLayer.anchorPoint.y * destination.height * sy,
                        width: destination.width * sx, height: destination.height * sy)
                    let clipWidth = previous.width + (destination.width - previous.width) * phase
                    let clipHeight = previous.height + (destination.height - previous.height) * phase
                    guard abs(contents.minX) < 0.001, abs(contents.minY) < 0.001,
                        abs(contents.maxX - clipWidth) < 0.001, abs(contents.maxY - clipHeight) < 0.001
                    else { throw NSError(domain: "Motion geometry", code: 8) }
                }
                print("CHECK: page morph and native sidebar use the reference duration, shown=\(shown)")
                print("CHECK: page fills all four clip edges from the first frame through the complete morph")
                print("CHECK: native sidebar rows are clipped during their delayed exit")
            }
            viewport.stopMotion()
            dock.stopMotion()
            dock.configure(
                width: width, shown: !shown, duration: SidebarMotion.duration, reduceMotion: true,
                hiddenOffset: -width - 32)
            dock.configure(
                width: width, shown: shown, duration: SidebarMotion.duration, reduceMotion: true,
                hiddenOffset: -width - 32)
        }
        let image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath.fill(rect)
            return true
        }
        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let snapshot = WebViewHost.HostView.ResizeImageView(
            image: pixels, sourceSize: image.size,
            frame: root.bounds, background: NSColor.white.cgColor)
        for destinationWidth: CGFloat in [780, 984] {
            snapshot.update(frame: NSRect(x: 0, y: 0, width: destinationWidth, height: 600), contentHeight: 600)
            guard snapshot.imageLayer.frame == snapshot.bounds
            else {
                throw NSError(
                    domain: "Motion geometry", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Snapshots must fill their viewport during the morph"])
            }
        }
        snapshot.update(frame: NSRect(x: 0, y: 0, width: 780, height: 620), contentHeight: 588)
        guard snapshot.imageLayer.frame.height == 588, snapshot.topInset == 32 else {
            throw NSError(domain: "Motion geometry", code: 9)
        }
        print("CHECK: snapshots fill the morph and interpolate height when toolbar insets change")
        let webTab = store.newTab(showOmnibar: false)
        let webView = webTab.webView
        let webHost = WebViewHost.HostView(frame: NSRect(x: 0, y: 0, width: 772, height: 600))
        webHost.wantsLayer = true
        webView.frame = webHost.bounds
        webView.autoresizingMask = []
        webHost.addSubview(webView)
        webHost.hostedWebView = webView
        webTab.webViewHost = webHost
        root.addSubview(webHost)
        webView.loadHTMLString("<body style='background:#ffe;width:100%'>instant sidebar</body>", baseURL: nil)
        try await Task.sleep(for: .milliseconds(150))
        webHost.layoutSubtreeIfNeeded()
        let sourceFrame = webView.frame
        let started = ProcessInfo.processInfo.systemUptime
        store.sidebarVisible = false
        guard !store.sidebarPresented, ProcessInfo.processInfo.systemUptime - started < 0.016 else {
            throw NSError(
                domain: "Motion geometry", code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "The shortcut must update presentation before any snapshot callback"
                ])
        }
        print("CHECK: sidebar presentation changes immediately without waiting for capture")
        webHost.viewportSize = CGSize(width: 984, height: 600)
        webHost.sidebarDidChange()
        webHost.frame.size.width = 984
        webHost.layoutSubtreeIfNeeded()
        guard webHost.preparingResizeSnapshot, webView.frame == sourceFrame,
            let liveLayer = webView.layer, abs(liveLayer.frame.width - 984) < 0.5,
            abs(liveLayer.frame.maxX - 984) < 0.5
        else {
            throw NSError(
                domain: "Motion geometry", code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Pending capture must fill the moving viewport without WebKit reflow"
                ])
        }
        print("CHECK: pending capture fills the live surface without WebKit reflow")
        for _ in 0..<24 where webHost.preparingResizeSnapshot {
            try await Task.sleep(for: .milliseconds(10))
        }
        print(
            "CHECK: capture state visible=\(webHost.resizeSnapshotVisible), pending=\(webHost.preparingResizeSnapshot), width=\(webView.frame.width), identity=\(CATransform3DIsIdentity(webView.layer!.transform))"
        )
        guard webHost.resizeSnapshotVisible, !webHost.preparingResizeSnapshot,
            CATransform3DIsIdentity(webView.layer!.transform), webView.frame.width == 984
        else {
            throw NSError(
                domain: "Motion geometry", code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: "Capture must restore live geometry and commit the final WebKit size"
                ])
        }
        print("CHECK: asynchronous capture hands off without a second scale or trailing gap")
        webHost.cancelResizeSnapshot()
        webHost.beginResizeSnapshot()
        webHost.viewportSize = CGSize(width: 772, height: 600)
        webHost.frame.size.width = 772
        webHost.layoutSubtreeIfNeeded()
        guard abs(webView.layer!.frame.width - 772) < 0.5, abs(webView.layer!.frame.maxX - 772) < 0.5 else {
            throw NSError(domain: "Motion geometry", code: 10)
        }
        print("CHECK: reversing the pending capture fills the smaller viewport")
        webHost.cancelResizeSnapshot()
        guard CATransform3DIsIdentity(webView.layer!.transform), webView.frame.width == 772 else {
            throw NSError(domain: "Motion geometry", code: 7)
        }
        print("CHECK: cancelling a pending capture restores the live surface")
        print("PASS: immediate sidebar motion, continuous page morph, and complete edge coverage")
    }
    @MainActor static func run() async throws {
        setbuf(stdout, nil)
        let repository = Bundle.main.object(forInfoDictionaryKey: "LoafRepository") as! String
        FileManager.default.changeCurrentDirectoryPath(repository)
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "Sidebar refinement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
            print("CHECK:", message)
        }
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
        }
        func settle(_ ms: Int = 150) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "loaf-refinements-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = BrowserApplication(directory: directory, prepareServices: false)
        for _ in 0..<100 where !app.ready { try await settle(10) }
        let coordinator = WindowCoordinator(application: app)
        let store = app.initialWindows()[0]
        defer {
            store.nativeWindow?.close()
            store.dispose()
        }
        store.preferences.weatherCity = ""
        let tabs = (0..<5).map { i in
            let tab = store.newTab(showOmnibar: false)
            tab.title = "row \(i)"
            tab.url = URL(string: "https://fixture.invalid/\(i)")
            store.tabChanged(tab)
            return tab
        }
        store.setPinPresentation(tabs[0], row: false)
        store.setPinPresentation(tabs[1], row: true)
        try expect(
            store.gridPinnedTabs.map(\.id) == [tabs[0].id] && store.rowPinnedTabs.map(\.id) == [tabs[1].id],
            "Grid shortcuts and row pins coexist")
        try expect(store.sidebarEntries.first?.id == tabs[1].id, "Row pins appear above the new-tab divider")
        let saved = try JSONDecoder().decode(SavedTab.self, from: JSONEncoder().encode(tabs[1].saved))
        try expect(saved.pinPresentation == "row", "Row-pin presentation survives serialization")
        store.close(tabs[1])
        let preview = store.rowPinnedTabs[0]
        try expect(
            preview.pinPresentation == "row" && !preview.isDisposed, "Closing a pinned page retains a row shortcut")
        store.setPinPresentation(preview, row: false)
        try expect(
            store.rowPinnedTabs.isEmpty && store.gridPinnedTabs.count == 2, "A closed row pin can move to the grid")
        store.setPinPresentation(tabs[0], row: true)
        let groupID = store.createTabGroup(with: tabs[2])
        store.assignTab(tabs[3], to: groupID)
        store.editingGroupID = nil
        coordinator.show(store)
        NSApp.activate()
        try await settle(350)
        let window = store.nativeWindow!
        let root = window.contentView!
        let scroll = descendants(root, TabListView.TabScrollView.self)[0]
        func point(_ y: CGFloat) -> NSPoint {
            let document = scroll.documentView!
            return document.convert(NSPoint(x: 50, y: document.isFlipped ? y : document.bounds.height - y), to: nil)
        }
        let source = descendants(root, TabDragArea.DragView.self).first { $0.tab === tabs[3] }!
        let drop = SidebarDropFixture()
        drop.draggingDestinationWindow = window
        drop.draggingSource = source
        drop.draggingPasteboard.setData(
            try JSONEncoder().encode(TabDrag(window: store.id, profile: store.selectedProfileID, tab: tabs[3].id)),
            forType: .init(UTType.loafTab.identifier))
        store.draggedTabID = tabs[3].id
        let index = store.sidebarEntries.firstIndex { $0.id == tabs[3].id }!
        drop.draggingLocation = point(scroll.insertionLayout.offset(at: index) + 30)
        try expect(
            scroll.draggingUpdated(drop) == .move && store.draggedGroupTargetID == nil,
            "Bottom edge of the last folder member is an outside drop target")
        try expect(
            scroll.performDragOperation(drop) && tabs[3].groupID == nil,
            "Dragging below a folder removes the tab from it")
        try expect(
            store.sidebarEntries.firstIndex { $0.id == tabs[3].id }! > store.sidebarEntries.firstIndex {
                $0.id == groupID
            }!, "Extracted tab follows the complete folder")
        try await settle()
        let external = SidebarDropFixture()
        external.draggingSourceOperationMask = .copy
        external.draggingDestinationWindow = window
        external.draggingPasteboard.setString("https://example.invalid/dragged", forType: .URL)
        let header = store.sidebarEntries.firstIndex { $0.id == groupID }!
        external.draggingLocation = point(scroll.insertionLayout.offset(at: header) + 16)
        try expect(
            scroll.draggingUpdated(external) == .copy && scroll.prepareForDragOperation(external),
            "External browser URL drags are accepted")
        try expect(scroll.performDragOperation(external), "Dropping an external URL opens a page")
        try expect(
            store.tabs.contains {
                $0.url?.absoluteString == "https://example.invalid/dragged" && $0.groupID == groupID
            }, "External URL drops retain the folder destination")
        external.draggingPasteboard.clearContents()
        external.draggingPasteboard.setString(
            "javascript:alert(1)\nfile:///tmp/private\nhttps://user:password@example.invalid/", forType: .string)
        try expect(
            BrowserDragTypes.urls(external.draggingPasteboard).isEmpty,
            "External drag import rejects scripts, files, and credentials")
        external.draggingPasteboard.clearContents()
        external.draggingPasteboard.setString(
            "https://example.invalid/a\nhttps://example.invalid/b\nhttps://example.invalid/a", forType: .string)
        try expect(
            BrowserDragTypes.urls(external.draggingPasteboard).count == 2,
            "Text link drags import multiple distinct URLs")
        let searchDocument = LocalPageSearch.Document(
            title: "loaf web browser – Google Search", address: "https://www.google.com/search?q=loaf+web+browser")
        try expect(
            searchDocument.score(.init("loaf google")) != nil && searchDocument.score(.init("google loaf")) != nil,
            "Search matches query terms across title and address in either order")
        try expect(
            LocalPageSearch.Document(title: "Swift reference", address: "https://developer.invalid/").score(
                .init("swift docs")) != nil,
            "Related browser vocabulary works without a downloaded language model")
        let embedding = NLEmbedding.wordEmbedding(for: .english)
        if let embedding,
            let related = embedding.neighbors(for: "recipe", maximumCount: 4).first(where: { $0.1 <= 0.45 })
        {
            try expect(
                LocalPageSearch.Document(title: related.0, address: "https://food.invalid/").score(
                    .init("recipe", embedding: embedding)) != nil, "Local language embeddings match related words")
        }
        let visit = Visit(title: "loaf web browser – Google Search", address: "https://www.google.com/search?q=loaf")
        store.updateCurrent { $0.history = [visit] }
        let engine = SuggestionEngine(fetch: { _ in Data() })
        engine.update("loaf google", store: store)
        try expect(
            engine.suggestions.contains { $0.destination == visit.address && $0.visibleTitle == visit.title },
            "Wonderbar retains and searches the actual page title")
        let history = HistoryPresentation(store: store)
        history.query = "loaf google"
        try expect(history.ordered == [visit.id], "History library uses the same multi-term matching")
        store.updateCurrent {
            $0.history =
                (0..<600).map { Visit(title: "fixture \($0)", address: "https://history.invalid/\($0)") } + [visit]
        }
        history.query = "google loaf"
        for _ in 0..<100 where history.isBusy { try await settle(20) }
        try expect(history.ordered == [visit.id], "Background history search matches the synchronous search semantics")
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let previousSession = UUID()
        let recent = (0..<10).map {
            Visit(
                title: "recent \($0)", address: "https://recent.invalid/\($0)",
                date: now.addingTimeInterval(-Double($0)), sessionID: app.browsingSessionID)
        }
        let oldSession = Visit(
            title: "session", address: "https://session.invalid/", date: today.addingTimeInterval(60),
            sessionID: previousSession)
        let oldDay = Visit(title: "day", address: "https://day.invalid/", date: today.addingTimeInterval(-86400))
        let oldWeek = Visit(
            title: "week", address: "https://week.invalid/", date: today.addingTimeInterval(-86400 * 14))
        let sections = HistoryMenuSections(
            visits: recent + [oldSession, oldDay, oldWeek], currentSession: app.browsingSessionID, now: now)
        try expect(
            sections.recent.count == 10 && sections.sessions.count == 1 && sections.days.count == 1
                && sections.weeks.count == 1, "History menus partition ten recent pages, sessions, days, and weeks")
        let menus = LoafMainMenus(coordinator: coordinator)
        menus.install()
        store.updateCurrent {
            $0.favorites = [
                Favorite(
                    title: String(repeating: "long bookmark title ", count: 40), address: "https://bookmark.invalid/")
            ]
        }
        let bookmarks = NSApp.mainMenu!.items.first { $0.title == "bookmarks" }!.submenu!
        menus.menuNeedsUpdate(bookmarks)
        let bookmark = bookmarks.items.first { ($0.representedObject as? String) == "https://bookmark.invalid/" }!
        try expect(
            bookmark.image != nil && bookmark.attributedTitle!.size().width <= 280,
            "Bookmarks show icons and restrict title width")
        let historyMenu = NSApp.mainMenu!.items.first { $0.title == "history" }!.submenu!
        menus.menuNeedsUpdate(historyMenu)
        let historyPages = historyMenu.items.filter { ($0.representedObject as? String)?.hasPrefix("https:") == true }
        try expect(
            historyPages.count == 10
                && historyPages.allSatisfy { $0.image != nil && $0.attributedTitle!.size().width <= 280 },
            "History menu exposes ten bounded page entries with icons")
        let cursor = descendants(root, CursorRegion.Region.self)
        try expect(cursor.isEmpty, "Color-pad cursor regions are scoped to their controls")
        let colorHost = NSHostingView(
            rootView: ProfileColorPad(selection: .constant(nil), strength: .constant(0.06), fallback: .blue))
        colorHost.frame = NSRect(x: 0, y: 0, width: 260, height: 208)
        let colorWindow = NSWindow(contentRect: colorHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        colorWindow.isReleasedWhenClosed = false
        colorWindow.contentView = colorHost
        colorWindow.makeKeyAndOrderFront(nil)
        defer { colorWindow.close() }
        try await settle()
        let region = descendants(colorHost, CursorRegion.Region.self)[0]
        try expect(
            region.changed != nil && region.hitTest(NSPoint(x: 40, y: 40)) === region,
            "Color picker owns hover and drag hit testing in the cursor view")
        colorWindow.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        let webTab = store.newTab(showOmnibar: false)
        webTab.url = URL(string: "https://fullscreen.invalid/")
        webTab.webView.loadHTMLString(
            "<style>body{margin:0;background:#fff5cc;height:3000px}h1{padding:100px}</style><h1>fullscreen sidebar</h1>",
            baseURL: webTab.url)
        try await settle(400)
        let volumeResult = try await webTab.webView.callAsyncJavaScript(
            """
            const first = document.createElement('audio'), lowered = document.createElement('audio');
            first.muted = true; first.volume = 0; lowered.volume = 0.3;
            document.body.append(first, lowered);
            await new Promise(resolve => setTimeout(resolve, 20));
            first.dispatchEvent(new Event('play'));
            const startsFull = first.volume === 1 && first.muted;
            loafMediaControl('1', 'mute');
            const unmutesFull = first.volume === 1 && !first.muted;
            lowered.muted = true; loafMediaControl('2', 'mute');
            const retainsLowered = lowered.volume === 0.3 && !lowered.muted;
            first.volume = 0.35; first.dispatchEvent(new Event('volumechange'));
            loafMediaControl('1', 'mute'); loafMediaControl('1', 'mute');
            return [startsFull, unmutesFull, retainsLowered, first.volume === 0.35 && !first.muted, first.volume, lowered.volume];
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        try expect(
            (volumeResult as? [Any])?.prefix(4).allSatisfy { ($0 as? Bool) == true } == true,
            "Muted media defaults to full volume and preserves later volume adjustments")
        window.toggleFullScreen(nil)
        for _ in 0..<100 where !store.isFullscreen { try await settle(50) }
        try expect(store.isFullscreen, "Fixture enters native fullscreen")
        let dock = descendants(root, SidebarDockHost.ContainerView.self)[0]
        for cycle in 0..<4 {
            let started = ProcessInfo.processInfo.systemUptime
            let originalWidth = webTab.webViewHost!.bounds.width
            let commits = webTab.webViewHost!.resizeCommits
            var widths = Set<Int>()
            store.sidebarVisible = !store.sidebarVisible
            for _ in 0..<30 where store.sidebarPresented != store.sidebarVisible { try await settle(5) }
            try expect(
                store.sidebarPresented == store.sidebarVisible && ProcessInfo.processInfo.systemUptime - started < 0.15,
                "Fullscreen sidebar starts promptly instead of waiting for a slow snapshot")
            for frameIndex in 0..<20 {
                try await settle(20)
                root.layoutSubtreeIfNeeded()
                if let host = webTab.webViewHost {
                    if abs(host.bounds.width - originalWidth) > 1 { widths.insert(Int(host.bounds.width.rounded())) }
                    var ancestor: NSView? = host
                    while let current = ancestor,
                        !(String(reflecting: type(of: current)).contains("PageViewport")
                            && String(reflecting: type(of: current)).contains(".Container"))
                    { ancestor = current.superview }
                    if let surface = ancestor?.subviews.first {
                        if let clip = surface.layer?.presentation(),
                            let contents = surface.subviews.first?.layer?.presentation()
                        {
                            try expect(
                                abs(clip.frame.maxX - (root.bounds.width - store.pageEdgeInset)) < 1,
                                "The fullscreen page clip stays anchored to the trailing edge")
                            try expect(
                                abs(contents.frame.minX) < 1 && abs(contents.frame.maxX - clip.bounds.width) < 1,
                                "The page contents fill the moving clip without a trailing gap")
                        }
                        try expect(
                            surface.layer?.mask == nil && surface.layer?.masksToBounds == true,
                            "Native rounded clipping never interpolates a shape path")
                        if dock.moving, let shape = surface.layer?.presentation(),
                            let pane = dock.hostedSidebar.layer?.presentation()
                        {
                            try expect(
                                abs(shape.frame.minX - (pane.frame.minX + store.preferences.sidebarWidth)) < 9,
                                "Sidebar contents move with its shape throughout the fullscreen transition")
                        }
                        try expect((surface.layer?.cornerRadius ?? 999) <= 12, "Fullscreen page corners stay bounded")
                        if frameIndex == 7, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])!.write(
                                to: URL(fileURLWithPath: "build/tests/fullscreen-native-\(cycle).png"))
                        }
                    }
                    try expect(
                        host.bounds.width > 0 && host.bounds.width <= root.bounds.width + 1,
                        "Fullscreen viewport stays within its window, cycle \(cycle)")
                }
            }
            try await settle(250)
            try expect(
                widths.count <= 2 && webTab.webViewHost!.resizeCommits - commits <= 2,
                "Fullscreen transition lays out WebKit once, without per-frame reflow")
            try expect(
                webTab.webViewHost?.resizeSnapshotVisible == false,
                "Fullscreen transition removes its snapshot, cycle \(cycle)")
        }
        window.toggleFullScreen(nil)
        for _ in 0..<100 where store.isFullscreen { try await settle(50) }
        try expect(!store.isFullscreen, "Fullscreen fixture returns to its window")
        print("PASS: \(checks) sidebar refinement checks")
    }
}

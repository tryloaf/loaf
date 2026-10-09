import AppKit
import WebKit

extension BrowserTab {

    func canSleep(at now: Date, idleInterval: TimeInterval = 30 * 60) -> Bool {
        guard let store, let view = existingWebView,
            (store.preferences.sleepIdleTabs == true || store.application.resources.saverEnabled),
            store.visibleSplit?.contains(id) != true, !store.profileFor(profileID).privateMode,
            store.selectedTab?.id != id, page == .web, loaded, !sleeping,
            now.timeIntervalSince(lastActivated) >= idleInterval,
            sleepEligibleNavigation, !loading, !view.isLoading, navigationError == nil,
            readerArticle == nil, !pinned, media.isEmpty,
            view.fullscreenState == .notInFullscreen,
            view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
            WebKitAdapter.inspectorView(view)?.window == nil,
            store.pointerLockOffer?.tabID != id, !pointerCapturePosition.captured,
            store.passwordOffer == nil, store.passwordFillOffer?.tabID != id,
            store.nativeWindow?.attachedSheet == nil,
            !store.downloads.items.contains(where: { $0.profileID == profileID && $0.download != nil }),
            let url, ["http", "https"].contains(url.scheme), view.url == url
        else { return false }
        return view.interactionState != nil
    }

    @discardableResult func sleepIfIdle(at now: Date = Date(), idleInterval: TimeInterval = 30 * 60) async -> Bool {
        guard canSleep(at: now, idleInterval: idleInterval), let view = existingWebView else { return false }
        let token = navigationID
        let activation = lastActivated
        let probe = #"""
            if (document.readyState !== 'complete' || document.pointerLockElement || document.fullscreenElement) return null;


            let visited = 0;
            const unsafe = root => {
              if (root.querySelector('input,textarea,select,form,[contenteditable]:not([contenteditable="false"]),audio,video,iframe,frame,object,embed,canvas')) return true;
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
              for (let el = walker.nextNode(); el; el = walker.nextNode()) {
                if (++visited > 5000) return true;
                if (el.localName.includes('-') || (el.shadowRoot && unsafe(el.shadowRoot))) return true;
              }
              return false;
            };
            if (unsafe(document)) return null;
            return {x:scrollX, y:scrollY};
            """#
        guard
            let position = try? await view.callAsyncJavaScript(
                probe, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Double],
            let x = position["x"], let y = position["y"], x.isFinite, y.isFinite,
            existingWebView === view, navigationID == token, lastActivated == activation,
            canSleep(at: now, idleInterval: idleInterval), let state = view.interactionState
        else { return false }
        sleepState = state
        sleepScrollPosition = CGPoint(x: x, y: y)
        sleepRestoreURL = url
        finder.reset(clearQuery: true)
        releaseWebView()
        loaded = false
        sleeping = true
        return true
    }
}

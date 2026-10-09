import WebKit

enum StorePageIntegration {
    static let script = #"""
        (() => {
          if (location.protocol !== 'https:' || location.hostname !== 'chromewebstore.google.com' || (location.port && location.port !== '443')) return;
          let installed = false, busy = false, scheduled = false, frame = 0, timer = 0, listing = '';
          const identifier = () => location.pathname.match(/\/([a-p]{32})(?:\/|$)/)?.[1] || '';
          const requestState = () => { installed = false; busy = false; listing = identifier(); window.webkit.messageHandlers.loafStore.postMessage({action:'state',id:listing}); };
          const style = document.createElement('style');
          style.textContent = `
            [data-loaf-chrome-promo="hidden"] { display:none!important; }
            button[data-loaf-install] { display:inline-flex!important; align-items:center!important; justify-content:center!important; gap:10px!important; min-height:40px!important; padding:10px 22px!important; border:1px solid transparent!important; border-radius:24px!important; background:#29261f!important; color:#fff6e7!important; font:500 14px/20px system-ui!important; opacity:1!important; cursor:pointer!important; white-space:nowrap!important; }
            button[data-loaf-install]:hover { background:#454036!important; }
            button[data-loaf-install]:focus-visible { outline:3px solid #887c63!important; outline-offset:3px!important; }
            button[data-loaf-install]:disabled { cursor:wait!important; }
            button[data-loaf-install]::before,button[data-loaf-install]::after { content:none!important; display:none!important; }
            [data-loaf-spinner] { display:block!important; position:static!important; width:14px!important; height:14px!important; margin:0!important; flex:0 0 14px!important; border:2px solid #fff6e74d!important; border-top-color:#fff6e7!important; border-radius:50%!important; animation:loaf-install-spin .75s linear infinite!important; }
            @keyframes loaf-install-spin { to { transform:rotate(360deg); } }
            @media(prefers-reduced-motion:reduce) { [data-loaf-spinner] { animation:none!important; } }
          `;
          (document.head || document.documentElement).append(style);
          const refresh = () => {
            scheduled = false;
            if (listing !== identifier()) requestState();
            for (const el of document.querySelectorAll('button,[role="button"]')) {
              const text = el.textContent.trim();
              if (/^(Add to Chrome|Remove from Chrome|Add to Desktop|Add to loaf|Remove from loaf)$/i.test(text)) {
                if (!el.dataset.loafInstall) {
                  const button = document.createElement('button');
                  button.dataset.loafInstall = 'true';
                  button.type = 'button'; el.replaceWith(button);
                  button.addEventListener('click', event => {
                    if (!event.isTrusted || busy) return;
                    busy = true; refresh();
                    window.webkit.messageHandlers.loafStore.postMessage({action:'install',id:listing});
                  });
                }
              }
            }
            for (const button of document.querySelectorAll('[data-loaf-install]')) {
              const label = busy ? 'please wait…' : installed ? 'remove from loaf' : 'add to loaf';
              if (button.textContent !== label || !!button.querySelector('[data-loaf-spinner]') !== busy) {
                button.replaceChildren();
                if (busy) { const spinner = document.createElement('span'); spinner.dataset.loafSpinner = ''; spinner.setAttribute('aria-hidden','true'); button.append(spinner); }
                button.append(document.createTextNode(label));
              }
              button.disabled = busy; button.setAttribute('aria-label', label); button.setAttribute('aria-busy', String(busy));
            }
            for (const dialog of document.querySelectorAll('[role="dialog"],aside,section,div')) {
              const text = dialog.textContent.replace(/\s+/g,' ').trim();
              if (text.length < 400 && /^Switch to Chrome\?\s*Google recommends using Chrome when using extensions and themes\.?/i.test(text) && dialog.querySelector('button')) {
                dialog.style.setProperty('display','none','important'); dialog.dataset.loafChromePromo = 'hidden';
              }
            }
            const clean = el => el.textContent.replace(/[\u200b-\u200f\ufeff]/g,'').replace(/\s+/g,' ').trim();

            for (const link of document.querySelectorAll('a[href]')) {
              let url; try { url = new URL(link.href, location.href); } catch { continue; }
              if (!['google.com','www.google.com'].includes(url.hostname) || !/^\/chrome(?:\/|$)/.test(url.pathname)) continue;
              let banner = link;
              for (let depth = 0; depth < 8 && banner.parentElement; depth++) {
                const parent = banner.parentElement;
                if (['BODY','HTML','MAIN'].includes(parent.tagName) || parent.querySelector('h1,[data-loaf-install]') || clean(parent).length > 650) break;
                banner = parent;
                if (parent.matches('aside,[role="alert"],[role="dialog"]')) break;
              }
              if (/\b(?:install|switch|download|get|try)\b.*\bChrome\b/i.test(clean(banner)) || /\bChrome\b.*\b(?:install|extensions|themes)\b/i.test(clean(banner))) {
                banner.style.setProperty('display','none','important'); banner.dataset.loafChromePromo = 'hidden';
              }
            }
            for (const el of document.querySelectorAll('span,p,aside,[role="alert"]')) {
              const text = clean(el);
              if (!/^Switch to Chrome to install extensions and themes[.!]?$/i.test(text)) continue;
              let banner = el.closest('aside,[role="alert"]') || el;
              while (banner.parentElement && !['BODY','HTML','MAIN'].includes(banner.parentElement.tagName)) {
                const parentText = banner.parentElement.textContent.replace(/\s+/g,' ').trim();
                if (!/^Switch to Chrome to install extensions and themes[.!]?(?: (?:Switch to Chrome|Get Chrome|Download Chrome))?$/i.test(parentText)) break;
                banner = banner.parentElement;
              }
              banner.remove();
            }
          };
          globalThis.loafStoreState = state => { if (listing !== identifier()) requestState(); if (state.id && state.id !== listing) return; installed = !!state.installed; busy = !!state.busy; refresh(); };
          addEventListener('popstate', scheduleNavigation);
          function scheduleNavigation() { schedule(); }
          setInterval(() => { if (listing !== identifier()) schedule(); }, 300);
          const schedule = () => {
            if (scheduled) return; scheduled = true;
            const run = () => { if (!scheduled) return; cancelAnimationFrame(frame); clearTimeout(timer); refresh(); };
            frame = requestAnimationFrame(run); timer = setTimeout(run, 200);
          };
          new MutationObserver(schedule)
            .observe(document.documentElement, {subtree:true,childList:true});
          requestState(); refresh();
        })();
        """#
}

extension BrowserTab {
    func receiveStoreAction(_ message: WKScriptMessage, body: [String: Any]) {
        guard message.frameInfo.isMainFrame, let store,
            message.frameInfo.request.url?.scheme == "https",
            message.frameInfo.request.url?.host == "chromewebstore.google.com",
            message.frameInfo.request.url?.port == nil || message.frameInfo.request.url?.port == 443,
            let url = existingWebView?.url, url.scheme == "https", url.host == "chromewebstore.google.com",
            url.port == nil || url.port == 443,
            let extensionID = ChromeStore.identifier(url.absoluteString)
        else { return }
        guard body["id"] == nil || body["id"] as? String == extensionID else { return }
        let manager = store.runtime(for: profileID).extensions
        func refresh() {
            guard self.existingWebView?.url == url else { return }
            let installed = store.profileFor(profileID).extensions.contains { $0.storeID == extensionID }
            self.webView.callAsyncJavaScript(
                "globalThis.loafStoreState?.({id,installed,busy})",
                arguments: ["id": extensionID, "installed": installed, "busy": manager.installing], in: nil,
                in: .defaultClient
            ) { _ in }
        }
        guard body["action"] as? String == "install", !manager.installing else {
            refresh()
            return
        }
        if let record = store.profileFor(profileID).extensions.first(where: { $0.storeID == extensionID }) {

            let alert = NSAlert()
            alert.messageText = "remove " + record.name + "?"
            alert.addButton(withTitle: "remove")
            alert.addButton(withTitle: "cancel")
            guard let window = store.nativeWindow else {
                refresh()
                return
            }
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { manager.remove(record) }
                refresh()
            }
        } else {
            Task {
                await manager.installStore(extensionID, owner: store)
                refresh()
            }
        }
    }
}

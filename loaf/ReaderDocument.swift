import Foundation

struct ReaderDocument: Identifiable {
    let id = UUID()
    let originalURL: URL
    let title: String
    let text: String
    let body: String
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    func html(dark: Bool) -> String {
        """
        <!doctype html><html data-theme="\(dark ? "dark" : "light")"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>\(Self.escape(title))</title>
        <style>
        :root{color-scheme:light;--bg:#fafaf8;--ink:#292b28;--muted:#71756d;--rule:#dedfd8}
        :root[data-theme=dark]{color-scheme:dark;--bg:#1d1f1d;--ink:#e3e5df;--muted:#a2a69d;--rule:#3b4039}
        *{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--ink)}
        body{font:18px/1.65 ui-serif,Georgia,serif;overflow-wrap:anywhere}
        main{max-width:740px;margin:auto;padding:44px 40px 72px}
        header{margin-bottom:32px}header small{font:12px system-ui;color:var(--muted)}
        h1{font-size:34px;line-height:1.2;font-weight:600;margin:12px 0 24px}
        h2,h3,h4,h5,h6{line-height:1.3;margin:1.6em 0 .6em}h2{font-size:25px}h3{font-size:21px}
        p{margin:0 0 1em}a{color:inherit;text-decoration-color:var(--muted);text-underline-offset:3px}
        img{display:block;max-width:100%;height:auto;margin:24px auto;border-radius:4px}
        figure{margin:28px 0}figcaption{font:13px/1.5 system-ui;color:var(--muted);margin-top:8px}
        blockquote{margin:24px 0;padding-left:20px;border-left:2px solid var(--rule);color:var(--muted)}
        pre{white-space:pre-wrap;padding:16px;background:color-mix(in srgb,var(--ink) 5%,transparent);border-radius:6px}
        code{font:14px/1.6 ui-monospace,monospace}table{border-collapse:collapse;display:block;max-width:100%;overflow-x:auto;font-size:15px}
        th,td{padding:8px 12px;border:1px solid var(--rule);text-align:left}hr{border:0;border-top:1px solid var(--rule);margin:32px 0}
        @media(max-width:500px){main{padding:28px 24px 56px}h1{font-size:28px}}
        </style></head><body><main><header><small>\(Self.escape(originalURL.host ?? ""))</small><h1>\(Self.escape(title))</h1></header><article>\(body)</article></main></body></html>
        """
    }

    static let extraction = #"""
        const root = document.querySelector('article,[role=article]') || document.querySelector('main,[role=main]');
        if (!root) return null;
        const heading = root.querySelector('h1');
        const title = (heading?.innerText || document.title || '').trim().slice(0, 500);
        const allowed = new Set(['h1','h2','h3','h4','h5','h6','p','div','section','span','a','strong','em','b','i','s','del','u','ul','ol','li','blockquote','pre','code','hr','br','figure','figcaption','img','table','thead','tbody','tfoot','tr','th','td','sup','sub']);
        const excluded = new Set(['script','style','noscript','iframe','frame','object','embed','svg','canvas','form','input','textarea','select','button','nav','aside','footer','audio','video']);
        const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        let nodes = 0, characters = 0, images = 0;
        const textParts = [];
        const ids = new Map();
        for (const el of [...root.querySelectorAll('[id]')].slice(0, 500)) ids.set(el.id, 'loaf-reader-' + ids.size);
        const link = value => {
          try { const url = new URL(value, document.baseURI); return ['https:','http:'].includes(url.protocol) && !url.username && !url.password ? url : null; } catch { return null; }
        };
        const visit = (node, depth = 0) => {
          if (++nodes > 5000 || depth > 60 || characters >= 200000) return '';
          if (node.nodeType === Node.TEXT_NODE) { const text = node.textContent.slice(0, 200000 - characters); characters += text.length; textParts.push(text); return esc(text); }
          if (node.nodeType !== Node.ELEMENT_NODE) return '';
          const tag = node.localName;
          if (excluded.has(tag) || node.hidden || node.getAttribute('aria-hidden') === 'true' || node === heading) return '';
          const style = getComputedStyle(node);
          if (style.display === 'none' || style.visibility === 'hidden') return '';
          if (tag === 'img') {
            if (++images > 24) return '';
            const source = node.currentSrc || node.getAttribute('src') || node.getAttribute('data-src') || '';
            let src;
            if (/^data:image\/(png|jpeg|gif|webp);base64,[a-z0-9+/=]+$/i.test(source) && source.length <= 100000) src = source;
            else { const url = link(source); if (url?.protocol === 'https:') src = url.href; }
            return src ? '<img src="' + esc(src) + '" alt="' + esc((node.alt || '').slice(0, 500)) + '" loading="lazy" referrerpolicy="no-referrer">' : '';
          }
          const content = [...node.childNodes].map(child => visit(child, depth + 1)).join('');
          if (!allowed.has(tag)) return content;
          let attributes = '';
          if (node.id && ids.has(node.id)) attributes += ' id="' + ids.get(node.id) + '"';
          if (tag === 'a') {
            const value = node.getAttribute('href') || '';
            if (value.startsWith('#') && ids.has(value.slice(1))) attributes += ' href="#' + ids.get(value.slice(1)) + '"';
            else { const url = link(value); if (url) attributes += ' href="' + esc(url.href) + '" rel="noreferrer noopener"'; }
          }
          if (tag === 'br' || tag === 'hr') return '<' + tag + '>';
          return '<' + tag + attributes + '>' + content + '</' + tag + '>';
        };
        const body = [...root.childNodes].map(node => visit(node)).join('');
        const text = textParts.join(' ').trim().slice(0, 200000);
        if (text.length < 120 || body.length > 600000) return null;
        return {title, text, body};
        """#
}

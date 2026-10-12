import Foundation

enum ExtensionShazam {
    static let identifier = "mmioliijnhnoblpgimnlajmefafdfilb"
    static let marker = "_loaf_shazam_v2"
    static let diagnostic =
        "Shazam history is available. Song recognition requires Chrome's tab audio capture, which loaf does not support yet."
    static let script = #"""
        (() => {
            const message = 'Song recognition isn’t available in loaf yet. Shazam requires Chrome’s tab audio capture.';
            const showNotice = () => {
                if (!document.body || document.getElementById('loaf-shazam-notice')) return;
                const notice = document.createElement('p');
                notice.id = 'loaf-shazam-notice';
                notice.setAttribute('role', 'status');
                notice.textContent = message;
                document.body.prepend(notice);
            };
            globalThis.__loafShazamCaptureUnavailable = () => {
                showNotice();
                chrome.runtime.sendMessage({type:'tracknomatch', error:message}, () => { void chrome.runtime.lastError; });
            };
            document.addEventListener('DOMContentLoaded', showNotice, {once:true});
        })();
        """#
    static let styles = """
        :root { color-scheme: light !important; }
        body { background: #fff; color: #000; }
        #app-container { position: relative; }
        body, button, input, select, textarea, [class*="Text-module_fontFamily"] {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        }
        #loaf-shazam-notice {
            margin: 0; padding: 12px 16px; font-size: 12px; line-height: 1.4;
            background: #e9f5ff; color: #14334b; text-align: left;
        }
        """

    static func prepare(_ runtime: URL, original: URL) throws -> String {
        let bundle = original.appendingPathComponent("popup.bundle.js")
        guard (try bundle.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 2_000_000 else {
            throw PackageError(reason: "This Shazam popup exceeds the compatibility adapter's size limit.")
        }
        let source = try String(contentsOf: bundle, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"(chrome\.tabCapture\.capture\(\{audio:!0\},)([\w$]+)=>\{"#)
        let range = NSRange(source.startIndex..., in: source)
        guard pattern.numberOfMatches(in: source, range: range) == 1 else {
            throw PackageError(reason: "This Shazam package needs a new audio compatibility adapter.")
        }
        let updated = pattern.stringByReplacingMatches(
            in: source, range: range,
            withTemplate:
                "$1$2=>{if(!$2){void chrome.runtime.lastError;globalThis.__loafShazamCaptureUnavailable();return;}")
        try Data(updated.utf8).write(to: runtime.appendingPathComponent("popup.bundle.js"), options: .atomic)
        let popup = runtime.appendingPathComponent("popup.html")
        var html = try String(contentsOf: popup, encoding: .utf8)
        if !html.contains("_loaf_shazam.js") {
            guard let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
                throw PackageError(reason: "This Shazam package needs a new popup compatibility adapter.")
            }
            html.insert(
                contentsOf:
                    "<link rel=\"stylesheet\" href=\"_loaf_shazam.css\"><script src=\"_loaf_shazam.js\"></script>",
                at: head.upperBound)
            try Data(html.utf8).write(to: popup, options: .atomic)
        }
        let manifestFile = runtime.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any] ?? [:]
        if manifest["devtools_page"] as? String == "devtools.html",
            !FileManager.default.fileExists(atPath: runtime.appendingPathComponent("devtools.html").path)
        {
            manifest.removeValue(forKey: "devtools_page")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
                to: manifestFile, options: .atomic)
        }
        try Data(script.utf8).write(to: runtime.appendingPathComponent("_loaf_shazam.js"), options: .atomic)
        try Data(styles.utf8).write(to: runtime.appendingPathComponent("_loaf_shazam.css"), options: .atomic)
        try Data("1".utf8).write(to: runtime.appendingPathComponent(marker), options: .atomic)
        return diagnostic
    }

    static func resolvedDiagnostic(_ value: String) -> Bool {
        (value.contains("Unable to find") && value.contains("devtools.html"))
            || (value.contains("createMediaStreamSource") && value.contains("must be an instance of MediaStream"))
    }
}

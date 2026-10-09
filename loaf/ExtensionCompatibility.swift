import AppKit
import WebKit

@MainActor enum ExtensionCompatibility {
    static let host = "app.tryloaf.loaf.compatibility"
    static let script = #"""
        (() => {
            const api = globalThis.chrome || globalThis.browser;
            if (!api?.runtime?.sendNativeMessage) return;
            const runtime = api.runtime;


            if (typeof document === 'undefined' && typeof addEventListener === 'function') {
                const report = (error) => {
                    let message;
                    try { message = String(error?.message || error || 'Unknown background error').slice(0, 512); }
                    catch (_) { message = 'Unknown background error'; }
                    try {
                        runtime.sendNativeMessage('app.tryloaf.loaf.compatibility', {operation:'runtime.reportError', args:{message}}, () => { void runtime.lastError; });
                    } catch (_) {}
                };
                addEventListener('error', (event) => report(event.error || event.message));
                addEventListener('unhandledrejection', (event) => report(event.reason));
            }
            const invoke = (operation, args, callback) => {
                if (typeof callback === 'function') {
                    runtime.sendNativeMessage('app.tryloaf.loaf.compatibility', {operation, args}, (result) => {
                        if (runtime.lastError) { callback(undefined); return; }
                        callback(result?.value);
                    });
                    return;
                }
                return new Promise((resolve, reject) => {
                    runtime.sendNativeMessage('app.tryloaf.loaf.compatibility', {operation, args}, (result) => {
                        const error = runtime.lastError;
                        if (error) reject(new Error(error.message)); else resolve(result?.value);
                    });
                });
            };
            if (!api.theme) {
                const listeners = new Set();
                api.theme = {
                    getCurrent: (windowId, callback) => invoke('theme.getCurrent', {}, typeof windowId === 'function' ? windowId : callback),
                    onUpdated: {addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn), hasListener: fn => listeners.has(fn)},
                    update: (...args) => invoke('unsupported.theme.update', {}, typeof args.at(-1) === 'function' ? args.at(-1) : undefined),
                    reset: (...args) => invoke('unsupported.theme.reset', {}, typeof args.at(-1) === 'function' ? args.at(-1) : undefined)
                };
                if (typeof matchMedia === 'function') matchMedia('(prefers-color-scheme: dark)').addEventListener('change', async () => {
                    try { const theme = await api.theme.getCurrent(); for (const listener of listeners) listener({theme}); } catch (_) {}
                });
            }
            if (typeof document !== 'undefined' && /^(?:webkit|moz|chrome|safari)-extension:$/.test(location.protocol)) {
                const apply = () => {
                    const root = document.documentElement;
                    if (!root) return;
                    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
                    if (!root.style.colorScheme) root.style.colorScheme = 'light dark';
                    root.style.setProperty('--loaf-system-color-scheme', dark ? 'dark' : 'light');
                    root.style.setProperty('--loaf-system-background', dark ? '#282828' : '#ececec');
                    root.style.setProperty('--loaf-system-text', dark ? '#ffffff' : '#000000');
                };
                apply(); document.addEventListener('DOMContentLoaded', apply, {once:true});
                matchMedia('(prefers-color-scheme: dark)').addEventListener('change', apply);
            }
            if (!runtime.getBrowserInfo) runtime.getBrowserInfo = (callback) => invoke('runtime.getBrowserInfo', {}, callback);
            if (!runtime.getPlatformInfo) runtime.getPlatformInfo = (callback) => invoke('runtime.getPlatformInfo', {}, callback);
            if (!api.fontSettings) api.fontSettings = {
                getFontList: (callback) => invoke('fontSettings.getFontList', {}, callback),
                getFont: (details, callback) => invoke('unsupported.fontSettings.getFont', details, callback),
                setFont: (details, callback) => invoke('unsupported.fontSettings.setFont', details, callback),
                clearFont: (details, callback) => invoke('unsupported.fontSettings.clearFont', details, callback)
            };
            for (const [namespace, methods] of Object.entries({debugger:['attach','detach','sendCommand'], tts:['speak','stop'], tabCapture:['capture','getMediaStreamId']})) {
                if (api[namespace]) continue;
                api[namespace] = {};
                for (const method of methods) api[namespace][method] = (...args) => invoke(`unsupported.${namespace}.${method}`, {}, typeof args.at(-1) === 'function' ? args.at(-1) : undefined);
            }
        })();
        """#
    static func prepare(_ folder: URL, extensionID: String? = nil) throws -> [String] {
        let file = folder.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        var diagnostics = [
            "loaf bridge: runtime browser metadata and permission-gated font listing",
            "Native messaging is limited to loaf's own compatibility adapter.",
        ]
        if extensionID == "mnjggcdmjocbbbhaepdhchncahnbgone" {
            diagnostics.append(try prepareSponsorBlock(folder, original: folder))
        }
        if extensionID == vimiumID {
            diagnostics.append(try prepareVimium(folder, original: folder))
        }
        let shim = folder.appendingPathComponent("_loaf_bridge.js")
        try Data(script.utf8).write(to: shim, options: .atomic)
        var permissions = manifest["permissions"] as? [String] ?? []
        if !permissions.contains("nativeMessaging") { permissions.append("nativeMessaging") }
        manifest["permissions"] = permissions

        if var background = manifest["background"] as? [String: Any] {
            if let rawWorker = background["service_worker"] as? String {
                let module = background["type"] as? String == "module"
                guard let worker = workerResource(rawWorker) else {
                    throw PackageError(reason: "Unsafe service worker path.")
                }
                let parent = (worker as NSString).deletingLastPathComponent
                let original = (worker as NSString).lastPathComponent
                let shimPath =
                    parent.split(separator: "/").filter { $0 != "." }.map { _ in "../" }.joined() + "_loaf_bridge.js"
                let path = "./" + original
                let quotedShim = try quoted(shimPath)
                let quotedScript = try quoted(module ? path : original)
                let wrapper =
                    module
                    ? "import \(quotedShim);\nimport \(quotedScript);\n"
                    : "importScripts(\(quotedShim));\nimportScripts(\(quotedScript));\n"
                let wrapped = parent.isEmpty ? "_loaf_background.js" : parent + "/_loaf_background.js"
                try Data(wrapper.utf8).write(to: folder.appendingPathComponent(wrapped), options: .atomic)
                background["service_worker"] = wrapped
            } else if let scripts = background["scripts"] as? [String] {
                background["scripts"] = ["_loaf_bridge.js"] + scripts
            }
            manifest["background"] = background
        }
        if var scripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in scripts.indices where scripts[index]["world"] as? String != "MAIN" {
                if let files = scripts[index]["js"] as? [String] { scripts[index]["js"] = ["_loaf_bridge.js"] + files }
            }
            manifest["content_scripts"] = scripts
        }
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let html as URL in enumerator where html.pathExtension.lowercased() == "html" {
                guard let source = try? String(contentsOf: html, encoding: .utf8), source.utf8.count < 2_000_000 else {
                    continue
                }
                let relative =
                    html.deletingLastPathComponent().path.dropFirst(folder.path.count).split(separator: "/").map { _ in
                        "../"
                    }.joined() + "_loaf_bridge.js"
                let tag = "<script src=\"\(relative)\"></script>"
                let updated: String
                if let head = source.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                    updated = String(source[..<head.upperBound]) + tag + String(source[head.upperBound...])
                } else {
                    updated = tag + source
                }
                try Data(updated.utf8).write(to: html, options: .atomic)
            }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
            to: file, options: .atomic)
        return diagnostics
    }
    static let sponsorBlockMarker = "_loaf_sponsorblock_frame_v1"
    static let vimiumID = "dbepggeogbaibhgnhhndojpepiihcmeb"
    static let vimiumMarker = "_loaf_vimium_navigation_v1"
    static func prepareVimium(_ runtime: URL, original: URL) throws -> String {
        let path = "background_scripts/main.js"
        let file = original.appendingPathComponent(path)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else {
            throw PackageError(reason: "This Vimium background script exceeds the compatibility adapter's size limit.")
        }
        var source = try String(contentsOf: file, encoding: .utf8)

        let history = "chrome.webNavigation.onHistoryStateUpdated.addListener(onURLChange);"
        let fragment = "chrome.webNavigation.onReferenceFragmentUpdated.addListener(onURLChange);"
        guard source.utf8.count <= 2_000_000, source.components(separatedBy: history).count == 2,
            source.components(separatedBy: fragment).count == 2
        else {
            throw PackageError(reason: "This Vimium package needs a new navigation compatibility adapter.")
        }
        source = source.replacingOccurrences(
            of: history,
            with:
                "chrome.tabs.onUpdated.addListener((tabId, changes) => { if (changes.url) onURLChange({tabId, frameId: 0}); });"
        )
        .replacingOccurrences(of: fragment, with: "")
        try Data(source.utf8).write(to: runtime.appendingPathComponent(path), options: .atomic)
        try Data("1".utf8).write(to: runtime.appendingPathComponent(vimiumMarker), options: .atomic)
        return
            "Vimium rechecks top-frame URL rules through native tab updates. Same-document iframe rule changes remain unsupported."
    }
    static func prepareSponsorBlock(_ runtime: URL, original: URL) throws -> String {

        let source = try String(contentsOf: original.appendingPathComponent("js/popup.js"), encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"chrome\.tabs\.sendMessage\(([\w$]+\[0\]\.id),([\w$]+),([\w$]+)\)"#)
        let range = NSRange(source.startIndex..., in: source)
        guard source.utf8.count <= 2_000_000, regex.numberOfMatches(in: source, range: range) == 1 else {
            throw PackageError(reason: "This SponsorBlock package needs a new popup/frame compatibility adapter.")
        }
        let updated = regex.stringByReplacingMatches(
            in: source, range: range, withTemplate: "chrome.tabs.sendMessage($1,$2,{frameId:0},$3)")
        try Data(updated.utf8).write(to: runtime.appendingPathComponent("js/popup.js"), options: .atomic)
        try Data("1".utf8).write(to: runtime.appendingPathComponent(sponsorBlockMarker), options: .atomic)
        return
            "SponsorBlock popup controls target the main player frame; live-chat frames retain their own content scripts."
    }

    static func workerResource(_ path: String) -> String? {
        guard !path.hasPrefix("//"), !path.contains("\\"), !path.contains(":"),
            !path.contains("\0"), !path.contains("%"), !path.contains("?"), !path.contains("#")
        else { return nil }
        let components = path.split(separator: "/")
        guard !components.contains("..") else { return nil }
        let value = components.filter { $0 != "." }.joined(separator: "/")
        return value.isEmpty ? nil : value
    }
    private static func quoted(_ string: String) throws -> String {
        let data = try JSONEncoder().encode(string)
        return String(decoding: data, as: UTF8.self)
    }
}

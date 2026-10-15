import Foundation

enum ExtensionReturnYouTubeDislike {
    static let identifier = "gebbhagfogifgggkldgodflihgfeippi"
    static let marker = "_loaf_ryd_page_helper_v1"
    static let diagnostic =
        "Return YouTube Dislike's page helper runs as a main-world content script so WebKit startup does not wait for a script-tag load event."

    static func prepare(_ runtime: URL, original: URL) throws -> String {
        let content = original.appendingPathComponent("ryd.content-script.js")
        let helper = original.appendingPathComponent("menu-fixer.js")
        guard (try content.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8_000_000,
            (try helper.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_000_000
        else { throw PackageError(reason: "This Return YouTube Dislike package exceeds the adapter's size limit.") }
        let source = try String(contentsOf: content, encoding: .utf8)
        let startup = "const pageWorldHelpersReady = injectPageWorldHelpers();"
        guard source.components(separatedBy: startup).count == 2 else {
            throw PackageError(reason: "This Return YouTube Dislike package needs a new page-helper adapter.")
        }
        let manifestFile = runtime.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any] ?? [:]
        var scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        guard let contentScript = scripts.first(where: {
            ($0["js"] as? [String] ?? []).contains("ryd.content-script.js") && $0["world"] as? String != "MAIN"
        }), let matches = contentScript["matches"] as? [String], !matches.isEmpty else {
            throw PackageError(reason: "This Return YouTube Dislike package needs a new content-script adapter.")
        }
        var pageHelper: [String: Any] = [
            "matches": matches, "js": ["menu-fixer.js"], "world": "MAIN", "run_at": "document_start",
        ]
        for key in ["exclude_matches", "include_globs", "exclude_globs", "all_frames", "match_about_blank", "match_origin_as_fallback"] {
            if let value = contentScript[key] { pageHelper[key] = value }
        }
        scripts.removeAll { $0["world"] as? String == "MAIN" && $0["js"] as? [String] == ["menu-fixer.js"] }
        scripts.insert(pageHelper, at: 0)
        manifest["content_scripts"] = scripts

        try Data(source.replacingOccurrences(of: startup, with: "const pageWorldHelpersReady = Promise.resolve(true);").utf8)
            .write(to: runtime.appendingPathComponent("ryd.content-script.js"), options: .atomic)
        try Data(contentsOf: helper).write(to: runtime.appendingPathComponent("menu-fixer.js"), options: .atomic)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestFile, options: .atomic)
        try Data("1".utf8).write(to: runtime.appendingPathComponent(marker), options: .atomic)
        return diagnostic
    }
}

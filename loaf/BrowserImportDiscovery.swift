import AppKit
import Darwin
import Foundation
import Security

nonisolated struct ImportBrowser: Identifiable, Sendable {
    let id: String
    let name: String
    let applicationURL: URL
    let roots: [URL]
    let safeStorageService: String?
}

nonisolated enum BrowserImportDiscovery {
    static var home: URL {
        // NSHomeDirectory points at the app container in a sandboxed build.
        getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    static var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    static func installed(appDirectories: [URL]? = nil, library: URL = Self.library) -> [ImportBrowser] {
        let fm = FileManager.default
        var found: [String: ImportBrowser] = [:]
        func apps(in directory: URL, depth: Int = 0) -> [URL] {
            guard depth <= 3, let children = try? fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return [] }
            return children.filter { !$0.lastPathComponent.hasPrefix(".") }.flatMap { child -> [URL] in
                // Safari’s system app symlink also carries the hidden Finder flag.
                // Inspect app bundles before filtering directory attributes.
                if child.pathExtension == "app" { return [child] }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    values.isDirectory == true, values.isSymbolicLink != true else { return [] }
                return apps(in: child, depth: depth + 1)
            }
        }
        for directory in appDirectories ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")] {
            for app in apps(in: directory) {
                guard app.pathExtension == "app",
                    let bundle = Bundle(url: app), let id = bundle.bundleIdentifier, id != BrowserBrand.bundleIdentifier
                else { continue }
                let resolvedApp = app.resolvingSymlinksInPath()
                let info = bundle.infoDictionary ?? [:]
                let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
                var code: SecStaticCode?
                var signing: CFDictionary?
                if SecStaticCodeCreateWithPath(resolvedApp as CFURL, [], &code) == errSecSuccess, let code {
                    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
                }
                let entitlements = (signing as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
                let name = (info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent)
                let support = library.appendingPathComponent("Application Support", isDirectory: true)
                var relative = [name, id, info["CrProductDirName"] as? String].compactMap { $0 }
                let known: [String: [String]] = [
                    "com.google.Chrome": ["Google/Chrome"], "com.google.Chrome.beta": ["Google/Chrome Beta"],
                    "com.google.Chrome.canary": ["Google/Chrome Canary"], "com.microsoft.edgemac": ["Microsoft Edge"],
                    "com.brave.Browser": ["BraveSoftware/Brave-Browser"], "com.operasoftware.Opera": ["com.operasoftware.Opera"],
                    "org.mozilla.firefox": ["Firefox/Profiles"], "org.mozilla.firefoxdeveloperedition": ["Firefox/Profiles"],
                    "app.zen-browser.zen": ["zen/Profiles"], "company.thebrowser.Browser": ["Arc", "Arc/User Data"],
                    "com.vivaldi.Vivaldi": ["Vivaldi"], "org.chromium.Chromium": ["Chromium"],
                ]
                let browserEntitlement = entitlements["com.apple.developer.web-browser"] as? Bool == true
                    || entitlements["com.apple.developer.web-browser.public-key-credential"] as? Bool == true
                let htmlViewer = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).contains { type in
                    guard (type["CFBundleTypeRole"] as? String)?.lowercased() == "viewer" else { return false }
                    let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
                    let extensions = type["CFBundleTypeExtensions"] as? [String] ?? []
                    let mimeTypes = type["CFBundleTypeMIMETypes"] as? [String] ?? []
                    return contentTypes.contains("public.html") || contentTypes.contains("public.xhtml")
                        || extensions.contains("html") || extensions.contains("htm") || mimeTypes.contains("text/html")
                }
                // Generic network access and HTTP deep links also belong to Electron apps.
                // Require browser authority, a known browser, or an explicit HTML viewer registration.
                guard schemes.contains("http"), schemes.contains("https"),
                    browserEntitlement || known[id] != nil || id == "com.apple.Safari" || htmlViewer else { continue }
                relative += known[id] ?? []
                var roots = relative.filter { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }.map { support.appendingPathComponent($0, isDirectory: true) }
                roots += [library.appendingPathComponent("Containers/\(id)/Data/Library/Application Support"), library.appendingPathComponent("Containers/\(id)/Data/Library/WebKit")]
                if id == "com.apple.Safari" {
                    roots += [library.appendingPathComponent("Safari"), library.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Safari"), library.appendingPathComponent("Group Containers/group.com.apple.Safari/Library/Safari"), library.appendingPathComponent("Cookies")]
                }
                let storageName = id.hasPrefix("com.google.Chrome") ? "Chrome" : id.hasPrefix("com.microsoft.edgemac") ? "Microsoft Edge" : id == "com.brave.Browser" ? "Brave" : name
                found[id] = .init(id: id, name: name, applicationURL: resolvedApp, roots: Array(Set(roots)), safeStorageService: storageName + " Safe Storage")
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func profileFolders(_ browser: ImportBrowser) -> [URL] {
        let fm = FileManager.default
        let markers = ["History", "History.db", "places.sqlite", "Bookmarks", "Bookmarks.plist", "cookies.sqlite", "Cookies.binarycookies", "session.json"]
        var result = Set<URL>()
        var visited = 0
        func walk(_ folder: URL, depth: Int) {
            visited += 1
            guard depth <= 5, result.count < 100, visited < 5_000,
                let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return }
            if markers.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { result.insert(folder) }
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children.prefix(300) {
                if ["Cache", "Code Cache", "GPUCache", "Service Worker", "Extensions", "Storage", "IndexedDB", "Local Storage", "Caches"].contains(child.lastPathComponent) { continue }
                walk(child, depth: depth + 1)
            }
        }
        for root in browser.roots { walk(root, depth: 0) }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    static func preview(_ browser: ImportBrowser, cookiePassword: Data? = nil) throws -> [ProfileImportPreview] {
        var previews: [ProfileImportPreview] = []
        var failures: [String] = []
        for folder in profileFolders(browser) {
            do {
                var result = try ProfileImport.preview(folder, cookiePassword: cookiePassword)
                for index in result.indices {
                    result[index].name = profileName(folder) ?? (folder.lastPathComponent == "Default" ? browser.name : folder.lastPathComponent)
                }
                previews += result
            } catch { failures.append(folder.lastPathComponent + ": " + error.localizedDescription) }
        }
        if browser.id == "company.thebrowser.Browser" {
            for root in browser.roots {
                let sidebar = root.appendingPathComponent("StorableSidebar.json")
                if FileManager.default.fileExists(atPath: sidebar.path) {
                    do { previews += try ProfileImport.arcSpaces(sidebar) } catch { failures.append("Arc spaces: " + error.localizedDescription) }
                    break
                }
            }
        }
        guard !previews.isEmpty else {
            throw ProfileImport.Failure(message: "No readable profiles found in \(browser.name). Close it, grant loaf Full Disk Access, then scan again. You can also choose its profile folder or a bookmarks export.")
        }
        if !failures.isEmpty { previews[0].warnings += failures }
        return previews
    }
    private static func profileName(_ folder: URL) -> String? {
        let file = folder.appendingPathComponent("Preferences")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50_000_000,
            let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["profile"] as? [String: Any])?["name"] as? String
    }
    /// Called only after the user asks to unlock cookies for one selected browser.
    static func cookiePassword(_ browser: ImportBrowser) throws -> Data {
        guard let service = browser.safeStorageService else { throw ProfileImport.Failure(message: "This browser has no supported cookie key.") }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProfileImport.Failure(message: "The cookie key wasn’t available (\(status)). History and bookmarks can still be imported.")
        }
        return data
    }
}

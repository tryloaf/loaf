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

    var isSafari: Bool { id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" }
    var suggestedFolder: URL? {
        if isSafari, let cookies = roots.first(where: { $0.path.hasSuffix("/Data/Library/Cookies") }) {
            return cookies.deletingLastPathComponent()
        }
        return roots.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? roots.first
    }
    func selectingFolder(_ folder: URL) -> Self {
        var selectedRoots = [folder]
        if (id == "com.kagi.kagimacOS" || id == "com.kagi.kagimacOS.RC"), folder.lastPathComponent == "HTTPStorages" {
            selectedRoots = [folder.appendingPathComponent(id + ".binarycookies")]
        }
        if isSafari {
            let library: URL?
            if folder.lastPathComponent == id {
                library = folder.appendingPathComponent("Data/Library")
            } else if folder.lastPathComponent == "Data", folder.deletingLastPathComponent().lastPathComponent == id {
                library = folder.appendingPathComponent("Library")
            } else if folder.lastPathComponent == "Library",
                folder.deletingLastPathComponent().lastPathComponent == "Data",
                folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == id
            {
                library = folder
            } else {
                library = nil
            }
            if let library {

                selectedRoots = [library.appendingPathComponent("Safari"), library.appendingPathComponent("Cookies")]
            }
        }
        return .init(
            id: id, name: name, applicationURL: applicationURL, roots: selectedRoots,
            safeStorageService: safeStorageService)
    }
}

nonisolated enum BrowserImportDiscovery {
    static var home: URL {

        getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    static var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    static func installed(appDirectories: [URL]? = nil, library: URL = Self.library) -> [ImportBrowser] {
        let fm = FileManager.default
        var found: [String: ImportBrowser] = [:]
        func apps(in directory: URL, depth: Int = 0) -> [URL] {
            guard depth <= 3,
                let children = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            else { return [] }
            return children.filter { !$0.lastPathComponent.hasPrefix(".") }.flatMap { child -> [URL] in

                if child.pathExtension == "app" { return [child] }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    values.isDirectory == true, values.isSymbolicLink != true
                else { return [] }
                return apps(in: child, depth: depth + 1)
            }
        }
        var candidates: [URL] = []
        if appDirectories == nil {

            candidates += NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            candidates += NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "http://example.com")!)
            if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                candidates.append(safari)
            }
        }
        for directory in appDirectories ?? [
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
        ] {
            candidates += apps(in: directory)
        }
        for app in candidates {
            guard app.pathExtension == "app",
                let bundle = Bundle(url: app), let id = bundle.bundleIdentifier,
                !id.isEmpty, !id.contains("/"), id != ".", id != "..", id != BrowserBrand.bundleIdentifier
            else { continue }
            let resolvedApp = app.resolvingSymlinksInPath()
            let info = bundle.infoDictionary ?? [:]
            let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap {
                $0["CFBundleURLSchemes"] as? [String] ?? []
            }.map { $0.lowercased() }
            var code: SecStaticCode?
            var signing: CFDictionary?
            if SecStaticCodeCreateWithPath(resolvedApp as CFURL, [], &code) == errSecSuccess, let code {
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
            }
            let entitlements =
                (signing as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            let name =
                (info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                    ?? app.deletingPathExtension().lastPathComponent)
            let support = library.appendingPathComponent("Application Support", isDirectory: true)
            var relative = [name, id, info["CrProductDirName"] as? String].compactMap { $0 }
            let known: [String: [String]] = [
                "com.google.Chrome": ["Google/Chrome"], "com.google.Chrome.beta": ["Google/Chrome Beta"],
                "com.google.Chrome.dev": ["Google/Chrome Dev"],
                "com.google.Chrome.canary": ["Google/Chrome Canary"], "com.microsoft.edgemac": ["Microsoft Edge"],
                "com.microsoft.edgemac.Beta": ["Microsoft Edge Beta"],
                "com.microsoft.edgemac.Dev": ["Microsoft Edge Dev"],
                "com.microsoft.edgemac.Canary": ["Microsoft Edge Canary"],
                "com.brave.Browser": ["BraveSoftware/Brave-Browser"],
                "com.brave.Browser.beta": ["BraveSoftware/Brave-Browser-Beta"],
                "com.brave.Browser.nightly": ["BraveSoftware/Brave-Browser-Nightly"],
                "com.operasoftware.Opera": ["com.operasoftware.Opera"],
                "org.mozilla.firefox": ["Firefox/Profiles"],
                "org.mozilla.firefoxdeveloperedition": ["Firefox/Profiles"],
                "org.mozilla.nightly": ["Firefox/Profiles"],
                "app.zen-browser.zen": ["zen/Profiles"],
                "com.apple.SafariTechnologyPreview": [], "company.thebrowser.Browser": ["Arc", "Arc/User Data"],
                "company.thebrowser.dia": ["Dia/User Data", "Dia"],
                "com.vivaldi.Vivaldi": ["Vivaldi"], "org.chromium.Chromium": ["Chromium"],
                "com.kagi.kagimacOS": ["Orion"], "com.kagi.kagimacOS.RC": ["Orion RC"],
            ]
            let browserEntitlement =
                entitlements["com.apple.developer.web-browser"] as? Bool == true
                || entitlements["com.apple.developer.web-browser.public-key-credential"] as? Bool == true
            let htmlViewer = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).contains { type in
                guard (type["CFBundleTypeRole"] as? String)?.lowercased() == "viewer" else { return false }
                let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
                let extensions = type["CFBundleTypeExtensions"] as? [String] ?? []
                let mimeTypes = type["CFBundleTypeMIMETypes"] as? [String] ?? []
                return contentTypes.contains("public.html") || contentTypes.contains("public.xhtml")
                    || extensions.contains("html") || extensions.contains("htm") || mimeTypes.contains("text/html")
            }

            guard
                known[id] != nil || id == "com.apple.Safari"
                    || (schemes.contains("http") && schemes.contains("https") && (browserEntitlement || htmlViewer))
            else { continue }

            relative = (known[id] ?? relative).filter {
                !$0.isEmpty && !$0.hasPrefix("/")
                    && !$0.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                        $0.isEmpty || $0 == "." || $0 == ".."
                    })
            }
            var roots = relative.map { support.appendingPathComponent($0, isDirectory: true) }
            if known[id] == nil && id != "com.apple.Safari" {
                let containerSupport = library.appendingPathComponent(
                    "Containers/\(id)/Data/Library/Application Support")
                roots += relative.map { containerSupport.appendingPathComponent($0, isDirectory: true) }
            }
            if id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" {
                roots = []
                let safariFolder = id == "com.apple.Safari" ? "Safari" : "SafariTechnologyPreview"
                roots += [
                    library.appendingPathComponent(safariFolder),
                    library.appendingPathComponent("Containers/\(id)/Data/Library/Safari"),
                    library.appendingPathComponent("Containers/\(id)/Data/Library/Cookies"),
                    library.appendingPathComponent("Group Containers/group.\(id)/Library/Safari"),
                ]
            }
            if id == "com.kagi.kagimacOS" || id == "com.kagi.kagimacOS.RC" {
                roots.append(library.appendingPathComponent("HTTPStorages/\(id).binarycookies"))
            }
            let storageName =
                id.hasPrefix("com.google.Chrome")
                ? "Chrome"
                : id.hasPrefix("com.microsoft.edgemac") ? "Microsoft Edge" : id == "com.brave.Browser" ? "Brave" : name
            if found[id] == nil {
                found[id] = .init(
                    id: id, name: name, applicationURL: resolvedApp,
                    roots: Array(Set(roots)).sorted { $0.path < $1.path },
                    safeStorageService: id.hasPrefix("com.apple.Safari") ? nil : storageName + " Safe Storage")
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static let markers: Set<String> = [
        "History", "History.db", "places.sqlite", "Bookmarks",
        "Bookmarks.plist", "cookies.sqlite", "Cookies.binarycookies", "Cookies", "session.json", "cookies.json",
        "StorableSidebar.json", "history", "favourites.plist", "sessionstore.jsonlz4", "sessionstore.json",
        "Current Session",
    ]
    private struct Inspection {
        var folders = Set<URL>()
        var denied = false
        var readable = false
        var unreadable = false
    }

    private static func inspect(_ browser: ImportBrowser, readFiles: Bool) -> Inspection {
        let fm = FileManager.default
        var result = Inspection()
        var visited = Set<URL>()
        func walk(_ folder: URL, depth: Int, ownerProfile: URL? = nil) {
            guard depth <= 5, result.folders.count < 100, visited.count < 5_000,
                visited.insert(folder.standardizedFileURL).inserted
            else { return }
            do {
                let values = try folder.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
                if values.isRegularFile == true, values.isSymbolicLink != true,
                    folder.lastPathComponent.hasSuffix(".binarycookies")
                {
                    if readFiles {
                        let handle = try FileHandle(forReadingFrom: folder)
                        defer { try? handle.close() }
                        _ = try handle.read(upToCount: 1)
                        result.readable = true
                    }
                    return
                }
                guard values.isDirectory == true, values.isSymbolicLink != true else { return }
                let children = try fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                var isProfile = false
                for child in children where markers.contains(child.lastPathComponent) {
                    do {
                        let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        if child.lastPathComponent != "StorableSidebar.json" { isProfile = true }
                        if readFiles {
                            let handle = try FileHandle(forReadingFrom: child)
                            defer { try? handle.close() }
                            _ = try handle.read(upToCount: 1)
                            result.readable = true
                        }
                    } catch {
                        if permissionDenied(error) { result.denied = true } else { result.unreadable = true }
                    }
                }
                if isProfile {
                    result.folders.insert(
                        ownerProfile
                            ?? (folder.lastPathComponent == "Network" ? folder.deletingLastPathComponent() : folder))
                }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if isProfile && !["Profiles", "Network", "Cookies"].contains(child.lastPathComponent) { continue }
                    if [
                        "Cache", "Code Cache", "GPUCache", "Service Worker", "Extensions", "Storage", "IndexedDB",
                        "Local Storage", "Caches",
                    ].contains(child.lastPathComponent) {
                        continue
                    }

                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let owner =
                            isProfile && ["Network", "Cookies"].contains(child.lastPathComponent)
                            ? (ownerProfile ?? folder) : nil
                        walk(child, depth: depth + 1, ownerProfile: owner)
                    }
                }
            } catch {
                if permissionDenied(error) {
                    result.denied = true
                } else if !missingFile(error) {
                    result.unreadable = true
                }
            }
        }
        for root in browser.roots { walk(root, depth: 0) }
        return result
    }
    static func profileFolders(_ browser: ImportBrowser) -> [URL] {
        inspect(browser, readFiles: false).folders.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
    static func preview(_ browser: ImportBrowser, cookiePassword: Data? = nil) throws -> [ProfileImportPreview] {
        var previews: [ProfileImportPreview] = []
        var safariDefault: ProfileImportPreview?
        var failures: [String] = []
        for folder in profileFolders(browser) {
            do {
                var result = try ProfileImport.preview(folder, cookiePassword: cookiePassword)
                for index in result.indices {
                    result[index].name =
                        profileName(folder)
                        ?? (folder.lastPathComponent == "Default" ? browser.name : folder.lastPathComponent)
                    if browser.id.hasPrefix("com.kagi.kagimacOS"), folder.lastPathComponent == "Defaults" {
                        result[index].name = browser.name
                    }
                }
                if browser.isSafari, !folder.pathComponents.contains("Profiles") {

                    if safariDefault == nil { safariDefault = .init(name: browser.name) }
                    for item in result {
                        safariDefault?.history += item.history
                        safariDefault?.bookmarks += item.bookmarks
                        safariDefault?.folders += item.folders
                        safariDefault?.cookies += item.cookies
                        safariDefault?.tabs += item.tabs
                        safariDefault?.warnings += item.warnings
                    }
                } else {
                    previews += result
                }
            } catch { failures.append(folder.lastPathComponent + ": " + error.localizedDescription) }
        }
        if let safariDefault { previews.insert(ProfileImport.sanitize(safariDefault), at: 0) }
        if browser.id == "com.kagi.kagimacOS" || browser.id == "com.kagi.kagimacOS.RC" {

            for root in browser.roots where root.lastPathComponent.hasSuffix(".binarycookies") {
                do {
                    var cookies = try ProfileImport.preview(root)[0]
                    if let index = previews.firstIndex(where: { $0.name == browser.name }) {
                        previews[index].cookies += cookies.cookies
                        previews[index].warnings += cookies.warnings
                    } else {
                        cookies.name = browser.name + " cookies"
                        previews.append(cookies)
                    }
                } catch {
                    if !missingFile(error) { failures.append("Orion cookies: " + error.localizedDescription) }
                }
            }
        }
        if browser.id == "company.thebrowser.Browser" {
            for root in browser.roots {
                let sidebar = root.appendingPathComponent("StorableSidebar.json")
                if FileManager.default.fileExists(atPath: sidebar.path) {
                    do { previews += try ProfileImport.arcSpaces(sidebar) } catch {
                        failures.append("Arc spaces: " + error.localizedDescription)
                    }
                    break
                }
            }
        }
        guard !previews.isEmpty else {
            let reason =
                requestDataAccess(browser) == .denied
                ? "macOS denied access to this browser’s data. Choose its data folder to allow access for this import."
                : "Close the source browser and try again, or choose its profile folder or a bookmarks export."
            throw ProfileImport.Failure(message: "No readable profiles found in \(browser.name). " + reason)
        }
        guard previews.contains(where: { !$0.isEmpty }) else {
            throw ProfileImport.Failure(
                message:
                    "\(browser.name)’s data couldn’t be read. \(failures.joined(separator: " ")) \(previews.flatMap(\.warnings).joined(separator: " "))"
            )
        }
        let emptyWarnings = previews.filter(\.isEmpty).flatMap(\.warnings)
        previews.removeAll(where: \.isEmpty)
        previews[0].warnings += failures + emptyWarnings
        if requestDataAccess(browser) == .partial {
            previews[0].warnings.append(
                "Some source locations are blocked by macOS. Readable data is available below; choose a data folder from access help to read another location."
            )
        }
        return previews
    }
    enum DataAccess: Sendable, Equatable { case readable, partial, denied, noData, unreadable }

    static func requestDataAccess(_ browser: ImportBrowser) -> DataAccess {
        let result = inspect(browser, readFiles: true)
        if result.readable { return result.denied ? .partial : .readable }
        if result.denied { return .denied }
        return result.unreadable ? .unreadable : .noData
    }
    private static func missingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
            || (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { missingFile($0) } == true
    }
    private static func permissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
            || error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)
            || (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { permissionDenied($0) } == true
    }
    private static func profileName(_ folder: URL) -> String? {
        let file = folder.appendingPathComponent("Preferences")
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size < 50_000_000,
            let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["profile"] as? [String: Any])?["name"] as? String
    }

    static func cookiePassword(_ browser: ImportBrowser) throws -> Data {
        guard let service = browser.safeStorageService else {
            throw ProfileImport.Failure(message: "This browser has no supported cookie key.")
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProfileImport.Failure(
                message: "The cookie key wasn’t available (\(status)). History and bookmarks can still be imported.")
        }
        return data
    }
}

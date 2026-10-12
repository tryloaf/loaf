import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import WebKit

nonisolated struct CookieTransfer: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path = "/"
    var secure = false
    var httpOnly = false
    var expires: Double?
    func cookie(at date: Date = .now) -> HTTPCookie? {
        let host = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, name.count <= 1_024, value.utf8.count <= 16_384,
            !name.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
            let url = URL(string: "https://" + host), url.host == host, url.user == nil,
            path.hasPrefix("/"), expires.map({ $0.isFinite && $0 > date.timeIntervalSince1970 }) ?? true
        else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        return HTTPCookie(properties: properties)
    }
}

nonisolated struct ProfileImportPreview: Sendable {
    var name: String
    var history: [Visit] = []
    var bookmarks: [Favorite] = []
    var folders: [BookmarkFolder] = []
    var cookies: [CookieTransfer] = []
    var tabs: [SavedTab] = []
    var warnings: [String] = []
    var isEmpty: Bool { history.isEmpty && bookmarks.isEmpty && cookies.isEmpty && tabs.isEmpty }
}

nonisolated struct BookmarkArchive: Codable {
    var version = 1
    var bookmarks: [Favorite]
    var folders: [BookmarkFolder]
}

nonisolated enum ProfileImport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func preview(_ source: URL, cookiePassword: Data? = nil) throws -> [ProfileImportPreview] {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw Failure(message: "Choose the original folder or file, rather than a symbolic link.")
        }
        if values.isDirectory == true {
            let session = source.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: session.path) { return try snapshot(session) }
            var item = ProfileImportPreview(name: source.lastPathComponent)
            var foundSupportedSource = false
            func attempt(_ label: String, _ operation: () throws -> Void) {
                foundSupportedSource = true
                do { try operation() } catch { item.warnings.append(label + ": " + error.localizedDescription) }
            }

            let filenames = Set(try FileManager.default.contentsOfDirectory(atPath: source.path))
            for name in ["History", "History.db", "history"] where filenames.contains(name) {
                let file = source.appendingPathComponent(name)
                attempt("history") { item.history = try databaseHistory(file) }
                break
            }
            let places = source.appendingPathComponent("places.sqlite")
            if FileManager.default.fileExists(atPath: places.path) {
                attempt("Firefox history") { item.history = try firefoxHistory(places) }
                attempt("Firefox bookmarks") { try firefoxBookmarks(places, into: &item) }
            }
            let bookmarks = source.appendingPathComponent("Bookmarks")
            if FileManager.default.fileExists(atPath: bookmarks.path) {
                attempt("bookmarks") {
                    let object = try JSONSerialization.jsonObject(with: read(bookmarks)) as? [String: Any]
                    if let roots = object?["roots"] as? [String: Any] {
                        for key in roots.keys.sorted() {
                            collectBookmarks(roots[key], into: &item, folder: nil, depth: 0)
                        }
                    }
                }
            }
            let safariBookmarks = source.appendingPathComponent("Bookmarks.plist")
            if FileManager.default.fileExists(atPath: safariBookmarks.path) {
                attempt("Safari bookmarks") {
                    let object = try PropertyListSerialization.propertyList(
                        from: read(safariBookmarks), options: [], format: nil)
                    safariBookmarkTree(object, into: &item, folder: nil, depth: 0)
                }
            }
            let orionBookmarks = source.appendingPathComponent("favourites.plist")
            if FileManager.default.fileExists(atPath: orionBookmarks.path) {
                attempt("Orion bookmarks") { try orionBookmarkTree(orionBookmarks, into: &item) }
            }
            let firefoxCookies = source.appendingPathComponent("cookies.sqlite")
            if FileManager.default.fileExists(atPath: firefoxCookies.path) {
                attempt("Firefox cookies") { item.cookies = try firefoxCookieRows(firefoxCookies) }
            }
            for name in ["Cookies.binarycookies", "Cookies/Cookies.binarycookies"] {
                let file = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    attempt("WebKit cookies") { item.cookies += try binaryCookies(file) }
                    break
                }
            }
            let cookieJSON = source.appendingPathComponent("cookies.json")
            if FileManager.default.fileExists(atPath: cookieJSON.path) {
                attempt("cookies") {
                    item.cookies += try JSONDecoder().decode([CookieTransfer].self, from: read(cookieJSON))
                }
            } else {
                for name in ["Cookies", "Network/Cookies"] {
                    let file = source.appendingPathComponent(name)
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        attempt("Chromium cookies") {
                            let result = try databaseCookies(file, password: cookiePassword)
                            item.cookies += result.cookies
                            if result.encrypted > 0 {
                                item.warnings.append(
                                    "\(result.encrypted) protected cookies weren’t read. Use unlock encrypted cookies for a supported macOS browser, or import a readable cookies.json export."
                                )
                            }
                        }
                        break
                    }
                }
            }
            let firefoxSessions = [
                "sessionstore.jsonlz4", "sessionstore.json",
                "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4",
            ]
            .map { source.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if let session = firefoxSessions.sorted(by: {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast)
            }).first {
                attempt("Firefox pinned tabs") { item.tabs += try ImportedPinnedTabs.firefox(read(session)) }
            }
            let sessions = source.appendingPathComponent("Sessions")
            let chromiumSessions =
                ((try? FileManager.default.contentsOfDirectory(
                    at: sessions,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Session_") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let session = chromiumSessions.first {
                attempt("pinned tabs") { item.tabs += try ImportedPinnedTabs.chromium(read(session)) }
            } else if filenames.contains("Current Session") {
                attempt("pinned tabs") {
                    item.tabs += try ImportedPinnedTabs.chromium(read(source.appendingPathComponent("Current Session")))
                }
            } else if FileManager.default.fileExists(atPath: source.appendingPathComponent("SessionsEncrypted").path) {
                item.warnings.append("This browser encrypts its saved session; pinned tabs weren’t read.")
            }
            guard foundSupportedSource || !item.isEmpty || !item.warnings.isEmpty else {
                throw Failure(
                    message:
                        "No supported browsing data found. Choose a Chromium, Firefox, or WebKit profile folder, or an exported bookmarks/session file."
                )
            }
            return [sanitize(item)]
        }
        if source.pathExtension.lowercased() == "jsonlz4" {
            return [sanitize(.init(name: "Firefox", tabs: try ImportedPinnedTabs.firefox(read(source))))]
        }
        if source.pathExtension.lowercased() == "plist" {
            var item = ProfileImportPreview(name: source.deletingPathExtension().lastPathComponent)
            safariBookmarkTree(
                try PropertyListSerialization.propertyList(from: read(source), options: [], format: nil), into: &item,
                folder: nil, depth: 0)
            return [sanitize(item)]
        }
        if source.pathExtension.lowercased() == "binarycookies" {
            return [sanitize(.init(name: "WebKit", cookies: try binaryCookies(source)))]
        }
        if source.pathExtension.lowercased() == "html" {
            return [
                sanitize(
                    .init(
                        name: source.deletingPathExtension().lastPathComponent,
                        bookmarks: try BookmarkImport.html(String(decoding: read(source), as: UTF8.self))))
            ]
        }
        return try snapshot(source)
    }
    private static func snapshot(_ url: URL) throws -> [ProfileImportPreview] {
        let data = try read(url)
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(BrowserSnapshot.self, from: data) {
            guard [1, 2].contains(snapshot.version) else {
                throw Failure(message: "This session format is newer than this version of loaf.")
            }
            return snapshot.profiles.filter { !$0.privateMode }.prefix(8).map {
                sanitize(
                    .init(
                        name: $0.name, history: $0.history, bookmarks: $0.favorites, folders: $0.bookmarkFolders ?? []))
            }
        }
        if let archive = try? decoder.decode(BookmarkArchive.self, from: data), archive.version == 1 {
            return [sanitize(.init(name: "imported", bookmarks: archive.bookmarks, folders: archive.folders))]
        }
        if let bookmarks = try? decoder.decode([Favorite].self, from: data) {
            return [sanitize(.init(name: "imported", bookmarks: bookmarks))]
        }
        if let cookies = try? decoder.decode([CookieTransfer].self, from: data) {
            return [sanitize(.init(name: "imported", cookies: cookies))]
        }
        throw Failure(message: "This file isn’t a supported profile, bookmarks, or cookies export.")
    }
    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 50_000_000
        else { throw Failure(message: "Choose a regular export file smaller than 50 MB.") }
        return try Data(contentsOf: url)
    }
    private static func validURL(_ address: String) -> Bool {
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            url.port.map({ (1...65535).contains($0) }) != false,
            !address.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return false }
        return true
    }
    static func sanitize(_ item: ProfileImportPreview) -> ProfileImportPreview {
        var item = item
        let originalCounts = [item.history.count, item.bookmarks.count, item.cookies.count, item.tabs.count]
        item.name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var seenVisits = Set<[String]>()
        item.history = Array(
            item.history.filter {
                validURL($0.address) && $0.date.timeIntervalSince1970.isFinite
                    && $0.date <= Date.now.addingTimeInterval(86_400)
                    && seenVisits.insert([$0.address, String($0.date.timeIntervalSince1970)]).inserted
            }.sorted { $0.date > $1.date }.prefix(20_000))
        var seenBookmarks = Set<String>()
        item.bookmarks = Array(
            item.bookmarks.filter { validURL($0.address) && seenBookmarks.insert($0.address).inserted }.prefix(20_000))
        var uniqueCookies: [CookieTransfer] = []
        var cookieValues: [[String]: CookieTransfer] = [:]
        var conflictingCookies = Set<[String]>()
        for cookie in item.cookies {
            guard let parsed = cookie.cookie() else { continue }
            let identity = cookieIdentity(parsed)
            if let previous = cookieValues[identity] {
                if previous.value != cookie.value || previous.secure != cookie.secure
                    || previous.httpOnly != cookie.httpOnly
                {
                    conflictingCookies.insert(identity)
                }
            } else {
                cookieValues[identity] = cookie
                uniqueCookies.append(cookie)
            }
        }
        item.cookies = Array(
            uniqueCookies.filter {
                guard let cookie = $0.cookie() else { return false }
                return !conflictingCookies.contains(cookieIdentity(cookie))
            }.prefix(10_000))
        item.tabs = Array(item.tabs.filter { $0.address.map(validURL) == true }.prefix(500))
        var seenFolders = Set<UUID>()
        item.folders = Array(item.folders.filter { seenFolders.insert($0.id).inserted }.prefix(1_000))
        for index in item.history.indices {
            item.history[index].title = String(item.history[index].title.prefix(500))
            item.history[index].count = max(1, min(item.history[index].count, 1_000_000))
            item.history[index].sessionID = nil
        }
        for index in item.bookmarks.indices {
            item.bookmarks[index].title = String(item.bookmarks[index].title.prefix(500))
        }
        for index in item.folders.indices { item.folders[index].name = String(item.folders[index].name.prefix(80)) }
        let labels = ["history entries", "bookmarks", "cookies", "saved tabs"]
        let counts = [item.history.count, item.bookmarks.count, item.cookies.count, item.tabs.count]
        for index in counts.indices where counts[index] < originalCounts[index] {
            item.warnings.append(
                "\(originalCounts[index] - counts[index]) \(labels[index]) excluded because they were invalid, expired, duplicated, conflicting or exceeded import limits."
            )
        }
        let folderIDs = Set(item.folders.map(\.id))
        for index in item.bookmarks.indices
        where item.bookmarks[index].folderID.map({ !folderIDs.contains($0) }) == true {
            item.bookmarks[index].folderID = nil
        }
        return item
    }
    private static func collectBookmarks(
        _ object: Any?, into item: inout ProfileImportPreview, folder: UUID?, depth: Int
    ) {
        guard depth < 20, item.bookmarks.count < 20_000, let node = object as? [String: Any] else { return }
        if let url = node["url"] as? String, validURL(url) {
            item.bookmarks.append(
                .init(title: String((node["name"] as? String ?? url).prefix(500)), address: url, folderID: folder))
        } else if let children = node["children"] as? [[String: Any]] {
            var target = folder
            if depth > 0, item.folders.count < 1_000, let name = node["name"] as? String, !name.isEmpty {
                let new = BookmarkFolder(name: String(name.prefix(80)))
                item.folders.append(new)
                target = new.id
            }
            for child in children { collectBookmarks(child, into: &item, folder: target, depth: depth + 1) }
        }
    }
    private static func orionBookmarkTree(_ file: URL, into item: inout ProfileImportPreview) throws {
        guard
            let entries = try PropertyListSerialization.propertyList(from: read(file), options: [], format: nil)
                as? [String: [String: Any]], entries.count <= 25_000
        else {
            throw Failure(message: "This Orion bookmarks file has an unsupported format.")
        }
        var folders: [String: UUID] = [:]
        let ordered = entries.sorted {
            let left = $0.value["index"] as? Int ?? 0
            let right = $1.value["index"] as? Int ?? 0
            return left == right ? $0.key < $1.key : left < right
        }
        for (id, entry) in ordered where entry["type"] as? String == "folder" && id != "0" {
            guard item.folders.count < 1_000 else { break }
            let folder = BookmarkFolder(name: String((entry["title"] as? String ?? "folder").prefix(80)))
            folders[id] = folder.id
            item.folders.append(folder)
        }
        for (_, entry) in ordered where entry["type"] as? String == "bookmark" {
            guard item.bookmarks.count < 20_000 else { break }
            guard let address = entry["url"] as? String, validURL(address) else { continue }
            item.bookmarks.append(
                .init(
                    title: String((entry["title"] as? String ?? address).prefix(500)), address: address,
                    folderID: (entry["parentId"] as? String).flatMap { folders[$0] }))
        }
    }
    private static func query(_ file: URL, sql: String) throws -> [[String]] {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 500_000_000
        else { throw Failure(message: "Choose an original history or cookies database smaller than 500 MB.") }

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(
            "loaf-import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("database")
        func signature(_ url: URL) throws -> [AnyHashable] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber, size.int64Value <= 500_000_000
            else { throw Failure(message: "Choose an original database smaller than 500 MB.") }
            return [
                size, attributes[.modificationDate] as? Date ?? .distantPast,
                attributes[.systemFileNumber] as? NSNumber ?? 0,
            ]
        }
        let before = try signature(file)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let walBefore: [AnyHashable]?
        do { walBefore = try signature(wal) } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            walBefore = nil
        }
        try fm.copyItem(at: file, to: snapshot)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        if let walBefore {
            let snapshotWAL = URL(fileURLWithPath: snapshot.path + "-wal")
            try fm.copyItem(at: wal, to: snapshotWAL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotWAL.path)
            guard try signature(wal) == walBefore else {
                throw Failure(message: "The source browser is changing its data. Close it and try again.")
            }
        } else if fm.fileExists(atPath: wal.path) {
            throw Failure(message: "The source browser is changing its data. Close it and try again.")
        }
        guard try signature(file) == before else {
            throw Failure(message: "The source browser is changing its data. Close it and try again.")
        }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openStatus == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure(
                message:
                    "This database couldn’t be opened. Close the source browser and choose its profile folder, or import a bookmarks export."
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: "This database has an unsupported format.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW, rows.count < 20_000 {
            rows.append(
                (0..<sqlite3_column_count(statement)).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE || rows.count == 20_000 else {
            throw Failure(message: "The database is busy or unreadable. Close the source app and try again.")
        }
        return rows
    }
    private static func databaseHistory(_ file: URL) throws -> [Visit] {
        let rows: [[String]]
        let epoch: Double
        let divisor: Double
        let tables = Set(
            try query(
                file,
                sql:
                    "SELECT lower(name) FROM sqlite_master WHERE type='table' AND lower(name) IN ('urls','history_items','history_visits','visits')"
            )
            .compactMap(\.first))
        if tables.contains("urls") {
            rows = try query(
                file,
                sql:
                    "SELECT url, title, last_visit_time, visit_count FROM urls ORDER BY last_visit_time DESC LIMIT 20000"
            )
            epoch = -11_644_473_600
            divisor = 1_000_000
        } else if tables.isSuperset(of: ["history_items", "history_visits"]) {
            rows = try query(
                file,
                sql:
                    "SELECT h.url, v.title, v.visit_time, h.visit_count FROM history_items h JOIN history_visits v ON v.history_item=h.id ORDER BY v.visit_time DESC LIMIT 20000"
            )
            epoch = 978_307_200
            divisor = 1
        } else if tables.isSuperset(of: ["history_items", "visits"]) {
            rows = try query(
                file,
                sql:
                    "SELECT h.url, h.title, strftime('%s',v.visit_time), h.visit_count FROM history_items h JOIN visits v ON v.history_item_id=h.id ORDER BY v.visit_time DESC LIMIT 20000"
            )
            epoch = 0
            divisor = 1
        } else {
            throw Failure(message: "This history database has an unsupported format.")
        }
        return rows.compactMap { row in
            guard row.count == 4, validURL(row[0]), let time = Double(row[2]), time.isFinite else { return nil }
            return Visit(
                title: String(row[1].prefix(500)), address: row[0],
                date: Date(timeIntervalSince1970: time / divisor + epoch),
                count: max(1, min(1_000_000, Int(row[3]) ?? 1)))
        }
    }
    private static func databaseCookies(_ file: URL, password: Data?) throws -> (
        cookies: [CookieTransfer], encrypted: Int
    ) {
        let columns = Set(try query(file, sql: "PRAGMA table_info(cookies)").compactMap { $0.count > 1 ? $0[1] : nil })
        var conditions: [String] = []

        if columns.contains("top_frame_site_key") { conditions.append("top_frame_site_key=''") }
        if columns.contains("is_partitioned") { conditions.append("is_partitioned=0") }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let rows = try query(
            file,
            sql:
                "SELECT name, value, host_key, path, is_secure, is_httponly, expires_utc, hex(encrypted_value) FROM cookies"
                + filter + " LIMIT 10000")
        let metadata = try? query(file, sql: "SELECT value FROM meta WHERE key='version'")
        let requiresHostHash = (metadata?.first?.first.flatMap(Int.init) ?? 24) >= 24
        var cookies: [CookieTransfer] = []
        var encrypted = 0
        for row in rows where row.count == 8 {
            var value = row[1]
            if value.isEmpty && !row[7].isEmpty {
                guard let password,
                    let decoded = decryptChromiumCookie(
                        row[7], domain: row[2], password: password, requiresHostHash: requiresHostHash)
                else {
                    encrypted += 1
                    continue
                }
                value = decoded
            }
            let raw = Double(row[6]) ?? 0
            cookies.append(
                .init(
                    name: row[0], value: value, domain: row[2], path: row[3], secure: row[4] == "1",
                    httpOnly: row[5] == "1", expires: raw > 0 ? raw / 1_000_000 - 11_644_473_600 : nil))
        }
        return (cookies, encrypted)
    }
    private static func firefoxHistory(_ file: URL) throws -> [Visit] {
        try query(
            file,
            sql:
                "SELECT url, title, last_visit_date, visit_count FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 20000"
        ).compactMap { row in
            guard row.count == 4, let time = Double(row[2]) else { return nil }
            return Visit(
                title: String(row[1].prefix(500)), address: row[0], date: Date(timeIntervalSince1970: time / 1_000_000),
                count: max(1, Int(row[3]) ?? 1))
        }
    }
    private static func firefoxBookmarks(_ file: URL, into item: inout ProfileImportPreview) throws {
        let rows = try query(
            file,
            sql:
                "SELECT b.id, b.parent, b.type, COALESCE(b.title, p.title, ''), COALESCE(p.url, '') FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id=b.fk ORDER BY b.position LIMIT 20000"
        )
        var folders: [String: UUID] = [:]
        for row in rows where row.count == 5 && row[2] == "2" && !row[3].isEmpty {
            let folder = BookmarkFolder(name: String(row[3].prefix(80)))
            folders[row[0]] = folder.id
            item.folders.append(folder)
        }
        for row in rows where row.count == 5 && row[2] == "1" && validURL(row[4]) {
            item.bookmarks.append(
                .init(
                    title: String((row[3].isEmpty ? row[4] : row[3]).prefix(500)), address: row[4],
                    folderID: folders[row[1]]))
        }
    }
    private static func firefoxCookieRows(_ file: URL) throws -> [CookieTransfer] {
        try query(
            file,
            sql:
                "SELECT name, value, host, path, isSecure, isHttpOnly, expiry FROM moz_cookies WHERE originAttributes='' LIMIT 10000"
        ).compactMap { row in
            guard row.count == 7 else { return nil }
            return .init(
                name: row[0], value: row[1], domain: row[2], path: row[3], secure: row[4] == "1",
                httpOnly: row[5] == "1", expires: Double(row[6]))
        }
    }
    private static func safariBookmarkTree(
        _ object: Any, into item: inout ProfileImportPreview, folder: UUID?, depth: Int
    ) {
        guard depth < 20, item.bookmarks.count < 20_000, let node = object as? [String: Any] else { return }
        if let url = node["URLString"] as? String, validURL(url) {
            let title =
                (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String ?? url
            item.bookmarks.append(.init(title: String(title.prefix(500)), address: url, folderID: folder))
        } else if let children = node["Children"] as? [Any] {
            var target = folder
            if depth > 0, let name = node["Title"] as? String, !name.isEmpty, item.folders.count < 1_000 {
                let new = BookmarkFolder(name: String(name.prefix(80)))
                item.folders.append(new)
                target = new.id
            }
            for child in children { safariBookmarkTree(child, into: &item, folder: target, depth: depth + 1) }
        }
    }
    static func decryptChromiumCookie(_ hex: String, domain: String, password: Data, requiresHostHash: Bool = true)
        -> String?
    {
        guard hex.count <= 40_000, hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        guard bytes.starts(with: Array("v10".utf8)), bytes.count > 3 else { return nil }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { ptr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), ptr.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let ciphertext = Array(bytes.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: 16)
        var decoded = [UInt8](repeating: 0, count: ciphertext.count + 16)
        var count = 0
        let capacity = decoded.count
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
            ciphertext, ciphertext.count, &decoded, capacity, &count)
        guard status == kCCSuccess else { return nil }
        var result = Data(decoded.prefix(count))

        let hash = Data(SHA256.hash(data: Data(domain.utf8)))
        if requiresHostHash {
            guard result.starts(with: hash) else { return nil }
            result = result.dropFirst(32)
        }
        return String(data: result, encoding: .utf8)
    }
    static func binaryCookies(_ file: URL) throws -> [CookieTransfer] {
        let data = try read(file)
        func uint(_ offset: Int, in bytes: Data, big: Bool = false) -> Int? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            let b = Array(bytes[offset..<offset + 4])
            return big
                ? Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                : Int(b[3]) << 24 | Int(b[2]) << 16 | Int(b[1]) << 8 | Int(b[0])
        }
        guard data.starts(with: Data("cook".utf8)), let count = uint(4, in: data, big: true), count <= 10_000,
            8 + count * 4 <= data.count
        else { throw Failure(message: "Invalid WebKit cookie file.") }
        var result: [CookieTransfer] = []
        var cursor = 8 + count * 4
        for index in 0..<count {
            guard let size = uint(8 + index * 4, in: data, big: true), size >= 8, cursor <= data.count - size else {
                throw Failure(message: "Truncated WebKit cookie page.")
            }
            let page = Data(data[cursor..<cursor + size])
            cursor += size
            guard let cookies = uint(4, in: page), cookies <= 10_000, 8 + cookies * 4 <= page.count else { continue }
            for cookieIndex in 0..<cookies where result.count < 10_000 {
                guard let offset = uint(8 + cookieIndex * 4, in: page), let length = uint(offset, in: page),
                    length >= 56, offset <= page.count - length
                else { continue }
                let entry = Data(page[offset..<offset + length])
                func string(_ field: Int) -> String? {
                    guard let start = uint(field, in: entry), start >= 56, start < entry.count,
                        let end = entry[start...].firstIndex(of: 0)
                    else { return nil }
                    return String(data: entry[start..<end], encoding: .utf8)
                }
                guard let domain = string(16), let name = string(20), let path = string(24), let value = string(28),
                    let flags = uint(8, in: entry)
                else { continue }
                let bits = entry[40..<48].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                let expires = Double(bitPattern: bits) + 978_307_200
                result.append(
                    .init(
                        name: name, value: value, domain: domain, path: path, secure: flags & 1 != 0,
                        httpOnly: flags & 4 != 0, expires: expires))
            }
        }
        return result
    }
    static func arcSpaces(_ file: URL) throws -> [ProfileImportPreview] {
        guard let object = try JSONSerialization.jsonObject(with: read(file)) as? [String: Any],
            let state = object["sidebarSyncState"] as? [String: Any], let rawSpaces = state["spaceModels"] as? [Any],
            let rawItems = state["items"] as? [Any]
        else {
            throw Failure(message: "This Arc sidebar format isn’t supported. Export bookmarks from Arc instead.")
        }
        func values(_ raw: [Any]) -> [[String: Any]] {
            raw.compactMap { ($0 as? [String: Any])?["value"] as? [String: Any] }
        }
        let spaces = values(rawSpaces)
        let items = values(rawItems)
        var byID: [String: [String: Any]] = [:]
        for item in items { if let id = item["id"] as? String { byID[id] = item } }
        return spaces.prefix(100).compactMap { space in
            guard let name = space["title"] as? String, let id = space["id"] as? String else { return nil }
            var roots = Set(space["containerIDs"] as? [String] ?? [])
            for item in items {
                if let data = item["data"] as? [String: Any], let container = data["itemContainer"] as? [String: Any],
                    let type = container["containerType"] as? [String: Any],
                    let spaceItems = type["spaceItems"] as? [String: Any], spaceItems["_0"] as? String == id,
                    let itemID = item["id"] as? String
                {
                    roots.insert(itemID)
                }
            }
            var preview = ProfileImportPreview(name: name)
            func belongs(_ item: [String: Any]) -> Bool {
                var parent = item["parentID"] as? String
                var seen = Set<String>()
                while let current = parent, seen.insert(current).inserted, seen.count <= 100 {
                    if roots.contains(current) { return true }
                    parent = byID[current]?["parentID"] as? String
                }
                return false
            }
            func isPinned(_ item: [String: Any]) -> Bool {
                var current: [String: Any]? = item
                var seen = Set<String>()
                while let value = current {
                    if let pinned = value["isPinned"] as? Bool { return pinned }
                    if let data = value["data"] as? [String: Any] {
                        if let tab = data["tab"] as? [String: Any], let pinned = tab["isPinned"] as? Bool {
                            return pinned
                        }
                        if let container = data["itemContainer"] as? [String: Any],
                            let type = container["containerType"] as? [String: Any],
                            let space = type["spaceItems"] as? [String: Any], let section = space["_1"] as? String
                        {
                            if section == "pinned" { return true }
                            if section == "unpinned" { return false }
                        }
                    }
                    guard let parent = value["parentID"] as? String,
                        seen.insert(parent).inserted, seen.count <= 100
                    else { break }
                    current = byID[parent]
                }
                return false
            }
            for item in items where belongs(item) {
                guard let data = item["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                    let url = tab["savedURL"] as? String, validURL(url)
                else { continue }
                let title = item["title"] as? String ?? tab["savedTitle"] as? String ?? url
                preview.bookmarks.append(.init(title: title, address: url))
                preview.tabs.append(
                    SavedTab(
                        title: title, address: url, pinned: isPinned(item), pinnedAddress: isPinned(item) ? url : nil))
            }
            preview.warnings = [
                "Each Arc space becomes a separate loaf profile. Its saved tabs and bookmarks are imported; browser-profile history and cookies are available separately."
            ]
            return sanitize(preview)
        }
    }

}

extension ProfileImport {

    static func merging(_ preview: ProfileImportPreview, into original: Profile, history: Bool, bookmarks: Bool) throws
        -> Profile
    {
        var profile = original
        if history {
            var known = Set(profile.history.map { [$0.address, String($0.date.timeIntervalSince1970)] })
            let additions = preview.history.filter {
                known.insert([$0.address, String($0.date.timeIntervalSince1970)]).inserted
            }
            guard additions.isEmpty || profile.history.count + additions.count <= 50_000 else {
                throw Failure(
                    message:
                        "There isn’t room for this history in \(profile.name). Create a new profile or leave history unchecked. Your existing history has been kept."
                )
            }
            profile.history += additions.map {
                var visit = $0
                visit.id = UUID()
                return visit
            }
            profile.history.sort { $0.date > $1.date }
        }
        if bookmarks {
            var known = Set(profile.favorites.map(\.address))
            let additions = preview.bookmarks.filter { known.insert($0.address).inserted }
            let usedFolders = Set(additions.compactMap(\.folderID))
            var mapping: [UUID: UUID] = [:]
            for folder in preview.folders where usedFolders.contains(folder.id) {
                if let existing = profile.bookmarkFolders?.first(where: { $0.name == folder.name }) {
                    mapping[folder.id] = existing.id
                } else {
                    let new = BookmarkFolder(name: folder.name)
                    mapping[folder.id] = new.id
                    profile.bookmarkFolders = (profile.bookmarkFolders ?? []) + [new]
                }
            }
            profile.favorites += additions.map {
                var bookmark = $0
                bookmark.id = UUID()
                bookmark.folderID = bookmark.folderID.flatMap { mapping[$0] }
                return bookmark
            }
        }
        return profile
    }
    nonisolated static func cookieIdentity(_ cookie: HTTPCookie) -> [String] {
        [cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), cookie.path, cookie.name]
    }
}

extension BrowserWindowState {
    func importProfile(
        _ source: ProfileImportPreview, name: String, newProfile: Bool, history: Bool, bookmarks: Bool, cookies: Bool,
        tabs: Bool = false
    ) async throws {
        _ = try await importProfiles(
            [source], names: [name], newProfile: newProfile, history: history,
            bookmarks: bookmarks, cookies: cookies, tabs: tabs, destinationID: selectedProfileID)
    }

    @discardableResult func importProfiles(
        _ sources: [ProfileImportPreview], names: [String], newProfile: Bool, history: Bool, bookmarks: Bool,
        cookies: Bool, tabs: Bool = false, destinationID: UUID
    ) async throws -> [UUID] {
        guard !application.profileImportInProgress, !application.busyProfileIDs.contains(destinationID),
            let destination = application.profiles.first(where: { $0.id == destinationID }), !destination.privateMode,
            !sources.isEmpty, sources.count == names.count, newProfile || sources.count == 1,
            !newProfile || application.profiles.count + sources.count <= 8
        else {
            throw ProfileImport.Failure(
                message: "Choose an available regular profile with room to import. loaf supports up to 8 profiles.")
        }
        let previews = sources.map(ProfileImport.sanitize)
        let cleanNames = names.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
        guard !newProfile || cleanNames.allSatisfy({ !$0.isEmpty }),
            previews.allSatisfy({
                history && !$0.history.isEmpty || bookmarks && !$0.bookmarks.isEmpty || cookies && !$0.cookies.isEmpty
                    || tabs && !$0.tabs.isEmpty
            })
        else {
            throw ProfileImport.Failure(message: "Choose a name and readable data for every profile being imported.")
        }
        guard !cookies || newProfile else {
            throw ProfileImport.Failure(
                message: "Create a new profile to import cookies. Existing profile sign-ins are kept untouched.")
        }
        try Task.checkCancellation()
        application.profileImportInProgress = true
        application.busyProfileIDs.insert(destinationID)
        var importedIDs: [UUID] = []
        defer {
            application.profileImportInProgress = false
            application.busyProfileIDs.subtract(importedIDs + [destinationID])
        }
        let originals =
            newProfile
            ? cleanNames.enumerated().map { index, name in
                Profile(name: name, tint: (application.profiles.count + index) % 4)
            } : [profileFor(destinationID)]
        let prepared = try zip(previews, originals).map {
            try ProfileImport.merging($0.0, into: $0.1, history: history, bookmarks: bookmarks)
        }
        importedIDs = prepared.map(\.id)
        application.busyProfileIDs.formUnion(importedIDs)
        let previousProfiles = application.profiles
        let previousWorkspaces = workspaces
        if newProfile {
            application.profiles.append(contentsOf: prepared)
        } else {
            updateProfile(destinationID) { $0 = prepared[0] }
        }
        do { try application.persistImport() } catch {
            application.profiles = previousProfiles
            workspaces = previousWorkspaces
            try? application.persistImport()
            throw ProfileImport.Failure(
                message:
                    "The import couldn’t be saved and was stopped before cookies were written or websites opened. Check available disk space and folder access, then try again."
            )
        }

        for (preview, profile) in zip(previews, prepared) {
            if cookies {
                let jar = runtime(for: profile.id).dataStore.httpCookieStore
                var known = Set<[String]>()
                for item in preview.cookies {
                    if let cookie = item.cookie(), known.insert(ProfileImport.cookieIdentity(cookie)).inserted {
                        await jar.setCookie(cookie)
                    }
                }
            }
            for saved in tabs ? preview.tabs : [] {
                if let address = saved.address, let url = URL(string: address) {
                    let tab = newTab(url: url, profileID: profile.id, showOmnibar: false, activate: false)
                    tab.customTitle = saved.customTitle ?? saved.title
                    if saved.pinned {
                        tab.pinnedTitle = saved.pinnedTitle ?? saved.title
                        togglePin(tab)
                    }
                }
            }
        }
        if newProfile, let first = importedIDs.first { switchProfile(first) }
        persist()
        return importedIDs
    }
}

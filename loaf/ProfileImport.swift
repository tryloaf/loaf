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
    var warnings: [String] = []
    var isEmpty: Bool { history.isEmpty && bookmarks.isEmpty && cookies.isEmpty }
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
    static func preview(_ source: URL) throws -> [ProfileImportPreview] {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw Failure(message: "Choose the original folder or file, rather than a symbolic link.")
        }
        if values.isDirectory == true {
            let session = source.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: session.path) { return try snapshot(session) }
            var item = ProfileImportPreview(name: source.lastPathComponent)
            for name in ["History", "History.db"] {
                let file = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    item.history = try databaseHistory(file)
                    break
                }
            }
            let bookmarks = source.appendingPathComponent("Bookmarks")
            if FileManager.default.fileExists(atPath: bookmarks.path) {
                let object = try JSONSerialization.jsonObject(with: read(bookmarks)) as? [String: Any]
                if let roots = object?["roots"] as? [String: Any] {
                    for key in roots.keys.sorted() { collectBookmarks(roots[key], into: &item, folder: nil, depth: 0) }
                }
            }
            let cookieJSON = source.appendingPathComponent("cookies.json")
            if FileManager.default.fileExists(atPath: cookieJSON.path) {
                item.cookies = try JSONDecoder().decode([CookieTransfer].self, from: read(cookieJSON))
            } else {
                for name in ["Cookies", "Network/Cookies"] {
                    let file = source.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: file.path) {
                        let result = try databaseCookies(file)
                        item.cookies = result.cookies
                        if result.encrypted > 0 {
                            item.warnings.append(
                                "\(result.encrypted) encrypted cookies cannot be imported from this database. Export readable cookies to cookies.json to include them."
                            )
                        }
                        break
                    }
                }
            }
            guard !item.isEmpty || !item.warnings.isEmpty else {
                throw Failure(
                    message:
                        "No supported browsing data found. Choose a profile folder containing History or History.db, or a loaf session JSON file."
                )
            }
            return [sanitize(item)]
        }
        if source.pathExtension.lowercased() == "html" {
            return [
                .init(
                    name: source.deletingPathExtension().lastPathComponent,
                    bookmarks: try BookmarkImport.html(String(decoding: read(source), as: UTF8.self)))
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
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil,
            url.password == nil
        else { return false }
        return true
    }
    static func sanitize(_ item: ProfileImportPreview) -> ProfileImportPreview {
        var item = item
        item.name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        item.history = Array(
            item.history.filter {
                validURL($0.address) && $0.date.timeIntervalSince1970.isFinite
                    && $0.date <= Date.now.addingTimeInterval(86_400)
            }.prefix(20_000))
        item.bookmarks = Array(item.bookmarks.filter { validURL($0.address) }.prefix(20_000))
        item.cookies = Array(item.cookies.filter { $0.cookie() != nil }.prefix(10_000))
        item.folders = Array(item.folders.prefix(1_000))
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
    private static func query(_ file: URL, sql: String) throws -> [[String]] {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 500_000_000
        else { throw Failure(message: "Choose an original history or cookies database smaller than 500 MB.") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure(
                message:
                    "The selected database can’t be read. Close the source app and, if macOS blocks access, grant loaf Full Disk Access in System Settings."
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
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
        if file.lastPathComponent == "History.db" {
            rows = try query(
                file,
                sql:
                    "SELECT h.url, v.title, v.visit_time, h.visit_count FROM history_items h JOIN history_visits v ON v.history_item=h.id ORDER BY v.visit_time DESC LIMIT 20000"
            )
            epoch = 978_307_200
            divisor = 1
        } else {
            rows = try query(
                file,
                sql:
                    "SELECT url, title, last_visit_time, visit_count FROM urls ORDER BY last_visit_time DESC LIMIT 20000"
            )
            epoch = -11_644_473_600
            divisor = 1_000_000
        }
        return rows.compactMap { row in
            guard row.count == 4, validURL(row[0]), let time = Double(row[2]), time.isFinite else { return nil }
            return Visit(
                title: String(row[1].prefix(500)), address: row[0],
                date: Date(timeIntervalSince1970: time / divisor + epoch),
                count: max(1, min(1_000_000, Int(row[3]) ?? 1)))
        }
    }
    private static func databaseCookies(_ file: URL) throws -> (cookies: [CookieTransfer], encrypted: Int) {
        let rows = try query(
            file,
            sql:
                "SELECT name, value, host_key, path, is_secure, is_httponly, expires_utc, length(encrypted_value) FROM cookies LIMIT 10000"
        )
        var cookies: [CookieTransfer] = []
        var encrypted = 0
        for row in rows where row.count == 8 {
            if row[1].isEmpty && (Int(row[7]) ?? 0) > 0 {
                encrypted += 1
                continue
            }
            let raw = Double(row[6]) ?? 0
            cookies.append(
                .init(
                    name: row[0], value: row[1], domain: row[2], path: row[3], secure: row[4] == "1",
                    httpOnly: row[5] == "1", expires: raw > 0 ? raw / 1_000_000 - 11_644_473_600 : nil))
        }
        return (cookies, encrypted)
    }
}

extension BrowserWindowState {
    func importProfile(
        _ source: ProfileImportPreview, name: String, newProfile: Bool, history: Bool, bookmarks: Bool, cookies: Bool
    ) async throws {
        guard !profile.privateMode, !newProfile || profiles.count < 8 else {
            throw ProfileImport.Failure(
                message: "Choose a regular profile with room to import. loaf supports up to 8 profiles.")
        }
        let preview = ProfileImport.sanitize(source)
        let destination: UUID
        if newProfile {
            let imported = Profile(
                name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), tint: profiles.count % 4)
            application.profiles.append(imported)
            destination = imported.id
        } else {
            destination = selectedProfileID
        }
        updateProfile(destination) { profile in
            if history {
                var known = Set(profile.history.map { $0.address + String($0.date.timeIntervalSince1970) })
                for var visit in preview.history
                where known.insert(visit.address + String(visit.date.timeIntervalSince1970)).inserted {
                    visit.id = UUID()
                    profile.history.append(visit)
                }
                profile.history.sort { $0.date > $1.date }
                profile.history = Array(profile.history.prefix(20_000))
            }
            if bookmarks {
                var mapping: [UUID: UUID] = [:]
                for folder in preview.folders {
                    let new = BookmarkFolder(name: folder.name)
                    mapping[folder.id] = new.id
                    profile.bookmarkFolders = (profile.bookmarkFolders ?? []) + [new]
                }
                var known = Set(profile.favorites.map(\.address))
                for var bookmark in preview.bookmarks where known.insert(bookmark.address).inserted {
                    bookmark.id = UUID()
                    bookmark.folderID = bookmark.folderID.flatMap { mapping[$0] }
                    profile.favorites.append(bookmark)
                }
            }
        }
        if cookies {
            let jar = runtime(for: destination).dataStore.httpCookieStore
            for item in preview.cookies { if let cookie = item.cookie() { await jar.setCookie(cookie) } }
        }
        if newProfile { switchProfile(destination) }
        persist()
    }
}

import Foundation
import Security

struct ImportedPassword: Sendable, Identifiable {
    let origin: String
    let username: String
    let password: String
    let title: String
    let notes: String
    nonisolated var id: String { origin + "\n" + username }
}

struct PasswordImportReview: Sendable {
    var entries: [ImportedPassword]
    var skipped: Int
    var duplicates: Int
    var conflicting: Int
    var unsupportedCodes: Int
}

enum PasswordImportError: LocalizedError {
    case tooLarge, invalidEncoding, malformedCSV, missingColumns, tooManyRows
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a CSV smaller than 10 MB."
        case .invalidEncoding: "This file isn’t a UTF-8 CSV. Export it again using UTF-8."
        case .malformedCSV: "The CSV has an incomplete or incorrectly quoted row. Nothing was imported."
        case .missingColumns: "The CSV needs URL, Username and Password columns."
        case .tooManyRows: "Import up to 10,000 accounts at a time."
        }
    }
}

enum PasswordImport {
    nonisolated static let maximumBytes = 10 * 1024 * 1024
    nonisolated static let maximumRows = 10_000

    nonisolated static func origin(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4096,
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            var components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil, let host = components.host?.lowercased(),
            !host.isEmpty, !host.hasSuffix("."), !host.contains(where: { $0.isWhitespace }),
            components.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        components.scheme = "https"
        guard let url = components.url else { return nil }
        return BrowserAddress.origin(url)
    }

    nonisolated static func parse(_ data: Data) throws -> PasswordImportReview {
        guard data.count <= maximumBytes else { throw PasswordImportError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw PasswordImportError.invalidEncoding }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = try csv(text)
        guard let header = rows.first else { throw PasswordImportError.missingColumns }
        let aliases = [
            "website": "url", "websiteurl": "url", "loginuri": "url", "loginurl": "url", "uri": "url",
            "loginusername": "username", "user": "username", "email": "username", "loginpassword": "password",
            "name": "title", "extra": "notes",
        ]
        let names = header.map { value in
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().filter {
                $0.isLetter || $0.isNumber
            }
            return aliases[key] ?? key
        }
        guard Set(names).count == names.count, let url = names.firstIndex(of: "url"),
            let username = names.firstIndex(of: "username"), let password = names.firstIndex(of: "password")
        else { throw PasswordImportError.missingColumns }
        let title = names.firstIndex(of: "title")
        let notes = names.firstIndex(of: "notes")
        let code = names.firstIndex(of: "otpauth")
        var review = PasswordImportReview(entries: [], skipped: 0, duplicates: 0, conflicting: 0, unsupportedCodes: 0)
        var accounts: [String: ImportedPassword] = [:]
        var conflicts = Set<String>()
        for row in rows.dropFirst() {
            guard row.count == header.count, let site = origin(row[url]),
                validUsername(row[username]), validPassword(row[password]),
                notes.map({ row[$0].utf8.count <= 16_384 }) ?? true
            else {
                review.skipped += 1
                continue
            }
            if let code, !row[code].isEmpty { review.unsupportedCodes += 1 }
            let entry = ImportedPassword(
                origin: site, username: row[username], password: row[password],
                title: title.map { String(row[$0].prefix(200)) } ?? "", notes: notes.map { row[$0] } ?? "")
            if let previous = accounts[entry.id] {
                if previous.password == entry.password && previous.notes == entry.notes {
                    review.duplicates += 1
                } else {
                    conflicts.insert(entry.id)
                    review.conflicting += 1
                }
            } else {
                accounts[entry.id] = entry
            }
        }

        review.entries = accounts.values.filter { !conflicts.contains($0.id) }.sorted {
            ($0.origin, $0.username) < ($1.origin, $1.username)
        }
        review.skipped += conflicts.count
        return review
    }

    nonisolated static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    nonisolated static func validPassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\0")
    }

    nonisolated static func csv(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var start = true
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func finishField() throws {
            guard row.count < 64, field.utf8.count <= 65_536 else { throw PasswordImportError.malformedCSV }
            row.append(field)
            field = ""
            start = true
            closedQuote = false
        }
        func finishRow() throws {
            try finishField()
            if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
            row = []
            guard rows.count <= maximumRows + 1 else { throw PasswordImportError.tooManyRows }
        }
        while index < scalars.count {
            let c = scalars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.unicodeScalars.append(c)
                        index += 1
                    } else {
                        quoted = false
                        closedQuote = true
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "," {
                try finishField()
            } else if c == "\r" || c == "\n" {
                try finishRow()
                if c == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n" { index += 1 }
            } else if c == "\"" && start {
                quoted = true
                start = false
            } else {
                guard !closedQuote, c != "\"" else { throw PasswordImportError.malformedCSV }
                field.unicodeScalars.append(c)
                start = false
            }
            guard field.utf8.count <= 65_536 else { throw PasswordImportError.malformedCSV }
            index += 1
        }
        guard !quoted else { throw PasswordImportError.malformedCSV }
        if !row.isEmpty || !field.isEmpty || closedQuote { try finishRow() }
        return rows
    }
}

enum PasswordGenerator {
    nonisolated static func generate(length: Int = 24, symbols: Bool = true) throws -> String {
        guard (16...64).contains(length) else { throw CocoaError(.coderInvalidValue) }
        let groups =
            [Array("abcdefghijkmnopqrstuvwxyz"), Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), Array("23456789")]
            + (symbols ? [Array("!#$%&()*+,-.:=?@[]^_{|}~")] : [])
        let alphabet = groups.flatMap { $0 }
        func random(_ upper: Int) throws -> Int {
            let limit = 256 - 256 % upper
            while true {
                var byte: UInt8 = 0
                guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                    throw CocoaError(.coderInvalidValue)
                }
                if Int(byte) < limit { return Int(byte) % upper }
            }
        }
        var characters = try groups.map { $0[try random($0.count)] }
        while characters.count < length { characters.append(alphabet[try random(alphabet.count)]) }
        for i in stride(from: characters.count - 1, through: 1, by: -1) { characters.swapAt(i, try random(i + 1)) }
        return String(characters)
    }
}

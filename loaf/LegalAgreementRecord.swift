import CryptoKit
import Foundation

struct LegalDocument: Identifiable, Sendable {
    let id: String
    let title: String
    let version: String
    let body: String
    var digest: String { SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct LegalAgreementRecord: Codable, Sendable {
    let schema: Int
    let acceptedAt: Date
    let appVersion: String
    let appBuild: String
    let bundleIdentifier: String
    let documents: [AcceptedDocument]
    struct AcceptedDocument: Codable, Sendable {
        let id: String
        let version: String
        let sha256: String
        let text: String
    }
    init(documents: [LegalDocument], appVersion: String, appBuild: String, bundleIdentifier: String, now: Date = Date())
    {
        schema = 1
        acceptedAt = now
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.documents = documents.map {
            AcceptedDocument(id: $0.id, version: $0.version, sha256: $0.digest, text: $0.body)
        }
    }
    func matches(_ current: [LegalDocument], bundleIdentifier: String) -> Bool {
        guard schema == 1, self.bundleIdentifier == bundleIdentifier, !current.isEmpty,
            Set(current.map(\.id)).count == current.count,
            documents.count == current.count, Set(documents.map(\.id)).count == documents.count
        else { return false }
        return current.allSatisfy { doc in
            documents.contains {
                $0.id == doc.id && $0.version == doc.version && $0.sha256 == doc.digest && $0.text == doc.body
            }
        }
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(from url: URL) -> LegalAgreementRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: Data(contentsOf: url))
    }
}

import AppKit
import Combine
import CryptoKit
import Security

nonisolated struct SavedChat: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    var updatedAt: Date
    var turns: [ChatTurn]
    var title: String { String((turns.first?.query ?? "new chat").prefix(80)) }
}

@MainActor final class ChatArchive: ObservableObject {
    @Published private(set) var chats: [SavedChat] = []
    @Published private(set) var error: String?
    private var restoreFailed = false
    private let file: URL
    private let localAccount: String
    private let keychainService: String
    private var syncPayloads: [UUID: (date: Date, data: Data)] = [:]
    init(directory: URL, keychainService: String? = nil) {
        self.keychainService =
            keychainService ?? (Bundle.main.bundleIdentifier ?? BrowserBrand.bundleIdentifier) + ".chat-vault.v1"
        file = directory.appendingPathComponent("chats-v1.encrypted")
        localAccount = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 64_000_000 else { throw CocoaError(.fileReadTooLarge) }
            chats = try JSONDecoder().decode([SavedChat].self, from: open(data, synced: false))
        } catch {
            restoreFailed = true
            self.error = "saved chats couldn’t be unlocked. the encrypted file has been retained."
        }
    }
    func save(id: UUID, profileID: UUID, turns: [ChatTurn]) throws {
        guard !turns.isEmpty else { return }
        var chat = SavedChat(id: id, profileID: profileID, updatedAt: .now, turns: Array(turns.suffix(100)))

        for index in chat.turns.indices {
            chat.turns[index].captureTarget = nil
            if !chat.turns[index].complete && chat.turns[index].error == nil {
                chat.turns[index].error = "this answer was interrupted."
            }
        }
        var next = chats.filter { $0.id != id }
        next.append(chat)
        try persist(next)
    }
    func delete(_ id: UUID) throws { try persist(chats.filter { $0.id != id }) }
    func deleteProfile(_ id: UUID) throws { try persist(chats.filter { $0.profileID != id }) }
    private func persist(_ next: [SavedChat]) throws {
        do {
            guard !restoreFailed else { throw CocoaError(.fileReadNoPermission) }
            let data = try JSONEncoder().encode(next)
            guard data.count <= 64_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try seal(data, synced: false).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            chats = next.sorted { $0.updatedAt > $1.updatedAt }
            error = nil
        } catch {
            self.error = "chat couldn’t be saved: " + error.localizedDescription
            throw error
        }
    }
    func syncValues(profileID: UUID) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for chat in chats where chat.profileID == profileID {
            if let cached = syncPayloads[chat.id], cached.date == chat.updatedAt {
                result[chat.id.uuidString] = cached.data
                continue
            }

            var portable = chat
            for index in portable.turns.indices {
                portable.turns[index].images = []
                portable.turns[index].capture = nil
            }
            let compressed = try (JSONEncoder().encode(portable) as NSData).compressed(using: .zlib) as Data
            let encrypted = try seal(compressed, synced: true)
            guard encrypted.count < 600_000 else { throw ICloudSyncFailure.tooLarge }
            syncPayloads[chat.id] = (chat.updatedAt, encrypted)
            result[chat.id.uuidString] = encrypted
        }
        return result
    }
    func merge(profileID: UUID, document: SyncDocument) throws {
        var next = chats
        for (identifier, field) in document.fields {
            guard let id = UUID(uuidString: identifier) else { throw ICloudSyncFailure.invalidData }
            guard let data = field.value else {
                next.removeAll { $0.id == id && $0.profileID == profileID }
                continue
            }
            guard data.count <= 600_000 else { throw ICloudSyncFailure.tooLarge }
            let decrypted = try open(data, synced: true)
            let plain = try (decrypted as NSData).decompressed(using: .zlib) as Data
            guard plain.count <= 8_000_000 else { throw ICloudSyncFailure.tooLarge }
            var chat = try JSONDecoder().decode(SavedChat.self, from: plain)
            guard chat.id == id, chat.profileID == profileID, chat.turns.count <= 100 else {
                throw ICloudSyncFailure.invalidData
            }
            if let local = next.first(where: { $0.id == id }), local.updatedAt >= chat.updatedAt { continue }
            if let local = next.first(where: { $0.id == id }) {
                for index in chat.turns.indices {
                    if let previous = local.turns.first(where: { $0.id == chat.turns[index].id }) {
                        chat.turns[index].images = previous.images
                        chat.turns[index].capture = previous.capture
                    }
                }
            }
            next.removeAll { $0.id == id }
            next.append(chat)
        }
        if try JSONEncoder().encode(next) != JSONEncoder().encode(chats) { try persist(next) }
    }
    private func key(synced: Bool, create: Bool = true) throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: synced ? "icloud" : localAccount,
            kSecAttrSynchronizable as String: synced,
        ]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound && create else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let key = SymmetricKey(size: .bits256)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] =
            synced ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecDuplicateItem { return try self.key(synced: synced) }
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
    private func seal(_ data: Data, synced: Bool) throws -> Data {
        try AES.GCM.seal(data, using: key(synced: synced)).combined!
    }
    private func open(_ data: Data, synced: Bool) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(synced: synced, create: false))
    }
}

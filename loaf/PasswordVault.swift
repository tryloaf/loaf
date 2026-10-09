import AppKit
import Foundation
import LocalAuthentication
import Security
import WebKit

struct PasswordFillOffer: Identifiable {
    let id = UUID()
    let tabID: UUID
    let navigationID: UUID
    let origin: String
    let usernames: [String]
    var targetID: String? = nil
    var anchor: PasswordFieldAnchor? = nil
}

struct PasswordOffer: Identifiable {
    let id = UUID()
    let profileID: UUID
    let origin: String
    let username: String
    var password: String
    var title = ""
    var notes = ""
}

enum PasswordVault {
    private static func query(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BrowserBrand.passwordServicePrefix + profileID.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
    static func save(_ offer: PasswordOffer, replaceExisting: Bool = true) throws {
        var q = query(profileID: offer.profileID)
        q[kSecAttrAccount as String] = offer.origin + "\n" + offer.username
        guard PasswordImport.origin(offer.origin) == offer.origin, PasswordImport.validUsername(offer.username),
            PasswordImport.validPassword(offer.password), offer.notes.utf8.count <= 16_384
        else { throw CocoaError(.coderInvalidValue) }
        let data = try encode(password: offer.password, notes: offer.notes)
        let label = "loaf · " + (offer.title.isEmpty ? offer.origin : String(offer.title.prefix(200)))
        let status =
            replaceExisting
            ? SecItemUpdate(
                q as CFDictionary,
                [kSecValueData as String: data, kSecAttrLabel as String: label, kSecAttrGeneric as String: envelope]
                    as CFDictionary) : errSecItemNotFound
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrGeneric as String] = envelope
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrLabel as String] = label

            let result = SecItemAdd(q as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        changed(profileID: offer.profileID)
    }
    static func usernames(profileID: UUID, origin: String) -> [String] {
        var q = query(profileID: profileID)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]]
        else { return [] }
        let prefix = origin + "\n"
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.map {
            String($0.dropFirst(prefix.count))
        }.sorted()
    }
    private struct Secret: Codable {
        let password: String
        let notes: String
    }
    private static let envelope = Data("LOAF-PASSWORD-V1\n".utf8)
    private static func encode(password: String, notes: String) throws -> Data {
        try JSONEncoder().encode(Secret(password: password, notes: notes))
    }
    static func readSecret(profileID: UUID, origin: String, username: String) throws -> (
        password: String, notes: String
    ) {
        var q = query(profileID: profileID)
        q[kSecAttrAccount as String] = origin + "\n" + username
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any],
            let data = attributes[kSecValueData as String] as? Data
        else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }

        if attributes[kSecAttrGeneric as String] as? Data == envelope {
            let value = try JSONDecoder().decode(Secret.self, from: data)
            return (value.password, value.notes)
        }

        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return (value, "")
    }
    static func read(profileID: UUID, origin: String, username: String) throws -> String {
        try readSecret(profileID: profileID, origin: origin, username: username).password
    }
    static func contains(profileID: UUID, origin: String, username: String) -> Bool {
        var q = query(profileID: profileID)
        q[kSecAttrAccount as String] = origin + "\n" + username
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static let didChange = Notification.Name("loaf.passwords.changed")
    static func changed(profileID: UUID) { NotificationCenter.default.post(name: didChange, object: profileID) }

    @MainActor static func fill(tab: BrowserTab) {
        guard tab.store?.profileFor(tab.profileID).privateMode == false, let url = tab.webView.url,
            let origin = BrowserAddress.origin(url), tab.webView.hasOnlySecureContent
        else {
            tab.store?.error = "Passwords can only be filled into a secure HTTPS page."
            return
        }
        let users = usernames(profileID: tab.profileID, origin: origin)
        guard !users.isEmpty else {
            tab.store?.error = "No loaf passwords saved for \(origin)."
            return
        }
        let token = tab.navigationID
        Task {
            let presentation =
                try? await tab.webView.callAsyncJavaScript(
                    PageScripts.passwordPresentation, arguments: [:], in: nil, contentWorld: PageScripts.passwordWorld)
                as? [String: Any]
            guard let presentation, let target = presentation["targetID"] as? String,
                let anchor = PasswordFieldAnchor(presentation["anchor"]),
                canFill(tab: tab, origin: origin, navigationID: token)
            else {
                if canFill(tab: tab, origin: origin, navigationID: token) {
                    tab.store?.error = "Focus a login field, then try filling again."
                }
                return
            }
            tab.passwordSuggestions.anchor = anchor
            tab.passwordSuggestions.query = presentation["query"] as? String ?? ""
            tab.store?.passwordFillOffer = PasswordFillOffer(
                tabID: tab.id, navigationID: token, origin: origin, usernames: users, targetID: target, anchor: anchor)
        }
    }
    @MainActor static func canFill(tab: BrowserTab, origin: String, navigationID: UUID) -> Bool {
        guard let owner = tab.store, let view = tab.existingWebView else { return false }
        return !tab.isDisposed && tab.page == .web && tab.readerDocument == nil
            && !owner.profileFor(tab.profileID).privateMode && owner.selectedProfileID == tab.profileID
            && owner.selectedTab?.id == tab.id && tab.navigationID == navigationID && view.hasOnlySecureContent
            && view.url.flatMap(BrowserAddress.origin) == origin
    }
    @MainActor static func fill(
        tab: BrowserTab, username: String, origin: String, navigationID: UUID, targetID: String? = nil
    ) {
        guard NSApp.isActive, let targetID, targetID.count == 32,
            canFill(tab: tab, origin: origin, navigationID: navigationID), let owner = tab.store,
            owner.nativeWindow?.isKeyWindow == true
        else { return }
        guard let request = owner.beginPasswordFillAuthentication() else { return }
        let generation = request.generation
        Task {
            do {
                let approved: Bool
                if tab.hasPasswordApproval(origin: origin, username: username) {
                    request.context.invalidate()
                    owner.passwordAuthentication = nil
                    approved = true
                } else {
                    approved = try await authenticateFill(
                        owner: owner, context: request.context, generation: generation)
                }
                guard approved,
                    generation == owner.passwordFillGeneration, NSApp.isActive, owner.nativeWindow?.isKeyWindow == true,
                    canFill(tab: tab, origin: origin, navigationID: navigationID)
                else { return }
                let password = try read(profileID: tab.profileID, origin: origin, username: username)

                guard generation == owner.passwordFillGeneration,
                    canFill(tab: tab, origin: origin, navigationID: navigationID)
                else { return }
                let result = try await tab.webView.callAsyncJavaScript(
                    PageScripts.passwordFill,
                    arguments: [
                        "origin": origin, "username": username, "password": password, "allowPasswordOnly": true,
                        "targetID": targetID,
                    ], in: nil, contentWorld: PageScripts.passwordWorld)
                guard generation == owner.passwordFillGeneration,
                    canFill(tab: tab, origin: origin, navigationID: navigationID)
                else { return }
                if result as? Bool == true {
                    tab.pendingLoginUsername = .init(origin: origin, username: username, date: Date())
                    tab.approvedPasswordFill = (origin, username, Date())
                } else {
                    owner.error = "the login form changed. focus it again to fill."
                }
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            } catch {
                if generation == owner.passwordFillGeneration,
                    canFill(tab: tab, origin: origin, navigationID: navigationID)
                {
                    owner.error = "couldn’t fill this password. try again."
                }
            }
        }
    }

    @MainActor static func authenticateFill(
        owner: BrowserStore, context: LAContext, generation: UUID,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        windowIsKey: (@MainActor () -> Bool)? = nil,
        evaluate: (@MainActor () async throws -> Bool)? = nil
    ) async throws -> Bool {
        defer {
            context.invalidate()
            if owner.passwordAuthentication === context { owner.passwordAuthentication = nil }
        }
        func current() -> Bool {
            generation == owner.passwordFillGeneration && owner.passwordAuthentication === context
        }
        func focused() -> Bool {
            applicationIsActive() && (windowIsKey?() ?? (owner.nativeWindow?.isKeyWindow == true))
        }
        guard current() else { return false }
        let accepted: Bool
        if let evaluate {
            accepted = try await evaluate()
        } else {
            accepted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "fill your saved password")
        }
        guard accepted, current() else { return false }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        await Task.yield()
        while current(), !focused(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return current() && focused()
    }
}

struct PasswordEntry: Identifiable {
    let account: String
    let origin: String
    let username: String
    var title: String = ""
    var id: String { account }
    var displayTitle: String { title.isEmpty ? URL(string: origin)?.host ?? origin : title }
    var searchText: String { title + " " + origin + " " + username }
}
extension PasswordVault {
    static func entries(profileID: UUID) -> [PasswordEntry] {
        (try? list(profileID: profileID)) ?? []
    }
    static func list(profileID: UUID) throws -> [PasswordEntry] {
        var q = query(profileID: profileID)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return items.compactMap {
            guard let account = $0[kSecAttrAccount as String] as? String, let split = account.firstIndex(of: "\n")
            else { return nil }
            let origin = String(account[..<split])
            let username = String(account[account.index(after: split)...])
            guard PasswordImport.origin(origin) == origin, PasswordImport.validUsername(username) else { return nil }
            let label = $0[kSecAttrLabel as String] as? String ?? ""
            let title = label.hasPrefix("loaf · ") ? String(label.dropFirst(7)) : ""
            return PasswordEntry(
                account: account, origin: origin, username: username, title: title == origin ? "" : title)
        }.sorted { $0.origin < $1.origin }
    }
    static func delete(_ entry: PasswordEntry, profileID: UUID) throws {
        var q = query(profileID: profileID)
        q[kSecAttrAccount as String] = entry.account
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        changed(profileID: profileID)
    }
    static func deleteAll(profileID: UUID) throws {
        let status = SecItemDelete(query(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        changed(profileID: profileID)
    }
}

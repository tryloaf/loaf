import Combine
import Foundation
import Security
import SwiftUI

@MainActor final class ClaudeAccount: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var models: [ChatModel] = []
    @Published private(set) var checkingModels = false
    @Published private(set) var selectedModelID: String?
    @Published var error: String?
    private var key: String?
    private let persistCredentials: Bool
    private let defaults: UserDefaults
    private var catalogTask: Task<Void, Never>?
    private var generation = UUID()
    let session: URLSession
    var modelName: String { models.first { $0.id == selectedModelID }?.name ?? "Claude" }
    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? BrowserBrand.bundleIdentifier) + ".claude",
            kSecAttrAccount as String: "api-key",
        ]
    }
    init(persistCredentials: Bool = true, session: URLSession? = nil, defaults: UserDefaults = .standard) {
        self.persistCredentials = persistCredentials
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 240
        self.session =
            session ?? URLSession(configuration: configuration, delegate: ChatGPTNetworkDelegate(), delegateQueue: nil)
        selectedModelID = defaults.string(forKey: "loaf.claude.model")
        if persistCredentials {
            var query = keychainQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecSuccess, let data = value as? Data {
                key = String(data: data, encoding: .utf8)
            } else if status != errSecItemNotFound {
                error = "Loaf couldn’t read the Claude API key from Keychain."
            }
        }
        connected = key?.isEmpty == false
    }
    func connect(apiKey: String) {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains(where: { $0.isWhitespace }) else {
            error = "enter a valid Claude API key."
            return
        }
        if persistCredentials {
            let attributes: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                error = "Loaf couldn’t save the Claude API key in Keychain."
                return
            }
        }
        generation = UUID()
        catalogTask?.cancel()
        catalogTask = nil
        checkingModels = false
        key = value
        connected = true
        models = []
        error = nil
        refreshCatalog()
    }
    func disconnect() {
        if persistCredentials {
            let status = SecItemDelete(keychainQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                error = "Loaf couldn’t remove the Claude API key from Keychain."
                return
            }
        }
        generation = UUID()
        catalogTask?.cancel()
        catalogTask = nil
        checkingModels = false
        key = nil
        connected = false
        models = []
        error = nil
    }
    func selectModel(_ id: String) {
        guard models.contains(where: { $0.id == id }) else { return }
        selectedModelID = id
        defaults.set(id, forKey: "loaf.claude.model")
    }
    func request(path: String) throws -> URLRequest {
        guard connected, let key else {
            throw ChatGPTFailure.message("connect Claude with an API key in intelligence settings.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/" + path)!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func requireModel(_ id: String? = nil) async throws -> ChatModel {
        if models.isEmpty {
            refreshCatalog()
            if let catalogTask { await catalogTask.value }
        }
        guard connected else {
            throw ChatGPTFailure.message("connect Claude with an API key in intelligence settings.")
        }
        guard let model = models.first(where: { $0.id == (id ?? selectedModelID) }) else {
            throw ChatGPTFailure.message(error ?? "choose an available Claude model in intelligence settings.")
        }
        return model
    }
    func refreshCatalog() {
        guard connected, !checkingModels else { return }
        generation = UUID()
        let current = generation
        checkingModels = true
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    checkingModels = false
                    catalogTask = nil
                }
            }
            do {
                var values: [[String: Any]] = []
                var cursor: String?
                for _ in 0..<5 {
                    var request = try request(path: "models")
                    var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    components.queryItems = [.init(name: "limit", value: "100")]
                    if let cursor { components.queryItems?.append(.init(name: "after_id", value: cursor)) }
                    request.url = components.url
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    guard let http = response as? HTTPURLResponse else { throw ChatGPTFailure.interrupted }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ClaudeAnswerProvider.failure(status: http.statusCode)
                    }
                    guard data.count <= 1_000_000,
                        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let page = object["data"] as? [[String: Any]]
                    else { throw ChatGPTFailure.interrupted }
                    values += page
                    guard object["has_more"] as? Bool == true else { break }
                    guard let next = object["last_id"] as? String, !next.isEmpty, next.count <= 200, next != cursor
                    else { break }
                    cursor = next
                }
                models = ChatModel.catalog(values)
                if !models.contains(where: { $0.id == self.selectedModelID }),
                    let first = models.first(where: { $0.id.contains("haiku") }) ?? models.first(where: {
                        $0.id.contains("sonnet")
                    }) ?? models.first
                {
                    selectModel(first.id)
                }
                error = models.isEmpty ? "no Claude models are available for this key." : nil
            } catch is CancellationError {} catch {
                if generation == current { self.error = friendly(error) }
            }
        }
    }
    func friendly(_ error: Error) -> String {
        (error as? ChatGPTFailure)?.localizedDescription
            ?? ChatGPTFailure.networkMessage(error, service: "Claude")
            ?? "Claude couldn’t finish this request. try again."
    }
}

struct ClaudeConnectionView: View {
    @ObservedObject var account: ClaudeAccount
    @State private var apiKey = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.connected {
                HStack {
                    Text("Claude connected")
                    Spacer()
                    Button("disconnect") { account.disconnect() }
                }
                Picker(
                    "model",
                    selection: Binding<String?>(
                        get: { account.selectedModelID }, set: { if let id = $0 { account.selectModel(id) } })
                ) {
                    if account.models.isEmpty {
                        Text(account.checkingModels ? "loading models…" : "choose a model").tag(account.selectedModelID)
                    }
                    ForEach(account.models) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(account.models.isEmpty)
                SettingsActionButton("refresh models", busy: account.checkingModels) { account.refreshCatalog() }
            } else {
                SecureField("Claude API key", text: $apiKey).textFieldStyle(.roundedBorder)
                HStack {
                    Button("connect Claude") {
                        account.connect(apiKey: apiKey)
                        apiKey = ""
                    }.disabled(apiKey.isEmpty)
                    Link("get an API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                }
            }
            Text(
                "uses Anthropic API billing. your key stays in this Mac’s Keychain. questions and approved page context are sent to Anthropic when submitted."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error = account.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { if account.models.isEmpty { account.refreshCatalog() } }
    }
}

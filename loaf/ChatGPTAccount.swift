import AppKit
import Combine
import Network
import Security

nonisolated final class ChatGPTNetworkDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

@MainActor final class ChatGPTAccount: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var disconnecting = false
    @Published private(set) var lunaModel: String?
    var lunaAvailable: Bool { lunaModel != nil }
    var lunaName: String { ChatGPTProtocol.modelName(lunaModel) }
    @Published private(set) var checkingModels = false
    @Published var error: String?
    @Published var showPlanWelcome = false
    var useExternalWebSearch = false
    private var registration: ChatGPTRegistration?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<ChatGPTRegistration, Error>?
    private var catalogTask: Task<Void, Never>?
    private var generation = UUID()
    let session: URLSession
    private let keychainService: String
    private let defaults: UserDefaults
    private let persistCredentials: Bool
    private var loopback: ChatGPTLoopback?

    init(
        persistCredentials: Bool = true, session: URLSession? = nil, defaults: UserDefaults = .standard,
        registration: ChatGPTRegistration? = nil
    ) {
        self.persistCredentials = persistCredentials
        self.defaults = defaults
        self.registration = registration
        keychainService = (Bundle.main.bundleIdentifier ?? BrowserBrand.bundleIdentifier) + ".chatgpt"
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: config, delegate: ChatGPTNetworkDelegate(), delegateQueue: nil)
        }
        if persistCredentials && registration == nil {
            do { self.registration = try readRegistration() } catch {
                self.error = "Loaf couldn’t read its ChatGPT connection from Keychain. try connecting again."
            }
        }
        publishAccount()
    }
    private func publishAccount() {
        email = registration?.email
        connected = registration?.credentials?.scopes.contains(ChatGPTProtocol.planScope) == true
    }
    func connect(openAuthorization: ((URL) -> Bool)? = nil) {
        guard !connecting, !disconnecting else { return }
        useExternalWebSearch = false
        catalogTask?.cancel()
        lunaModel = nil
        generation = UUID()
        let current = generation
        error = nil
        connecting = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    connecting = false
                    connectionTask = nil
                    loopback = nil
                }
            }
            do {
                let attempt = try ChatGPTSignInAttempt()
                let callback = ChatGPTLoopback(attempt: attempt, registration: registration)
                loopback = callback
                let old = registration
                let authorization = try await callback.authorize(hostID: hostID(), open: openAuthorization)
                try Task.checkCancellation()
                guard generation == current else { return }

                let pending = ChatGPTRegistration(
                    clientID: authorization.clientID, subject: old?.subject, email: old?.email,
                    credentials: old?.credentials)
                try saveRegistration(pending)
                registration = pending
                let tokens = try await tokenRequest([
                    "grant_type": "authorization_code", "client_id": authorization.clientID,
                    "code": authorization.code, "code_verifier": attempt.verifier,
                    "redirect_uri": callback.redirectURL!.absoluteString, "resource": ChatGPTProtocol.resource,
                ])
                guard let idToken = tokens["id_token"] as? String else { throw ChatGPTFailure.invalidIdentity }
                let keys = try await data(
                    URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/jwks.json")!))
                let identity = try ChatGPTIdentityVerifier.verify(
                    idToken, jwks: keys, clientID: authorization.clientID, nonce: attempt.nonce, subject: old?.subject)
                let credentials = try credentials(tokens, retaining: nil, idToken: idToken)
                guard credentials.scopes.contains(ChatGPTProtocol.planScope),
                    credentials.scopes.contains("resource.invoke")
                else {
                    throw ChatGPTFailure.message(
                        "ChatGPT plan usage wasn’t enabled. connect again and allow Loaf to use your plan.")
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                let record = ChatGPTRegistration(
                    clientID: authorization.clientID, subject: identity.subject, email: identity.email,
                    credentials: credentials)
                try saveRegistration(record)
                registration = record
                publishAccount()
                if !defaults.bool(forKey: "loaf.chatgpt.planWelcome") { showPlanWelcome = true }
                await checkModels()
            } catch is CancellationError {} catch {
                if generation == current {
                    self.error = friendly(error)
                    publishAccount()
                }
            }
        }
    }
    func dismissWelcome() {
        showPlanWelcome = false
        defaults.set(true, forKey: "loaf.chatgpt.planWelcome")
    }
    func cancelConnection() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        loopback?.cancel()
        loopback = nil
        connecting = false
    }
    func disconnect() {
        guard !disconnecting else { return }
        let inFlightRefresh = refreshTask
        cancelConnection()
        catalogTask?.cancel()
        disconnecting = true
        error = nil
        let current = generation
        Task {

            let refreshed = try? await inFlightRefresh?.value
            refreshTask = nil
            let old = refreshed ?? registration
            var revoked = true
            if let token = old?.credentials?.refreshToken, let clientID = old?.clientID {
                do {
                    let discovery = try await data(
                        URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/openid-configuration")!))
                    let object = try JSONSerialization.jsonObject(with: discovery) as? [String: Any]
                    guard let address = object?["revocation_endpoint"] as? String,
                        let endpoint = URL(string: address), endpoint.scheme == "https",
                        endpoint.host == "auth.openai.com"
                    else { throw ChatGPTFailure.invalidIdentity }
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = ChatGPTProtocol.form([
                        "token": token, "token_type_hint": "refresh_token", "client_id": clientID,
                    ])
                    request.timeoutInterval = 15
                    _ = try await data(request)
                } catch { revoked = false }
            }
            guard generation == current else { return }
            do {
                if var record = old {
                    record.credentials = nil
                    try saveRegistration(record)
                    registration = record
                }
                connected = false
                lunaModel = nil
                publishAccount()
                if !revoked {
                    error =
                        "signed out on this Mac. remote revocation wasn’t confirmed; disconnect Loaf in ChatGPT manage usage."
                }
            } catch {
                self.error = "Loaf couldn’t clear its ChatGPT credentials from Keychain. try disconnecting again."
            }
            disconnecting = false
        }
    }
    func refreshCatalog() {
        guard connected, !checkingModels, catalogTask == nil, !disconnecting else { return }
        catalogTask = Task {
            await checkModels()
            catalogTask = nil
        }
    }
    func requireLuna() async throws -> String {
        if let catalogTask { await catalogTask.value } else if lunaModel == nil { await checkModels() }
        guard connected, !disconnecting else { throw ChatGPTFailure.signIn }
        guard let lunaModel else {
            throw ChatGPTFailure.message(error ?? ChatGPTFailure.unavailable.localizedDescription)
        }
        return lunaModel
    }
    private func checkModels() async {
        checkingModels = true
        defer { checkingModels = false }
        let current = generation
        do {
            var request = URLRequest(url: URL(string: ChatGPTProtocol.resource + "/models")!)
            request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
            let body = try await data(request)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let models = object?["models"] as? [[String: Any]] ?? object?["data"] as? [[String: Any]] ?? []
            try Task.checkCancellation()
            guard generation == current else { return }
            lunaModel = ChatGPTProtocol.availableLuna(in: models)
            error = lunaAvailable ? nil : ChatGPTFailure.unavailable.localizedDescription
        } catch is CancellationError {} catch {
            if generation == current {
                lunaModel = nil
                self.error = friendly(error)
            }
        }
    }
    func accessToken() async throws -> String {
        guard !disconnecting, let saved = registration, let credentials = saved.credentials,
            credentials.scopes.contains(ChatGPTProtocol.planScope)
        else { throw ChatGPTFailure.signIn }
        if credentials.expiresAt.timeIntervalSinceNow > 90 { return credentials.accessToken }
        if let refreshTask { return try await refreshTask.value.credentials!.accessToken }
        guard let refreshToken = credentials.refreshToken else { throw ChatGPTFailure.signIn }
        let current = generation
        let task = Task<ChatGPTRegistration, Error> {
            let tokens = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refreshToken,
                "resource": ChatGPTProtocol.resource,
            ])
            var record = saved
            if let token = tokens["id_token"] as? String {
                let keys = try await data(
                    URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/jwks.json")!))
                let identity = try ChatGPTIdentityVerifier.verify(
                    token, jwks: keys, clientID: saved.clientID, nonce: nil, subject: saved.subject)
                record.email = identity.email ?? saved.email
            }
            record.credentials = try self.credentials(
                tokens, retaining: credentials, idToken: tokens["id_token"] as? String ?? credentials.idToken)
            guard record.credentials!.scopes.contains(ChatGPTProtocol.planScope) else { throw ChatGPTFailure.signIn }
            try Task.checkCancellation()

            if generation != current {
                if disconnecting { return record }
                throw CancellationError()
            }
            try saveRegistration(record)
            registration = record
            publishAccount()
            return record
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.credentials!.accessToken
    }
    private func credentials(_ tokens: [String: Any], retaining old: ChatGPTCredentials?, idToken: String) throws
        -> ChatGPTCredentials
    {
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
            let expires = tokens["expires_in"] as? Double, expires > 0,
            (tokens["token_type"] as? String)?.lowercased() == "bearer"
        else { throw ChatGPTFailure.invalidIdentity }
        let scopes = (tokens["scope"] as? String)?.split(separator: " ").map(String.init) ?? old?.scopes ?? []
        return ChatGPTCredentials(
            accessToken: access, refreshToken: tokens["refresh_token"] as? String ?? old?.refreshToken,
            idToken: idToken, expiresAt: Date().addingTimeInterval(expires), scopes: scopes)
    }
    private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.httpBody = ChatGPTProtocol.form(values)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let result = try JSONSerialization.jsonObject(with: await data(request)) as? [String: Any] else {
            throw ChatGPTFailure.invalidIdentity
        }
        return result
    }
    func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTFailure.interrupted }
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["code"] as? String
            throw ChatGPTFailure.service(
                status: response.statusCode, code: code,
                param: (object?["error"] as? [String: Any])?["param"] as? String,
                requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        guard data.count < 2_000_000 else { throw ChatGPTFailure.interrupted }
        return data
    }
    func friendly(_ error: Error) -> String {
        (error as? ChatGPTFailure)?.localizedDescription
            ?? "couldn’t reach ChatGPT. check your connection and try again."
    }
    private func hostID() -> String {
        if let value = defaults.string(forKey: "loaf.chatgpt.hostID"), value.hasPrefix("urn:uuid:") { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: "loaf.chatgpt.hostID")
        return value
    }
    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "registration", kSecAttrSynchronizable as String: false,
        ]
    }
    private func readRegistration() throws -> ChatGPTRegistration? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTFailure.invalidIdentity }
        return try JSONDecoder().decode(ChatGPTRegistration.self, from: data)
    }
    private func saveRegistration(_ registration: ChatGPTRegistration) throws {
        guard persistCredentials else { return }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(registration)]
        let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query.merge(attributes) { _, value in value }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ChatGPTFailure.invalidIdentity }
        } else if status != errSecSuccess {
            throw ChatGPTFailure.invalidIdentity
        }
    }
}

@MainActor final class ChatGPTLoopback {
    let attempt: ChatGPTSignInAttempt
    let registration: ChatGPTRegistration?
    private(set) var redirectURL: URL?
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var result: CheckedContinuation<ChatGPTAuthorization, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    init(attempt: ChatGPTSignInAttempt, registration: ChatGPTRegistration?) {
        self.attempt = attempt
        self.registration = registration
    }
    func authorize(hostID: String, open: ((URL) -> Bool)? = nil) async throws -> ChatGPTAuthorization {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port, let continuation = self.ready {
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                            self.redirectURL = url
                            self.ready = nil
                            continuation.resume(returning: url)
                        }
                    case .failed:
                        self.cancel(
                            ChatGPTFailure.message("Loaf couldn’t start its local sign-in callback. please try again."))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.cancel(ChatGPTFailure.message("ChatGPT sign-in timed out. please try again."))
            }
            let redirect = try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
            }
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                result = continuation
                let url = ChatGPTProtocol.authorizationURL(
                    attempt: attempt, redirect: redirect, hostID: hostID, registration: registration)
                if !(open?(url) ?? NSWorkspace.shared.open(url)) {
                    cancel(ChatGPTFailure.message("the sign-in page couldn’t open. please try again."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }
    func cancel(_ error: Error = CancellationError()) {
        let starting = ready
        ready = nil
        let pending = result
        result = nil
        stop()
        starting?.resume(throwing: error)
        pending?.resume(throwing: error)
    }
    private func stop() {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 4, result != nil else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            if let connection { connection.cancel() }
            self?.connections.removeValue(forKey: id)
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                buffer.append(chunk ?? Data())
                guard buffer.count <= 16_384, error == nil else {
                    connection.cancel()
                    self.connections.removeValue(forKey: id)
                    return
                }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete {
                        connection.cancel()
                        self.connections.removeValue(forKey: id)
                    } else {
                        self.receive(connection, id: id, buffer: buffer)
                    }
                    return
                }
                let words = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard words.count == 3, words[0] == "GET", words[2] == "HTTP/1.1", let port = self.redirectURL?.port,
                    request.components(separatedBy: "\r\n").contains(where: {
                        $0.lowercased() == "host: 127.0.0.1:\(port)"
                    })
                else {
                    self.respond(connection, id: id, status: 400, valid: false)
                    return
                }
                let target = String(words[1])

                guard let components = URLComponents(string: "http://127.0.0.1" + target),
                    components.path == "/auth/callback",
                    components.queryItems?.filter({ $0.name == "state" }).map(\.value) == [self.attempt.state]
                else {
                    self.respond(connection, id: id, status: 400, valid: false)
                    return
                }
                do {
                    let authorization = try ChatGPTProtocol.callback(
                        target, attempt: self.attempt, clientID: self.registration?.clientID)
                    let pending = self.result
                    self.result = nil
                    self.respond(connection, id: id, status: 200, valid: true) { [weak self] in
                        self?.stop()
                        pending?.resume(returning: authorization)
                    }
                } catch {
                    let pending = self.result
                    self.result = nil
                    self.respond(connection, id: id, status: 400, valid: false) { [weak self] in
                        self?.stop()
                        pending?.resume(throwing: error)
                    }
                }
            }
        }
    }
    private func respond(
        _ connection: NWConnection, id: UUID, status: Int, valid: Bool, completion: (() -> Void)? = nil
    ) {
        let message =
            valid
            ? "return to Loaf to finish connecting your ChatGPT account."
            : "this sign-in callback couldn’t be accepted. return to Loaf and try again."
        let html =
            "<!doctype html><meta name=viewport content='width=device-width'><title>loaf</title><body style='font:16px system-ui;padding:48px;max-width:480px;margin:auto'><h1 style='font-size:22px'>loaf</h1><p>\(message)</p>"
        let body = Data(html.utf8)
        let header =
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + body,
            completion: .contentProcessed { [weak self] _ in
                MainActor.assumeIsolated {
                    connection.cancel()
                    self?.connections.removeValue(forKey: id)
                    completion?()
                }
            })
    }
}

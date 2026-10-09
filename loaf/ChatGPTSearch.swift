import Combine
import Foundation

nonisolated struct ChatGPTSearchTurn: Identifiable {
    let id: UUID
    let query: String
    var text = ""
    var citations: [ChatGPTCitation] = []
    var complete = false
    var error: String?
    var phase: AnswerPhase = .connecting
    var sources: [LiveSearchSource] = []
    var searchQuery: String?
    var provider: AIProvider = .chatgpt
    var externalSources = false
    init(id: UUID = UUID(), query: String) {
        self.id = id
        self.query = query
    }
}

@MainActor final class ChatGPTSearch: ObservableObject {
    @Published private(set) var turns: [ChatGPTSearchTurn] = []
    @Published private(set) var searching = false
    @Published private(set) var activeTurnID: UUID?
    @Published var draft = ""
    private struct Node {
        var turn: ChatGPTSearchTurn
        let parent: UUID?
    }
    private var nodes: [UUID: Node] = [:]
    private var children: [UUID?: [UUID]] = [:]
    private var selectedBranch: [UUID?: UUID] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    let account: ChatGPTAccount
    let selectedProvider: () -> AIProvider
    let webSearch: (String) async throws -> [WebSearchResult]
    let enabled: () -> Bool
    private var providerOverride: AIProvider?
    var provider: AIProvider { providerOverride ?? selectedProvider() }
    var available: Bool {
        available(for: provider)
    }
    private var usesChatGPT: Bool { provider == .chatgpt || nodes.values.contains { $0.turn.provider == .chatgpt } }
    private var observations = Set<AnyCancellable>()
    init(
        account: ChatGPTAccount, provider: @escaping () -> AIProvider = { .chatgpt },
        enabled: @escaping () -> Bool = { true },
        webSearch: @escaping (String) async throws -> [WebSearchResult] = { try await WebSearchService.search($0) }
    ) {
        self.account = account
        self.selectedProvider = provider
        self.enabled = enabled
        self.webSearch = webSearch
        account.$connected.dropFirst().sink { [weak self] connected in
            if !connected, self?.usesChatGPT == true { self?.clear() }
        }.store(in: &observations)
        account.$disconnecting.dropFirst().sink { [weak self] disconnecting in
            if disconnecting, self?.usesChatGPT == true { self?.clear() }
        }.store(in: &observations)
    }
    func open(query: String, provider: AIProvider? = nil) {
        clear()
        providerOverride = provider
        draft = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if available { submit() }
    }
    func submit() {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searching, available else { return }
        guard query.utf8.count <= 8_000 else { return }
        draft = ""
        var turn = ChatGPTSearchTurn(query: query)
        turn.provider = provider
        append(turn, parent: turns.last?.id)
        respond(to: turn)
    }
    func canRetry(_ turnID: UUID) -> Bool {
        guard !searching, let turn = turns.first(where: { $0.id == turnID }) else { return false }
        return turn.error != nil && available(for: turn.provider)
    }
    func retry(_ turnID: UUID) {
        guard canRetry(turnID), let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        var replacement = ChatGPTSearchTurn(id: turnID, query: turns[index].query)
        replacement.provider = turns[index].provider
        update(turnID) { $0 = replacement }
        respond(to: replacement)
    }
    func canEdit(_ turnID: UUID) -> Bool {
        guard !searching, let node = nodes[turnID], turns.contains(where: { $0.id == turnID }) else { return false }
        return available(for: node.turn.provider)
    }
    func edit(_ turnID: UUID, query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(turnID), !query.isEmpty, query.utf8.count <= 8_000, let node = nodes[turnID]
        else { return }
        var turn = ChatGPTSearchTurn(query: query)
        turn.provider = node.turn.provider
        append(turn, parent: node.parent)
        respond(to: turn)
    }
    func branchPosition(_ turnID: UUID) -> (index: Int, count: Int) {
        guard let node = nodes[turnID], let siblings = children[node.parent],
            let index = siblings.firstIndex(of: turnID)
        else { return (0, 1) }
        return (index, siblings.count)
    }
    func selectBranch(_ turnID: UUID, offset: Int) {
        guard !searching, let node = nodes[turnID], let siblings = children[node.parent],
            let index = siblings.firstIndex(of: turnID), siblings.indices.contains(index + offset)
        else { return }
        selectedBranch[node.parent] = siblings[index + offset]
        showSelectedPath()
    }
    private func append(_ turn: ChatGPTSearchTurn, parent: UUID?) {
        nodes[turn.id] = Node(turn: turn, parent: parent)
        children[parent, default: []].append(turn.id)
        selectedBranch[parent] = turn.id
        showSelectedPath()
    }
    private func showSelectedPath() {
        var path: [ChatGPTSearchTurn] = []
        var parent: UUID?
        while let siblings = children[parent],
            let id = selectedBranch[parent] ?? siblings.first, let node = nodes[id]
        {
            path.append(node.turn)
            parent = id
        }
        turns = path
    }
    private func available(for provider: AIProvider) -> Bool {
        enabled()
            && (provider == .chatgpt
                ? account.connected && !account.disconnecting
                : AppleIntelligence.unavailableReason(for: provider) == nil)
    }
    private func respond(to turn: ChatGPTSearchTurn) {
        searching = true
        activeTurnID = turn.id
        generation = UUID()
        let current = generation
        let query = turn.query
        let turnID = turn.id
        let turnProvider = turn.provider
        let preceding = Array(turns.prefix { $0.id != turnID }.filter { $0.complete && $0.error == nil })
        var history = preceding.suffix(6).flatMap { turn -> [[String: Any]] in
            [
                ["role": "user", "content": turn.query],
                [
                    "role": "assistant",
                    "content": turn.text
                        + (turn.citations.isEmpty
                            ? ""
                            : "\n\nSources used:\n"
                                + turn.citations.map { $0.title + " — " + $0.url.absoluteString }.joined(
                                    separator: "\n"))
                        ,
                ],
            ]
        }
        if history.reduce(0, { $0 + (($1["content"] as? String)?.utf8.count ?? 0) }) > 120_000 {
            history = Array(history.suffix(4))
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    searching = false
                    activeTurnID = nil
                    task = nil
                }
            }
            do {
                if turnProvider != .chatgpt {
                    update(turnID) {
                        $0.phase = .searching
                        $0.searchQuery = query
                    }
                    let sources = try await webSearch(WebSearchService.searchQuery(query, preceding: preceding.map(\.query)))
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    update(turnID) {
                        $0.phase = .writing
                        $0.sources = sources.map { LiveSearchSource(url: $0.url, title: $0.title) }
                    }
                    try await AppleIntelligence.respond(
                        to: query, history: preceding, provider: turnProvider, sources: sources
                    ) {
                        [weak self] text in
                        guard let self, self.generation == current else { return }
                        self.update(turnID) {
                            $0.text = text
                            $0.citations = WebSearchService.citations(in: text, results: sources)
                        }
                    }
                    guard generation == current else { return }
                    update(turnID) {
                        $0.complete = true
                        $0.phase = .complete
                    }
                    return
                }
                let model = try await account.requireLuna()
                let token = try await account.accessToken()
                try Task.checkCancellation()
                guard generation == current else { return }
                let input = history + [["role": "user", "content": query]]
                if account.useExternalWebSearch {
                    try await externalAnswer(
                        query: query, input: input, model: model, token: token, turnID: turnID, current: current)
                } else {
                    do {
                        try await stream(input: input, model: model, token: token, turnID: turnID, current: current)
                    } catch let failure as ChatGPTFailure where failure.canUseSearchFallback {
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        try await externalAnswer(
                            query: query, input: input, model: model, token: token, turnID: turnID, current: current)
                        guard generation == current else { return }
                        account.useExternalWebSearch = true
                    }
                }

            } catch is CancellationError {} catch {
                guard generation == current else { return }
                update(turnID) {
                    $0.error =
                        turnProvider == .chatgpt ? self.account.friendly(error) : AppleIntelligence.friendly(error)
                }
            }
        }
    }
    private func externalAnswer(
        query: String, input: [[String: Any]], model: String, token: String, turnID: UUID, current: UUID
    ) async throws {
        update(turnID) {
            $0.text = ""
            $0.citations = []
            $0.sources = []
            $0.complete = false
            $0.externalSources = true
            $0.phase = .searching
            $0.searchQuery = query
        }
        let preceding = input.dropLast().compactMap { $0["role"] as? String == "user" ? $0["content"] as? String : nil }
        let sources = try await webSearch(WebSearchService.searchQuery(query, preceding: preceding))
        try Task.checkCancellation()
        guard generation == current else { return }
        update(turnID) {
            $0.phase = .writing
            $0.sources = sources.map { .init(url: $0.url, title: $0.title) }
        }
        try await stream(input: input, model: model, token: token, sources: sources, turnID: turnID, current: current)
    }
    private func stream(
        input: [[String: Any]], model: String, token: String, sources: [WebSearchResult]? = nil, turnID: UUID,
        current: UUID
    ) async throws {
        var request = URLRequest(url: URL(string: ChatGPTProtocol.resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try ChatGPTProtocol.searchBody(history: input, model: model, sources: sources)
        let (bytes, response) = try await account.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTFailure.interrupted }
        if !(200..<300).contains(response.statusCode) {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 32_768 { break }
            }
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let failure = object?["error"] as? [String: Any]
            throw ChatGPTFailure.service(
                status: response.statusCode, code: failure?["code"] as? String,
                param: failure?["param"] as? String, requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
            !contentType.lowercased().contains("text/event-stream")
        {
            throw ChatGPTFailure.interrupted
        }
        do {
            try await ChatGPTStream.consume(bytes, requiresWebSearch: sources == nil) { [weak self] snapshot in
                await self?.receive(snapshot, turnID: turnID, generation: current, sources: sources)
            }
        } catch let failure as ChatGPTFailure {
            if case .remote(let status, let code, let param, _) = failure {
                throw ChatGPTFailure.service(
                    status: status, code: code, param: param,
                    requestID: response.value(forHTTPHeaderField: "x-request-id"))
            }
            throw failure
        }
    }
    private func receive(
        _ snapshot: ChatGPTStreamUpdate, turnID: UUID, generation token: UUID, sources: [WebSearchResult]? = nil
    ) {
        guard generation == token else { return }
        update(turnID) {
            $0.text = snapshot.text
            if let sources {
                $0.citations = WebSearchService.citations(in: snapshot.text, results: sources)
            } else {
                $0.citations = snapshot.citations
                $0.sources = snapshot.sources
            }
            $0.phase = snapshot.phase
            if sources == nil { $0.searchQuery = snapshot.query }
            $0.complete = snapshot.complete
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        searching = false
        if let id = activeTurnID, let turn = turns.first(where: { $0.id == id }), !turn.complete, turn.error == nil {
            update(id) { $0.error = "answer stopped. this answer is unfinished." }
        }
        activeTurnID = nil
    }
    func clear() {
        stop()
        turns = []
        nodes = [:]
        children = [:]
        selectedBranch = [:]
        draft = ""
        providerOverride = nil
    }
    private func update(_ id: UUID, _ change: (inout ChatGPTSearchTurn) -> Void) {
        guard var node = nodes[id] else { return }
        change(&node.turn)
        nodes[id] = node
        if let index = turns.firstIndex(where: { $0.id == id }) { turns[index] = node.turn }
    }
}

import AppKit
import Combine
import Foundation

nonisolated struct ChatTurn: Identifiable, Codable {
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
    var context: TabChatContext?
    var webQuery: String?
    var accountID: String?
    var modelID: String?
    var modelName: String?
    var pageReadStatus: String?
    var captureTarget: TabChatTarget?
    var capture: TabChatCapture?
    var captureStatus: String?
    var attachedPages: [TabChatContext] = []
    var images: [ChatImageAttachment] = []
    var reasoningEffort: String?
    var isSummary: Bool?
    var inputText: String {
        AIEvidence.question(query, page: context, attachments: attachedPages)
    }
    init(id: UUID = UUID(), query: String) {
        self.id = id
        self.query = query
    }
}

typealias ChatGPTSearchTurn = ChatTurn
typealias ChatGPTSearch = ChatSession

nonisolated struct PageReadRequest: Identifiable {
    let id = UUID()
    let sources: [WebSearchResult]
}

nonisolated struct ChatToolRequest: Identifiable {
    let id = UUID()
    let kind: String
    let value: String
}

nonisolated enum PageReadDecision { case allow, allowAll, deny }

@MainActor final class ChatSession: ObservableObject {
    var archiveID = UUID()
    @Published private(set) var toolRequest: ChatToolRequest?
    private var toolContinuation: CheckedContinuation<Bool, Never>?
    private var allowedTools = Set<String>()
    private var deniedTools = Set<String>()
    private var toolSources: [WebSearchResult] = []
    @Published private(set) var turns: [ChatGPTSearchTurn] = []
    @Published private(set) var searching = false
    @Published private(set) var activeTurnID: UUID?
    @Published var draft = ""
    @Published private(set) var pageReadRequest: PageReadRequest?
    @Published private(set) var allowsAllPageReads = false
    private var pageReadContinuation: CheckedContinuation<Bool, Never>?
    @Published private(set) var pageCaptureRequest: PageCaptureRequest?
    @Published private(set) var allowsAllCaptures = false
    private var captureContinuation: CheckedContinuation<Bool, Never>?
    private var unavailableCaptureModels = Set<String>()
    private struct Node {
        var turn: ChatGPTSearchTurn
        let parent: UUID?
    }
    private var nodes: [UUID: Node] = [:]
    private var children: [UUID?: [UUID]] = [:]
    private var selectedBranch: [UUID?: UUID] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let primaryAccount: ChatGPTAccount
    private let accounts: ChatGPTAccounts?
    private let selectedAccountID: () -> String?
    private let selectedModelID: () -> String?
    private let searchEngine: () -> SearchEngine
    private var activeAccountID: String?
    private var accountOverride: String?
    private var hasAccountOverride = false
    var account: ChatGPTAccount {
        accounts?.account(id: activeAccountID ?? (hasAccountOverride ? accountOverride : selectedAccountID()))
            ?? primaryAccount
    }
    let claudeAccount: ClaudeAccount?
    let selectedProvider: () -> AIProvider?
    let webSearch: ((String) async throws -> [WebSearchResult])?
    let readPage: (URL) async throws -> String
    let capturePage: ((TabChatTarget) async throws -> TabChatCapture)?
    let enabled: () -> Bool
    let isSideChat: Bool
    private var providerOverride: AIProvider?
    private var modelOverride: String?
    var automatic: Bool { providerOverride == nil && selectedProvider() == nil }
    var provider: AIProvider {
        if searching, let id = activeTurnID, let turn = nodes[id]?.turn { return turn.provider }
        return AppleIntelligence.resolve(providerOverride ?? selectedProvider())
    }
    var modelID: String? {
        if searching, let id = activeTurnID, let turn = nodes[id]?.turn { return turn.modelID }
        let value = modelOverride ?? selectedModelID()
        return value == PageSummary.defaultLuna ? account.lunaModel ?? ChatGPTProtocol.model : value
    }
    var acceptsImages: Bool {
        provider == .chatgpt
            && (account.models.first { $0.id == modelID } ?? account.selectedModel)?.acceptsImages == true
    }
    var available: Bool {
        available(for: provider)
    }
    var usesChatGPT: Bool { provider == .chatgpt || nodes.values.contains { $0.turn.provider == .chatgpt } }
    private var observations = Set<AnyCancellable>()
    init(
        account: ChatGPTAccount, provider: @escaping () -> AIProvider? = { .chatgpt },
        accounts: ChatGPTAccounts? = nil, accountID: @escaping () -> String? = { nil },
        selectedModelID: @escaping () -> String? = { nil },
        searchEngine: @escaping () -> SearchEngine = { .google },
        claudeAccount: ClaudeAccount? = nil,
        enabled: @escaping () -> Bool = { true },
        webSearch: ((String) async throws -> [WebSearchResult])? = nil,
        isSideChat: Bool = false,
        readPage: @escaping (URL) async throws -> String = { try await PublicPageReader.read($0) },
        capturePage: ((TabChatTarget) async throws -> TabChatCapture)? = nil
    ) {
        self.primaryAccount = account
        self.accounts = accounts
        self.selectedAccountID = accountID
        self.selectedModelID = selectedModelID
        self.searchEngine = searchEngine
        self.claudeAccount = claudeAccount
        self.selectedProvider = provider
        self.enabled = enabled
        self.webSearch = webSearch
        self.isSideChat = isSideChat
        self.readPage = readPage
        self.capturePage = capturePage
        account.$connected.dropFirst().sink { [weak self] connected in
            if self?.account === account && !connected {
                self?.providerDisconnected(.chatgpt)
            } else {
                self?.objectWillChange.send()
            }
        }.store(in: &observations)
        account.$disconnecting.dropFirst().sink { [weak self] disconnecting in
            if self?.account === account && disconnecting { self?.providerDisconnected(.chatgpt) }
        }.store(in: &observations)
        accounts?.didChange.sink { [weak self] in
            guard let self else { return }
            if self.searching, self.nodes[self.activeTurnID ?? UUID()]?.turn.provider == .chatgpt,
                !self.account.connected || self.account.disconnecting
            {
                self.providerDisconnected(.chatgpt)
            }
            self.objectWillChange.send()
        }.store(in: &observations)
        claudeAccount?.$connected.dropFirst().sink { [weak self] connected in
            if !connected { self?.providerDisconnected(.claude) }
        }.store(in: &observations)
        claudeAccount?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    func useAutomatic() {
        guard !searching else { return }
        objectWillChange.send()
        providerOverride = nil
        modelOverride = nil
        accountOverride = nil
        hasAccountOverride = false
    }
    func use(provider: AIProvider, model: String? = nil, accountID: String? = nil, accountRule: Bool = false) {
        guard !searching else { return }
        objectWillChange.send()
        providerOverride = provider
        hasAccountOverride = accountRule
        accountOverride = accountID
        modelOverride = model
    }
    func open(query: String, provider: AIProvider? = nil) {
        clear()
        providerOverride = provider
        draft = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if available { submit() }
    }
    func submit(
        context: TabChatContext? = nil, webQuery: String? = nil, captureTarget: TabChatTarget? = nil,
        attachedPages: [TabChatContext] = [], images: [ChatImageAttachment] = [], summary: Bool = false
    ) {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searching, available else { return }
        guard query.utf8.count <= 8_000, attachedPages.count <= 5,
            images.count <= ChatImageAttachment.maximumCount,
            images.allSatisfy({ $0.jpeg.count <= ChatImageAttachment.maximumFileBytes }),
            images.reduce(0, { $0 + $1.jpeg.count }) <= ChatImageAttachment.maximumTotalBytes,
            images.isEmpty || acceptsImages
        else { return }
        draft = ""
        var turn = ChatGPTSearchTurn(query: query)
        turn.provider = provider
        turn.accountID = provider == .chatgpt ? account.connectionID : nil
        turn.isSummary = summary ? true : nil
        turn.context = context
        turn.attachedPages = attachedPages
        turn.images = images
        turn.reasoningEffort = provider == .chatgpt && !summary ? account.reasoningEffort : nil
        turn.webQuery = webQuery
        turn.captureTarget = captureTarget
        turn.modelID =
            modelOverride ?? selectedModelID()
            ?? (provider == .chatgpt
                ? account.selectedModelID : provider == .claude ? claudeAccount?.selectedModelID : nil)
        append(turn, parent: turns.last?.id)
        respond(to: turn)
    }
    func canRetry(_ turnID: UUID) -> Bool {
        guard !searching, let turn = turns.first(where: { $0.id == turnID }) else { return false }
        return turn.error != nil && available(for: turn.provider, accountID: turn.accountID)
    }
    func retry(_ turnID: UUID) {
        guard canRetry(turnID), let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        var replacement = ChatGPTSearchTurn(id: turnID, query: turns[index].query)
        replacement.accountID = turns[index].accountID
        replacement.provider = turns[index].provider
        replacement.isSummary = turns[index].isSummary
        replacement.attachedPages = turns[index].attachedPages
        replacement.images = turns[index].images
        replacement.reasoningEffort = turns[index].reasoningEffort
        replacement.context = turns[index].context
        replacement.webQuery = turns[index].webQuery
        replacement.modelID = turns[index].modelID
        replacement.modelName = turns[index].modelName
        replacement.captureTarget = turns[index].captureTarget
        replacement.capture = turns[index].capture
        update(turnID) { $0 = replacement }
        respond(to: replacement)
    }
    func canEdit(_ turnID: UUID) -> Bool {
        guard !searching, let node = nodes[turnID], turns.contains(where: { $0.id == turnID }) else { return false }
        return available(for: node.turn.provider, accountID: node.turn.accountID)
    }
    func edit(_ turnID: UUID, query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(turnID), !query.isEmpty, query.utf8.count <= 8_000, let node = nodes[turnID]
        else { return }
        var turn = ChatGPTSearchTurn(query: query)
        turn.accountID = node.turn.accountID
        turn.provider = node.turn.provider
        turn.isSummary = node.turn.isSummary
        turn.attachedPages = node.turn.attachedPages
        turn.images = node.turn.images
        turn.reasoningEffort = node.turn.reasoningEffort
        turn.context = node.turn.context
        turn.webQuery = node.turn.webQuery
        turn.modelID = node.turn.modelID
        turn.modelName = node.turn.modelName
        turn.captureTarget = node.turn.captureTarget
        turn.capture = node.turn.capture
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
    private func available(for provider: AIProvider, accountID: String? = nil) -> Bool {
        guard enabled() else { return false }
        switch provider {
        case .chatgpt:
            let connection = accountID.flatMap { accounts?.account(id: $0) } ?? account
            return connection.connected && !connection.disconnecting
        case .claude: return claudeAccount?.connected == true
        case .onDevice, .privateCloud: return AppleIntelligence.unavailableReason(for: provider) == nil
        }
    }
    private func respond(to turn: ChatGPTSearchTurn) {
        activeAccountID = turn.accountID
        searching = true
        activeTurnID = turn.id
        generation = UUID()
        let current = generation
        toolSources = []
        deniedTools = []
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
        while history.reduce(0, { $0 + (($1["content"] as? String)?.utf8.count ?? 0) }) > 60_000 {
            history.removeFirst(min(2, history.count))
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    searching = false
                    activeAccountID = nil
                    activeTurnID = nil
                    task = nil
                }
            }
            do {
                if turnProvider == .claude {
                    guard let claudeAccount else {
                        throw ChatGPTFailure.message("connect Claude in intelligence settings.")
                    }
                    let model = try await claudeAccount.requireModel(turn.modelID)
                    guard generation == current else { return }
                    update(turnID) {
                        $0.modelID = model.id
                        $0.modelName = model.name
                        $0.phase = .writing
                    }
                    let handler: ((String, String) async throws -> String)? =
                        turn.isSummary == true
                        ? nil
                        : { [weak self] kind, value in
                            guard let self, self.generation == current else { throw CancellationError() }
                            return try await self.performWebTool(
                                kind: kind, value: value, turnID: turnID, current: current)
                        }
                    try await ClaudeAnswerProvider.respond(
                        account: claudeAccount,
                        input: (turn.isSummary == true ? [] : history) + [["role": "user", "content": turn.inputText]],
                        model: model.id, summary: turn.isSummary == true,
                        question: turn.query, precedingQuestions: preceding.filter(\.complete).map(\.query),
                        webTool: handler
                    ) { [weak self] text in
                        guard let self, self.generation == current else { return }
                        self.update(turnID) {
                            $0.text = text
                            $0.citations =
                                WebSearchService.citations(in: text, results: self.toolSources)
                                + ($0.context?.citations(in: text, soleSource: self.toolSources.isEmpty) ?? [])
                                + $0.attachedPages.enumerated().flatMap {
                                    $0.element.citations(in: text, marker: "tab\($0.offset + 1)")
                                }
                        }
                    }
                    guard generation == current else { return }
                    update(turnID) {
                        $0.complete = true
                        $0.phase = .complete
                    }
                    return
                }
                if turnProvider != .chatgpt {
                    if turn.isSummary == true, let page = turn.context {
                        update(turnID) {
                            $0.phase = .writing
                            $0.modelName = turnProvider.title
                        }
                        try await AppleIntelligence.summarize(page, provider: turnProvider) { [weak self] text in
                            guard let self, self.generation == current else { return }
                            self.update(turnID) {
                                $0.text = text
                                $0.citations = page.citations(in: text, soleSource: true)
                            }
                        }
                        guard generation == current else { return }
                        update(turnID) {
                            $0.complete = true
                            $0.phase = .complete
                        }
                        return
                    }
                    let sources = try await sideSources(turn.webQuery, turnID: turnID, current: current)
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    update(turnID) {
                        $0.phase = .writing
                        $0.sources = sources.map { LiveSearchSource(url: $0.url, title: $0.title) }
                    }
                    toolSources = sources
                    try await AppleIntelligence.respond(
                        to: query, history: preceding, provider: turnProvider, sources: sources,
                        pageContext: turn.context, attachedPages: turn.attachedPages,
                        searchWeb: { [weak self] value in
                            guard let self, self.generation == current else { throw CancellationError() }
                            return try await self.performWebTool(
                                kind: "search_web", value: value, turnID: turnID, current: current, compact: true)
                        }
                    ) {
                        [weak self] text in
                        guard let self, self.generation == current else { return }
                        self.update(turnID) {
                            $0.text = text
                            $0.citations =
                                WebSearchService.citations(in: text, results: self.toolSources)
                                + ($0.context?.citations(in: text, soleSource: self.toolSources.isEmpty) ?? [])
                                + $0.attachedPages.enumerated().flatMap {
                                    $0.element.citations(in: text, marker: "tab\($0.offset + 1)")
                                }
                        }
                    }
                    guard generation == current else { return }
                    update(turnID) {
                        $0.complete = true
                        $0.phase = .complete
                    }
                    return
                }
                let chosenModel: ChatModel
                if turn.modelID == PageSummary.defaultLuna {
                    chosenModel = try await account.requireLunaModel()
                } else {
                    chosenModel = try await account.requireModel(turn.modelID)
                }
                guard generation == current else { return }
                update(turnID) {
                    $0.modelID = chosenModel.id
                    $0.modelName = chosenModel.name
                    if let effort = $0.reasoningEffort, !chosenModel.reasoningEfforts.contains(effort) {
                        $0.reasoningEffort = nil
                    }
                }
                guard turn.images.isEmpty || chosenModel.acceptsImages else {
                    throw ChatGPTFailure.message(
                        "this model doesn’t accept images. choose an image-capable model or remove the attachment.")
                }
                let model = chosenModel.id
                let token = try await account.accessToken()
                try Task.checkCancellation()
                guard generation == current else { return }
                var input = (turn.isSummary == true ? [] : history) + [["role": "user", "content": turn.inputText]]
                if chosenModel.acceptsImages && turn.isSummary != true {
                    var remainingBytes =
                        ChatImageAttachment.maximumTotalBytes - turn.images.reduce(0, { $0 + $1.jpeg.count })
                        - (turn.capture?.jpeg.count ?? 0)
                    var remainingCount = max(0, ChatImageAttachment.maximumCount - turn.images.count)
                    let retained = Array(preceding.suffix(history.count / 2))
                    for index in retained.indices.reversed() {
                        let previous = retained[index]
                        var content: [[String: Any]] = [
                            ["type": "input_text", "text": input[index * 2]["content"] as? String ?? ""]
                        ]
                        for image in previous.images where remainingCount > 0 && image.jpeg.count <= remainingBytes {
                            content.append(["type": "input_image", "image_url": image.imageURL, "detail": "high"])
                            remainingBytes -= image.jpeg.count
                            remainingCount -= 1
                        }
                        if let capture = previous.capture, remainingCount > 0, capture.jpeg.count <= remainingBytes {
                            content += [
                                ["type": "input_text", "text": capture.evidence],
                                ["type": "input_image", "image_url": capture.imageURL, "detail": "high"],
                            ]
                            remainingBytes -= capture.jpeg.count
                            remainingCount -= 1
                        }
                        if content.count > 1 { input[index * 2]["content"] = content }
                    }
                }
                let sources = try await sideSources(turn.webQuery, turnID: turnID, current: current)
                try Task.checkCancellation()
                guard generation == current else { return }
                try await stream(
                    input: input, model: model, token: token, sources: sources, turnID: turnID, current: current)

            } catch {
                guard generation == current else { return }
                update(turnID) {
                    $0.error =
                        error is CancellationError
                        ? ChatGPTFailure.interrupted.localizedDescription
                        : turnProvider == .chatgpt
                            ? self.account.friendly(error)
                            : turnProvider == .claude
                                ? self.claudeAccount?.friendly(error) ?? error.localizedDescription
                                : AppleIntelligence.friendly(error)
                }
            }
        }
    }
    private func stream(
        input: [[String: Any]], model: String, token: String, sources: [WebSearchResult]? = nil, turnID: UUID,
        current: UUID
    ) async throws {
        let turn = nodes[turnID]?.turn
        toolSources = sources ?? []
        let canCapture =
            isSideChat && capturePage != nil && turn?.captureTarget != nil && turn?.capture == nil
            && !unavailableCaptureModels.contains(model)
            && account.models.first(where: { $0.id == model })?.acceptsImages == true
        let captureHandler: ((String) async throws -> TabChatCapture?)? =
            canCapture
            ? { [weak self] reason in
                guard let self, self.generation == current, let target = turn?.captureTarget else {
                    throw CancellationError()
                }
                return try await self.requestCapture(target, reason: reason, turnID: turnID, current: current)
            } : nil
        let webHandler: ((String, String) async throws -> String)? =
            unavailableCaptureModels.contains(model)
            ? nil
            : { [weak self] kind, value in
                guard let self, self.generation == current else { throw CancellationError() }
                return try await self.performWebTool(kind: kind, value: value, turnID: turnID, current: current)
            }
        do {
            try await ChatGPTAnswerProvider.respond(
                account: account, token: token, input: input, model: model, sources: sources,
                allowsNativeSearch: false, initialCapture: turn?.capture, capturePage: captureHandler,
                images: turn?.images ?? [], reasoningEffort: turn?.reasoningEffort,
                webTool: webHandler, summary: turn?.isSummary == true,
                question: turn?.query,
                precedingQuestions: turns.prefix(while: { $0.id != turnID }).filter(\.complete).map(\.query)
            ) { [weak self] snapshot in
                self?.receive(snapshot, turnID: turnID, generation: current, sources: sources)
            }
        } catch let failure as ChatGPTFailure {
            guard case .remote(let status, let code, let parameter, _) = failure,
                status == 0 || status == 400, code == "subscription_sharing_unsupported_capability",
                parameter?.hasPrefix("tools") == true
            else { throw failure }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            unavailableCaptureModels.insert(model)
            update(turnID) { $0.captureStatus = "read-only tools unavailable for this model · using text" }
            try await ChatGPTAnswerProvider.respond(
                account: account, token: token, input: input, model: model, sources: sources, allowsNativeSearch: false,
                images: turn?.images ?? [], reasoningEffort: turn?.reasoningEffort, summary: turn?.isSummary == true,
                question: turn?.query,
                precedingQuestions: turns.prefix(while: { $0.id != turnID }).filter(\.complete).map(\.query)
            ) { [weak self] snapshot in
                self?.receive(snapshot, turnID: turnID, generation: current, sources: sources)
            }
        }
    }
    private func sideSources(_ query: String?, turnID: UUID, current: UUID) async throws -> [WebSearchResult] {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        update(turnID) {
            $0.phase = .searching
            $0.searchQuery = query
            $0.externalSources = true
        }
        guard await approveTool(kind: "search_web", value: query, turnID: turnID) else { return [] }
        try Task.checkCancellation()

        let sources: [WebSearchResult]
        if let webSearch {
            sources = try await webSearch(query)
        } else {
            sources = try await WebSearchService.search(query, publicSnippetsOnly: true, engine: searchEngine())
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }

        let publicSources = Array(sources.filter { PublicSearchNavigation.isPublicURL($0.url) }.prefix(6))
        update(turnID) { $0.sources = publicSources.map { .init(url: $0.url, title: $0.title) } }
        guard !publicSources.isEmpty else { return [] }
        let allowed: Bool
        if allowsAllPageReads {
            allowed = true
        } else {
            update(turnID) { $0.phase = .awaitingPermission }
            allowed = await withCheckedContinuation { continuation in
                pageReadContinuation = continuation
                pageReadRequest = PageReadRequest(sources: publicSources)
            }
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        guard allowed else {
            update(turnID) {
                $0.pageReadStatus = "full-page access declined · using search snippets"
                $0.phase = .writing
            }
            return publicSources
        }
        update(turnID) { $0.phase = .reading }
        let enriched = await withTaskGroup(of: (Int, WebSearchResult).self) { group in
            for (index, source) in publicSources.enumerated() {
                group.addTask { @MainActor [readPage] in
                    var result = source
                    if let text = try? await readPage(source.url), text.count >= 100, !Task.isCancelled {
                        result.excerpt = WebSearchService.relevantExcerpt(text, query: query, limit: 4_800)
                        result.contentFetched = true
                    }
                    return (index, result)
                }
            }
            var results: [(Int, WebSearchResult)] = []
            for await value in group { results.append(value) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let read = enriched.filter(\.contentFetched).count
        update(turnID) {
            $0.pageReadStatus =
                read == enriched.count
                ? "read \(read) \(read == 1 ? "page" : "pages") · using relevant excerpts"
                : "read \(read) of \(enriched.count) pages · remaining sources use snippets"
            $0.phase = .writing
        }
        return enriched
    }
    func decidePageReads(_ decision: PageReadDecision, requestID: UUID) {
        guard pageReadRequest?.id == requestID, let continuation = pageReadContinuation else { return }
        if decision == .allowAll {
            allowsAllPageReads = true
            allowedTools.insert("fetch_page")
        }
        if decision == .deny { deniedTools.insert("fetch_page") }
        pageReadContinuation = nil
        pageReadRequest = nil
        continuation.resume(returning: decision != .deny)
    }
    func revokePageReads() {
        allowsAllPageReads = false
        allowedTools.remove("fetch_page")
    }
    private func requestCapture(_ target: TabChatTarget, reason: String, turnID: UUID, current: UUID) async throws
        -> TabChatCapture?
    {
        guard let capturePage else { return nil }
        update(turnID) {
            $0.phase = .reading
            $0.complete = false
        }
        let capture: TabChatCapture
        do { capture = try await capturePage(target) } catch is CancellationError { throw CancellationError() } catch {
            guard generation == current else { throw CancellationError() }
            update(turnID) {
                $0.captureStatus = "screenshot unavailable · continuing from text"
                $0.phase = .writing
            }
            return nil
        }
        try Task.checkCancellation()
        guard generation == current, capture.target == target, capture.jpeg.count <= 2_000_000 else {
            throw CancellationError()
        }
        let allowed: Bool
        if allowsAllCaptures {
            allowed = true
        } else {
            update(turnID) { $0.phase = .awaitingPermission }
            allowed = await withCheckedContinuation { continuation in
                captureContinuation = continuation
                pageCaptureRequest = .init(capture: capture, reason: reason)
            }
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        update(turnID) {
            $0.capture = allowed ? capture : nil
            $0.captureStatus =
                allowed ? "shared screenshot · visible viewport" : "screenshot declined · continuing from text"
            $0.phase = .writing
        }
        return allowed ? capture : nil
    }
    func decideCapture(_ decision: PageReadDecision, requestID: UUID) {
        guard pageCaptureRequest?.id == requestID, let continuation = captureContinuation else { return }
        if decision == .allowAll { allowsAllCaptures = true }
        captureContinuation = nil
        pageCaptureRequest = nil
        continuation.resume(returning: decision != .deny)
    }
    func revokeCaptures() { allowsAllCaptures = false }
    private func receive(
        _ snapshot: ChatGPTStreamUpdate, turnID: UUID, generation token: UUID, sources: [WebSearchResult]? = nil
    ) {
        guard generation == token else { return }
        update(turnID) {
            $0.text = snapshot.text
            let publicSources = toolSources.isEmpty ? (sources ?? []) : toolSources
            $0.citations = snapshot.citations + WebSearchService.citations(in: snapshot.text, results: publicSources)
            $0.sources = snapshot.sources + publicSources.map { .init(url: $0.url, title: $0.title) }
            $0.citations +=
                $0.capture?.citations(in: snapshot.text, soleSource: publicSources.isEmpty && $0.attachedPages.isEmpty)
                ?? $0.context?.citations(
                    in: snapshot.text, soleSource: publicSources.isEmpty && $0.attachedPages.isEmpty) ?? []
            for (index, context) in $0.attachedPages.enumerated() {
                $0.citations += context.citations(in: snapshot.text, marker: "tab\(index + 1)")
            }
            $0.phase = snapshot.phase
            if sources == nil { $0.searchQuery = snapshot.query }
            $0.citations = Array(Dictionary(grouping: $0.citations, by: \.id).compactMap { $0.value.first }).sorted {
                $0.start < $1.start
            }
            $0.complete = snapshot.complete
        }
    }
    private func providerDisconnected(_ provider: AIProvider) {
        let activeProvider = activeTurnID.flatMap { nodes[$0]?.turn.provider }
        if activeProvider == provider {
            stop(
                message:
                    "\(provider.title) disconnected. reconnect in intelligence settings, then retry this answer.")
        }
        if self.provider == provider || activeProvider == provider {
            allowedTools = []
            allowsAllPageReads = false
            allowsAllCaptures = false
        }
        objectWillChange.send()
    }
    func stop(message: String = "answer stopped. this answer is unfinished.") {
        generation = UUID()
        task?.cancel()
        let pendingTool = toolContinuation
        toolContinuation = nil
        toolRequest = nil
        pendingTool?.resume(returning: false)
        let pending = pageReadContinuation
        pageReadContinuation = nil
        pageReadRequest = nil
        pending?.resume(returning: false)
        let pendingCapture = captureContinuation
        captureContinuation = nil
        pageCaptureRequest = nil
        pendingCapture?.resume(returning: false)
        task = nil
        searching = false
        if let id = activeTurnID, let turn = turns.first(where: { $0.id == id }), !turn.complete, turn.error == nil {
            update(id) { $0.error = message }
        }
        activeTurnID = nil
        activeAccountID = nil
    }
    func clear() {
        archiveID = UUID()
        stop()
        turns = []
        nodes = [:]
        children = [:]
        selectedBranch = [:]
        draft = ""
        providerOverride = nil
        modelOverride = nil
        accountOverride = nil
        hasAccountOverride = false
        allowedTools = []
        deniedTools = []
        toolSources = []
        allowsAllPageReads = false
        allowsAllCaptures = false
        unavailableCaptureModels = []
    }
    func restore(_ saved: [ChatTurn]) {
        clear()
        for var turn in saved {
            turn.captureTarget = nil
            if !turn.complete && turn.error == nil { turn.error = "this answer was interrupted." }
            append(turn, parent: turns.last?.id)
        }
    }
    func revokeWebTools() {
        allowedTools = []
        allowsAllPageReads = false
    }
    func decideTool(_ decision: PageReadDecision, requestID: UUID) {
        guard let request = toolRequest, request.id == requestID, let continuation = toolContinuation else { return }
        if decision == .allowAll {
            allowedTools.insert(request.kind)
            if request.kind == "fetch_page" { allowsAllPageReads = true }
        }
        if decision == .deny { deniedTools.insert(request.kind) }
        toolRequest = nil
        toolContinuation = nil
        continuation.resume(returning: decision != .deny)
    }
    private func approveTool(kind: String, value: String, turnID: UUID) async -> Bool {
        if deniedTools.contains(kind) { return false }
        if allowedTools.contains(kind) { return true }
        update(turnID) { $0.phase = .awaitingPermission }
        NSSound.beep()
        return await withCheckedContinuation { continuation in
            toolContinuation = continuation
            toolRequest = ChatToolRequest(kind: kind, value: value)
        }
    }
    private func performWebTool(kind: String, value: String, turnID: UUID, current: UUID, compact: Bool = false)
        async throws -> String
    {
        guard enabled(), value.utf8.count <= 2_000 else { throw CancellationError() }
        guard ["search_web", "fetch_page"].contains(kind),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Invalid tool request. Use search_web with a query or fetch_page with a public URL."
        }
        if kind == "fetch_page" {
            guard let url = URL(string: value), PublicSearchNavigation.isPublicURL(url),
                toolSources.contains(where: { $0.url == url }) || nodes[turnID]?.turn.query.contains(value) == true
            else {
                return "Unavailable: fetch only public URLs supplied by the user or returned by this chat’s search."
            }
        }
        let approved = await approveTool(kind: kind, value: value, turnID: turnID)
        try Task.checkCancellation()
        guard generation == current, enabled() else { throw CancellationError() }
        guard approved else {
            update(turnID) { $0.phase = .writing }
            return "User denied this tool. Continue from available evidence."
        }
        var returnedURLs = Set<URL>()
        if kind == "search_web" {
            update(turnID) {
                $0.phase = .searching
                $0.searchQuery = value
                $0.externalSources = true
            }
            let results: [WebSearchResult]
            if let webSearch {
                results = try await webSearch(value)
            } else {
                results = try await WebSearchService.search(value, publicSnippetsOnly: true, engine: searchEngine())
            }
            try Task.checkCancellation()
            guard generation == current, enabled() else { throw CancellationError() }
            returnedURLs = Set(results.prefix(6).map(\.url))
            for source in results.prefix(6)
            where PublicSearchNavigation.isPublicURL(source.url)
                && !toolSources.contains(where: { $0.url == source.url })
            {
                if toolSources.count < 18 { toolSources.append(source) }
            }
        } else if kind == "fetch_page", let url = URL(string: value) {
            update(turnID) { $0.phase = .reading }
            let text = try await readPage(url)
            try Task.checkCancellation()
            guard generation == current, enabled() else { throw CancellationError() }
            if let index = toolSources.firstIndex(where: { $0.url == url }) {
                toolSources[index].excerpt = String(text.prefix(12_000))
                toolSources[index].contentFetched = true
            } else {
                toolSources.append(
                    WebSearchResult(
                        url: url, title: url.host ?? "page", excerpt: String(text.prefix(12_000)), contentFetched: true)
                )
            }
        } else {
            return "Unknown tool."
        }
        update(turnID) {
            $0.phase = .writing
            $0.sources = toolSources.map { .init(url: $0.url, title: $0.title) }
        }
        let question = nodes[turnID]?.turn.query ?? value
        let candidates = toolSources.enumerated().filter { index, source in
            kind == "fetch_page" ? source.url.absoluteString == value : returnedURLs.contains(source.url)
        }
        let sources = candidates.prefix(compact ? 3 : 6).map { index, source in
            AIEvidence.Source(
                citation: String(index + 1), title: String(source.title.prefix(160)),
                url: source.url.absoluteString, evidenceType: source.contentFetched ? "page extract" : "search snippet",
                text: WebSearchService.relevantExcerpt(
                    source.excerpt, query: question,
                    limit: compact ? 500 : kind == "fetch_page" ? 9_000 : 1_600))
        }
        return AIEvidence.json(AIEvidence.ToolResult(status: sources.isEmpty ? "no_results" : "ok", sources: sources))
    }
    private func update(_ id: UUID, _ change: (inout ChatGPTSearchTurn) -> Void) {
        guard var node = nodes[id] else { return }
        change(&node.turn)
        nodes[id] = node
        if let index = turns.firstIndex(where: { $0.id == id }) { turns[index] = node.turn }
    }
}

import Foundation

nonisolated struct ClaudeStream {
    private(set) var blocks: [Int: [String: Any]] = [:]
    private var arguments: [Int: String] = [:]
    private(set) var stopped = false
    private(set) var stopReason: String?
    var content: [[String: Any]] { blocks.keys.sorted().compactMap { blocks[$0] } }
    var text: String { content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() }
    mutating func receive(_ data: Data) throws {
        guard data.count <= 1_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { throw ChatGPTFailure.interrupted }
        switch type {
        case "content_block_start":
            guard let index = object["index"] as? Int, (0..<64).contains(index),
                let block = object["content_block"] as? [String: Any]
            else { throw ChatGPTFailure.interrupted }
            blocks[index] = block
        case "content_block_delta":
            guard let index = object["index"] as? Int, blocks[index] != nil,
                let delta = object["delta"] as? [String: Any]
            else { throw ChatGPTFailure.interrupted }
            if delta["type"] as? String == "text_delta", let value = delta["text"] as? String {
                let next = (blocks[index]?["text"] as? String ?? "") + value
                guard next.utf8.count <= 200_000 else { throw ChatGPTFailure.interrupted }
                blocks[index]?["text"] = next
            } else if delta["type"] as? String == "input_json_delta", let value = delta["partial_json"] as? String {
                arguments[index, default: ""] += value
                guard arguments[index]!.utf8.count <= 8_000 else { throw ChatGPTFailure.interrupted }
            }
        case "content_block_stop":
            if let index = object["index"] as? Int, let value = arguments[index] {
                guard let input = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
                    throw ChatGPTFailure.interrupted
                }
                blocks[index]?["input"] = input
            }
        case "message_delta": stopReason = (object["delta"] as? [String: Any])?["stop_reason"] as? String
        case "message_stop": stopped = true
        case "error": throw ChatGPTFailure.message("Claude couldn’t finish this answer. try again.")
        default: break
        }
    }
    func validateCompletion() throws {
        guard stopped, stopReason == "end_turn" || stopReason == "tool_use" || stopReason == "stop_sequence" else {
            throw ChatGPTFailure.message(
                stopReason == "max_tokens"
                    ? "Claude reached the response limit. try a shorter question."
                    : "the Claude answer was interrupted. try again.")
        }
    }
}

@MainActor enum ClaudeAnswerProvider {
    nonisolated static func failure(status: Int) -> ChatGPTFailure {
        switch status {
        case 401, 403:
            .message("Claude couldn’t authorize this API key. check the connection in intelligence settings.")
        case 429: .message("Claude’s API limit was reached. check your Anthropic usage or try again later.")
        case 400, 404: .message("Claude couldn’t accept this request. refresh models in intelligence settings.")
        default: .message("Claude is temporarily unavailable. try again.")
        }
    }
    static func respond(
        account: ClaudeAccount, input: [[String: Any]], model: String, summary: Bool = false,
        question: String? = nil, precedingQuestions: [String] = [],
        webTool: ((String, String) async throws -> String)? = nil,
        update: @escaping (String) -> Void
    ) async throws {
        var messages = input
        var accumulated = ""
        for round in 0..<5 {
            try Task.checkCancellation()
            var request = try account.request(path: "messages")
            request.httpMethod = "POST"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let system =
                summary
                ? PageSummary.instructions
                : ChatGPTProtocol.answerInstructions(query: question ?? "", preceding: precedingQuestions)
                    + " Cite page facts with [page], other tabs with [tab1], [tab2], etc., and web evidence with its supplied [1], [2], etc. markers."
                    + (webTool == nil
                        ? " Web tools are unavailable for this request."
                        : " Use search_web for current, unfamiliar or source-dependent facts. The app handles permission; call the tool rather than asking the user for a search query. General explanations and page summaries usually need no search. If a tool is denied, continue from available information without claiming verification.")
            var body: [String: Any] = [
                "model": model, "max_tokens": 4_096, "stream": true, "system": system, "messages": messages,
            ]
            if let _ = webTool, !summary, round < 4 {
                body["tools"] = [
                    [
                        "name": "search_web",
                        "description": "Search the public web with user approval. Never send private page details.",
                        "input_schema": [
                            "type": "object", "properties": ["query": ["type": "string"]], "required": ["query"],
                            "additionalProperties": false,
                        ],
                    ],
                    [
                        "name": "fetch_page",
                        "description":
                            "Read a public URL returned by search or named by the user, with approval. No cookies or authenticated content.",
                        "input_schema": [
                            "type": "object", "properties": ["url": ["type": "string"]], "required": ["url"],
                            "additionalProperties": false,
                        ],
                    ],
                ]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await account.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatGPTFailure.interrupted }
            guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode) }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
            else { throw ChatGPTFailure.interrupted }
            var stream = ClaudeStream()
            var totalBytes = 0
            var last = Date.distantPast
            for try await line in bytes.lines {
                try Task.checkCancellation()
                totalBytes += line.utf8.count
                guard totalBytes <= 2_000_000 else { throw ChatGPTFailure.interrupted }
                guard line.hasPrefix("data:") else { continue }
                try stream.receive(Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))
                if Date().timeIntervalSince(last) >= 0.05, !stream.text.isEmpty {
                    update((accumulated.isEmpty ? "" : accumulated + "\n\n") + stream.text)
                    last = Date()
                }
                if stream.stopped { break }
            }
            try stream.validateCompletion()
            accumulated += (accumulated.isEmpty || stream.text.isEmpty ? "" : "\n\n") + stream.text
            update(accumulated)
            let calls = stream.content.filter { $0["type"] as? String == "tool_use" }
            guard !calls.isEmpty else {
                guard !accumulated.isEmpty else { throw ChatGPTFailure.interrupted }
                return
            }
            guard !summary, round < 4, calls.count <= 4, let webTool else { throw ChatGPTFailure.interrupted }
            messages.append(["role": "assistant", "content": stream.content])
            var results: [[String: Any]] = []
            var usedIDs = Set<String>()
            for call in calls {
                guard let id = call["id"] as? String, !id.isEmpty, id.count <= 200, usedIDs.insert(id).inserted,
                    let name = call["name"] as? String, ["search_web", "fetch_page"].contains(name),
                    let args = call["input"] as? [String: Any],
                    let value = args[name == "search_web" ? "query" : "url"] as? String,
                    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 2_000
                else { throw ChatGPTFailure.interrupted }
                let result = try await webTool(name, value)
                results.append(["type": "tool_result", "tool_use_id": id, "content": result])
            }
            messages.append(["role": "user", "content": results])
        }
        throw ChatGPTFailure.interrupted
    }
}

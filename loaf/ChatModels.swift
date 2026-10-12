import Foundation
import SwiftUI

nonisolated struct ChatModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var acceptsImages = false
    var reasoningEfforts: [String] = []
    static func efforts(id: String, metadata: [String: Any]) -> [String] {
        let supported = ["none", "minimal", "low", "medium", "high", "xhigh"]
        if let values = metadata["supported_reasoning_efforts"] as? [String] {
            return supported.filter(values.contains)
        }
        if id.hasPrefix("o3") || id.hasPrefix("o4-mini") { return ["low", "medium", "high"] }
        if id.hasPrefix("gpt-5"), !id.contains("chat"), !id.contains("pro"), !id.contains("codex") {
            return ["low", "medium", "high"]
        }
        return []
    }

    static func catalog(_ values: [[String: Any]]) -> [ChatModel] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard value["visibility"] == nil || value["visibility"] as? String == "list",
                let id = value["slug"] as? String ?? value["id"] as? String,
                !id.isEmpty, id.count <= 200,
                id.unicodeScalars.allSatisfy({
                    CharacterSet.alphanumerics.contains($0) || "-._:/".unicodeScalars.contains($0)
                }),
                seen.insert(id).inserted
            else { return nil }
            let name = (value["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatModel(
                id: id, name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? id,
                acceptsImages: (value["input_modalities"] as? [String])?.contains("image") == true,
                reasoningEfforts: efforts(id: id, metadata: value))
        }
    }
}

struct ChatModelPicker: View {
    @ObservedObject var account: ChatGPTAccount
    var body: some View {
        Picker(
            "model",
            selection: Binding<String?>(
                get: { account.selectedModelID },
                set: { id in
                    if let id { account.selectModel(id) }
                })
        ) {
            if account.selectedModel == nil {
                Text(account.selectedModelID ?? (account.checkingModels ? "loading models…" : "choose a model"))
                    .tag(account.selectedModelID)
            }
            ForEach(account.models) { model in Text(model.name).tag(Optional(model.id)) }
        }
        .disabled(account.models.isEmpty || account.disconnecting)
        .help("models listed by your ChatGPT account; access is checked when you send")
    }
}

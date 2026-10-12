import SwiftUI

struct ChatConnectionRecovery: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var store: BrowserStore
    var body: some View {
        if !session.available && !session.turns.isEmpty && store.preferences.aiFeaturesEnabled != false {
            HStack {
                Text(
                    AppleIntelligence.unavailableReason(for: session.provider)
                        ?? "reconnect \(session.provider.title) to continue this chat."
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("intelligence settings…") {
                    store.application.coordinator?.showSettings(for: store, section: "intelligence")
                }
            }.font(.system(size: 12)).controlSize(.small)
        }
    }
}

struct AISettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var account: ChatGPTAccount
    @ObservedObject var claude: ClaudeAccount
    private func preference<Value>(_ key: WritableKeyPath<BrowserPreferences, Value?>, fallback: Value) -> Binding<
        Value
    > {
        Binding(
            get: { store.preferences[keyPath: key] ?? fallback },
            set: {
                store.preferences[keyPath: key] = $0
                store.persistSoon()
            })
    }
    private var summaryProvider: AIProvider { PageSummary.provider(preferences: store.preferences) }
    var body: some View {
        Section("answers in loaf") {
            Toggle(
                "intelligence features",
                isOn: Binding(
                    get: { store.preferences.aiFeaturesEnabled != false },
                    set: { store.application.setAIFeaturesEnabled($0) }
                )
            ).id("ai-features")
            Picker("answer provider", selection: preference(\.aiProvider, fallback: .chatgpt)) {
                ForEach(AppleIntelligence.visibleProviders, id: \.self) { Text($0.title).tag($0) }
            }.disabled(store.preferences.aiFeaturesEnabled == false)
            if let reason = AppleIntelligence.unavailableReason(for: store.preferences.aiProvider ?? .chatgpt) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "choose the provider for chat and answers inside loaf. the alternate search shortcut has its own provider in search settings."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("page summaries") {
            Picker(
                "summary provider",
                selection: Binding<AIProvider?>(
                    get: { store.preferences.summaryProvider },
                    set: {
                        store.preferences.summaryProvider = $0
                        store.preferences.summaryModelID = nil
                        store.persistSoon()
                    })
            ) {
                Text("automatic · Apple Intelligence or Luna").tag(Optional<AIProvider>.none)
                ForEach([AIProvider.onDevice, .chatgpt, .claude], id: \.self) { Text($0.title).tag(Optional($0)) }
            }.id("summaries")
            if summaryProvider == .chatgpt || summaryProvider == .claude {
                let models = summaryProvider == .chatgpt ? account.models : claude.models
                Picker(
                    "summary model",
                    selection: Binding<String?>(
                        get: { store.preferences.summaryModelID },
                        set: {
                            store.preferences.summaryModelID = $0
                            store.persistSoon()
                        })
                ) {
                    Text(summaryProvider == .chatgpt ? "Luna (default)" : "default Claude model").tag(
                        Optional<String>.none)
                    if let saved = store.preferences.summaryModelID, !models.contains(where: { $0.id == saved }) {
                        Text(saved + " · unavailable").tag(Optional(saved))
                    }
                    ForEach(models) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let reason = AppleIntelligence.unavailableReason(for: summaryProvider) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "summarize the current page from side chat or the View menu. automatic uses Apple Intelligence on this Mac when available, otherwise Luna through your ChatGPT connection. summary models are independent of the chat model."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.disabled(store.preferences.aiFeaturesEnabled == false)
        if store.preferences.aiFeaturesEnabled != false {
            Section("ChatGPT connection") {
                ChatGPTConnectionView(account: account).id("chatgpt-connection")
                    .onAppear { if account.models.isEmpty { account.refreshCatalog() } }
            }
            Section("Claude connection") {
                ClaudeConnectionView(account: claude).id("claude-connection")
            }
            Section("saved chats") {
                Toggle("sync chat transcripts with iCloud", isOn: preference(\.syncSideChats, fallback: false)).id(
                    "saved-chats")
                Text(
                    "chats are encrypted on this Mac with a Keychain key. sync requires iCloud sync and iCloud Keychain. image attachments stay on this Mac. private chats are never saved."
                )
                .font(.caption).foregroundStyle(.secondary)
                if store.preferences.syncSideChats == true && !store.application.cloudSync.enabled {
                    Text("enable iCloud sync to sync chats").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

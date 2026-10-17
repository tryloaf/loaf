import SwiftUI

struct AIRouteSettings: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var accounts: ChatGPTAccounts
    @ObservedObject var claude: ClaudeAccount
    var quickSearch: Bool

    private var provider: Binding<AIProvider?> {
        Binding(
            get: { quickSearch ? store.preferences.quickSearchProvider : store.preferences.aiProvider },
            set: {
                if quickSearch {
                    store.preferences.quickSearchProvider = $0
                    store.preferences.quickSearchModelID = nil
                } else {
                    store.preferences.aiProvider = $0
                    store.preferences.sideChatModelID = nil
                }
                store.persistSoon()
            })
    }
    private var model: Binding<String?> {
        Binding(
            get: { quickSearch ? store.preferences.quickSearchModelID : store.preferences.sideChatModelID },
            set: {
                if quickSearch {
                    store.preferences.quickSearchModelID = $0
                } else {
                    store.preferences.sideChatModelID = $0
                }
                store.persistSoon()
            })
    }
    private var account: ChatGPTAccount {
        accounts.account(id: quickSearch ? store.preferences.quickSearchAccountID : store.preferences.sideChatAccountID)
    }
    var body: some View {
        Picker(quickSearch ? "quick search provider" : "side chat provider", selection: provider) {
            Text("automatic").tag(Optional<AIProvider>.none)
            ForEach(AppleIntelligence.visibleProviders, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        if let chosen = provider.wrappedValue, chosen == .chatgpt || chosen == .claude {
            let models = chosen == .chatgpt ? account.models : claude.models
            Picker("model", selection: model) {
                Text("account default").tag(Optional<String>.none)
                if let saved = model.wrappedValue, !models.contains(where: { $0.id == saved }) {
                    Text(saved + " · unavailable").tag(Optional(saved))
                }
                ForEach(models) { Text($0.name).tag(Optional($0.id)) }
            }.onAppear { account.refreshCatalog() }
        }
    }
}

struct ChatGPTAccountSettings: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var accounts: ChatGPTAccounts

    private func rule(_ label: String, key: WritableKeyPath<BrowserPreferences, String?>) -> some View {
        Picker(
            label,
            selection: Binding<String?>(
                get: { store.preferences[keyPath: key] },
                set: {
                    store.preferences[keyPath: key] = $0
                    if key == \BrowserPreferences.quickSearchAccountID { store.preferences.quickSearchModelID = nil }
                    if key == \BrowserPreferences.sideChatAccountID { store.preferences.sideChatModelID = nil }
                    if key == \BrowserPreferences.summaryAccountID { store.preferences.summaryModelID = nil }
                    store.persistSoon()
                })
        ) {
            Text("first connected account").tag(Optional<String>.none)
            if let saved = store.preferences[keyPath: key],
                !accounts.accounts.contains(where: { $0.connectionID == saved })
            {
                Text("connection unavailable on this Mac").tag(Optional(saved))
            }
            ForEach(Array(accounts.accounts.enumerated()), id: \.element.connectionID) { index, account in
                Text((account.email ?? "account \(index + 1)") + (account.connected ? "" : " · disconnected"))
                    .tag(Optional(account.connectionID))
            }
        }
    }
    var body: some View {
        ForEach(accounts.accounts, id: \.connectionID) { account in
            VStack(alignment: .leading, spacing: 10) {
                ChatGPTConnectionView(account: account, showModel: false)
                    .onAppear { account.refreshCatalog() }
                if account !== accounts.accounts.first && account.canForgetConnection {
                    Button("remove connection") {
                        guard accounts.remove(account) else { return }
                        if store.preferences.quickSearchAccountID == account.connectionID {
                            store.preferences.quickSearchAccountID = nil
                        }
                        if store.preferences.sideChatAccountID == account.connectionID {
                            store.preferences.sideChatAccountID = nil
                        }
                        if store.preferences.summaryAccountID == account.connectionID {
                            store.preferences.summaryAccountID = nil
                        }
                        store.persistSoon()
                    }
                }
            }
        }
        Button("add ChatGPT account") { accounts.add() }
            .disabled(accounts.accounts.contains { $0.connecting || $0.disconnecting })
        Text(
            "choose a different account on the ChatGPT sign-in page. credentials stay in Keychain. questions and approved context go to OpenAI through the assigned account."
        )
        .font(.caption).foregroundStyle(.secondary)
        Group {
            rule("quick search account", key: \.quickSearchAccountID)
            rule("side chat account", key: \.sideChatAccountID)
            rule("page summary account", key: \.summaryAccountID)
        }.id("chatgpt-account-rules")
        Text(
            "these rules apply when ChatGPT is used. an assigned account must be connected; usage limits belong to your ChatGPT plan or credits."
        )
        .font(.caption).foregroundStyle(.secondary)
    }
}

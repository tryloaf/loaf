import Combine
import Foundation

/// Connection IDs stay on this Mac. Tokens are held separately in Keychain by each account.
@MainActor final class ChatGPTAccounts: ObservableObject {
    @Published private(set) var accounts: [ChatGPTAccount]
    let didChange = PassthroughSubject<Void, Never>()
    private let makeAccount: (String) -> ChatGPTAccount
    private let defaults: UserDefaults
    private var missingAccounts: [String: ChatGPTAccount] = [:]
    private var observations = Set<AnyCancellable>()

    init(primary: ChatGPTAccount, defaults: UserDefaults = .standard, makeAccount: ((String) -> ChatGPTAccount)? = nil)
    {
        self.defaults = defaults
        let make = makeAccount ?? { ChatGPTAccount(connectionID: $0) }
        self.makeAccount = make
        let ids = defaults.stringArray(forKey: "loaf.chatgpt.connections") ?? []
        var seen = Set<String>()
        accounts =
            [primary]
            + ids.filter { seen.insert($0).inserted }.compactMap { id in
                guard UUID(uuidString: id) != nil else { return nil }
                return make(id)
            }
        observeAccounts()
    }

    func account(id: String?) -> ChatGPTAccount {
        // An explicit rule never silently sends a request to a different account.
        if let id {
            if let account = accounts.first(where: { $0.connectionID == id }) { return account }
            if let account = missingAccounts[id] { return account }
            let unavailable = ChatGPTAccount(persistCredentials: false, connectionID: id)
            missingAccounts[id] = unavailable
            return unavailable
        }
        return accounts.first(where: { $0.connected && !$0.disconnecting }) ?? accounts[0]
    }

    func add() {
        guard !accounts.contains(where: { $0.connecting || $0.disconnecting }) else { return }
        let account = makeAccount(UUID().uuidString)
        accounts.append(account)
        defaults.set(accounts.dropFirst().map(\.connectionID), forKey: "loaf.chatgpt.connections")
        observeAccounts()
        account.connect()
    }

    func remove(_ account: ChatGPTAccount) -> Bool {
        guard accounts.contains(where: { $0 === account }), account !== accounts.first, account.forgetConnection()
        else { return false }
        accounts.removeAll { $0 === account }
        defaults.set(accounts.dropFirst().map(\.connectionID), forKey: "loaf.chatgpt.connections")
        observeAccounts()
        didChange.send()
        return true
    }
    private func observeAccounts() {
        observations.removeAll()
        for account in accounts {
            account.objectWillChange.sink { [weak self] in
                // Published values are committed before consumers resolve their routes.
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                    self?.didChange.send()
                }
            }.store(in: &observations)
        }
    }
}

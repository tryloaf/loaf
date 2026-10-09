import Combine
import CryptoKit
import Foundation
import WebKit

@MainActor final class ContentBlocker: ObservableObject {
    @Published var ruleLists: [WKContentRuleList] = []
    @Published var domainCount = 0
    @Published var error: String?
    @Published var updating = false
    private let chunkSize = 35_000
    private let defaults = UserDefaults.standard

    func prepare() async {
        do {
            guard let url = Bundle.main.url(forResource: "adblock-domains", withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let bundled = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            let saved = defaults.stringArray(forKey: "loaf.blocker.domains.v2")
            let domains = saved.flatMap { $0.count > 1000 ? $0 : nil } ?? bundled
            ruleLists = try await compile(domains)
            domainCount = domains.count
        } catch { self.error = "Ad blocking could not start: \(error.localizedDescription)" }
    }

    func update() async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let (data, response) = try await URLSession.shared.data(
                from: URL(string: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 12_000_000,
                let source = String(data: data, encoding: .utf8)
            else { throw URLError(.badServerResponse) }
            let domains = AdBlockDomains.parse(source)
            guard domains.count > 1000 else { throw URLError(.cannotParseResponse) }
            let replacement = try await compile(domains)
            ruleLists = replacement
            domainCount = domains.count
            error = nil
            defaults.set(domains, forKey: "loaf.blocker.domains.v2")
        } catch {
            self.error = "Couldn’t update filters. The previous list is still active. \(error.localizedDescription)"
        }
    }

    private func compile(_ domains: [String]) async throws -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        for offset in stride(from: 0, to: domains.count, by: chunkSize) {
            let chunk = Array(domains[offset..<min(offset + chunkSize, domains.count)])
            let digest = SHA256.hash(data: Data(chunk.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }
                .joined()
            let identifier = "loaf-adguard-v2-" + String(digest.prefix(20))
            if let cached = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: identifier) {
                lists.append(cached)
                continue
            }
            guard
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: AdBlockDomains.rules(chunk))
            else { throw CocoaError(.coderInvalidValue) }
            lists.append(list)
        }
        return lists
    }
}

import Combine
import Foundation

@MainActor final class TopLevelDomains {
    static let shared = TopLevelDomains()
    static let source = URL(string: "https://data.iana.org/TLD/tlds-alpha-by-domain.txt")!
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    let changes = PassthroughSubject<Void, Never>()
    private(set) var domains = IANASeed.domains
    private var updated: Date?
    private var loadedFile: URL?
    private var refreshing = false
    private var task: Task<Void, Never>?
    private let fetch: (URL) async throws -> Data
    private struct Snapshot: Codable {
        let updated: Date
        let text: String
    }

    init(fetch: @escaping (URL) async throws -> Data = { try await AssetRequest.data($0, limit: 100_000) }) {
        self.fetch = fetch
    }

    func start(directory: URL) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(directory: directory)

                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
    }

    func refresh(directory: URL, at now: Date = Date()) async {
        let file = directory.appendingPathComponent("iana-tlds.json")
        if loadedFile != file {
            loadedFile = file
            updated = nil
            if let data = try? Data(contentsOf: file), data.count <= 200_000,
                let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                snapshot.updated <= now, let parsed = Self.parse(Data(snapshot.text.utf8))
            {
                replace(with: parsed)
                updated = snapshot.updated
            }
        }
        guard !refreshing, updated.map({ now.timeIntervalSince($0) < Self.refreshInterval }) != true else { return }
        refreshing = true
        defer { refreshing = false }
        guard let data = try? await fetch(Self.source), !Task.isCancelled,
            let parsed = Self.parse(data), let text = String(data: data, encoding: .utf8)
        else { return }
        replace(with: parsed)
        updated = now
        try? JSONEncoder().encode(Snapshot(updated: now, text: text)).write(to: file, options: .atomic)
    }

    private func replace(with parsed: Set<String>) {
        guard domains != parsed else { return }
        domains = parsed
        changes.send()
    }

    nonisolated static func parse(_ data: Data) -> Set<String>? {
        guard data.count <= 100_000, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0.isNewline })
        guard let header = lines.first, header.hasPrefix("# Version "),
            let version = header.dropFirst(10).split(separator: ",").first,
            version.count == 10, version.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        let entries = lines.dropFirst().filter { !$0.hasPrefix("#") }
        guard entries.allSatisfy({ BrowserAddress.isDNSLabel(String($0).lowercased()) }) else { return nil }
        let parsed = Set(entries.map { $0.lowercased() })

        guard parsed.count >= 1000, parsed.count == entries.count,
            ["com", "org", "net", "edu", "uk", "de"].allSatisfy(parsed.contains)
        else { return nil }
        return parsed
    }
}

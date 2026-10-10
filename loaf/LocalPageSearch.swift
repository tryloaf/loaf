import Darwin
import Foundation
import NaturalLanguage

nonisolated enum LocalPageSearch {
    struct Text: Sendable {
        private let bytes: [UInt8]
        init(_ value: String) {
            bytes = Array(value.lowercased().precomposedStringWithCanonicalMapping.utf8)
        }
        func contains(_ pattern: [UInt8]) -> Bool {
            guard !pattern.isEmpty, pattern.count <= bytes.count else { return false }
            return bytes.withUnsafeBytes { source in
                pattern.withUnsafeBytes { needle in
                    memmem(source.baseAddress!, source.count, needle.baseAddress!, needle.count) != nil
                }
            }
        }
        func hasPrefix(_ pattern: [UInt8]) -> Bool {
            guard !pattern.isEmpty, pattern.count <= bytes.count else { return false }
            return bytes.withUnsafeBytes { source in
                pattern.withUnsafeBytes { needle in memcmp(source.baseAddress!, needle.baseAddress!, needle.count) == 0
                }
            }
        }
    }
    struct Query: Sendable {
        let text: String
        let terms: [[String]]
        let literal: [UInt8]
        let patterns: [[[UInt8]]]
        init(_ text: String, embedding: NLEmbedding? = nil) {
            self.text = text
            literal = Array(text.lowercased().precomposedStringWithCanonicalMapping.utf8)
            let words = LocalPageSearch.words(text)
            terms = words.map { word in
                let aliases = LocalPageSearch.aliases[word] ?? []
                guard word.count >= 4, let embedding, embedding.contains(word) else { return [word] + aliases }
                let related = embedding.neighbors(for: word, maximumCount: 4)
                    .filter { $0.1 <= 0.45 }.map(\.0)
                return [word] + aliases + related
            }
            patterns = terms.map { $0.map { Array($0.precomposedStringWithCanonicalMapping.utf8) } }
        }
    }
    struct Document: Sendable {
        let title: String
        let address: String
        let host: String
        private let corpus: String
        private let words: Set<String>
        init(title: String, address: String) {
            self.title = title.lowercased()
            self.address = address.lowercased()
            host = URL(string: address)?.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
            corpus = (title + " " + (address.removingPercentEncoding ?? address))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            words = Set(LocalPageSearch.words(corpus))
        }
        func score(_ query: Query) -> Double? {
            let text = query.text.lowercased()
            if text.isEmpty { return 0 }
            if host.hasPrefix(text) || address.hasPrefix(text) { return 120 }
            if title.hasPrefix(text) { return 100 }
            if (title as NSString).localizedCaseInsensitiveContains(query.text)
                || (address as NSString).localizedCaseInsensitiveContains(query.text)
            {
                return 45
            }
            guard !query.terms.isEmpty else { return nil }
            var semantic = false
            for alternatives in query.terms {
                if corpus.contains(alternatives[0]) { continue }
                guard alternatives.dropFirst().contains(where: { words.contains($0) }) else { return nil }
                semantic = true
            }
            return semantic ? 24 : 40
        }
    }
    private static let aliases: [String: [String]] = [
        "documentation": ["docs", "reference", "manual"], "docs": ["documentation", "reference", "manual"],
        "tutorial": ["guide", "tutorials", "walkthrough"], "guide": ["tutorial", "walkthrough"],
        "recipe": ["recipes", "cooking", "cookbook"], "recipes": ["recipe", "cooking", "cookbook"],
        "music": ["songs", "song", "audio"], "song": ["music", "songs"],
        "video": ["videos", "youtube"], "videos": ["video", "youtube"],
        "email": ["mail", "gmail", "outlook"], "mail": ["email", "gmail", "outlook"],
        "flight": ["flights", "airfare"], "flights": ["flight", "airfare"],
        "shopping": ["shop", "store", "buy"], "map": ["maps", "directions"],
        "maps": ["map", "directions"], "bookmark": ["bookmarks", "favorites"],
        "bookmarks": ["bookmark", "favorites"], "search": ["searches", "query"],
    ]
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

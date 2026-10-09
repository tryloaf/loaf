import AppKit
import Combine
import CryptoKit

enum AssetRequest {
    private static let transfers = AssetTransfers()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: transfers, delegateQueue: nil)
    }()
    static func data(_ url: URL, limit: Int = 1_000_000, timeout: TimeInterval = 8) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil, limit >= 0, limit <= 50_000_000 else {
            throw URLError(.unsupportedURL)
        }
        let transfer = AssetTransfer(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                let task = session.dataTask(with: request)
                transfers.register(transfer, task: task)
                if !transfer.start(task, continuation: continuation) { transfers.remove(task.taskIdentifier) }
            }
        } onCancel: {
            transfer.cancel()
        }
    }
}

@MainActor final class FaviconService {
    let directory: URL
    private var memory: [String: NSImage] = [:]
    private var order: [String] = []
    private var failures: [String: Date] = [:]
    private var privateGenerations: [UUID: Int] = [:]
    private let assets: FaviconAssets
    private let fetch: (URL) async throws -> Data
    private struct Pending {
        let id: UUID
        let task: Task<NSImage?, Never>
    }
    private var pending: [String: Pending] = [:]
    init(directory: URL, fetch: @escaping (URL) async throws -> Data = { try await AssetRequest.data($0) }) {
        self.directory = directory
        self.fetch = fetch
        assets = FaviconAssets(directory: directory)
    }

    func cachedImage(for url: URL, privateID: UUID? = nil) -> NSImage? {
        guard let origin = BrowserAddress.websiteOrigin(url) else { return nil }
        return memory[(privateID?.uuidString ?? "normal") + origin]
    }
    private func cacheFile(for origin: String) -> URL {
        directory.appendingPathComponent(
            SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    private func remember(_ image: NSImage, key: String) {
        memory[key] = image
        failures[key] = nil
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 512 { memory.removeValue(forKey: order.removeFirst()) }
    }

    func storedImage(for url: URL, privateID: UUID? = nil) async -> NSImage? {
        if let image = cachedImage(for: url, privateID: privateID) { return image }
        guard privateID == nil, let origin = BrowserAddress.websiteOrigin(url),
            let prepared = await assets.read(cacheFile(for: origin), allowExpired: true)
        else { return nil }
        if let image = cachedImage(for: url) { return image }
        let image = NSImage(
            cgImage: prepared.image, size: NSSize(width: prepared.image.width, height: prepared.image.height))
        remember(image, key: "normal" + origin)
        return image
    }
    func image(for url: URL, privateID: UUID? = nil, declared: [URL] = [], refresh: Bool = false, quick: Bool = false) async -> NSImage? {
        guard let origin = BrowserAddress.websiteOrigin(url) else { return nil }
        let key = (privateID?.uuidString ?? "normal") + origin
        let generation = privateID.map { privateGenerations[$0, default: 0] }
        func valid() -> Bool { privateID.map { privateGenerations[$0, default: 0] == generation } ?? true }
        if !refresh, let image = memory[key] { return image }
        if let request = pending[key] {
            let image = await request.task.value
            guard valid() else { return nil }
            if let image { return image }
            if pending[key]?.id == request.id { pending[key] = nil }
            if declared.isEmpty { return nil }
        }
        if declared.isEmpty, let failed = failures[key], Date().timeIntervalSince(failed) < 60 { return nil }
        let file = cacheFile(for: origin)
        let assets = assets
        let fetch = fetch
        let task = Task<NSImage?, Never> {
            func image(_ prepared: PreparedFavicon) -> NSImage {
                NSImage(
                    cgImage: prepared.image, size: NSSize(width: prepared.image.width, height: prepared.image.height))
            }
            if !refresh, privateID == nil, let prepared = await assets.read(file), !Task.isCancelled {
                return image(prepared)
            }
            var seen = Set<URL>()
            var fallback = URLComponents(string: origin)!
            fallback.scheme = "https"
            fallback.path = "/favicon.ico"
            if quick, declared.isEmpty, let candidate = fallback.url {
                seen.insert(candidate)
                if let data = try? await fetch(candidate), !Task.isCancelled,
                    let prepared = await assets.decode(data), !Task.isCancelled
                {
                    if privateID == nil { await assets.write(data, to: file) }
                    return image(prepared)
                }
            }
            let known =
                PublicSuffixList.shared.registrableDomain(url.host ?? "") == "reddit.com"
                ? [URL(string: "https://www.redditstatic.com/shreddit/assets/favicon/192x192.png")!] : []
            var discovered = declared
            if discovered.isEmpty, let pageURL = URL(string: origin), let data = try? await fetch(pageURL),
                data.count <= 512_000, !Task.isCancelled, let html = String(data: data, encoding: .utf8)
            {
                discovered = Self.declaredIcons(in: html, relativeTo: pageURL)
            }
            let candidates = (discovered + known).filter {
                $0.scheme == "https" && $0.user == nil && $0.password == nil && seen.insert($0).inserted
            }
            for candidate in candidates + (fallback.url.map { seen.contains($0) ? [] : [$0] } ?? []) {
                if Task.isCancelled { return nil }
                guard let data = try? await fetch(candidate), !Task.isCancelled,
                    let prepared = await assets.decode(data), !Task.isCancelled
                else { continue }
                if privateID == nil { await assets.write(data, to: file) }
                guard !Task.isCancelled else { return nil }
                return image(prepared)
            }
            return nil
        }
        let id = UUID()
        pending[key] = Pending(id: id, task: task)
        let result = await task.value
        if pending[key]?.id == id { pending[key] = nil }
        guard valid() else { return nil }
        if let result {
            remember(result, key: key)
        } else {
            if failures.count >= 512 { failures = failures.filter { Date().timeIntervalSince($0.value) < 60 } }
            if failures.count >= 512 { failures.removeAll() }
            failures[key] = Date()
        }
        return result
    }
    nonisolated static func declaredIcons(in html: String, relativeTo page: URL) -> [URL] {
        guard let links = try? NSRegularExpression(pattern: "<link\\b[^>]{0,4096}>", options: .caseInsensitive),
            let attributes = try? NSRegularExpression(
                pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        else { return [] }
        let text = html as NSString
        return links.matches(in: html, range: NSRange(location: 0, length: text.length)).prefix(64).compactMap {
            match in
            let tag = text.substring(with: match.range)
            let value = tag as NSString
            var fields: [String: String] = [:]
            for field in attributes.matches(in: tag, range: NSRange(location: 0, length: value.length)) {
                let range = (2...4).map { field.range(at: $0) }.first { $0.location != NSNotFound }!
                fields[value.substring(with: field.range(at: 1)).lowercased()] = value.substring(with: range)
                    .replacingOccurrences(of: "&amp;", with: "&")
            }
            let rel = (fields["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard
                rel.contains("icon") || rel.contains("apple-touch-icon")
                    || rel.contains("apple-touch-icon-precomposed"),
                let href = fields["href"], let url = URL(string: href, relativeTo: page)?.absoluteURL
            else { return nil }
            return url
        }
    }
    func forgetPrivate(_ id: UUID) {
        privateGenerations[id, default: 0] += 1
        for key in pending.keys.filter({ $0.hasPrefix(id.uuidString) }) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        memory = memory.filter { !$0.key.hasPrefix(id.uuidString) }
        failures = failures.filter { !$0.key.hasPrefix(id.uuidString) }
        order.removeAll { $0.hasPrefix(id.uuidString) }
    }
}

struct PopularSite: Codable, Hashable {
    let title: String
    let address: String
}
@MainActor final class PopularSites: ObservableObject {

    static let bundled = [
        PopularSite(title: "YouTube", address: "https://www.youtube.com/"),
        PopularSite(title: "Google", address: "https://www.google.com/"),
        PopularSite(title: "Reddit", address: "https://www.reddit.com/"),
        PopularSite(title: "Wikipedia", address: "https://www.wikipedia.org/"),
        PopularSite(title: "GitHub", address: "https://github.com/"),
        PopularSite(title: "Gmail", address: "https://mail.google.com/"),
        PopularSite(title: "Apple", address: "https://www.apple.com/"),
        PopularSite(title: "Amazon", address: "https://www.amazon.com/"),
        PopularSite(title: "Netflix", address: "https://www.netflix.com/"),
        PopularSite(title: "Spotify", address: "https://open.spotify.com/"),
        PopularSite(title: "Instagram", address: "https://www.instagram.com/"),
        PopularSite(title: "Discord", address: "https://discord.com/"),
        PopularSite(title: "Figma", address: "https://www.figma.com/"),
        PopularSite(title: "Notion", address: "https://www.notion.so/"),
        PopularSite(title: "Owen", address: "https://owen.uno/"),
        PopularSite(title: "Basic Apple Guy", address: "https://basicappleguy.com/"),
        PopularSite(title: "DuckDuckGo", address: "https://duckduckgo.com/"),
        PopularSite(title: "Bing", address: "https://www.bing.com/"),
        PopularSite(title: "Microsoft", address: "https://www.microsoft.com/"),
        PopularSite(title: "Apple Developer", address: "https://developer.apple.com/"),
        PopularSite(title: "MDN Web Docs", address: "https://developer.mozilla.org/"),
        PopularSite(title: "Swift", address: "https://www.swift.org/"),
        PopularSite(title: "Stack Overflow", address: "https://stackoverflow.com/"),
        PopularSite(title: "StackBlitz", address: "https://stackblitz.com/"),
        PopularSite(title: "CodePen", address: "https://codepen.io/"),
        PopularSite(title: "Framer", address: "https://www.framer.com/"),
        PopularSite(title: "Linear", address: "https://linear.app/"),
        PopularSite(title: "Canva", address: "https://www.canva.com/"),
        PopularSite(title: "Dropbox", address: "https://www.dropbox.com/"),
        PopularSite(title: "Google Drive", address: "https://drive.google.com/"),
        PopularSite(title: "Google Docs", address: "https://docs.google.com/"),
        PopularSite(title: "Zoom", address: "https://www.zoom.com/"),
        PopularSite(title: "ChatGPT", address: "https://chatgpt.com/"),
        PopularSite(title: "Claude", address: "https://claude.ai/"),
        PopularSite(title: "Proton", address: "https://proton.me/"),
        PopularSite(title: "Bluesky", address: "https://bsky.app/"),
        PopularSite(title: "LinkedIn", address: "https://www.linkedin.com/"),
        PopularSite(title: "Twitch", address: "https://www.twitch.tv/"),
        PopularSite(title: "Vimeo", address: "https://vimeo.com/"),
        PopularSite(title: "SoundCloud", address: "https://soundcloud.com/"),
        PopularSite(title: "eBay", address: "https://www.ebay.com/"),
        PopularSite(title: "PayPal", address: "https://www.paypal.com/"),
        PopularSite(title: "OpenStreetMap", address: "https://www.openstreetmap.org/"),
        PopularSite(title: "Internet Archive", address: "https://archive.org/"),
        PopularSite(title: "PBS", address: "https://www.pbs.org/"),
        PopularSite(title: "AP News", address: "https://apnews.com/"),
    ]
    @Published var entries = bundled
    private let fetch: (URL) async throws -> Data
    init(fetch: @escaping (URL) async throws -> Data = { try await AssetRequest.data($0) }) { self.fetch = fetch }
    private struct Catalog: Codable {
        var updated: Date
        var sites: [PopularSite]
    }
    func refresh(directory: URL, allowNetwork: Bool = false) async {
        let file = directory.appendingPathComponent("popular-sites.json")
        if let data = try? Data(contentsOf: file), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            merge(catalog.sites)
            if Date().timeIntervalSince(catalog.updated) < 604800 { return }
        }
        guard allowNetwork else { return }
        guard
            let data = try? await fetch(
                URL(
                    string:
                        "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/top-sites/records")!),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let records = json["data"] as? [[String: Any]]
        else { return }
        let sites = records.compactMap { record -> PopularSite? in
            guard (record["include_experiments"] as? [String] ?? []).isEmpty,
                (record["include_regions"] as? [String] ?? []).isEmpty,
                record["search_shortcut"] as? Bool != true,
                let address = record["url"] as? String, let url = URL(string: address), url.scheme == "https",
                url.user == nil,
                url.host != "addons.mozilla.org", let title = record["title"] as? String
            else { return nil }
            return PopularSite(title: title, address: address)
        }
        guard !sites.isEmpty else { return }
        merge(sites)
        try? JSONEncoder().encode(Catalog(updated: Date(), sites: sites)).write(to: file, options: .atomic)
    }
    private func merge(_ sites: [PopularSite]) {
        for site in sites
        where BrowserAddress.isSuggestedWebsite(URL(string: site.address))
            && !entries.contains(where: { URL(string: $0.address)?.host == URL(string: site.address)?.host })
        {
            entries.append(site)
        }
    }
}

struct PublicSuffixList {
    static let shared = PublicSuffixList()
    private let rules: Set<String>
    init(text: String? = nil) {
        let resource = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
        let source =
            text ?? resource.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "com\norg\nnet\nco.uk\ncom.au\nco.jp\ngithub.io"
        rules = Set(
            source.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty && !$0.hasPrefix("//")
            })
    }
    func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 1, !labels.allSatisfy({ Int($0) != nil }) else { return host }
        var suffixLength = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                suffixLength = labels.count - index - 1
                break
            }
            if rules.contains(suffix) { suffixLength = max(suffixLength, labels.count - index) }
            if index + 1 < labels.count && rules.contains("*." + labels[(index + 1)...].joined(separator: ".")) {
                suffixLength = max(suffixLength, labels.count - index)
            }
        }
        return labels.suffix(min(labels.count, suffixLength + 1)).joined(separator: ".")
    }
}

import AppKit
import ImageIO

@MainActor final class StartBackgroundCache {
    static let shared = StartBackgroundCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var pending: [URL: Task<Prepared?, Never>] = [:]
    private struct Prepared: @unchecked Sendable { let image: CGImage }
    init() {
        cache.countLimit = 3
        cache.totalCostLimit = 64_000_000
    }
    func image(for url: URL) async -> NSImage? {
        guard url.isFileURL else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        let task: Task<Prepared?, Never>
        if let existing = pending[url] {
            task = existing
        } else {
            task = Task.detached(priority: .utility) {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size > 0, size <= 20_000_000,
                    let data = try? Data(contentsOf: url), data.count <= 20_000_000,
                    let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4096,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary)
                else { return nil }
                return Prepared(image: image)
            }
            pending[url] = task
        }
        let prepared = await task.value
        pending[url] = nil

        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let prepared else { return nil }
        let image = NSImage(
            cgImage: prepared.image, size: NSSize(width: prepared.image.width, height: prepared.image.height))
        cache.setObject(image, forKey: url as NSURL, cost: prepared.image.bytesPerRow * prepared.image.height)
        return image
    }
}

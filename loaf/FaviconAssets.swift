import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated struct PreparedFavicon: @unchecked Sendable {
    let image: CGImage
}

actor FaviconAssets {
    let directory: URL
    private var pruneTask: Task<Void, Never>?
    init(directory: URL) { self.directory = directory }
    func read(_ file: URL, allowExpired: Bool = false) async -> PreparedFavicon? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= 1_000_000,
            (allowExpired || Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) < 604800),
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return nil }
        return await decode(data)
    }
    func decode(_ data: Data) async -> PreparedFavicon? {
        guard !data.isEmpty, data.count <= 1_000_000 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return await Self.decodeVector(data)
        }
        var best: (index: Int, pixels: Int)?
        for index in 0..<min(CGImageSourceGetCount(source), 32) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 16384, height <= 16384
            else { continue }
            let pixels = min(width, height, 128)
            if pixels > (best?.pixels ?? 0) { best = (index, pixels) }
        }
        guard let best,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, best.index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return await Self.decodeVector(data) }
        return Self.visibleImage(image)
    }
    nonisolated private static func visibleImage(_ image: CGImage) -> PreparedFavicon? {

        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self),
            stride(from: 3, to: image.width * image.height * 4, by: 4).contains(where: { pixels[$0] > 0 })
        else { return nil }
        return PreparedFavicon(image: image)
    }
    @MainActor private static func decodeVector(_ data: Data) -> PreparedFavicon? {
        guard data.count <= 128_000, let source = String(data: data, encoding: .utf8),
            source.range(of: "<svg[\\s>]", options: [.regularExpression, .caseInsensitive]) != nil,
            source.range(
                of:
                    "<!DOCTYPE|<!ENTITY|<script|<foreignObject|@import|(?:href|src)\\s*=\\s*[\"'](?!#)|url\\(\\s*[\"']?(?!#)",
                options: [.regularExpression, .caseInsensitive]) == nil,
            let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
            image.size.width <= 16_384, image.size.height <= 16_384,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = min(128 / image.size.width, 128 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: NSRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage.flatMap { visibleImage($0) }
    }
    func write(_ data: Data, to file: URL) {
        guard data.count <= 1_000_000 else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)

        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.prune()
        }
    }
    private func prune() {
        pruneTask = nil
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
        let entries = urls.map { url in
            (url, try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
        }
        .sorted { ($0.1?.contentModificationDate ?? .distantPast) > ($1.1?.contentModificationDate ?? .distantPast) }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1?.fileSize ?? 0
            if index >= 512 || bytes > 32_000_000 { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
    deinit { pruneTask?.cancel() }
}

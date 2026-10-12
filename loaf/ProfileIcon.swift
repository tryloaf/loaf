import AppKit
import SwiftUI

@MainActor enum ProfileIconAsset {
    private static let images = NSCache<NSData, NSImage>()

    static func image(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty, data.count <= 100_000 else { return nil }
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data), image.isValid else { return nil }
        images.countLimit = 64
        images.setObject(image, forKey: key)
        return image
    }

    static func importPNG(from url: URL) async throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["png", "svg"].contains(url.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        let decoder = FaviconAssets(directory: FileManager.default.temporaryDirectory)
        guard let prepared = await decoder.decode(data),
            let png = NSBitmapImageRep(cgImage: prepared.image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileReadCorruptFile) }
        return png
    }
}

struct ProfileIcon: View {
    let glyph: String
    let customIconPNG: Data?
    var size: CGFloat

    init(profile: Profile, size: CGFloat = 18) {
        self.init(glyph: profile.emoji, customIconPNG: profile.customIconPNG, size: size)
    }

    init(glyph: String, customIconPNG: Data?, size: CGFloat = 18) {
        self.glyph = glyph
        self.customIconPNG = customIconPNG
        self.size = size
    }

    var body: some View {
        Group {
            if let image = ProfileIconAsset.image(customIconPNG) {
                Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
            } else {
                EmojiIcon(glyph: glyph, size: size)
            }
        }.frame(width: size + 2, height: size + 2).accessibilityHidden(true)
    }
}

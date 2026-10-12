import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ChatImageAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let jpeg: Data
    var imageURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
    static let maximumCount = 4
    static let maximumFileBytes = 10_000_000
    static let maximumTotalBytes = 20_000_000
    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= maximumFileBytes else {
            throw ChatGPTFailure.message("choose an image smaller than 10 MB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
            ] as CFDictionary) else { throw ChatGPTFailure.message("this file isn’t a supported image.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileReadCorruptFile) }
        return Self(id: UUID(), name: url.lastPathComponent, jpeg: output as Data)
    }
}

struct ChatToolApprovalView: View {
    let request: ChatToolRequest
    let decide: (PageReadDecision) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.kind == "search_web" ? "allow web search?" : "allow site fetch?", systemImage: "network")
                .font(.system(size: 12, weight: .medium))
            Text(request.value).font(.system(size: 12)).textSelection(.enabled).lineLimit(3)
            Text(request.kind == "search_web" ? "this query will be sent to web search." : "loaf will read this public page without your cookies.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ChatApprovalActions(decide: decide)
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

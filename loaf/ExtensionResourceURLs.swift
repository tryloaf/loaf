import Foundation

enum ExtensionResourceURLs {
    static func normalize(in folder: URL, identifier: String) throws {

        let prefix = "webkit-extension://" + identifier.lowercased() + "/"
        let aliases = ["chrome-extension://" + identifier + "/", "chrome-extension://__MSG_@@extension_id__/"]
        guard
            let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        else { return }
        for case let file as URL in files where ["css", "html", "js"].contains(file.pathExtension.lowercased()) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000,
                var source = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let original = source
            for alias in aliases { source = source.replacingOccurrences(of: alias, with: prefix) }
            if original != source { try Data(source.utf8).write(to: file, options: .atomic) }
        }
    }
}

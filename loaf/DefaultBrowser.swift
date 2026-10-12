import AppKit

@MainActor enum DefaultBrowser {
    static func makeDefault() async throws {
        for scheme in ["https", "http"] {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    }
}

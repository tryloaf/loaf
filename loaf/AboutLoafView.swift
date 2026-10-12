import SwiftUI

struct AboutLoafView: View {
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var body: some View {
        VStack(spacing: 0) {
            Image("loaf-logo").resizable().scaledToFit().frame(width: 72, height: 72).accessibilityHidden(true)
            Image("loaf-word").resizable().scaledToFit().frame(width: 108, height: 42)
                .padding(.top, 12).accessibilityLabel("loaf")
            Text("a browser for Mac").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            Text("version \(version) · build \(build)").font(.system(size: 11)).foregroundStyle(.tertiary)
                .textSelection(.enabled).padding(.top, 6)
            HStack(spacing: 8) {
                Link("website", destination: BrowserBrand.website)
                Link("report a bug", destination: BrowserBrand.reportBug)
            }.buttonStyle(.bordered).controlSize(.small).padding(.top, 20)
            Button("check for updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
                .controlSize(.small).padding(.top, 10)
            Divider().padding(.vertical, 20)
            Text("designed and developed by").font(.system(size: 11)).foregroundStyle(.secondary)
            Link("owen van vooren", destination: BrowserBrand.authorWebsite)
                .font(.system(size: 12, weight: .medium)).padding(.top, 4)
            Link("source on github", destination: BrowserBrand.github)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
        }.padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 24).frame(width: 360)
            .frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

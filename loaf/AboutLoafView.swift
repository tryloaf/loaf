import SwiftUI

struct AboutLoafView: View {
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    private var versionLabel: String {
        ["version \(version)", BrowserBrand.releaseName(for: version), "build \(build)"]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(spacing: 0) {
            Image("loaf-logo").resizable().scaledToFit().frame(width: 72, height: 72).accessibilityHidden(true)
            Image("loaf-word").resizable().scaledToFit().frame(width: 108, height: 42)
                .padding(.top, 12).accessibilityLabel("loaf")
            Text("a browser for Mac").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            Text(versionLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                .textSelection(.enabled).padding(.top, 6)
            Button("check for updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
                .buttonStyle(.bordered).controlSize(.regular).padding(.top, 20)
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                Divider().padding(.bottom, 18)
                Text("designed and developed by")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Link(destination: BrowserBrand.authorWebsite) {
                    Text("owen van vooren").foregroundStyle(.primary)
                }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).padding(.top, 5)
                HStack(spacing: 14) {
                    footerLink("website", destination: BrowserBrand.website)
                    footerLink("report a bug", destination: BrowserBrand.reportBug)
                    footerLink("source", destination: BrowserBrand.github)
                        .accessibilityLabel("source on GitHub")
                }.font(.system(size: 11)).padding(.top, 18)
            }
        }.padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 24).frame(width: 360)
            .frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
    private func footerLink(_ title: String, destination: URL) -> some View {
        Link(destination: destination) { Text(title).foregroundStyle(.secondary) }
            .buttonStyle(.plain)
    }
}

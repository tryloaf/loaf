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

struct AboutBrowserContents: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 20) {
                    Image("loaf-logo").resizable().scaledToFit().frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("loaf").font(.system(size: 30, weight: .medium))
                        Text("a browser for Mac").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(["version \(version)", BrowserBrand.releaseName(for: version), "build \(build)"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Button("check for updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("inside loaf").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(BrowserPage.allCases.filter { $0 != .web && $0 != .about &&
                            ($0 != .ask || store.preferences.aiFeaturesEnabled != false) }, id: \.self) { page in
                            Button { store.showPage(page) } label: {
                                HStack(spacing: 12) {
                                    GolzheimIcon(icon: page.icon, size: 20).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(page.title).font(.system(size: 13, weight: .medium))
                                        Text(page.address).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    GolzheimIcon(icon: .forward, size: 12).foregroundStyle(.tertiary)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(LoafButtonStyle()).help(page.detail)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("designed and developed by").font(.system(size: 11)).foregroundStyle(.secondary)
                    Link("owen van vooren", destination: BrowserBrand.authorWebsite).font(.system(size: 13))
                    HStack(spacing: 18) {
                        Link("website", destination: BrowserBrand.website)
                        Link("report a bug", destination: BrowserBrand.reportBug)
                        Link("source", destination: BrowserBrand.github)
                    }.font(.system(size: 12))
                }.buttonStyle(.plain)
            }.frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
    }
}

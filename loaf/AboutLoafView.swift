import SwiftUI

struct AboutLoafView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var body: some View {
        VStack(spacing: 0) {
            Image("loaf-lockup").resizable().scaledToFit().frame(width: 208, height: 76).accessibilityLabel("loaf")
            Text("version " + version + " (" + build + ")").font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).padding(.top, 6)
            Link(destination: BrowserBrand.website) {
                HStack(spacing: 5) {
                    Text("tryloaf.app")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
            }.font(.system(size: 13, weight: .medium)).padding(.top, 20)
            Link("report a bug", destination: BrowserBrand.reportBug)
                .font(.system(size: 13, weight: .medium)).padding(.top, 12)
            Divider().padding(.vertical, 24)
            HStack(spacing: 16) {
                Link("owen van vooren", destination: BrowserBrand.authorWebsite)
                Spacer()
                Link("github", destination: BrowserBrand.github)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 32).padding(.top, 56).padding(.bottom, 28).frame(width: 360)
            .frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

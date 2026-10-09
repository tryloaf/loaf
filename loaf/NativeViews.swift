import AppKit
import SwiftUI

struct SiteIcon: View {
    @ObservedObject var tab: BrowserTab
    var size: CGFloat = 14
    var body: some View {
        Group {
            if let icon = tab.customIcon {
                EmojiIcon(glyph: icon, size: size)
            } else if let image = tab.favicon {
                Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size).clipShape(
                    RoundedRectangle(cornerRadius: max(2, size * 0.2)))
            } else {
                GolzheimIcon(icon: tab.page.icon, size: size)
            }
        }.accessibilityHidden(true)
    }
}
struct WebsiteIcon: View {
    let url: URL?
    @ObservedObject var store: BrowserStore
    var size: CGFloat = 16
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().clipShape(
                    RoundedRectangle(cornerRadius: max(2, size * 0.2)))
            } else {
                GolzheimIcon(icon: .globe, size: size).foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: "\(store.selectedProfileID):\(url?.absoluteString ?? "")") {
                image = nil
                guard let url, ["https", "http"].contains(url.scheme) else { return }
                let result = await store.application.favicons.image(
                    for: url, privateID: store.profile.privateMode ? store.selectedProfileID : nil)
                guard !Task.isCancelled else { return }
                image = result
            }
    }
}

struct ReaderView: View {
    @ObservedObject var tab: BrowserTab
    let article: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GolzheimIcon(icon: .book, size: 15)
                Text("reading view").font(.system(size: 12))
                Spacer()
                Button("done") { tab.exitReader() }.controlSize(.small)
            }.padding(.horizontal, 18).frame(height: 40).background(.regularMaterial)
            if let document = tab.readerDocument {
                ReaderHTMLView(document: document, tab: tab).id(document.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(tab.url?.host ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(tab.title).font(.system(size: 32, weight: .medium, design: .serif)).textSelection(.enabled)
                        Text(article).font(.system(size: 18, design: .serif)).lineSpacing(9).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: 660).padding(.horizontal, 40).padding(.vertical, 45).frame(maxWidth: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

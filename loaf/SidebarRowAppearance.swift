import SwiftUI

struct SidebarNewTabLabel: View {
    var pinTarget = false
    var body: some View {
        HStack(spacing: 4) {
            GolzheimIcon(icon: pinTarget ? .favorite : .plus, size: 12, weight: 220)
                .frame(width: 16, height: 16)
            Text(pinTarget ? "pin as tab" : "new tab")
            Spacer()
            if !pinTarget { Text("⌘T").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.font(.system(size: 13)).padding(.horizontal, 8).frame(height: 32)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8).padding(.bottom, 4)
    }
}

struct SidebarRowChrome: ViewModifier {
    let selected: Bool
    var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(hovered ? 0.06 : 0.025))
                .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 3, y: 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }.overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(selected ? 0.08 : 0.035))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
        }
    }
}

struct PinnedTileBackground: View {
    let selected: Bool
    var hovered = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill((scheme == .dark ? Color.white : Color.black).opacity(selected ? 0.12 : hovered ? 0.08 : 0.045))
    }
}

struct SiteIconContent: View {
    let glyph: String?
    let image: NSImage?
    let page: BrowserPage
    var size: CGFloat = 16
    var body: some View {
        Group {
            if let glyph { EmojiIcon(glyph: glyph, size: size) }
            else if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.2)))
            } else { GolzheimIcon(icon: page.icon, size: size) }
        }.accessibilityHidden(true)
    }
}

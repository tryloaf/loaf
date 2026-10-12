import AppKit
import SwiftUI

struct ChatComposerSurface<Content: View>: View {
    var focused: Bool
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(12)
            .background(scheme == .dark ? Color(white: 0.145) : .white,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(focused ? 0.22 : 0.09))
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.035), radius: 8, y: 3)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

struct ChatControlStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(Color.primary.opacity(selected ? (hovered ? 0.10 : 0.065) : enabled && hovered ? 0.055 : 0),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct ChatRemoveButton: View {
    let label: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GolzheimIcon(icon: .close, size: 11, weight: 240)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(ChatRemoveButtonStyle())
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

private struct ChatRemoveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovered ? Color.white : Color.red)
            .background(Color.red.opacity(hovered ? 0.9 : 0.10), in: Circle())
            .contentShape(Circle())
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct ChatAttachmentRow: View {
    let title: String
    let detail: String
    let icon: LoafIcon
    var thumbnail: NSImage? = nil
    var preview: (() -> Void)? = nil
    let removeLabel: String
    var removeHelp: String? = nil
    var canRemove = true
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let preview {
                Button(action: preview) { attachmentLabel }
                    .buttonStyle(.plain)
                    .help("preview the page text shared with this chat")
                    .accessibilityLabel("preview " + title)
            } else {
                attachmentLabel
            }
            ChatRemoveButton(label: removeLabel, help: removeHelp, action: remove)
                .disabled(!canRemove)
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045))
        }
    }

    private var attachmentLabel: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    GolzheimIcon(icon: icon, size: 15, weight: 220).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.045))
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

struct ChatAttachmentList<Content: View>: View {
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        if count <= 3 {
            content
        } else {
            GeometryReader { geometry in
                ScrollView {
                    content.frame(width: geometry.size.width)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: 144)
        }
    }
}

struct ChatSendButton: View {
    let busy: Bool
    let canSend: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous).frame(width: 12, height: 12)
                } else {
                    GolzheimIcon(icon: .up, size: 18, weight: 240)
                }
            }
                .foregroundStyle(busy || canSend
                    ? (scheme == .dark ? Color.black : .white) : Color.secondary.opacity(0.65))
                .frame(width: 32, height: 32)
                .background(busy || canSend ? Color.primary : Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(ChatControlStyle(cornerRadius: 16))
        .disabled(!busy && !canSend)
        .help(busy ? "stop answer" : "send question (return)")
        .accessibilityLabel(busy ? "stop answer" : "send question")
    }
}

struct ChatModelMenu: View {
    @ObservedObject var account: ChatGPTAccount
    let provider: AIProvider
    let changeProvider: (AIProvider) -> Void

    var body: some View {
        Menu {
            if account.connected {
                ForEach(account.models) { model in
                    Button {
                        changeProvider(.chatgpt)
                        account.selectModel(model.id)
                    } label: {
                        if provider == .chatgpt && account.selectedModelID == model.id {
                            Label { Text(model.name) } icon: { GolzheimIcon(icon: .check, size: 11) }
                        } else { Text(model.name) }
                    }
                }
                Button("refresh models") { account.refreshCatalog() }
            } else {
                Button("ChatGPT") { changeProvider(.chatgpt) }
            }
            if provider == .chatgpt, let model = account.selectedModel, !model.reasoningEfforts.isEmpty {
                Divider()
                Menu("thinking effort") {
                    Button("automatic") { account.reasoningEffort = nil }
                    ForEach(model.reasoningEfforts, id: \.self) { effort in
                        Button { account.reasoningEffort = effort } label: {
                            if account.reasoningEffort == effort { Label(effort, systemImage: "checkmark") }
                            else { Text(effort) }
                        }
                    }
                }
            }
            if AppleIntelligence.visibleProviders.contains(.onDevice) {
                Divider()
                Button(AIProvider.onDevice.title) { changeProvider(.onDevice) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(provider == .chatgpt ? account.modelName : provider.title)
                    .lineLimit(1).truncationMode(.middle)
                GolzheimIcon(icon: .disclosureDown, size: 10, weight: 220)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).frame(height: 32)
        }
        .menuStyle(.button).buttonStyle(ChatControlStyle()).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("chat model")
        .help("choose a model for new questions")
    }

}

struct ChatDraftEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    var enabled = true
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = DraftTextView(frame: .zero)
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 2, height: 5)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setAccessibilityLabel(placeholder)
        let scroll = DraftScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DraftTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text; view.invalidateIntrinsicContentSize() }
        view.placeholder = placeholder
        view.isEditable = enabled
        view.submit = submit
        view.focusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        view.needsDisplay = true
        scroll.needsLayout = true
        if focused && enabled && view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator, coordinator.parent.focused,
                      coordinator.parent.enabled, view.window != nil else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? 300
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 300
        let height = context.coordinator.measure(text, width: width)
        return .init(width: width, height: min(132, height))
    }
    final class DraftScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let view = documentView as? DraftTextView, let container = view.textContainer,
                  let manager = view.layoutManager, contentView.bounds.width > 0 else { return }
            let width = contentView.bounds.width
            container.containerSize = .init(width: max(1, width - 4), height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let bottom = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
            let size = NSSize(width: width, height: max(48, ceil(bottom) + 10))
            if view.frame.size != size { view.setFrameSize(size) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatDraftEditor
        private let measurementStorage = NSTextStorage()
        private let measurementManager = NSLayoutManager()
        private let measurementContainer = NSTextContainer()
        init(_ parent: ChatDraftEditor) {
            self.parent = parent
            super.init()
            measurementContainer.lineFragmentPadding = 0
            measurementStorage.addLayoutManager(measurementManager)
            measurementManager.addTextContainer(measurementContainer)
        }
        func measure(_ text: String, width: CGFloat) -> CGFloat {
            if measurementStorage.string != text {
                measurementStorage.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            }
            measurementContainer.containerSize = .init(width: max(1, width - 4), height: .greatestFiniteMagnitude)
            measurementManager.ensureLayout(for: measurementContainer)
            let bottom = max(measurementManager.usedRect(for: measurementContainer).maxY, measurementManager.extraLineFragmentRect.maxY)
            return max(48, ceil(bottom) + 10)
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? DraftTextView else { return }
            parent.text = view.string
            view.enclosingScrollView?.needsLayout = true
            view.needsDisplay = true
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
    final class DraftTextView: NSTextView {
        var placeholder = ""
        var submit: (() -> Void)?
        var focusChanged: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusChanged?(false) }
            return accepted
        }
        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
                let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
                if modifiers.isEmpty { submit?(); return }
                if modifiers == .shift { insertNewlineIgnoringFieldEditor(nil); return }
            }
            super.keyDown(with: event)
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty {
                (placeholder as NSString).draw(at: .init(x: 2, y: 5), withAttributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor
                ])
            }
        }
    }
}

struct ChatTranscriptEdge: View {
    let surface: Color
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.12), location: 0.25),
                        .init(color: .black.opacity(0.55), location: 0.65),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            LinearGradient(stops: [
                .init(color: surface.opacity(0), location: 0),
                .init(color: surface.opacity(0.1), location: 0.35),
                .init(color: surface.opacity(0.7), location: 0.8),
                .init(color: surface, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ChatApprovalActions: View {
    let decide: (PageReadDecision) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                action("allow", .allow, prominent: true)
                action("always allow for this chat", .allowAll)
                action("don’t allow", .deny)
            }.fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    action("allow", .allow, prominent: true)
                    action("don’t allow", .deny)
                }
                action("always allow for this chat", .allowAll)
            }
        }
    }
    private func action(_ title: String, _ decision: PageReadDecision, prominent: Bool = false) -> some View {
        Button { decide(decision) } label: {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(prominent ? (scheme == .dark ? Color.black : .white) : Color.primary)
                .background(prominent ? Color.primary : Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(ChatControlStyle())
    }
}

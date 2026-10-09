import AppKit
import SwiftUI

nonisolated enum SettingsNavigation {
    static let sections = [
        "general", "appearance", "search", "profiles", "websites", "privacy", "passwords", "extensions", "advanced",
    ]
    enum Shortcut: Equatable {
        case search
        case section(String)
    }
    static func shortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Shortcut? {
        guard modifiers.intersection([.command, .shift, .option, .control]) == .command, let characters else {
            return nil
        }
        if characters.lowercased() == "f" { return .search }
        guard characters.count == 1, let number = Int(characters), (1...min(9, sections.count)).contains(number) else {
            return nil
        }
        return .section(sections[number - 1])
    }
    static func adjacent(to section: String, direction: Int) -> String? {
        guard let index = sections.firstIndex(of: section), direction == -1 || direction == 1,
            sections.indices.contains(index + direction)
        else { return nil }
        return sections[index + direction]
    }
}

@MainActor private protocol FixedSettingsContent { func keepWindowSize() }
extension NSHostingView: FixedSettingsContent {
    fileprivate func keepWindowSize() { sizingOptions = [] }
}

@MainActor final class LoafSettingsWindow: NSWindow {

    private let titlebarMaterial = TitlebarMaterial()
    weak var titlebarContentAnchor: NSView?
    private var titlebarPromoted = false
    private var materialFrame = NSRect.zero
    func setTitlebarPromoted(_ promoted: Bool) {
        guard promoted != titlebarPromoted else { return }
        titlebarPromoted = promoted
        let destination = materialFrame.offsetBy(dx: 0, dy: promoted ? 0 : 6)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titlebarMaterial.animator().alphaValue = promoted ? 1 : 0
            titlebarMaterial.animator().frame = destination
        }
    }
    override var contentView: NSView? {
        didSet {
            (contentView as? FixedSettingsContent)?.keepWindowSize()
            contentMinSize = NSSize(width: 820, height: 680)
            contentMaxSize = contentMinSize
            titlebarMaterial.removeFromSuperview()
            updateTitlebarMaterial()
        }
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        updateTitlebarMaterial()
    }
    func updateTitlebarMaterial() {
        guard let contentView, let container = contentView.superview else { return }
        if titlebarMaterial.superview !== container {
            titlebarMaterial.removeFromSuperview()
            container.addSubview(titlebarMaterial, positioned: .above, relativeTo: contentView)
            titlebarMaterial.autoresizingMask = [.width, .minYMargin]
        }
        guard let anchor = titlebarContentAnchor, anchor.window === self, anchor.isDescendant(of: contentView),
            anchor.bounds.width > 0
        else {
            titlebarMaterial.frame = .zero
            return
        }
        let detail = contentView.convert(anchor.bounds, from: anchor)
        let leading = max(contentView.bounds.minX, detail.minX)
        let width = max(0, min(contentView.bounds.maxX, detail.maxX) - leading)
        let layout = contentView.convert(contentLayoutRect, from: nil)
        let height = max(
            0, contentView.isFlipped ? layout.minY - contentView.bounds.minY : contentView.bounds.maxY - layout.maxY)
        let next = container.convert(
            NSRect(
                x: leading, y: contentView.isFlipped ? contentView.bounds.minY : contentView.bounds.maxY - height,
                width: width, height: height), from: contentView)
        guard materialFrame != next else { return }
        materialFrame = next
        titlebarMaterial.frame = next.offsetBy(dx: 0, dy: titlebarPromoted ? 0 : 6)
    }
    private final class TitlebarMaterial: NSVisualEffectView {
        init() {
            super.init(frame: .zero)
            alphaValue = 0
            material = .titlebar
            blendingMode = .withinWindow
            state = .active
            identifier = .init("loaf.settings.titlebarMaterial")
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    weak var keyboardAnchor: SettingsKeyboardAnchor.AnchorView?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil,
            (firstResponder as? NSTextView)?.hasMarkedText() != true,
            let handler = keyboardAnchor?.handler,
            let shortcut = SettingsNavigation.shortcut(
                characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
        else { return super.performKeyEquivalent(with: event) }
        handler(shortcut)
        return true
    }
}

struct SettingsKeyboardAnchor: NSViewRepresentable {
    let handler: (SettingsNavigation.Shortcut) -> Void
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.handler = handler
        view.register()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.handler = nil }
    final class AnchorView: NSView {
        var handler: ((SettingsNavigation.Shortcut) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }
        func register() {
            if let window = window as? LoafSettingsWindow {
                window.keyboardAnchor = self
                window.updateTitlebarMaterial()
            }
        }
    }
}

import AppKit
import SwiftUI

struct OmnibarTextField: NSViewRepresentable {
    final class WeakField {
        weak var field: FocusField?
        init(_ field: FocusField) { self.field = field }
    }
    static var fields: [UUID: WeakField] = [:]
    static func isEditing(in windowID: UUID) -> Bool {
        guard let field = fields[windowID]?.field, let editor = field.currentEditor() else { return false }
        return editor === field.window?.firstResponder
    }
    var windowID: UUID? = nil
    @Binding var text: String
    var submit: () -> Void
    var alternateSubmit: ((NSEvent.ModifierFlags) -> Bool)? = nil
    var move: (Int) -> Void
    var cancel: () -> Void
    var complete: () -> Void
    var placeholder = "search or surf..."
    var fontSize: CGFloat = 17
    var bufferedInput = false
    var tracksOmnibar = true
    var inlineCompletion: String? = nil
    var actionPreview: String? = nil
    var suggestionPresentationChanged: ((String?) -> Void)? = nil
    var focusSnapshot: (() -> (text: String, select: Bool)?)? = nil
    var fadesOverflow = false
    var reduceMotion = false
    var monochromeSelection = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusField {
        let field = FocusField()
        field.selectOnFocus = !bufferedInput
        field.focusSnapshot = focusSnapshot
        field.alternateSubmit = tracksOmnibar ? alternateSubmit : nil
        field.fadesOverflow = fadesOverflow
        field.reduceMotion = reduceMotion
        field.monochromeSelection = monochromeSelection
        if tracksOmnibar, let windowID, focusSnapshot == nil || focusSnapshot?() != nil {
            Self.fields[windowID] = WeakField(field)
        }
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: fontSize)
        field.isBezeled = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.alignment = .left
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        return field
    }
    func updateNSView(_ field: FocusField, context: Context) {
        context.coordinator.parent = self
        field.alternateSubmit = tracksOmnibar ? alternateSubmit : nil
        field.fadesOverflow = fadesOverflow
        field.reduceMotion = reduceMotion
        field.monochromeSelection = monochromeSelection
        field.configureSelection()
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing && field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.offerCompletion(field)
        field.updateOverflowFade()
    }
    final class SuggestionOverlay: NSView {
        var suggestion = "" {
            didSet {
                needsDisplay = true
                updateTrailingFade()
            }
        }
        var startX: CGFloat = 0 {
            didSet {
                needsDisplay = true
                updateTrailingFade()
            }
        }
        var suggestionFont = NSFont.systemFont(ofSize: 17) {
            didSet {
                needsDisplay = true
                updateTrailingFade()
            }
        }
        private let trailingFade = CAGradientLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
            trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
            trailingFade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            updateTrailingFade()
        }
        private func updateTrailingFade() {
            let remainingWidth = bounds.maxX - startX
            let textWidth = (suggestion as NSString).size(withAttributes: [.font: suggestionFont]).width
            guard remainingWidth > 0, textWidth > remainingWidth + 0.5 else {
                layer?.mask = nil
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trailingFade.frame = bounds
            trailingFade.locations = [
                0, NSNumber(value: max(0, (bounds.width - min(20, remainingWidth)) / max(1, bounds.width))), 1,
            ]
            layer?.mask = trailingFade
            CATransaction.commit()
        }
        override func draw(_ dirtyRect: NSRect) {
            guard !suggestion.isEmpty, startX < bounds.maxX else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            let height = suggestionFont.ascender - suggestionFont.descender + suggestionFont.leading + 2
            NSAttributedString(
                string: suggestion,
                attributes: [
                    .font: suggestionFont,
                    .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7),
                    .paragraphStyle: paragraph,
                ]
            ).draw(
                with: NSRect(
                    x: startX, y: (bounds.height - height) / 2 + 1,
                    width: max(0, bounds.maxX - startX), height: height
                ), options: [.usesLineFragmentOrigin])
        }
    }
    final class FocusField: NSTextField {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
        var selectOnFocus = true
        var alternateSubmit: ((NSEvent.ModifierFlags) -> Bool)?
        var focusSnapshot: (() -> (text: String, select: Bool)?)?
        var fadesOverflow = false
        var reduceMotion = false
        var monochromeSelection = false
        private let suggestionOverlay = SuggestionOverlay()
        func showSuggestion(_ suffix: String?) {
            guard let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
                let suffix, !suffix.isEmpty
            else {
                suggestionOverlay.suggestion = ""
                suggestionOverlay.isHidden = true
                return
            }
            if suggestionOverlay.superview == nil {
                addSubview(suggestionOverlay, positioned: .above, relativeTo: nil)
                suggestionOverlay.frame = bounds
                suggestionOverlay.autoresizingMask = [.width, .height]
            }
            suggestionOverlay.suggestion = suffix
            suggestionOverlay.suggestionFont = editor.font ?? font ?? .systemFont(ofSize: 17)
            updateSuggestionPosition()
        }
        func updateSuggestionPosition() {
            guard !suggestionOverlay.suggestion.isEmpty,
                let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
                let window
            else {
                suggestionOverlay.isHidden = true
                return
            }
            let location = editor.string.utf16.count
            let caret = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            let x = convert(window.convertFromScreen(caret), from: nil).minX
            suggestionOverlay.startX = x
            suggestionOverlay.isHidden = x < 0 || x >= bounds.maxX
        }
        private weak var selectionEditor: NSTextView?
        private var originalSelectionAttributes: [NSAttributedString.Key: Any]?
        func configureSelection() {
            guard let editor = currentEditor() as? NSTextView else { return }
            if monochromeSelection {
                if selectionEditor !== editor {
                    restoreSelection()
                    selectionEditor = editor
                    originalSelectionAttributes = editor.selectedTextAttributes
                }
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(white: 0.38, alpha: 1), .foregroundColor: NSColor(white: 0.98, alpha: 1),
                ]
            } else {
                restoreSelection()
            }
        }
        private func restoreSelection() {
            if let editor = selectionEditor, let attributes = originalSelectionAttributes {
                editor.selectedTextAttributes = attributes
            }
            selectionEditor = nil
            originalSelectionAttributes = nil
        }
        override func textDidEndEditing(_ notification: Notification) {
            restoreSelection()
            showSuggestion(nil)
            super.textDidEndEditing(notification)
        }
        private(set) var overflowFadeVisible = false
        private var fadeMask: CAGradientLayer?
        private var previousMask: CALayer?
        private var clipWasLayerBacked = false
        private var didFocus = false
        private var clipObserver: NSObjectProtocol?
        private weak var observedClip: NSClipView?
        private var editorBaseline: CGFloat = 0
        func releaseEditorObservation() {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clipObserver = nil
            if let clip = observedClip, let mask = fadeMask, clip.layer?.mask === mask {
                clip.layer?.mask = previousMask
                if !clipWasLayerBacked { clip.wantsLayer = false }
            }
            fadeMask = nil
            previousMask = nil
            overflowFadeVisible = false
            observedClip = nil
        }
        deinit { releaseEditorObservation() }
        override func layout() {
            super.layout()
            updateOverflowFade()
        }
        func updateOverflowFade() {
            guard let clip = observedClip, currentEditor() === window?.firstResponder else { return }
            let visible = fadesOverflow && clip.bounds.minX > 0.5 && clip.bounds.width > 0
            guard visible || fadeMask != nil else { return }
            if fadeMask == nil {
                clipWasLayerBacked = clip.wantsLayer
                clip.wantsLayer = true
                previousMask = clip.layer?.mask
                let mask = CAGradientLayer()
                mask.startPoint = CGPoint(x: 0, y: 0.5)
                mask.endPoint = CGPoint(x: 1, y: 0.5)
                mask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
                clip.layer?.mask = mask
                fadeMask = mask
            }
            guard let mask = fadeMask else { return }
            let oldColors = mask.presentation()?.colors ?? mask.colors
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = clip.layer?.bounds ?? CGRect(origin: .zero, size: clip.bounds.size)
            mask.locations = [0, NSNumber(value: min(0.25, 14 / max(1, clip.bounds.width))), 1]
            mask.colors = [
                (visible ? NSColor.clear : NSColor.white).cgColor, NSColor.white.cgColor, NSColor.white.cgColor,
            ]
            CATransaction.commit()
            if reduceMotion { mask.removeAnimation(forKey: "overflowFade") }
            if visible != overflowFadeVisible {
                mask.removeAnimation(forKey: "overflowFade")
                if visible && !reduceMotion {
                    let animation = CABasicAnimation(keyPath: "colors")
                    animation.fromValue = oldColors
                    animation.toValue = mask.colors
                    animation.duration = 0.16
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    mask.add(animation, forKey: "overflowFade")
                }
                overflowFadeVisible = visible
            }
        }
        func revealCaretAfterEditing() {
            guard let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
                !editor.hasMarkedText(), let clip = observedClip
            else { return }
            if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
            let width = (editor.string as NSString).size(withAttributes: [
                .font: editor.font ?? font ?? NSFont.systemFont(ofSize: 14)
            ]).width
            if width + editor.textContainerInset.width * 2 + 4 <= clip.bounds.width {
                clip.scroll(to: NSPoint(x: 0, y: editorBaseline))
            } else {
                editor.scrollRangeToVisible(editor.selectedRange())
            }
            updateOverflowFade()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {

            if event.type == .keyDown, [36, 76].contains(event.keyCode),
                let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
                !editor.hasMarkedText(), alternateSubmit?(event.modifierFlags) == true
            {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didFocus else { return }
            if let focusSnapshot {
                guard let snapshot = focusSnapshot() else { return }
                stringValue = snapshot.text
                selectOnFocus = snapshot.select
            }
            didFocus = true
            window.makeFirstResponder(self)
            configureEditor()
            if selectOnFocus {
                selectText(nil)
            } else {
                (currentEditor() as? NSTextView)?.setSelectedRange(
                    NSRange(location: stringValue.utf16.count, length: 0))
            }
            configureSelection()
        }
        func configureEditor() {
            guard let editor = currentEditor() as? NSTextView else { return }
            configureSelection()
            editor.alignment = .left
            if let clip = (editor.superview as? NSClipView) ?? editor.enclosingScrollView?.contentView,
                observedClip !== clip
            {
                releaseEditorObservation()
                observedClip = clip
                editorBaseline = clip.bounds.minY
                clip.postsBoundsChangedNotifications = true
                clipObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self, weak clip, weak editor] _ in
                    MainActor.assumeIsolated {
                        guard let self, let clip, let editor, self.currentEditor() === editor,
                            self.window?.firstResponder === editor
                        else { return }
                        let x = max(0, clip.bounds.minX)
                        if abs(clip.bounds.minY - self.editorBaseline) > 0.01 || abs(clip.bounds.minX - x) > 0.01 {
                            clip.scroll(to: NSPoint(x: x, y: self.editorBaseline))
                        }
                        self.updateOverflowFade()
                        self.updateSuggestionPosition()
                    }
                }
            }
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.smartInsertDeleteEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.inlinePredictionType = .no
            editor.mathExpressionCompletionType = .no
            clearTextDecorations(editor)
            updateOverflowFade()
        }
        func clearTextDecorations(_ editor: NSTextView) {
            guard !editor.hasMarkedText() else { return }
            let range = NSRange(location: 0, length: editor.string.utf16.count)
            for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .spellingState, .link] {
                editor.textStorage?.removeAttribute(key, range: range)
                editor.layoutManager?.removeTemporaryAttribute(key, forCharacterRange: range)
                editor.typingAttributes.removeValue(forKey: key)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextField
        init(_ parent: OmnibarTextField) { self.parent = parent }
        private var reportedPresentation: String?
        private var presentationRevision = 0
        private var selectionObserver: NSObjectProtocol?
        private weak var observedEditor: NSTextView?
        private func observeSelection(_ field: FocusField) {
            guard let editor = field.currentEditor() as? NSTextView, observedEditor !== editor else { return }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            observedEditor = editor
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main
            ) { [weak self, weak field] _ in
                MainActor.assumeIsolated {
                    if let field { self?.offerCompletion(field) }
                }
            }
        }
        private func reportPresentation(_ value: String?) {
            guard value != reportedPresentation else { return }
            reportedPresentation = value
            presentationRevision += 1
            let revision = presentationRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentationRevision == revision else { return }
                self.parent.suggestionPresentationChanged?(value)
            }
        }
        func offerCompletion(_ field: FocusField) {
            guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText(),
                editor.string == parent.text, !parent.text.isEmpty
            else {
                field.showSuggestion(nil)
                reportPresentation(nil)
                return
            }
            observeSelection(field)
            let range = editor.selectedRange()
            guard range.length == 0, range.location == parent.text.utf16.count else {
                field.showSuggestion(nil)
                reportPresentation(nil)
                return
            }
            if let full = parent.inlineCompletion, full.hasPrefix(parent.text), full.count > parent.text.count {
                var tail = String(full.dropFirst(parent.text.count))
                if let title = parent.actionPreview, !title.isEmpty, title != full {
                    tail += "  –  " + title
                }
                field.showSuggestion(tail)
                reportPresentation(full)
            } else if let title = parent.actionPreview, !title.isEmpty {
                let tail =
                    title.lowercased().hasPrefix(parent.text.lowercased())
                    ? String(title.dropFirst(parent.text.count)) : "  –  " + title
                field.showSuggestion(tail)
                reportPresentation(title)
            } else {
                field.showSuggestion(nil)
                reportPresentation(nil)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? FocusField else { return }
            field.configureEditor()
            observeSelection(field)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = nil
            observedEditor = nil
            if let field = notification.object as? FocusField {
                field.releaseEditorObservation()
                field.showSuggestion(nil)
                reportPresentation(nil)
            }
        }
        deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? FocusField,
                parent.focusSnapshot == nil || parent.focusSnapshot?() != nil
            else { return }
            field.showSuggestion(nil)
            if let editor = field.currentEditor() as? NSTextView { field.clearTextDecorations(editor) }
            parent.text = field.stringValue
            field.revealCaretAfterEditing()
            reportPresentation(nil)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText(), parent.focusSnapshot == nil || parent.focusSnapshot?() != nil else {
                return false
            }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.tracksOmnibar, parent.alternateSubmit?(NSApp.currentEvent?.modifierFlags ?? []) == true {
                    return true
                }
                if !parent.tracksOmnibar && NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    parent.move(-1)
                } else {
                    parent.submit()
                }
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            case #selector(NSResponder.insertTab(_:)):
                let range = textView.selectedRange()
                guard range.length == 0, range.location == textView.string.utf16.count else { return false }
                if let full = parent.inlineCompletion, full.hasPrefix(parent.text),
                    full.count > parent.text.count
                {
                    parent.text = full
                    (control as? NSTextField)?.stringValue = full
                    textView.string = full
                    textView.setSelectedRange(NSRange(location: full.utf16.count, length: 0))
                } else {
                    parent.complete()
                }
            default: return false
            }
            return true
        }
    }
}

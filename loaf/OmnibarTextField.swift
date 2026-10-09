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
    var actionPreviewID: String? = nil
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
        if !composing && field.stringValue != text && !context.coordinator.hasSuffix && !context.coordinator.hasPreview
        {
            field.stringValue = text
        }
        context.coordinator.offerCompletion(field)
        field.updateOverflowFade()
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
        var pinsCompletionPrefix = false
        private var completionScrollOrigin: CGFloat = 0
        func pinCompletionPrefix(resetOrigin: Bool = false) {
            if resetOrigin {
                completionScrollOrigin = 0
            } else if !pinsCompletionPrefix {
                completionScrollOrigin = max(0, observedClip?.bounds.minX ?? 0)
            }
            pinsCompletionPrefix = true
        }
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
                        let x =
                            self.pinsCompletionPrefix && editor.selectedRange().length > 0
                            ? self.completionScrollOrigin : max(0, clip.bounds.minX)
                        if abs(clip.bounds.minY - self.editorBaseline) > 0.01 || abs(clip.bounds.minX - x) > 0.01 {
                            clip.scroll(to: NSPoint(x: x, y: self.editorBaseline))
                        }
                        self.updateOverflowFade()
                    }
                }
            }
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.smartInsertDeleteEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            updateOverflowFade()
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextField
        init(_ parent: OmnibarTextField) { self.parent = parent }
        var hasSuffix = false
        var hasPreview = false
        var rejectedPreviewID: String?

        var inlineSuggestionsDenied = false
        func offerCompletion(_ field: FocusField) {
            guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
            let range = editor.selectedRange()
            let prefixLength = parent.text.utf16.count
            let ownsPreview = hasPreview && range == NSRange(location: 0, length: editor.string.utf16.count)
            let selectingAllForAction =
                parent.actionPreview != nil && range == NSRange(location: 0, length: editor.string.utf16.count)
            let atEnd =
                ownsPreview || selectingAllForAction
                || (range.location == prefixLength
                    && (range.length == 0 || (hasSuffix && range.length == editor.string.utf16.count - prefixLength)))
            guard atEnd else {
                field.pinsCompletionPrefix = false
                return
            }
            if let preview = parent.actionPreview, let id = parent.actionPreviewID, id != rejectedPreviewID {
                field.pinCompletionPrefix(resetOrigin: true)
                if editor.string != preview {
                    field.stringValue = preview
                    editor.string = preview
                }
                editor.setSelectedRange(NSRange(location: 0, length: preview.utf16.count))
                editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
                hasPreview = true
                hasSuffix = false
                return
            }
            if hasPreview {
                field.pinsCompletionPrefix = false
                field.stringValue = parent.text
                editor.string = parent.text
                editor.setSelectedRange(NSRange(location: prefixLength, length: 0))
                hasPreview = false
            }
            guard !inlineSuggestionsDenied, let full = parent.inlineCompletion, full.hasPrefix(parent.text),
                full.utf16.count > prefixLength
            else {
                if hasSuffix {
                    field.pinsCompletionPrefix = false
                    field.stringValue = parent.text
                    editor.string = parent.text
                    editor.setSelectedRange(NSRange(location: prefixLength, length: 0))
                    hasSuffix = false
                }
                return
            }
            field.pinCompletionPrefix()
            if editor.string != full {
                field.stringValue = full
                editor.string = full
            }
            editor.setSelectedRange(NSRange(location: prefixLength, length: full.utf16.count - prefixLength))
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            hasSuffix = true
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? FocusField)?.configureEditor()
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? FocusField)?.releaseEditorObservation()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? FocusField,
                parent.focusSnapshot == nil || parent.focusSnapshot?() != nil
            else { return }
            field.pinsCompletionPrefix = false
            hasSuffix = false
            hasPreview = false
            rejectedPreviewID = nil
            parent.text = field.stringValue
            field.revealCaretAfterEditing()
        }
        func accept(_ control: NSControl, textView: NSTextView) {
            (control as? FocusField)?.pinsCompletionPrefix = false
            let range = textView.selectedRange()
            if hasPreview, range == NSRange(location: 0, length: textView.string.utf16.count), !textView.hasMarkedText()
            {
                hasPreview = false
                parent.text = textView.string
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
                return
            }
            let selectedSuffix =
                textView.string.hasPrefix(parent.text) && range.location == parent.text.utf16.count && range.length > 0
                && range.length == textView.string.utf16.count - parent.text.utf16.count
            guard selectedSuffix, !textView.hasMarkedText() else { return }
            hasSuffix = false
            parent.text = textView.string
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
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
                    accept(control, textView: textView)
                    parent.submit()
                }
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            case #selector(NSResponder.insertTab(_:)):
                let range = textView.selectedRange()
                let accepted =
                    (hasPreview && range == NSRange(location: 0, length: textView.string.utf16.count))
                    || (textView.string.hasPrefix(parent.text) && range.location == parent.text.utf16.count
                        && range.length > 0 && range.length == textView.string.utf16.count - parent.text.utf16.count)
                accept(control, textView: textView)
                if !accepted {
                    guard range.length == 0, range.location == textView.string.utf16.count else { return false }
                    parent.complete()
                }
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                #selector(NSResponder.moveLeft(_:)):
                let range = textView.selectedRange()
                if hasPreview, range == NSRange(location: 0, length: textView.string.utf16.count) {
                    guard command != #selector(NSResponder.moveLeft(_:)) else { return false }
                    hasPreview = false
                    rejectedPreviewID = parent.actionPreviewID
                    inlineSuggestionsDenied = true
                    (control as? FocusField)?.pinsCompletionPrefix = false
                    (control as? NSTextField)?.stringValue = parent.text
                    textView.string = parent.text
                    textView.setSelectedRange(NSRange(location: parent.text.utf16.count, length: 0))
                    (control as? FocusField)?.revealCaretAfterEditing()
                    return true
                }
                guard textView.string.hasPrefix(parent.text), range.location == parent.text.utf16.count,
                    range.length > 0, range.length == textView.string.utf16.count - parent.text.utf16.count
                else { return false }
                hasSuffix = false
                inlineSuggestionsDenied = true
                (control as? FocusField)?.pinsCompletionPrefix = false
                (control as? NSTextField)?.stringValue = parent.text
                textView.string = parent.text
                textView.setSelectedRange(NSRange(location: parent.text.utf16.count, length: 0))
                (control as? FocusField)?.revealCaretAfterEditing()
            default: return false
            }
            return true
        }
    }
}

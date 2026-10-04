import AppKit
import SwiftUI

/// The chat's text field: an `NSTextView` that sends on Return, grows from one line to eight, and
/// feeds the suggestion list. A SwiftUI `TextField` cannot see ↑/↓/Tab/Esc/⇧Tab, nor where the caret is.
struct IDEAgentComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let state: IDEAgentComposerState
    /// Bumped by the panel to take focus.
    let focusRequest: Int
    /// Bumped by the panel when a row of the suggestion list was clicked.
    let acceptRequest: Int
    let suggestions: (IDEAgentComposerTrigger) -> [IDEAgentSuggestion]
    let onSend: () -> Void
    let onStop: () -> Void
    var onCycleMode: (() -> Void)?
    /// A row with an action was accepted; the field has already been emptied.
    var onAccept: ((IDEAgentSuggestionPayload) -> Void)?
    /// `-1` for the previous prompt, `1` for the next; the text to show, or `nil` for none.
    var onHistory: ((Int) -> String?)?
    /// Text to insert for files dropped on the field (project-relative mentions).
    var onDropFiles: (([URL]) -> String)?

    static let maxLines = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = IDEAgentComposerTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([.fileURL])
        textView.placeholder = placeholder
        context.coordinator.textView = textView
        context.coordinator.applyAppearance()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if textView.string != text {
            // An outside change: Send cleared the draft, or something filled the composer.
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.textDidChangeProgrammatically()
        }
        textView.placeholder = placeholder
        coordinator.applyAppearance()
        if coordinator.lastAcceptRequest != acceptRequest {
            coordinator.lastAcceptRequest = acceptRequest
            _ = coordinator.acceptSuggestion()
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            // The window may not exist yet on the first pass.
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IDEAgentComposerField
        weak var textView: IDEAgentComposerTextView?
        var lastFocusRequest = 0
        var lastAcceptRequest = 0

        init(_ parent: IDEAgentComposerField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            lastAcceptRequest = parent.acceptRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            textDidChangeProgrammatically()
        }

        /// Everything that follows a change of text, however it came about.
        func textDidChangeProgrammatically() {
            guard let textView else { return }
            highlightTokens()
            refreshSuggestions()
            measureHeight()
            textView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshSuggestions()
        }

        // MARK: - Appearance

        func applyAppearance() {
            guard let textView else { return }
            let font = IDEUIFonts.nsFont(familyName: IDEUIFonts.currentFamilyName, size: IDEUIFonts.scaledSize(15))
            if textView.font != font {
                textView.font = font
                highlightTokens()
                measureHeight()
            }
            textView.insertionPointColor = IDEAppearance.NSToken.foreground
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: textView?.font ?? NSFont.systemFont(ofSize: 15),
                .foregroundColor: IDEAppearance.NSToken.foreground,
            ]
        }

        /// Colors `/command` and `@mention` words. The text itself is untouched: the model gets plain text.
        private func highlightTokens() {
            guard let textView, let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: whole)
            let accent = IDEAppearance.NSToken.accent
            if storage.string.hasPrefix("/") {
                let end = (storage.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines).location
                let length = end == NSNotFound ? storage.length : end
                storage.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 0, length: length))
            }
            for token in IDEAgentMentionToken.scan(storage.string) {
                storage.addAttribute(.foregroundColor, value: accent, range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
        }

        private func measureHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let font = textView.font ?? NSFont.systemFont(ofSize: 15)
            let line = layout.defaultLineHeight(for: font)
            let inset = textView.textContainerInset.height * 2
            let content = max(layout.usedRect(for: container).height, line) + inset
            let height = min(content, line * CGFloat(IDEAgentComposerField.maxLines) + inset)
            if abs(parent.height - height) > 0.5 {
                // Not inside a view update: this runs from text changes and from updateNSView's
                // own text sync, which SwiftUI would flag as a state change during a view update.
                DispatchQueue.main.async { [weak self] in self?.parent.height = height }
            }
        }

        // MARK: - Suggestions

        private func refreshSuggestions() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            let trigger: IDEAgentComposerTrigger = selection.length == 0
                ? .detect(in: textView.string, caret: selection.location) : .none
            parent.state.update(trigger: trigger, suggestions: parent.suggestions(trigger))
        }

        func acceptSuggestion() -> Bool {
            guard let textView, let suggestion = parent.state.selected, let range = parent.state.trigger.range else { return false }
            if let payload = suggestion.payload, let handler = parent.onAccept {
                textView.string = ""
                parent.text = ""
                textDidChangeProgrammatically()
                handler(payload)
                return true
            }
            // Through the text view, so the insertion is one undo step and the delegate hears about it.
            textView.insertText(suggestion.insertion, replacementRange: range)
            return true
        }

        // MARK: - Keys

        func handle(_ event: NSEvent, in textView: IDEAgentComposerTextView) -> Bool {
            let action = IDEAgentComposerKeyMap.action(
                keyCode: event.keyCode, modifiers: event.modifierFlags, context: context(for: textView))
            switch action {
            case .passThrough:
                return false
            case .send:
                parent.onSend()
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
            case .acceptSuggestion:
                if !acceptSuggestion() { return false }
            case .nextSuggestion:
                parent.state.move(by: 1)
            case .previousSuggestion:
                parent.state.move(by: -1)
            case .dismissSuggestions:
                parent.state.dismiss()
            case .stop:
                parent.onStop()
            case .cycleMode:
                guard let cycle = parent.onCycleMode else { return false }
                cycle()
            case .historyPrevious:
                return showHistory(-1, in: textView)
            case .historyNext:
                return showHistory(1, in: textView)
            }
            return true
        }

        private func showHistory(_ direction: Int, in textView: IDEAgentComposerTextView) -> Bool {
            guard let recalled = parent.onHistory?(direction) else { return false }
            textView.string = recalled
            textView.setSelectedRange(NSRange(location: (recalled as NSString).length, length: 0))
            parent.text = recalled
            textDidChangeProgrammatically()
            return true
        }

        private func context(for textView: IDEAgentComposerTextView) -> IDEAgentComposerKeyMap.Context {
            let selection = textView.selectedRange()
            let string = textView.string as NSString
            let before = string.substring(to: min(selection.location, string.length))
            let after = string.substring(from: min(selection.location + selection.length, string.length))
            return .init(
                suggestionsVisible: parent.state.isShowingSuggestions,
                caretOnFirstLine: !before.contains("\n"),
                caretOnLastLine: !after.contains("\n"),
                hasMarkedText: textView.hasMarkedText(),
                selectionIsEmpty: selection.length == 0)
        }

        // MARK: - Drops

        func dropped(_ urls: [URL], into textView: IDEAgentComposerTextView) -> Bool {
            guard let insertion = parent.onDropFiles?(urls), !insertion.isEmpty else { return false }
            textView.insertText(insertion, replacementRange: textView.selectedRange())
            return true
        }
    }
}

/// The `NSTextView` behind the composer: routes key presses through the key map, draws the
/// placeholder, and takes dropped files.
final class IDEAgentComposerTextView: NSTextView {
    weak var coordinator: IDEAgentComposerField.Coordinator?
    var placeholder = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    override func keyDown(with event: NSEvent) {
        if let coordinator, MainActor.assumeIsolated({ coordinator.handle(event, in: self) }) { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        placeholder.draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 15),
                .foregroundColor: IDEAppearance.NSToken.muted,
            ])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        if !urls.isEmpty, let coordinator, MainActor.assumeIsolated({ coordinator.dropped(urls, into: self) }) { return true }
        return super.performDragOperation(sender)
    }

    private static func fileURLs(in sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}

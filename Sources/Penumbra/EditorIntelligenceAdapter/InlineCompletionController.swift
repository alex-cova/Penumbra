@preconcurrency import AppKit
import EditorIntelligence

/// The key that accepts a whole inline suggestion.
public enum InlineAcceptKey: String, Sendable, CaseIterable {
    case tab
    case rightArrow
    case enter

    public var title: String {
        switch self {
        case .tab: return "Tab"
        case .rightArrow: return "→"
        case .enter: return "Enter"
        }
    }
}

/// Host settings for full-line (inline) completion.
public struct InlineCompletionSettings: Sendable, Equatable {
    public var isEnabled = false
    /// Languages with validation-grade suggestions; others get none unless listed in
    /// `otherLanguageIDs` too. Java is on by default, everything else off.
    public var languageIDs: Set<String> = ["java"]
    public var otherLanguagesEnabled = false
    public var multiLineEnabled = false
    public var syncWithPopup = false
    public var acceptKey: InlineAcceptKey = .tab

    public init() {}

    public func isEnabled(for languageID: String?) -> Bool {
        guard isEnabled else { return false }
        if let languageID, languageIDs.contains(languageID) { return true }
        return otherLanguagesEnabled
    }
}

/// Drives one inline (ghost text) suggestion at a time for an
/// ``EditorIntelligenceController``: idle scheduling, typing through, acceptance by
/// whole suggestion / word / line, and suppression of rejected suggestions.
@MainActor
final class InlineCompletionController {
    struct Host {
        var textView: @MainActor () -> TextView?
        var document: @MainActor () -> Document?
        var popupVisible: @MainActor () -> Bool
    }

    var engine: InlineCompletionEngine?
    var settings = InlineCompletionSettings()
    var onOpenSettings: (() -> Void)?
    /// Called after the visible suggestion (or its absence) changed, so the owner can
    /// move the multi-line overlay.
    var onPresentationChanged: (() -> Void)?

    private func notifyPresentationChanged() { onPresentationChanged?() }

    private let host: Host
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The suggestion being shown, where it is anchored, and its remaining text.
    private(set) var current: (anchor: Int, suggestion: InlineSuggestion)?
    /// The last accepted insertion, watched briefly for a delete-that-means-reject.
    private var lastAccepted: (range: NSRange, linePrefix: String, text: String, at: Date)?

    init(host: Host) {
        self.host = host
    }

    var isVisible: Bool { current != nil }

    var visibleFirstLine: String? { current?.suggestion.lines.first }

    // MARK: - Scheduling

    /// Idle-after-typing entry point. All conditions from the plan are checked here, on
    /// the live view, before a request is even built.
    func scheduleAfterTyping() {
        guard let engine, let textView = host.textView(),
              settings.isEnabled, textView.isEditable,
              !host.popupVisible() || settings.syncWithPopup else { return }
        let selection = textView.selectedRange
        guard selection.length == 0, !textView.isComposingText else { return }
        guard let document = host.document(), settings.isEnabled(for: document.languageIdentifier) else { return }
        // End of line, or followed only by whitespace and closers.
        let lineRest = textView.text(in: NSRange(
            location: selection.location,
            length: max(0, min(256, textView.documentLength - selection.location))
        )) ?? ""
        let restOfLine = lineRest.prefix { $0 != "\n" }
        guard restOfLine.allSatisfy({ $0.isWhitespace || ")]}>\"';,".contains($0) }) else { return }

        generation += 1
        let mine = generation
        let anchor = selection.location
        let position = document.cursor.position
        var request = InlineCompletionRequest(
            filePath: document.url?.path, languageID: document.languageIdentifier,
            prefix: "", suffix: "",
            maxLines: settings.multiLineEnabled ? 8 : 1,
            maxTokens: settings.multiLineEnabled ? 160 : 48,
            stop: settings.multiLineEnabled ? [] : ["\n"]
        )
        request.prefix = InlineCompletionEngine.window(in: document, at: position).prefix
        task?.cancel()
        task = Task { [weak self] in
            let suggestion = await engine.suggest(request: request, document: document, position: position)
            guard !Task.isCancelled, let self, mine == self.generation, let suggestion else { return }
            await MainActor.run {
                guard mine == self.generation, let textView = self.host.textView(),
                      textView.selectedRange == NSRange(location: anchor, length: 0) else { return }
                self.current = (anchor, suggestion)
                textView.inlineCompletion = InlineCompletionPresentation(utf16Offset: anchor, text: suggestion.text)
                self.notifyPresentationChanged()
            }
        }
    }

    // MARK: - Typing through and dismissal

    /// Called after text was inserted. A character equal to the next ghost character is
    /// consumed from the suggestion with no new request; anything else dismisses it.
    func noteInserted(_ text: String) {
        guard let current, let textView = host.textView() else { return }
        if let lastAccepted, Date().timeIntervalSince(lastAccepted.at) < 2,
           textView.selectedRange.location < lastAccepted.range.location {
            engine?.filter.recordSuppressed(linePrefix: lastAccepted.linePrefix, suggestion: lastAccepted.text)
            self.lastAccepted = nil
        }
        guard text.count == 1, current.suggestion.text.hasPrefix(text) else {
            dismiss(recordSuppression: false)
            return
        }
        let rest = String(current.suggestion.text.dropFirst())
        if rest.isEmpty {
            self.current = nil
            textView.inlineCompletion = nil
            notifyPresentationChanged()
            return
        }
        let anchor = textView.selectedRange.location
        self.current = (anchor, InlineSuggestion(text: rest, additionalEdits: current.suggestion.additionalEdits))
        textView.inlineCompletion = InlineCompletionPresentation(utf16Offset: anchor, text: rest)
        notifyPresentationChanged()
    }

    func noteCaretMoved() {
        guard let current, let textView = host.textView() else { return }
        // Typing through already moved the anchor with the caret; only a caret that
        // left the anchor dismisses.
        if textView.selectedRange.location != current.anchor {
            dismiss(recordSuppression: false)
        }
    }

    func dismiss(recordSuppression: Bool) {
        if recordSuppression, let current, let document = host.document() {
            let prefix = InlineCompletionEngine.window(in: document, at: document.cursor.position).prefix
            let linePrefix = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            engine?.filter.recordSuppressed(linePrefix: linePrefix, suggestion: current.suggestion.text)
        }
        generation += 1
        task?.cancel()
        current = nil
        host.textView()?.inlineCompletion = nil
        notifyPresentationChanged()
    }

    // MARK: - Acceptance

    func acceptWhole() { accept(upTo: nil) }

    func acceptWord() {
        guard let text = current?.suggestion.text else { return }
        // The next word (identifier characters), plus one trailing separator (`(`).
        var end = text.startIndex
        while end < text.endIndex, text[end].isWhitespace, text[end] != "\n" { end = text.index(after: end) }
        while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" || text[end] == "$" {
            end = text.index(after: end)
        }
        if end < text.endIndex, text[end] != "\n" { end = text.index(after: end) }
        accept(upTo: text.distance(from: text.startIndex, to: end))
    }

    func acceptLine() {
        guard let text = current?.suggestion.text else { return }
        if let newline = text.firstIndex(of: "\n") {
            accept(upTo: text.distance(from: text.startIndex, to: newline))
        } else {
            acceptWhole()
        }
    }

    /// Inserts the first `count` characters (the whole text when `nil`), plus the
    /// suggestion's additional edits, in one undo group.
    private func accept(upTo count: Int?) {
        guard let current, let textView = host.textView() else { return }
        let caret = textView.selectedRange.location
        let inserted = count.map { String(current.suggestion.text.prefix($0)) } ?? current.suggestion.text
        guard !inserted.isEmpty else { return }
        let linePrefix = (textView.text(in: NSRange(location: 0, length: caret)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        textView.undoManager?.beginUndoGrouping()
        textView.replace(NSRange(location: caret, length: 0), withText: inserted)
        if !current.suggestion.additionalEdits.isEmpty {
            TextEditApplicator.apply(current.suggestion.additionalEdits, in: textView)
        }
        textView.undoManager?.endUndoGrouping()
        lastAccepted = (
            NSRange(location: caret, length: (inserted as NSString).length),
            linePrefix, current.suggestion.text, Date()
        )
        let rest = String(current.suggestion.text.dropFirst(inserted.count))
        if rest.isEmpty {
            self.current = nil
            textView.inlineCompletion = nil
            notifyPresentationChanged()
        } else {
            // The next line of a multi-line suggestion becomes the new first ghost line.
            let trimmed = rest.hasPrefix("\n") ? String(rest.dropFirst()) : rest
            let anchor = textView.selectedRange.location
            self.current = (anchor, InlineSuggestion(text: trimmed, additionalEdits: []))
            textView.inlineCompletion = trimmed.isEmpty
                ? nil
                : InlineCompletionPresentation(utf16Offset: anchor, text: trimmed)
            if trimmed.isEmpty { self.current = nil }
        }
        notifyPresentationChanged()
    }

    // MARK: - Keys

    /// Keys intercepted while a ghost is visible. The popup takes precedence: the caller
    /// only forwards here when the popup is closed (or this returns `false`).
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard current != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 0x35: // Esc
            dismiss(recordSuppression: true)
            return true
        case 0x30 where modifiers.isEmpty || modifiers == .shift: // Tab
            if settings.acceptKey == .tab { acceptWhole(); return true }
            return false
        case 0x24, 0x4C: // Return / keypad Enter
            if settings.acceptKey == .enter, modifiers.isEmpty { acceptWhole(); return true }
            return false
        case 0x7C where modifiers == .option: // ⌥→
            acceptWord()
            return true
        case 0x7C where modifiers == .command: // ⌘→
            acceptLine()
            return true
        case 0x7C where modifiers.isEmpty: // →
            if settings.acceptKey == .rightArrow { acceptWhole(); return true }
            return false
        default:
            return false
        }
    }
}

/// The small overlay shown when the pointer rests on ghost text: how to accept, a menu
/// to change the accept key, and a path to the Full Line settings.
@MainActor
final class InlineCompletionChipView: NSView {
    var onChooseAcceptKey: ((InlineAcceptKey) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let keyButton = NSPopUpButton()
    private let moreButton = NSButton(title: "⋯", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        keyButton.controlSize = .small
        keyButton.menu?.items = InlineAcceptKey.allCases.map { key in
            let item = NSMenuItem(title: key.title, action: #selector(chooseKey(_:)), keyEquivalent: "")
            item.representedObject = key.rawValue
            item.target = self
            return item
        }
        keyButton.selectItem(at: 0)
        moreButton.controlSize = .small
        moreButton.bezelStyle = .rounded
        moreButton.target = self
        moreButton.action = #selector(openSettings)
        for view in [label, keyButton, moreButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(acceptKey: InlineAcceptKey) {
        label.stringValue = "⇥ Accept · ⌥→ Word · ⌘→ Line"
        keyButton.selectItem(withTitle: acceptKey.title)
        let labelWidth = label.intrinsicContentSize.width
        label.frame = CGRect(x: 8, y: 5, width: labelWidth, height: 16)
        keyButton.frame = CGRect(x: 8 + labelWidth + 6, y: 3, width: 64, height: 20)
        moreButton.frame = CGRect(x: 8 + labelWidth + 6 + 70, y: 3, width: 28, height: 20)
        frame.size = CGSize(width: moreButton.frame.maxX + 8, height: 26)
    }

    @objc private func chooseKey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let key = InlineAcceptKey(rawValue: raw) {
            onChooseAcceptKey?(key)
        }
    }

    @objc private func openSettings() { onOpenSettings?() }
}

import EditorIntelligence
import Foundation

/// `Inject language…` in the ⌥↩ menu when the caret sits inside a string literal. Carries the
/// string-content range to `IDEWorkspace`, which asks which language and records a temporary
/// injection (highlighting only — no completion or diagnostics inside fragments).
///
/// One generic provider (not one per language): most bundled grammars have no `LanguageService`
/// claiming them, so a per-language provider would silently never fire there.
struct IDEManualInjectionCodeActionProvider: CodeActionProviding {
    static let injectCommand = "umbra.injectLanguage"

    private let store: IDEManualInjectionStore

    init(store: IDEManualInjectionStore) {
        self.store = store
    }

    func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        guard let range = Self.stringContentRange(at: position.utf16Offset, in: document.text) else {
            return []
        }
        // Hidden when a temporary injection already covers the range; re-invoking would stack a
        // duplicate layer over the same bytes.
        let key = IDEManualInjectionStore.key(url: document.url, displayName: document.displayName)
        if store.injections(forKey: key).contains(where: { NSIntersectionRange($0.utf16Range, range).length > 0 }) {
            return []
        }
        return [CodeAction(
            title: "Inject language…",
            edits: [],
            command: CodeActionCommand(id: Self.injectCommand,
                                       arguments: [String(range.location), String(range.length)])
        )]
    }

    /// Content range (quotes excluded) of the string literal enclosing `offset`, scanning only
    /// the caret's line. `nil` when the caret is not inside quotes on one line. Multi-line
    /// strings and exotic escapes are best-effort: a miss hides the action, never corrupts text.
    static func stringContentRange(at offset: Int, in text: String) -> NSRange? {
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count else {
            return nil
        }
        // Caret line bounds, capped so a pathological single-line file cannot walk far.
        let cap = 8_192
        var lineStart = offset
        var steps = 0
        while lineStart > 0, units[lineStart - 1] != 10, steps < cap {
            lineStart -= 1
            steps += 1
        }
        var lineEnd = offset
        steps = 0
        while lineEnd < units.count, units[lineEnd] != 10, steps < cap {
            lineEnd += 1
            steps += 1
        }
        guard lineStart < lineEnd else {
            return nil
        }
        // Nearest unescaped quote on each side of the caret.
        func isEscaped(_ index: Int) -> Bool {
            var backslashes = 0
            var i = index - 1
            while i >= lineStart, units[i] == 92 {
                backslashes += 1
                i -= 1
            }
            return backslashes % 2 == 1
        }
        func isQuote(_ unit: UInt16) -> Bool {
            unit == 34 || unit == 39 || unit == 96
        }
        var left: Int?
        var i = min(offset, lineEnd) - 1
        while i >= lineStart {
            if isQuote(units[i]), !isEscaped(i) {
                left = i
                break
            }
            i -= 1
        }
        var right: Int?
        var j = max(offset, lineStart)
        // The caret may sit right after the opening quote or right before the closing one;
        // either side may equal the caret, but not both.
        while j < lineEnd {
            if isQuote(units[j]), !isEscaped(j) {
                right = j
                break
            }
            j += 1
        }
        guard let open = left, let close = right, open < offset, offset <= close, open + 1 <= close else {
            return nil
        }
        // Paired quotes of one kind; a `'`…`"` mismatch is two unrelated apostrophes.
        guard units[open] == units[close] else {
            return nil
        }
        return NSRange(location: open + 1, length: close - open - 1)
    }
}

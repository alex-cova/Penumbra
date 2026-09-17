import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Regression coverage for two confirmed per-keystroke `O(document size)` materializations found
/// on a large, file-backed (piece-tree) document:
///
/// 1. `OccurrenceHighlightController.term(for:)` used to open with `stringView.string` — called
///    synchronously on every keystroke (before its own debounce), so occurrence highlighting made
///    typing scale with file size.
/// 2. `TextInputView.restartSyntaxParseAfterCancelledEdit()` used to materialize the document to
///    pass to `startFullParse(of:)`, whose `languageMode.parse(_:completion:)` never actually read
///    the argument — the materialized copy was discarded unused.
///
/// Both are asserted here via `stringView.materializeCount` (`PieceTree.materializeCount`), not
/// timing — a direct, size-independent signal that `stringView.string` was never called, rather
/// than inferring it from how fast a run happens to complete.
///
/// Drives a bare `TextInputView(theme:)` directly — no `NSWindow`, no `TextView`, no
/// `layoutSubviews()` — matching `AppearanceChangeSmokeTests`'s established pattern for exercising
/// `TextInputView` in isolation. Nothing under test needs window membership, real keyboard focus,
/// or layout: `occurrenceHighlightController`/`languageMode`/`replaceText`/`selection` are all
/// `TextInputView`-level. (A real, focused `NSWindow` over a >256 KiB document was measured to be
/// dramatically — multi-minute — slower for reasons unrelated to the fix under test; this avoids
/// that path entirely rather than chasing it.)
@MainActor
final class StringMaterializationRegressionTests: XCTestCase {
    /// Comfortably over `StringView.pieceTreeUntitledThreshold` (256 KiB) so the document is
    /// piece-tree-backed and a full materialization is both possible and would be expensive.
    private static let largeText: String = {
        let line = String(repeating: "the quick brown fox jumps over lazy dog ", count: 20) + "\n"
        return String(repeating: line, count: 340) // ~272 KB (801 UTF-16 units/line)
    }()

    private func makeLargeTextInputView() -> TextInputView {
        let textInputView = TextInputView(theme: DefaultTheme())
        textInputView.string = Self.largeText as NSString
        XCTAssertTrue(textInputView.stringView.usesPieceTree, "fixture must be large enough to force piece-tree storage")
        return textInputView
    }

    func testOccurrenceHighlightingDoesNotMaterializeTheDocumentOnKeystroke() {
        let textInputView = makeLargeTextInputView()
        textInputView.highlightsOccurrencesOfSelection = true
        textInputView.languageConfiguration = LanguageConfiguration(declarations: [], highlightsOccurrences: true, minimumOccurrenceLength: 2)

        // Caret inside a word, matching the empty-selection "word under the caret" path in
        // `OccurrenceHighlightController.term(for:)` (exercises the real `tokenizer`).
        let location = Self.largeText.utf16.count / 2
        textInputView.selection = NSRange(location: location, length: 0)
        XCTAssertEqual(textInputView.stringView.materializeCount, 0)

        for offset in 0..<10 {
            textInputView.replaceText(in: NSRange(location: location + offset, length: 0), with: "x")
        }

        XCTAssertEqual(
            textInputView.stringView.materializeCount, 0,
            "OccurrenceHighlightController.term(for:) must not materialize the document on keystroke"
        )
    }

    func testOccurrenceHighlightingWithAnExplicitSelectionDoesNotMaterializeTheDocumentOnKeystroke() {
        let textInputView = makeLargeTextInputView()
        textInputView.highlightsOccurrencesOfSelection = true
        textInputView.languageConfiguration = LanguageConfiguration(declarations: [], highlightsOccurrences: true, minimumOccurrenceLength: 2)

        let location = Self.largeText.utf16.count / 2
        textInputView.selection = NSRange(location: location, length: 5) // non-empty selection path
        XCTAssertEqual(textInputView.stringView.materializeCount, 0)

        textInputView.replaceText(in: NSRange(location: location, length: 0), with: "y")

        XCTAssertEqual(textInputView.stringView.materializeCount, 0)
    }

    func testRestartingAnInterruptedParseDoesNotMaterializeTheDocument() {
        let originalMaxSyncEditLength = TreeSitterPerformanceConstants.maxSyncEditLength
        TreeSitterPerformanceConstants.maxSyncEditLength = 64
        defer { TreeSitterPerformanceConstants.maxSyncEditLength = originalMaxSyncEditLength }

        let textInputView = makeLargeTextInputView()
        let language = TreeSitterLanguage(tree_sitter_javascript())
        textInputView.setLanguageMode(TreeSitterLanguageMode(language: language))
        XCTAssertEqual(textInputView.stringView.materializeCount, 0, "setLanguageMode's eager parse reads from the buffer reader, not a materialized string")

        // An edit at/above `maxSyncEditLength` skips the synchronous incremental reparse and
        // marks the tree not-ready, which is exactly what makes the next edit take
        // `restartSyntaxParseAfterCancelledEdit()`'s `startFullParse` branch.
        let hugeInsertion = String(repeating: "x", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        textInputView.replaceText(in: NSRange(location: 0, length: 0), with: hugeInsertion)
        XCTAssertFalse(textInputView.isSyntaxTreeReady, "the large edit should have left the tree not-ready")

        textInputView.replaceText(in: NSRange(location: 0, length: 0), with: "z")

        XCTAssertEqual(
            textInputView.stringView.materializeCount, 0,
            "restartSyntaxParseAfterCancelledEdit() must not materialize the document — parse(completion:) reads from the buffer reader"
        )
    }
}

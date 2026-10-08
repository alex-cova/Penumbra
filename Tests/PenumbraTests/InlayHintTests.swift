import XCTest
import AppKit
import EditorIntelligence
@testable import Penumbra

@MainActor
final class InlayHintTests: XCTestCase {
    private func hint(_ offset: Int, _ label: String = "a:") -> InlayHint {
        InlayHint(utf16Offset: offset, label: label)
    }

    // MARK: - Model

    func testNormalizingSortsMergesSameOffsetAndDropsUnusable() {
        let result = InlayHintIndex.normalized([hint(9, "b:"), hint(3, "x:"), hint(3, "y:"), hint(-1), hint(5, "")])
        XCTAssertEqual(result.map(\.utf16Offset), [3, 9])
        XCTAssertEqual(result[0].label, "x: y:")
    }

    func testLocalHintsAreLineRelativeAndSkipTheLineStart() {
        let hints = InlayHintIndex.normalized([hint(10), hint(14), hint(20), hint(31)])
        // A line at 10...30: the hint at its first character has nothing before it to widen.
        let appearance = InlayHintAppearance.standard
        let local = InlayHintIndex.localHints(in: hints, lineLocation: 10, lineLength: 20, appearance: appearance)
        XCTAssertEqual(local.map(\.localOffset), [4, 10])
        XCTAssertTrue(local.allSatisfy { $0.width == appearance.width(of: "a:") })
        XCTAssertTrue(InlayHintIndex.localHints(in: [], lineLocation: 0, lineLength: 5, appearance: appearance).isEmpty)
    }

    func testEditsMoveLaterHintsAndDropOnesInsideTheEditedRange() {
        let hints = [hint(2), hint(6), hint(12)]
        let edited = InlayHintIndex.applyingEdit(to: hints, range: NSRange(location: 4, length: 4), replacementLength: 1)
        XCTAssertEqual(edited.map(\.utf16Offset), [2, 9])
        let inserted = InlayHintIndex.applyingEdit(to: hints, range: NSRange(location: 6, length: 0), replacementLength: 3)
        XCTAssertEqual(inserted.map(\.utf16Offset), [2, 6, 15], "a hint exactly at the edit stays in front of it")
    }

    func testWidthGrowsWithTheLabel() {
        let appearance = InlayHintAppearance.standard
        XCTAssertGreaterThan(appearance.width(of: "capacity:"), appearance.width(of: "n:"))
        XCTAssertGreaterThan(appearance.width(of: "n:"), InlayHintAppearance.horizontalPadding * 2)
    }

    // MARK: - Text view

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        textView.layoutIfNeeded()
        return textView
    }

    func testHintsWidenTheLineAndLeaveTheTextAlone() {
        let text = "call(1, 2);"
        let textView = makeTextView(text)
        let before = textView.caretRectInViewport(at: 8)
        let start = textView.caretRectInViewport(at: 3)
        textView.inlayHints = [hint(5, "count:")]
        textView.layoutIfNeeded()
        let after = textView.caretRectInViewport(at: 8)
        XCTAssertEqual(after.minX - before.minX, textView.inlayHintAppearanceForTesting.width(of: "count:"), accuracy: 0.5)
        XCTAssertEqual(textView.text, text)
        XCTAssertEqual(textView.caretRectInViewport(at: 3).minX, start.minX, accuracy: 0.01, "text before the hint does not move")
    }

    func testClearingHintsRestoresTheOriginalLayout() {
        let textView = makeTextView("call(1, 2);")
        let before = textView.caretRectInViewport(at: 8)
        textView.inlayHints = [hint(5, "count:"), hint(8, "n:")]
        textView.layoutIfNeeded()
        XCTAssertGreaterThan(textView.caretRectInViewport(at: 10).minX, before.minX)
        textView.inlayHints = []
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.caretRectInViewport(at: 8).minX, before.minX, accuracy: 0.5)
    }

    func testTypingBeforeAHintKeepsItOnTheSameArgument() {
        let textView = makeTextView("call(1, 2);")
        textView.inlayHints = [hint(5, "count:")]
        textView.replace(NSRange(location: 0, length: 0), withText: "xx")
        XCTAssertEqual(textView.inlayHints.map(\.utf16Offset), [7])
    }

    func testEditingInsideTheHintedArgumentRangeDropsTheHint() {
        let textView = makeTextView("call(1, 2);")
        textView.inlayHints = [hint(5, "count:")]
        textView.replace(NSRange(location: 4, length: 3), withText: "")
        XCTAssertTrue(textView.inlayHints.isEmpty)
    }

    func testHintsAreNotPartOfTheText() {
        let textView = makeTextView("call(1, 2);")
        textView.inlayHints = [hint(5, "count:")]
        XCTAssertFalse((textView.text as String).contains("count"))
        XCTAssertEqual(textView.inlayHints.count, 1)
    }

    // MARK: - Appearance

    func testAppearanceFollowsTheEditorFontAndTheTheme() {
        let textView = makeTextView("call(1, 2);")
        let editorSize = textView.theme.font.pointSize
        let ui = textView.inlayHintAppearanceForTesting
        XCTAssertEqual(ui.font.pointSize, max(editorSize - 2, 9), accuracy: 0.01)

        textView.inlayHintsUseEditorFont = true
        let editor = textView.inlayHintAppearanceForTesting
        XCTAssertEqual(editor.font.pointSize, max(editorSize - 1, 8), accuracy: 0.01)
        XCTAssertEqual(editor.font.familyName, textView.theme.font.familyName)
    }

    func testChangingTheFontRetypesetsLinesWithHints() {
        let textView = makeTextView("call(1, 2);")
        textView.inlayHints = [hint(5, "count:")]
        textView.layoutIfNeeded()
        let narrow = textView.caretRectInViewport(at: 8).minX

        textView.inlayHintsUseEditorFont = true
        textView.layoutIfNeeded()
        let wide = textView.caretRectInViewport(at: 8).minX

        // The editor font is monospaced and larger than the UI font, so the label needs more room.
        XCTAssertNotEqual(wide, narrow, accuracy: 0.01)
        let expected = textView.inlayHintAppearanceForTesting.width(of: "count:")
        let plain = makeTextView("call(1, 2);").caretRectInViewport(at: 8).minX
        XCTAssertEqual(wide - plain, expected, accuracy: 0.5)
    }

    func testThemeColorsOverrideTheDefaults() {
        let textView = makeTextView("x")
        textView.theme = DefaultTheme(inlayHintTextColor: .systemPink, inlayHintBackgroundColor: .systemTeal)
        XCTAssertEqual(textView.inlayHintAppearanceForTesting.textColor, .systemPink)
        XCTAssertEqual(textView.inlayHintAppearanceForTesting.backgroundColor, .systemTeal)
    }
}

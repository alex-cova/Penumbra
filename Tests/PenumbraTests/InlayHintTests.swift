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

    func testLocalHintsAreLineRelativeAndTheLineStartHintGetsOffsetZero() {
        let hints = InlayHintIndex.normalized([hint(10), hint(14), hint(20), hint(31)])
        // A line at 10...30: the hint at its first character has nothing before it to widen, so it
        // is offset 0 and the first fragment reserves its room.
        let appearance = InlayHintAppearance.standard
        let local = InlayHintIndex.localHints(in: hints, lineLocation: 10, lineLength: 20, appearance: appearance)
        XCTAssertEqual(local.map(\.localOffset), [0, 4, 10])
        XCTAssertTrue(local.allSatisfy { $0.width == appearance.width(of: "a:") })
        XCTAssertEqual(LineInlayHint.leadingInset(of: local), appearance.width(of: "a:"))
        XCTAssertEqual(LineInlayHint.leadingInset(of: Array(local.dropFirst())), 0)
        XCTAssertTrue(InlayHintIndex.localHints(in: [], lineLocation: 0, lineLength: 5, appearance: appearance).isEmpty)
    }

    func testEditsMoveLaterHintsAndDropOnesInsideTheEditedRange() {
        let hints = [hint(2), hint(6), hint(12)]
        let edited = InlayHintIndex.applyingEdit(to: hints, range: NSRange(location: 4, length: 4), replacementLength: 1)
        XCTAssertEqual(edited.map(\.utf16Offset), [2, 9])
        let inserted = InlayHintIndex.applyingEdit(to: hints, range: NSRange(location: 6, length: 0), replacementLength: 3)
        XCTAssertEqual(inserted.map(\.utf16Offset), [2, 6, 15], "a hint exactly at the edit stays in front of it")
    }

    func testRightAffinityMovesOnInsertionAndDropsWhenTheAnchorIsReplaced() {
        let original = InlayHint(
            utf16Offset: 6, label: "count:", providerID: "java", symbol: "example.Target.call",
            tooltip: "Parameter count", affinity: .afterInsertion
        )
        let inserted = InlayHintIndex.applyingEdit(to: [original], range: NSRange(location: 6, length: 0), replacementLength: 3)
        XCTAssertEqual(inserted, [original.anchored(at: 9)])
        let replaced = InlayHintIndex.applyingEdit(to: [original], range: NSRange(location: 6, length: 1), replacementLength: 3)
        XCTAssertTrue(replaced.isEmpty)
    }

    func testProviderValidationRejectsUnusableOutOfRangeAndDuplicateHints() {
        let start = TextPosition(line: 0, column: 2, utf16Offset: 2)
        let end = TextPosition(line: 0, column: 9, utf16Offset: 9)
        let range = EditorIntelligence.TextRange(start: start, end: end)
        let result = InlayHintController.validated([
            hint(1), hint(2), hint(2), hint(3, "one\ntwo"), hint(4, String(repeating: "x", count: 513)),
            hint(9), hint(10), InlayHint(utf16Offset: 5, label: "ghost", kind: .inlineCompletion)
        ], in: range)
        XCTAssertEqual(result, [hint(2), hint(9)])
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

    func testALineStartHintMovesTheTextRightAndLeavesTheTextAlone() {
        let text = "call(1, 2);\nnext();"
        let textView = makeTextView(text)
        let appearance = textView.inlayHintAppearanceForTesting
        let startBefore = textView.caretRectInViewport(at: 0)
        let midBefore = textView.caretRectInViewport(at: 5)
        let nextBefore = textView.caretRectInViewport(at: 12)
        textView.inlayHints = [hint(0, "name:")]
        textView.layoutIfNeeded()
        let width = appearance.width(of: "name:")
        XCTAssertEqual(textView.caretRectInViewport(at: 0).minX - startBefore.minX, width, accuracy: 0.5,
                       "the caret at the line start sits behind the chip")
        XCTAssertEqual(textView.caretRectInViewport(at: 5).minX - midBefore.minX, width, accuracy: 0.5)
        XCTAssertEqual(textView.caretRectInViewport(at: 12).minX, nextBefore.minX, accuracy: 0.01, "other lines do not move")
        XCTAssertEqual(textView.text, text)
        textView.inlayHints = []
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.caretRectInViewport(at: 5).minX, midBefore.minX, accuracy: 0.5, "clearing the hint takes the room back")
    }

    func testAClickOnALineStartChipPutsTheCaretAtTheLineStart() throws {
        let textView = makeTextView("call(1, 2);")
        let appearance = textView.inlayHintAppearanceForTesting
        textView.inlayHints = [hint(0, "name:")]
        textView.layoutIfNeeded()
        let layoutManager = textView.layoutManagerForTesting
        let textStart = textView.caretRectInViewport(at: 0)
        let width = appearance.width(of: "name:")
        let y = textStart.midY
        XCTAssertEqual(layoutManager.closestIndex(to: CGPoint(x: textStart.minX - width / 2, y: y)), 0, "on the chip")
        XCTAssertEqual(layoutManager.inlayHintAnchor(at: CGPoint(x: textStart.minX - width / 2, y: y)), 0)
        let fourth = textView.caretRectInViewport(at: 4)
        XCTAssertEqual(layoutManager.closestIndex(to: CGPoint(x: fourth.minX + 0.5, y: y)), 4, "text clicks are not shifted")
        XCTAssertNil(layoutManager.inlayHintAnchor(at: CGPoint(x: fourth.minX + 0.5, y: y)))
    }

    func testAWrappedLineStartHintWidensOnlyTheFirstFragment() {
        let text = String(repeating: "word ", count: 60)
        let textView = makeTextView(text)
        let before = textView.caretRectInViewport(at: 0)
        let laterBefore = textView.caretRectInViewport(at: 290)
        textView.inlayHints = [hint(0, "name:")]
        textView.layoutIfNeeded()
        let after = textView.caretRectInViewport(at: 0)
        XCTAssertGreaterThan(after.minX, before.minX)
        XCTAssertGreaterThan(after.maxY, 0)
        let laterAfter = textView.caretRectInViewport(at: 290)
        XCTAssertGreaterThanOrEqual(laterAfter.minY, laterBefore.minY, "the hint cannot pull text up")
    }

    func testGhostTextAndSemanticHintReserveSeparateSpaceAtOneAnchor() {
        let textView = makeTextView("call(1, 2);")
        let before = textView.caretRectInViewport(at: 8)
        textView.inlayHints = [hint(5, "count:")]
        textView.inlineCompletion = InlineCompletionPresentation(utf16Offset: 5, text: "extra")
        textView.layoutIfNeeded()
        let appearance = textView.inlayHintAppearanceForTesting
        let width = appearance.width(of: "count:") + appearance.inlineTextWidth(of: "extra")
        XCTAssertEqual(textView.caretRectInViewport(at: 8).minX - before.minX, width, accuracy: 0.5)
        XCTAssertEqual(textView.text, "call(1, 2);")
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

    func testObsoleteProviderResultDoesNotReplaceNewerHints() async throws {
        let textView = makeTextView("call(1)")
        let provider = DelayedInlayProvider()
        let controller = InlayHintController(textView: textView, provider: provider)
        controller.makeDocument = { [weak textView] in
            guard let textView else { return nil }
            let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                displayName: "test.java", contentSnapshot: TextSnapshot(version: 1, text: textView.text),
                selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)),
                cursor: Cursor(position: start), viewport: Viewport(x: 0, y: 0, width: 600, height: 300),
                languageIdentifier: "java"
            )
        }

        controller.refresh(delay: 0)
        try await waitForRequests(1, from: provider)
        textView.replace(NSRange(location: 5, length: 1), withText: "2")
        controller.refresh(delay: 0)
        try await waitForRequests(2, from: provider)
        let start = TextPosition(line: 0, column: 5, utf16Offset: 5)
        let end = TextPosition(line: 0, column: 6, utf16Offset: 6)
        let edit = TextEdit(range: EditorIntelligence.TextRange(start: start, end: end), replacement: "3")
        let newHint = InlayHint(utf16Offset: 5, label: "new:", edits: [edit])
        await provider.finish(request: 1, with: [newHint])
        let deadline = ContinuousClock.now + .seconds(2)
        while textView.inlayHints.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await provider.finish(request: 0, with: [hint(5, "obsolete:")])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(textView.inlayHints, [newHint])
        XCTAssertTrue(controller.accept(newHint))
        XCTAssertEqual(textView.text, "call(3)")
        XCTAssertFalse(controller.accept(newHint), "applying edits consumes that revision")
    }

    private func waitForRequests(_ count: Int, from provider: DelayedInlayProvider) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await provider.requestCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = await provider.requestCount
        XCTAssertEqual(actual, count)
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

    // MARK: - Chip geometry

    /// Core Text's index offset at a kerned boundary is the middle of the gap inside a line and
    /// the position in front of the gap at the end of a line; the glyph positions are exact.
    func testChipEndIsTheLeadingEdgeOfTheNextGlyphNotCoreTextsIndexOffset() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo", size: 14))
        let kern: CGFloat = 40
        func line(kerning index: Int, text: String) -> CTLine {
            let string = NSMutableAttributedString(string: text, attributes: [.font: font])
            string.addAttribute(.kern, value: kern, range: NSRange(location: index, length: 1))
            return CTTypesetterCreateLine(CTTypesetterCreateWithAttributedString(string), CFRange(location: 0, length: text.utf16.count))
        }
        let advance = ("a" as NSString).size(withAttributes: [.font: font]).width

        // Inside a line: the next glyph starts after the whole kern.
        let inside = line(kerning: 4, text: "call(1, 2);")
        XCTAssertEqual(InlayChipGeometry.chipEnd(forLocalOffset: 5, in: inside), 5 * advance + kern, accuracy: 0.01)
        XCTAssertLessThan(CTLineGetOffsetForStringIndex(inside, 5, nil), 5 * advance + kern - 1,
                          "Core Text puts the caret offset in the gap; if this fails the workaround can go")

        // After the last character: the end of the line includes the kern.
        let end = line(kerning: 10, text: "call(1, 2);")
        XCTAssertEqual(InlayChipGeometry.chipEnd(forLocalOffset: 11, in: end), 11 * advance + kern, accuracy: 0.01)
    }
}


private actor DelayedInlayProvider: InlayHintProviding {
    private(set) var requestCount = 0
    private var requests: [Int: CheckedContinuation<[InlayHint], Never>] = [:]

    func inlayHints(for document: Document, in range: EditorIntelligence.TextRange) async -> [InlayHint] {
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { requests[request] = $0 }
    }

    func finish(request: Int, with hints: [InlayHint]) {
        requests.removeValue(forKey: request)?.resume(returning: hints)
    }
}

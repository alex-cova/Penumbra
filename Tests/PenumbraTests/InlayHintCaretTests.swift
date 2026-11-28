@preconcurrency import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// An inlay hint is a chip drawn between two characters. The caret steps in front of it and then
/// behind it, a click on the chip lands at the hint, and selections and block carets stop short of it.
@MainActor
final class InlayHintCaretTests: XCTestCase {
    private let text = "call(1, 2);"
    private let hintOffset = 5

    private func makeTextView(shape: CaretShape = .bar) -> TextView {
        let textView = makeFocusedTextView(text: text)
        textView.caretShape = shape
        textView.inlayHints = [InlayHint(utf16Offset: hintOffset, label: "count:")]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 4, length: 0)
        return textView
    }

    private func press(_ keyCode: UInt16, in textView: TextView) {
        send(keyEvent(keyCode: keyCode), to: textView)
    }

    private func width(_ textView: TextView) -> CGFloat {
        textView.inlayHintAppearanceForTesting.width(of: "count:")
    }

    private func caret(in textView: TextView) -> CaretView? {
        func find(_ view: NSView) -> CaretView? {
            if let caret = view as? CaretView, !caret.isHidden, caret.frame.height > 0 { return caret }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(textView)
    }

    func testRightArrowStopsInFrontOfTheChipThenBehindIt() throws {
        let textView = makeTextView()
        let behind = textView.caretRectInViewport(at: hintOffset).minX

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind - width(textView), accuracy: 1,
                       "drawn in front of the chip")

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0), "same offset, other side")
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind, accuracy: 1)

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset + 1, length: 0))
    }

    func testLeftArrowStopsBehindTheChipThenInFrontOfIt() {
        let textView = makeTextView()
        textView.selectedRange = NSRange(location: hintOffset + 1, length: 0)

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint, "arrives behind the chip")

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset - 1, length: 0))
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
    }

    // MARK: - A chip at the first character of a line

    private let twoLines = "call(1, 2);\nnext();"
    private let lineStart = 12

    private func makeLineStartTextView() -> TextView {
        let textView = makeFocusedTextView(text: twoLines)
        textView.inlayHints = [InlayHint(utf16Offset: lineStart, label: "name:")]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: lineStart - 1, length: 0)
        return textView
    }

    func testRightArrowIntoALineStartChipStopsInFrontOfItThenBehindIt() throws {
        let textView = makeLineStartTextView()
        let chip = textView.inlayHintAppearanceForTesting.width(of: "name:")
        let behind = textView.caretRectInViewport(at: lineStart).minX

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint, "arrives in front of the chip")
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind - chip, accuracy: 1)

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart, length: 0), "same offset, behind the chip")
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind, accuracy: 1)

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart + 1, length: 0))
    }

    func testLeftArrowOutOfALineStartChipStopsBehindThenInFrontOfIt() {
        let textView = makeLineStartTextView()
        textView.selectedRange = NSRange(location: lineStart + 1, length: 0)

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart, length: 0))
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint, "arrives behind the chip")

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint, "now in front of it")

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: lineStart - 1, length: 0), "onto the previous line")
    }

    func testAClickOnALineStartChipPutsTheCaretInFrontOfTheLine() throws {
        let textView = makeLineStartTextView()
        let chip = textView.inlayHintAppearanceForTesting.width(of: "name:")
        let start = textView.caretRectInViewport(at: lineStart)
        let point = CGPoint(x: start.minX - chip / 2, y: start.midY)
        XCTAssertEqual(textView.layoutManagerForTesting.closestIndex(to: point), lineStart)
        XCTAssertEqual(textView.layoutManagerForTesting.inlayHintAnchor(at: point), lineStart)
    }

    // MARK: - Linked label parts

    private let listLocation = InlayHintLabelPart.Target.location(
        uri: "file:///tmp/List.swift", range: LSPRange(start: LSPPosition(line: 3, character: 7), end: LSPPosition(line: 3, character: 11))
    )

    /// "List<String>" with the first four characters linked to a location and the last six to a token.
    private func makeLinkedTextView() -> TextView {
        let textView = makeFocusedTextView(text: text)
        textView.inlayHints = [InlayHint(
            utf16Offset: hintOffset, label: ": List<String>", kind: .type, providerID: "test",
            parts: [
                InlayHintLabelPart(range: NSRange(location: 2, length: 4), target: listLocation),
                InlayHintLabelPart(range: NSRange(location: 7, length: 6), target: .token(Data("string".utf8))),
            ]
        )]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 2, length: 0)
        return textView
    }

    /// A point over the `index`th character of the chip's label, in the text view's coordinates.
    private func pointOverLabel(_ index: Int, in textView: TextView) -> CGPoint {
        let appearance = textView.inlayHintAppearanceForTesting
        let label = ": List<String>" as NSString
        let behind = textView.caretRectInViewport(at: hintOffset)
        let labelWidth = appearance.width(of: label as String)
        let pillStart = behind.minX - labelWidth
        let textStart = pillStart + InlayHintAppearance.horizontalPadding
        let before = appearance.textWidth(of: label.substring(to: index))
        let through = appearance.textWidth(of: label.substring(to: index + 1))
        return CGPoint(x: textStart + (before + through) / 2, y: behind.midY)
    }

    func testPartsAreFoundOnlyUnderTheirOwnCharacters() throws {
        let textView = makeLinkedTextView()
        let list = try XCTUnwrap(textView.inlayHintPart(at: pointOverLabel(3, in: textView)))
        XCTAssertEqual(list.part.range, NSRange(location: 2, length: 4))
        XCTAssertEqual(list.part.target, listLocation)
        XCTAssertEqual(list.hint.providerID, "test")
        let string = try XCTUnwrap(textView.inlayHintPart(at: pointOverLabel(9, in: textView)))
        XCTAssertEqual(string.part.target, .token(Data("string".utf8)))
        XCTAssertNil(textView.inlayHintPart(at: pointOverLabel(0, in: textView)), "the colon is not linked")
        XCTAssertNil(textView.inlayHintPart(at: pointOverLabel(6, in: textView)), "nor the angle bracket")
        let plain = makeTextView()
        XCTAssertNil(plain.inlayHintPart(at: CGPoint(x: 40, y: 8)))
    }

    func testCommandClickOnALinkedPartFollowsItAndPlainClickPlacesTheCaret() throws {
        let textView = makeLinkedTextView()
        var followed: [InlayHintLabelPart] = []
        textView.inlayHintPartClickHandler = { _, part in
            followed.append(part)
            return true
        }
        let point = pointOverLabel(3, in: textView)
        let input = textView.stickyLinesInput
        func click(_ flags: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: input.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                windowNumber: textView.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            input.mouseDown(with: event)
        }
        try click([.command])
        XCTAssertEqual(followed.map(\.range), [NSRange(location: 2, length: 4)])
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0), "the link took the click, the caret stayed")
        try click([])
        XCTAssertEqual(followed.count, 1, "a plain click does not follow a link")
        XCTAssertEqual(textView.selectedRange.location, hintOffset, "it lands at the hint, as before")
    }

    func testTheChipUnderThePointerIsFoundFromAWindowLocation() throws {
        let textView = makeFocusedTextView(text: text)
        let hint = InlayHint(utf16Offset: hintOffset, label: "count:", tooltip: "How many")
        textView.inlayHints = [hint]
        textView.layoutIfNeeded()
        let input = textView.stickyLinesInput
        let behind = textView.caretRectInViewport(at: hintOffset)
        let onChip = input.convert(CGPoint(x: behind.minX - width(textView) / 2, y: behind.midY), to: nil)
        XCTAssertEqual(textView.inlayHint(atWindowLocation: onChip), hint)
        let onText = input.convert(CGPoint(x: textView.caretRectInViewport(at: 1).minX, y: behind.midY), to: nil)
        XCTAssertNil(textView.inlayHint(atWindowLocation: onText))
    }

    func testPartsOutsideTheLabelAreDroppedAndSurviveReanchoring() {
        let hint = InlayHint(
            utf16Offset: 4, label: "ab", parts: [
                InlayHintLabelPart(range: NSRange(location: 0, length: 1), target: .token(Data())),
                InlayHintLabelPart(range: NSRange(location: 1, length: 5), target: .token(Data())),
                InlayHintLabelPart(range: NSRange(location: 0, length: 0), target: .token(Data())),
            ]
        )
        XCTAssertEqual(hint.parts.map(\.range), [NSRange(location: 0, length: 1)])
        XCTAssertEqual(hint.anchored(at: 9).parts, hint.parts)
    }

    // MARK: - VoiceOver

    private func rotorItem(
        in textView: TextView, direction: NSAccessibilityCustomRotor.SearchDirection,
        from current: NSAccessibilityCustomRotor.ItemResult? = nil, filter: String = ""
    ) throws -> NSAccessibilityCustomRotor.ItemResult? {
        let input = textView.stickyLinesInput
        let rotor = try XCTUnwrap(input.accessibilityCustomRotors().first { $0.label == "Inlay Hints" })
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = direction
        parameters.currentItem = current
        parameters.filterString = filter
        return rotor.itemSearchDelegate?.rotor(rotor, resultFor: parameters)
    }

    func testHintsAreReadAloudByKind() {
        XCTAssertEqual(TextInputView.accessibilityDescription(of: InlayHint(utf16Offset: 0, label: "count:", kind: .parameter)),
                       "Parameter name hint: count")
        XCTAssertEqual(TextInputView.accessibilityDescription(of: InlayHint(utf16Offset: 0, label: ": List<String>", kind: .type)),
                       "Type hint: List<String>")
        XCTAssertEqual(TextInputView.accessibilityDescription(of: InlayHint(utf16Offset: 0, label: "= 4", kind: .other)), "Hint: = 4")
    }

    func testTheRotorMovesBetweenHintsAndReadsEach() throws {
        let textView = makeFocusedTextView(text: "call(1, 2, 3);")
        textView.inlayHints = [
            InlayHint(utf16Offset: 5, label: "a:", kind: .parameter),
            InlayHint(utf16Offset: 8, label: "b:", kind: .parameter),
            InlayHint(utf16Offset: 11, label: "c:", kind: .parameter),
        ]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 0, length: 0)

        let first = try XCTUnwrap(rotorItem(in: textView, direction: .next))
        XCTAssertEqual(first.targetRange, NSRange(location: 5, length: 0), "from the caret, the first hint ahead")
        XCTAssertEqual(first.customLabel, "Parameter name hint: a")
        let second = try XCTUnwrap(rotorItem(in: textView, direction: .next, from: first))
        XCTAssertEqual(second.targetRange.location, 8)
        let third = try XCTUnwrap(rotorItem(in: textView, direction: .next, from: second))
        XCTAssertEqual(third.targetRange.location, 11)
        XCTAssertNil(try rotorItem(in: textView, direction: .next, from: third), "no hint after the last")
        let back = try XCTUnwrap(rotorItem(in: textView, direction: .previous, from: third))
        XCTAssertEqual(back.targetRange.location, 8)
        XCTAssertNil(try rotorItem(in: textView, direction: .previous, from: first), "no hint before the first")
        let filtered = try XCTUnwrap(rotorItem(in: textView, direction: .next, filter: "b"))
        XCTAssertEqual(filtered.targetRange.location, 8, "the search field narrows the hints")
    }

    func testTheRotorIsAbsentWithoutHintsAndIgnoresGhostText() throws {
        let textView = makeFocusedTextView(text: text)
        textView.layoutIfNeeded()
        XCTAssertNil(textView.stickyLinesInput.accessibilityCustomRotors().first { $0.label == "Inlay Hints" })
        textView.inlineCompletion = InlineCompletionPresentation(utf16Offset: 2, text: "ghost")
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.stickyLinesInput.accessibleInlayHints().isEmpty, "a suggestion is not a hint")
    }

    func testOtherSelectionChangesPutTheCaretBehindTheChip() {
        let textView = makeTextView()
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)

        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
    }

    func testArrowsWithoutHintsMoveOneCharacterAsBefore() {
        let textView = makeFocusedTextView(text: text)
        textView.selectedRange = NSRange(location: 4, length: 0)
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange.location, 5)
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange.location, 6)
    }

    // MARK: - Clicks

    func testClickOnTheChipPutsTheCaretAtTheHint() throws {
        let textView = makeTextView()
        let rect = textView.caretRectInViewport(at: hintOffset)
        let chipMiddle = rect.minX - width(textView) / 2

        let index = try XCTUnwrap(textView.characterIndex(at: CGPoint(x: chipMiddle, y: rect.midY)))
        XCTAssertEqual(index, hintOffset)
    }

    func testClickOnTheCharacterBeforeTheChipSplitsAtTheMiddleOfTheCharacterAlone() throws {
        let textView = makeTextView()
        let rect = textView.caretRectInViewport(at: hintOffset)
        let characterStart = textView.caretRectInViewport(at: hintOffset - 1).minX
        let characterEnd = rect.minX - width(textView)
        let quarter = characterStart + (characterEnd - characterStart) * 0.25
        let threeQuarters = characterStart + (characterEnd - characterStart) * 0.75

        XCTAssertEqual(try XCTUnwrap(textView.characterIndex(at: CGPoint(x: quarter, y: rect.midY))), hintOffset - 1)
        XCTAssertEqual(try XCTUnwrap(textView.characterIndex(at: CGPoint(x: threeQuarters, y: rect.midY))), hintOffset)
    }

    // MARK: - Geometry

    func testBlockCaretOnTheCharacterBeforeTheChipIsOneCharacterWide() throws {
        let textView = makeTextView(shape: .block)
        textView.selectedRange = NSRange(location: hintOffset - 1, length: 0)
        let block = try XCTUnwrap(caret(in: textView))
        let character = textView.caretRectInViewport(at: hintOffset).minX - width(textView)
            - textView.caretRectInViewport(at: hintOffset - 1).minX
        XCTAssertEqual(block.frame.width, character, accuracy: 1)
    }

    func testSelectionEndingAtTheHintStopsInFrontOfTheChip() {
        let textView = makeTextView()
        textView.selectedRange = NSRange(location: 0, length: hintOffset)
        textView.layoutIfNeeded()

        let maxX = textView.selectionRectsForTesting.map(\.rect.maxX).max() ?? 0
        let behind = textView.caretRectInViewport(at: hintOffset).minX
        XCTAssertEqual(maxX, behind - width(textView), accuracy: 1.5)
    }

    func testAControllerMadeOutsideLayoutAlreadyHasItsHints() throws {
        let long = (0 ..< 400).map { _ in "call(1, 2);" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: long)
        textView.inlayHints = (0 ..< 400).map { InlayHint(utf16Offset: $0 * 12 + 5, label: "count:") }
        textView.layoutIfNeeded()
        let input = textView.stickyLinesInput

        // A caret query far from the viewport builds a controller outside the layout pass.
        let before = input.lineControllerCount
        _ = textView.caretRectInViewport(at: 350 * 12 + 6)
        XCTAssertGreaterThan(input.lineControllerCount, before, "the query built a controller")
        XCTAssertTrue(input.lineControllerHasInlayHintsForTesting(atRow: 350))
    }
}

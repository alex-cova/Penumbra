@preconcurrency import AppKit
import XCTest
@testable import Penumbra

final class CharacterPairContextTests: XCTestCase {
    private func shouldPair(_ kind: CharacterPairKind, before: String, after: String = "") -> Bool {
        CharacterPairContext.shouldAutoInsert(kind: kind, textBefore: before, textAfter: after)
    }

    func testBracketPairsAtEndOfLineAndBeforeWhitespaceOrCloser() {
        XCTAssertTrue(shouldPair(.bracket, before: "foo"))
        XCTAssertTrue(shouldPair(.bracket, before: "foo", after: " bar"))
        XCTAssertTrue(shouldPair(.bracket, before: "foo(", after: ")"))
        XCTAssertTrue(shouldPair(.bracket, before: "{ ", after: "}"))
    }

    func testBracketDoesNotPairInFrontOfAnIdentifier() {
        XCTAssertFalse(shouldPair(.bracket, before: "", after: "foo"))
        XCTAssertFalse(shouldPair(.bracket, before: "x = ", after: "\"a\""))
    }

    func testQuoteDoesNotPairAfterIdentifierCharacter() {
        XCTAssertFalse(shouldPair(.quote, before: "don"))
        XCTAssertFalse(shouldPair(.quote, before: "x1"))
        XCTAssertTrue(shouldPair(.quote, before: "x = "))
        XCTAssertTrue(shouldPair(.quote, before: "foo("))
    }

    func testQuoteDoesNotPairAfterBackslashOrAnotherQuote() {
        XCTAssertFalse(shouldPair(.quote, before: "\"a\\"))
        XCTAssertFalse(shouldPair(.quote, before: "x = \"\""))
    }

    func testGenericAngleNeedsTypeNameInFront() {
        XCTAssertTrue(shouldPair(.genericAngle, before: "List"))
        XCTAssertTrue(shouldPair(.genericAngle, before: "private Map<String, List"))
        XCTAssertFalse(shouldPair(.genericAngle, before: "a "))
        XCTAssertFalse(shouldPair(.genericAngle, before: "i"))
        XCTAssertFalse(shouldPair(.genericAngle, before: "if (a "))
        XCTAssertFalse(shouldPair(.genericAngle, before: ""))
    }
}

@MainActor
final class SmartCharacterPairTests: XCTestCase {
    private static let pairs: [CharacterPair] = [
        BasicCharacterPair(leading: "(", trailing: ")", kind: .bracket),
        BasicCharacterPair(leading: "{", trailing: "}", kind: .bracket),
        BasicCharacterPair(leading: "\"", trailing: "\"", kind: .quote),
        BasicCharacterPair(leading: "<", trailing: ">", kind: .genericAngle)
    ]

    /// `input` marks the caret with `|`; every string in `typing` is inserted in turn.
    private func type(_ typing: [String], into input: String) -> String {
        let caret = (input as NSString).range(of: "|").location
        let text = input.replacingOccurrences(of: "|", with: "")
        let textView = makeFocusedTextView(text: text)
        textView.characterPairs = Self.pairs
        textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent
        textView.selectedRange = NSRange(location: caret, length: 0)
        for string in typing {
            textView.insertText(string)
        }
        let result = textView.text as String
        let location = textView.selectedRange.location
        return (result as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "|")
    }

    func testOpeningParenthesisInsertsPair() {
        XCTAssertEqual(type(["("], into: "foo|"), "foo(|)")
    }

    func testOpeningParenthesisBeforeIdentifierIsTypedAlone() {
        XCTAssertEqual(type(["("], into: "|foo"), "(|foo")
    }

    func testTypingTheClosingCharacterSkipsOverIt() {
        XCTAssertEqual(type(["(", ")"], into: "foo|"), "foo()|")
    }

    func testQuoteAfterLetterIsTypedAlone() {
        XCTAssertEqual(type(["'"], into: "don|"), "don'|")
        XCTAssertEqual(type(["\""], into: "x = |"), "x = \"|\"")
    }

    func testGenericAngleOnlyAfterTypeName() {
        XCTAssertEqual(type(["<"], into: "List|"), "List<|>")
        XCTAssertEqual(type(["<"], into: "a |"), "a <|")
    }

    func testPairWrapsASelectionRegardlessOfContext() {
        let textView = makeFocusedTextView(text: "foo bar")
        textView.characterPairs = Self.pairs
        textView.selectedRange = NSRange(location: 0, length: 3)
        textView.insertText("(")
        XCTAssertEqual(textView.text as String, "(foo) bar")
    }

    func testBackspaceRemovesBothComponents() {
        let textView = makeFocusedTextView(text: "foo")
        textView.characterPairs = Self.pairs
        textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertText("(")
        textView.deleteBackward()
        XCTAssertEqual(textView.text as String, "foo")
    }
}

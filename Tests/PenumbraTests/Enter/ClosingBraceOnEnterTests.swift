@preconcurrency import AppKit
import PenumbraLanguages
import XCTest
@testable import Penumbra

final class UnmatchedBraceScannerTests: XCTestCase {
    private func scan(_ text: String, indent: String = "", end: Bool = true) -> UnmatchedBraceScanner.Result {
        UnmatchedBraceScanner.scan(text: text, openerIndent: indent, isEndOfDocument: end)
    }

    func testEndOfDocumentLeavesTheBraceOpen() {
        XCTAssertEqual(scan("\n"), .unmatched)
    }

    func testCloserAtTheSameIndentMatches() {
        XCTAssertEqual(scan("\n    }\n}", indent: "    "), .matched)
    }

    func testCloserLessIndentedBelongsToAnEnclosingBlock() {
        XCTAssertEqual(scan("\n}\n", indent: "    "), .unmatched)
    }

    func testNestedBlocksAreCounted() {
        XCTAssertEqual(scan("\n    if (x) {\n    }\n}", indent: ""), .matched)
    }

    func testBracesInStringsAndCommentsAreIgnored() {
        XCTAssertEqual(scan("\n    String s = \"}\"; // }\n    /* } */\n", indent: "    "), .unmatched)
        XCTAssertEqual(scan("\n    char c = '}';\n    }\n", indent: "    "), .matched)
    }

    func testBracesInATextBlockAreIgnored() {
        XCTAssertEqual(scan("\n    String s = \"\"\"\n    }\n    \"\"\";\n", indent: "    "), .unmatched)
    }

    func testTruncatedWindowAsksForMoreText() {
        XCTAssertEqual(scan("\n    foo();\n", indent: "    ", end: false), .needsMoreText)
    }
}

@MainActor
final class ClosingBraceOnEnterTests: XCTestCase {
    private func pressEnter(_ input: String, enabled: Bool = true) -> String {
        let caretOffset = (input as NSString).range(of: "|").location
        let text = input.replacingOccurrences(of: "|", with: "")
        let textView = makeFocusedTextView(text: text)
        if let language = BundledLanguages.language(forIdentifier: "java") {
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        }
        textView.indentStrategy = .space(length: 4)
        textView.insertsClosingBraceOnEnter = enabled
        textView.selectedRange = NSRange(location: caretOffset, length: 0)
        textView.insertText("\n")
        let result = textView.text as String
        let caret = textView.selectedRange.location
        return (result as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "|")
    }

    func testUnclosedBraceAtEndOfFileGetsItsClosingBrace() {
        XCTAssertEqual(pressEnter("class A {|"), "class A {\n    |\n}")
    }

    func testBraceClosedByAnEnclosingBlockGetsItsOwn() {
        XCTAssertEqual(
            pressEnter("class A {\n    void f() {|\n}"),
            "class A {\n    void f() {\n        |\n    }\n}"
        )
    }

    func testBraceThatAlreadyHasItsCloserIsLeftAlone() {
        XCTAssertEqual(
            pressEnter("class A {\n    void f() {|\n    }\n}"),
            "class A {\n    void f() {\n        |\n    }\n}"
        )
    }

    func testBraceInACommentGetsNothing() {
        XCTAssertEqual(pressEnter("class A {\n    // see {|\n}"), "class A {\n    // see {\n    |\n}")
    }

    func testDisabledKeepsTheOldBehavior() {
        XCTAssertEqual(pressEnter("class A {|", enabled: false), "class A {\n    |")
    }
}

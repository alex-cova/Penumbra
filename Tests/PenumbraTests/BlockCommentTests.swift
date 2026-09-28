import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

final class BlockCommentServiceTests: XCTestCase {
    private func toggle(_ text: String, _ selections: [NSRange],
                        delimiters: BlockCommentDelimiters = .cStyle) -> (text: String, selections: [NSRange])? {
        let ns = text as NSString
        let service = BlockCommentService(delimiters: delimiters, documentLength: ns.length) { range in
            guard range.location >= 0, range.upperBound <= ns.length else { return nil }
            return ns.substring(with: range)
        }
        guard let result = service.toggle(selections) else { return nil }
        let output = NSMutableString(string: text)
        for edit in result.edits.reversed() {
            output.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return (output as String, result.selections)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    func testWrapsASelectionAndKeepsItSelected() {
        let result = toggle("let x = 1", [NSRange(location: 4, length: 1)])
        XCTAssertEqual(result?.text, "let /* x */ = 1")
        XCTAssertEqual(result?.selections, [NSRange(location: 7, length: 1)])
    }

    func testUnwrapsWhenTheSelectionIsTheComment() {
        let result = toggle("a /* b */ c", [NSRange(location: 2, length: 7)])
        XCTAssertEqual(result?.text, "a b c")
        XCTAssertEqual(result?.selections, [NSRange(location: 2, length: 1)])
    }

    func testUnwrapsWhenTheSelectionIsInsideTheComment() {
        let result = toggle("a /* b */ c", [NSRange(location: 5, length: 1)])
        XCTAssertEqual(result?.text, "a b c")
        XCTAssertEqual(result?.selections, [NSRange(location: 2, length: 1)])
    }

    func testUnwrapsWhenTheCaretIsInsideTheComment() {
        let result = toggle("a /* b */ c", [caret(6)])
        XCTAssertEqual(result?.text, "a b c")
        XCTAssertEqual(result?.selections, [caret(3)])
    }

    func testWrapsTheCaretLineContentAndKeepsIndent() {
        let result = toggle("  foo(bar);", [caret(5)])
        XCTAssertEqual(result?.text, "  /* foo(bar); */")
        XCTAssertEqual(result?.selections, [caret(8)])
    }

    func testCaretInLeadingWhitespaceStaysPut() {
        let result = toggle("    foo", [caret(2)])
        XCTAssertEqual(result?.text, "    /* foo */")
        XCTAssertEqual(result?.selections, [caret(2)])
    }

    func testBlankLineGetsAnEmptyCommentWithTheCaretInside() {
        let result = toggle("", [caret(0)])
        XCTAssertEqual(result?.text, "/*  */")
        XCTAssertEqual(result?.selections, [caret(3)])
    }

    func testDelimitersWithoutSpacesUnwrapCleanly() {
        XCTAssertEqual(toggle("/*x*/", [caret(3)])?.text, "x")
        XCTAssertEqual(toggle("/**/", [caret(2)])?.text, "")
    }

    func testRefusesToWrapTextThatAlreadyContainsTheClosingDelimiter() {
        XCTAssertNil(toggle("a */ b", [NSRange(location: 0, length: 6)]))
        XCTAssertNil(toggle("/* a */ b", [caret(8)]), "The line holds a closed comment, so wrapping would nest")
    }

    func testTwoAdjacentCommentsAreNotTreatedAsOne() {
        XCTAssertNil(toggle("/* a */ /* b */", [NSRange(location: 0, length: 15)]))
    }

    func testCaretAfterAClosedCommentIsNotInsideIt() {
        // The comment before the caret ended, so the caret's line is wrapped, not unwrapped.
        let result = toggle("x\n/* a */ b", [caret(1)])
        XCTAssertEqual(result?.text, "/* x */\n/* a */ b")
    }

    func testEveryCaretGetsItsOwnComment() {
        let result = toggle("one\ntwo", [caret(1), caret(5)])
        XCTAssertEqual(result?.text, "/* one */\n/* two */")
        XCTAssertEqual(result?.selections, [caret(4), caret(14)])
    }

    func testTwoCaretsOnTheSameLineWrapItOnce() {
        let result = toggle("foo bar", [caret(1), caret(5)])
        XCTAssertEqual(result?.text, "/* foo bar */")
    }

    func testTwoCaretsInTheSameCommentUnwrapItOnce() {
        let result = toggle("/* a b */", [caret(4), caret(6)])
        XCTAssertEqual(result?.text, "a b")
    }

    func testHTMLDelimiters() {
        let result = toggle("<p>hi</p>", [caret(3)], delimiters: .html)
        XCTAssertEqual(result?.text, "<!-- <p>hi</p> -->")
        XCTAssertEqual(toggle("<!-- <p>hi</p> -->", [caret(8)], delimiters: .html)?.text, "<p>hi</p>")
    }

    func testTogglingTwiceRestoresTheText() {
        let original = "let x = compute(a, b)"
        let once = toggle(original, [NSRange(location: 8, length: 13)])
        let twice = once.flatMap { toggle($0.text, $0.selections) }
        XCTAssertEqual(twice?.text, original)
        XCTAssertEqual(twice?.selections, [NSRange(location: 8, length: 13)])
    }

    func testAMultilineSelectionWrapsAsOneComment() {
        let result = toggle("a\nb\nc", [NSRange(location: 0, length: 5)])
        XCTAssertEqual(result?.text, "/* a\nb\nc */")
    }
}

@MainActor
final class BlockCommentTextViewTests: XCTestCase {
    private func makeTextView(_ text: String, delimiters: BlockCommentDelimiters? = .cStyle) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        let language = TreeSitterLanguage(tree_sitter_javascript(), lineCommentPrefix: "//",
                                          blockCommentDelimiters: delimiters)
        textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        return textView
    }

    func testWrapsTheSelectionInTheView() {
        let textView = makeTextView("let x = 1")
        textView.selectedRange = NSRange(location: 4, length: 1)

        textView.toggleBlockComment()

        XCTAssertEqual(textView.text, "let /* x */ = 1")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 1))
    }

    func testIsOneUndoStepAcrossCarets() {
        let textView = makeTextView("one\ntwo")
        textView.selectedRanges = [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)]

        textView.toggleBlockComment()
        XCTAssertEqual(textView.text, "/* one */\n/* two */")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "one\ntwo")
    }

    func testDoesNothingWithoutBlockCommentSyntax() {
        let textView = makeTextView("let x = 1", delimiters: nil)
        textView.selectedRange = NSRange(location: 4, length: 1)

        textView.toggleBlockComment()

        XCTAssertEqual(textView.text, "let x = 1")
    }

    func testOptionCommandSlashRoutesToItUnderTheIntelliJKeymap() {
        let textView = makeTextView("let x = 1")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 4, length: 1)

        send(keyEvent(keyCode: 0x2C, characters: "/", flags: [.command, .option]), to: textView)

        XCTAssertEqual(textView.text, "let /* x */ = 1")
    }

    func testLineCommentStillWorksAlongsideIt() {
        let textView = makeTextView("let x = 1")
        textView.selectedRange = NSRange(location: 0, length: 0)

        textView.toggleComment()

        XCTAssertEqual(textView.text, "// let x = 1")
    }
}

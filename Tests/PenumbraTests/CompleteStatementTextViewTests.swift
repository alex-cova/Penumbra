import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

@MainActor
final class CompleteStatementTextViewTests: XCTestCase {
    /// A view whose language opts into C-style Enter behavior, like Java does.
    private func makeTextView(_ text: String, cStyle: Bool = true) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        let language = TreeSitterLanguage(tree_sitter_javascript(), enterBehavior: cStyle ? .java : nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        textView.indentStrategy = .space(length: 4)
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        return textView
    }

    func testClosesBracketsAddsASemicolonAndStartsANewLine() {
        let textView = makeTextView("foo(bar(")
        textView.selectedRange = NSRange(location: 3, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "foo(bar());\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 0))
    }

    func testTheNewLineGetsTheIndentationEnterWouldGive() {
        // Inside a block, the new line lines up with the statement above it.
        let textView = makeTextView("void f() {\n    foo(x)\n}")
        textView.selectedRange = NSRange(location: 17, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "void f() {\n    foo(x);\n    \n}")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 27, length: 0))
    }

    func testAHeaderGetsABodyWithTheCaretInsideIt() {
        let textView = makeTextView("if (x > 0")
        textView.selectedRange = NSRange(location: 9, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "if (x > 0) {\n    \n}")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 17, length: 0), "Inside the body, after its indent")
    }

    func testAFinishedLineJustStartsANewLine() {
        let textView = makeTextView("int x = 1;")
        textView.selectedRange = NSRange(location: 3, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "int x = 1;\n")
    }

    func testEveryCaretLineIsCompleted() {
        let textView = makeTextView("foo(a\nbar(b")
        textView.selectedRanges = [NSRange(location: 2, length: 0), NSRange(location: 9, length: 0)]

        textView.completeStatement()

        XCTAssertEqual(textView.text, "foo(a);\n\nbar(b);\n")
        XCTAssertEqual(textView.selectedRanges.count, 2)
    }

    func testIsOneUndoStep() {
        let textView = makeTextView("foo(bar(")
        textView.selectedRange = NSRange(location: 8, length: 0)

        textView.completeStatement()
        XCTAssertEqual(textView.text, "foo(bar());\n")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "foo(bar(")
    }

    func testLanguagesWithoutCStyleStructureJustStartANewLine() {
        let textView = makeTextView("foo(bar(", cStyle: false)
        textView.selectedRange = NSRange(location: 3, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "foo(bar(\n")
    }

    func testCommandShiftReturnRoutesToItUnderTheIntelliJKeymap() {
        let textView = makeTextView("foo(x)")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 2, length: 0)

        send(keyEvent(keyCode: 0x24, flags: [.command, .shift]), to: textView)

        XCTAssertEqual(textView.text, "foo(x);\n")
    }

    func testTheKeymapBindsItOnlyUnderIntelliJ() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x24, [.command, .shift]))), .completeStatement)
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x24, [.command, .shift]))), .insertLineAbove)
    }

    func testAnEmptyConditionKeepsTheCaretInTheParentheses() {
        let textView = makeTextView("if (")
        textView.selectedRange = NSRange(location: 4, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "if () {\n    \n}")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testDoGrowsAWhileAndSplitsTheBody() {
        let textView = makeTextView("do")
        textView.selectedRange = NSRange(location: 2, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "do {\n    \n} while ();")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 9, length: 0))
    }

    func testASwitchExpressionKeepsTheSemicolonOnTheClosingLine() {
        let textView = makeTextView("int x = switch (n)")
        textView.selectedRange = NSRange(location: 18, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "int x = switch (n) {\n    \n};")
    }

    func testACallSplitAcrossLinesClosesEveryParen() {
        let textView = makeTextView("foo(a,\n b")
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "foo(a,\n b);\n")
    }

    func testAnArrayInitializerClosesAndEndsTheStatement() {
        let textView = makeTextView("new int[]{1, 2")
        textView.selectedRange = NSRange(location: 14, length: 0)

        textView.completeStatement()

        XCTAssertEqual(textView.text, "new int[]{1, 2};\n")
    }

    func testLookbehindStopsAfterThirtyLines() {
        let above = Array(repeating: "foo(", count: 31).joined(separator: "\n")
        let textView = makeTextView(above + "\nx")
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)

        textView.completeStatement()

        let lines = textView.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "foo(")
        XCTAssertEqual(lines[lines.count - 2], "x" + String(repeating: ")", count: 30) + ";")
    }

    func testPreservingTheCaretAppendsTheSemicolonWithoutANewLine() {
        let textView = makeTextView("println()")
        textView.selectedRange = NSRange(location: 8, length: 0)

        textView.completeStatement(preservingCaretInsideParens: true)

        XCTAssertEqual(textView.text, "println();")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 0))
    }
}

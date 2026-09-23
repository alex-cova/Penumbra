@preconcurrency import AppKit
import PenumbraLanguages
import XCTest
@testable import Penumbra

@MainActor
final class JavaEnterHandlingTests: XCTestCase {
    /// Builds a Java text view from `input` (where `|` marks the caret), presses Enter, and returns the
    /// resulting text with `|` at the caret.
    private func pressEnter(_ input: String, language: String? = "java", indent: IndentStrategy = .space(length: 4)) -> String {
        let caretOffset = (input as NSString).range(of: "|").location
        let text = input.replacingOccurrences(of: "|", with: "")
        let textView = makeFocusedTextView(text: text)
        if let language, let treeSitterLanguage = BundledLanguages.language(forIdentifier: language) {
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: treeSitterLanguage))
        }
        textView.indentStrategy = indent
        textView.selectedRange = NSRange(location: caretOffset, length: 0)
        textView.insertText("\n")
        return annotated(textView)
    }

    private func annotated(_ textView: TextView) -> String {
        let text = textView.text as String
        let caret = textView.selectedRange.location
        return (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "|")
    }

    // MARK: - Braces

    func testEnterBetweenBracesSplitsAndIndents() {
        let result = pressEnter("class A {\n    void f() {|}\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        |\n    }\n}")
    }

    func testEnterAfterOpeningBraceIndentsOneLevel() {
        let result = pressEnter("class A {\n    void f() {|\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        |\n}")
    }

    func testEnterBeforeClosingBraceOutdents() {
        let result = pressEnter("class A {\n    void f() {\n        foo();|}\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        foo();\n    |}\n}")
    }

    // MARK: - Continuation

    func testEnterInsideUnclosedParenthesesUsesContinuationIndent() {
        let result = pressEnter("class A {\n    void f() {\n        foo(a,|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        foo(a,\n                |\n    }\n}")
    }

    func testEnterAfterFinishedContinuationReturnsToBlockIndent() {
        let result = pressEnter("class A {\n    void f() {\n        int y = foo(\n                a);|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        int y = foo(\n                a);\n        |\n    }\n}")
    }

    func testEnterAfterTrailingOperatorUsesContinuationIndent() {
        let result = pressEnter("class A {\n    void f() {\n        x = a +|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        x = a +\n                |\n    }\n}")
    }

    func testEnterAfterEnumConstantCommaKeepsIndent() {
        let result = pressEnter("enum E {\n    A,|\n}")
        XCTAssertEqual(result, "enum E {\n    A,\n    |\n}")
    }

    func testEnterAfterArrayInitializerCommaKeepsIndent() {
        let result = pressEnter("class A {\n    int[] a = {\n        1,|\n    };\n}")
        XCTAssertEqual(result, "class A {\n    int[] a = {\n        1,\n        |\n    };\n}")
    }

    // MARK: - Brace-less control statements

    func testEnterAfterBracelessIfIndentsBody() {
        let result = pressEnter("class A {\n    void f() {\n        if (x)|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        if (x)\n            |\n    }\n}")
    }

    func testEnterAfterBracelessElseIndentsBody() {
        let result = pressEnter("class A {\n    void f() {\n        if (x) a();\n        else|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        if (x) a();\n        else\n            |\n    }\n}")
    }

    func testEnterAfterBracelessBodyReturnsToBlockIndent() {
        let result = pressEnter("class A {\n    void f() {\n        if (x)\n            a();|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        if (x)\n            a();\n        |\n    }\n}")
    }

    func testEnterAfterCaseLabelIndentsBody() {
        // IntelliJ's default indents `case` labels one level inside the switch and their bodies one more.
        let result = pressEnter("class A {\n    void f() {\n        switch (x) {\n            case 1:|\n        }\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        switch (x) {\n            case 1:\n                |\n        }\n    }\n}")
    }

    func testBracesInsideStringsAndCommentsDoNotAffectIndent() {
        let result = pressEnter("class A {\n    void f() {\n        String s = \"{(\"; // {\n        g();|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        String s = \"{(\"; // {\n        g();\n        |\n    }\n}")
    }

    // MARK: - Javadoc

    func testEnterAfterDocCommentOpeningGeneratesClosingDelimiter() {
        let result = pressEnter("class A {\n    /**|\n    void f() {}\n}")
        XCTAssertEqual(result, "class A {\n    /**\n     * |\n     */\n    void f() {}\n}")
    }

    func testEnterInsideDocCommentContinuesPrefix() {
        let result = pressEnter("class A {\n    /**\n     * text|\n     */\n    void f() {}\n}")
        XCTAssertEqual(result, "class A {\n    /**\n     * text\n     * |\n     */\n    void f() {}\n}")
    }

    func testEnterOnDocCommentOpeningLineWithTextContinuesPrefix() {
        let result = pressEnter("class A {\n    /** text|\n     */\n    void f() {}\n}")
        XCTAssertEqual(result, "class A {\n    /** text\n     * |\n     */\n    void f() {}\n}")
    }

    func testEnterBeforeCommentTerminatorMovesItToItsOwnLine() {
        let result = pressEnter("class A {\n    /** text |*/\n    void f() {}\n}")
        XCTAssertEqual(result, "class A {\n    /** text \n     * |\n     */\n    void f() {}\n}")
    }

    func testStarLineOutsideCommentIsNotContinued() {
        let result = pressEnter("class A {\n    void f() {\n        int x = a\n                * b|\n    }\n}")
        XCTAssertEqual(result, "class A {\n    void f() {\n        int x = a\n                * b\n        |\n    }\n}")
    }

    // MARK: - String literals

    func testEnterInsideStringLiteralSplitsWithConcatenation() {
        let result = pressEnter("class A {\n    String s = \"abc|def\";\n}")
        XCTAssertEqual(result, "class A {\n    String s = \"abc\" +\n            \"|def\";\n}")
    }

    func testEnterInsideSecondStringSegmentKeepsAlignment() {
        let result = pressEnter("class A {\n    String s = \"abc\" +\n            \"de|f\";\n}")
        XCTAssertEqual(result, "class A {\n    String s = \"abc\" +\n            \"de\" +\n            \"|f\";\n}")
    }

    func testEnterInsideTextBlockDoesNotSplit() {
        let result = pressEnter("class A {\n    String s = \"\"\"\n        ab|c\n        \"\"\";\n}")
        XCTAssertFalse(result.contains("\" +"))
    }

    func testEnterAfterEscapedBackslashQuoteDoesNotSplit() {
        let result = pressEnter("class A {\n    String s = \"abc\\|\";\n}")
        XCTAssertFalse(result.contains("\" +"))
    }

    func testEnterInsideCharLiteralQuoteDoesNotSplit() {
        let result = pressEnter("class A {\n    char c = '\"';|\n}")
        XCTAssertEqual(result, "class A {\n    char c = '\"';\n    |\n}")
    }

    // MARK: - Editing semantics

    func testEnterReplacesSelectionFirst() {
        let textView = makeFocusedTextView(text: "class A {\n    int x = foo;\n}")
        if let language = BundledLanguages.language(forIdentifier: "java") {
            textView.setState(TextViewState(text: "class A {\n    int x = foo;\n}", theme: DefaultTheme(), language: language))
        }
        textView.indentStrategy = .space(length: 4)
        let range = ("class A {\n    int x = foo;\n}" as NSString).range(of: "foo")
        textView.selectedRange = range
        textView.insertText("\n")
        XCTAssertEqual(textView.text as String, "class A {\n    int x = \n            ;\n}")
    }

    func testEnterAtMultipleCaretsIsOneUndoStep() {
        let text = "class A {\n    void f() {}\n    void g() {}\n}"
        let textView = makeFocusedTextView(text: text)
        if let language = BundledLanguages.language(forIdentifier: "java") {
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        }
        textView.indentStrategy = .space(length: 4)
        let ns = text as NSString
        let first = ns.range(of: "{}").location + 1
        let second = ns.range(of: "{}", options: .backwards).location + 1
        textView.selectedRanges = [NSRange(location: first, length: 0), NSRange(location: second, length: 0)]
        textView.insertText("\n")
        XCTAssertEqual(textView.text as String,
                       "class A {\n    void f() {\n        \n    }\n    void g() {\n        \n    }\n}")
        XCTAssertEqual(textView.selectedRanges.count, 2)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, text)
    }

    func testHostDelegateWinsOverBuiltInHandlers() {
        final class Delegate: EnterHandlerDelegate {
            func enterEdit(for context: EnterContext) -> EnterEdit? {
                EnterEdit(replacementRange: context.selectedRange, text: "\n<host>", caretOffset: nil)
            }
        }
        let text = "class A {\n    void f() {}\n}"
        let textView = makeFocusedTextView(text: text)
        if let language = BundledLanguages.language(forIdentifier: "java") {
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        }
        let delegate = Delegate()
        textView.enterHandlerDelegates = [delegate]
        textView.selectedRange = NSRange(location: (text as NSString).range(of: "{}").location + 1, length: 0)
        textView.insertText("\n")
        XCTAssertEqual(textView.text as String, "class A {\n    void f() {\n<host>}\n}")
    }

    func testTabIndentStrategyUsesTabsForContinuation() {
        let result = pressEnter("class A {\n\tvoid f() {\n\t\tfoo(a,|\n\t}\n}", indent: .tab(length: 4))
        XCTAssertEqual(result, "class A {\n\tvoid f() {\n\t\tfoo(a,\n\t\t\t\t|\n\t}\n}")
    }

    // MARK: - Plain text and languages without rules

    func testPlainTextCopiesLeadingWhitespace() {
        let result = pressEnter("\t  foo|", language: nil)
        XCTAssertEqual(result, "\t  foo\n\t  |")
    }

    func testPlainTextSplitsBraces() {
        let result = pressEnter("  {|}", language: nil)
        XCTAssertEqual(result, "  {\n      |\n  }")
    }

    func testTextAfterCaretIsNotIndentedTwice() {
        let result = pressEnter("    foo| bar", language: nil)
        XCTAssertEqual(result, "    foo\n    |bar")
    }
}

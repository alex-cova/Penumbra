import XCTest
@testable import JavaIntelligence

/// `JavaCompletionProvider.blankingBrokenStatements`: an earlier statement that ends in `;` with a
/// parenthesis still open would swallow the caret's line as one more argument.
final class JavaBrokenStatementRepairTests: XCTestCase {
    /// Repairs everything before the end of `text` (the caret is at its end).
    private func repaired(_ text: String) -> String {
        JavaCompletionProvider.blankingBrokenStatements(in: text as NSString, before: (text as NSString).length)
    }

    func testUnmatchedParenthesesOfAStatementThatEndsInASemicolonAreReplaced() {
        XCTAssertEqual(repaired("a.println(x.length(;\nit"), "a.println+x.length+;\nit")
        XCTAssertEqual(repaired("foo(bar(baz(x.length(;\n  it"), "foo+bar+baz+x.length+;\n  it")
    }

    func testMatchedParenthesesStayAndOnlyTheOpenOnesGo() {
        // `a(1)` is closed and stays; `f(` and `b(` are the two that never close.
        XCTAssertEqual(repaired("f(a(1), b(;\nit"), "f+a(1), b+;\nit")
    }

    func testLengthAndEveryOffsetBeforeTheCaretArePreserved() {
        let text = "int é = 1;\nprintln(\"(\" + x(;\n  it"
        let result = repaired(text)
        XCTAssertEqual((result as NSString).length, (text as NSString).length)
        // Everything that is not a replaced parenthesis is where it was.
        let differences = zip(text.utf16, result.utf16).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(differences.count, 2, "println( and x( are the two unmatched parentheses")
    }

    func testForHeaderAndBalancedAndMultiLineConstructsAreLeftAlone() {
        for text in [
            "for (int i = 0;\n  it",
            "for(int i = 0;\n  it",
            "for (int i = 0;\n     i < 3;\n     i++) {\n  it",
            "System.out.println(\n    x.length());\n  it",
            "call(a,\n     b);\n  it",
            "int x = 1;\n  it",
        ] {
            XCTAssertEqual(repaired(text), text, "should be untouched:\n\(text)")
        }
    }

    func testAnIdentifierEndingInForIsNotAForHeader() {
        XCTAssertEqual(repaired("afor(x(;\n  it"), "afor+x+;\n  it")
    }

    func testStringsAndLineCommentsDoNotCountAsParentheses() {
        XCTAssertEqual(repaired("log(\"(((\");\n  it"), "log(\"(((\");\n  it")
        XCTAssertEqual(repaired("run(); // call(;\n  it"), "run(); // call(;\n  it")
        XCTAssertEqual(repaired("s = \"a;\" + f(;\n  it"), "s = \"a;\" + f+;\n  it")
    }

    func testOnlyALineEndingInASemicolonIsRepaired() {
        XCTAssertEqual(repaired("foo(bar,\n  it"), "foo(bar,\n  it")
        XCTAssertEqual(repaired("if (a) {\n  it"), "if (a) {\n  it")
    }

    func testOnlyTheLinesNearTheCaretAreLookedAt() {
        let far = "far(;\n" + String(repeating: "x = 1;\n", count: 60)
        XCTAssertEqual(repaired(far + "  it"), far + "  it", "a broken statement 60 lines up is out of the window")
        let near = "near(;\n" + String(repeating: "x = 1;\n", count: 10)
        XCTAssertEqual(repaired(near + "  it"), "near+;\n" + String(repeating: "x = 1;\n", count: 10) + "  it")
    }

    func testTextWithoutASemicolonIsReturnedAsIs() {
        XCTAssertEqual(repaired("foo(bar(\n  it"), "foo(bar(\n  it")
    }
}

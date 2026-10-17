import XCTest
@testable import Penumbra

final class StatementCompletionServiceTests: XCTestCase {
    /// The line after the completion is applied, with `|` marking the caret when the completion
    /// puts it somewhere other than the end of the line.
    private func complete(_ line: String, preceding: [String] = [], extra: Set<String> = []) -> String? {
        guard let completion = StatementCompletionService.complete(
            line: line, precedingLines: preceding, extraControlKeywords: extra
        ) else {
            return nil
        }
        let text = NSMutableString(string: line)
        text.insert(completion.appended, at: completion.insertionOffset)
        if let caret = completion.caretOffsetInAppended {
            text.insert("|", at: completion.insertionOffset + caret)
        }
        guard !preceding.isEmpty else {
            return text as String
        }
        return (preceding + [text as String]).joined(separator: "\n")
    }

    // MARK: Statements

    func testAddsASemicolonToAnExpressionStatement() {
        XCTAssertEqual(complete("    System.out.println(x)"), "    System.out.println(x);")
        XCTAssertEqual(complete("x = 5"), "x = 5;")
        XCTAssertEqual(complete("return x"), "return x;")
        XCTAssertEqual(complete("int count = list.size()"), "int count = list.size();")
    }

    func testClosesBracketsBeforeTheSemicolon() {
        XCTAssertEqual(complete("foo(bar("), "foo(bar());")
        XCTAssertEqual(complete("foo(bar(baz, qux"), "foo(bar(baz, qux));")
        XCTAssertEqual(complete("int[] a = new int[3"), "int[] a = new int[3];")
        XCTAssertEqual(complete("list.get(map[key"), "list.get(map[key]);")
    }

    func testClosesAnUnterminatedString() {
        XCTAssertEqual(complete("System.out.println(\"hello"), "System.out.println(\"hello\");")
    }

    func testBracketsInsideStringsAndCommentsAreIgnored() {
        XCTAssertEqual(complete("log(\"a (b\")"), "log(\"a (b\");")
        XCTAssertEqual(complete("foo(x // (see docs"), "foo(x); // (see docs")
        XCTAssertEqual(complete("foo(/* ( */ x"), "foo(/* ( */ x);")
        XCTAssertEqual(complete("char c = '('"), "char c = '(';")
    }

    func testTrailingCommentStaysAfterTheInsertion() {
        XCTAssertEqual(complete("int x = 1 // one"), "int x = 1; // one")
    }

    func testAlreadyFinishedLinesGetNothing() {
        XCTAssertEqual(complete("int x = 1;"), "int x = 1;")
        XCTAssertEqual(complete("}"), "}")
        XCTAssertEqual(complete("} else {"), "} else {")
        XCTAssertEqual(complete("if (x) {"), "if (x) {")
    }

    func testLinesThatContinueGetNothing() {
        XCTAssertEqual(complete("String s = a +"), "String s = a +")
        XCTAssertEqual(complete("foo(a,"), "foo(a,")
        XCTAssertEqual(complete("if (a &&"), "if (a &&")
        XCTAssertEqual(complete("case 1:"), "case 1:")
        XCTAssertEqual(complete("x = cond ?"), "x = cond ?")
    }

    func testIncrementIsNotAContinuation() {
        XCTAssertEqual(complete("i++"), "i++;")
        XCTAssertEqual(complete("count--"), "count--;")
    }

    func testAnnotationsAndCommentsGetNothing() {
        XCTAssertEqual(complete("@Override"), "@Override")
        XCTAssertEqual(complete("@SuppressWarnings(\"unchecked\")"), "@SuppressWarnings(\"unchecked\")")
        XCTAssertEqual(complete(" * a javadoc line"), " * a javadoc line")
        XCTAssertNil(complete("// just a comment"))
        XCTAssertNil(complete("   "))
    }

    func testAssignedBlocksStillNeedASemicolon() {
        XCTAssertEqual(complete("int[] a = {1, 2}"), "int[] a = {1, 2};")
        XCTAssertEqual(complete("Runnable r = () -> { run(); }"), "Runnable r = () -> { run(); };")
        XCTAssertEqual(complete("if (a == b) { run(); }"), "if (a == b) { run(); }")
    }

    // MARK: Headers with a body

    func testControlHeadersGetABodyWithTheCaretBetweenTheBraces() {
        XCTAssertEqual(complete("if (x > 0)"), "if (x > 0) {|}")
        XCTAssertEqual(complete("for (int i = 0; i < n; i++)"), "for (int i = 0; i < n; i++) {|}")
        XCTAssertEqual(complete("while (running)"), "while (running) {|}")
        XCTAssertEqual(complete("switch (kind)"), "switch (kind) {|}")
        XCTAssertEqual(complete("synchronized (lock)"), "synchronized (lock) {|}")
    }

    func testHeadersWithUnclosedConditionsAreClosedFirst() {
        XCTAssertEqual(complete("if (x > 0"), "if (x > 0) {|}")
        XCTAssertEqual(complete("if (check(a"), "if (check(a)) {|}")
        XCTAssertEqual(complete("for (String s : list"), "for (String s : list) {|}")
    }

    func testBareHeadersGetABody() {
        XCTAssertEqual(complete("try"), "try {|}")
        XCTAssertEqual(complete("else"), "else {|}")
        XCTAssertEqual(complete("} else"), "} else {|}")
        XCTAssertEqual(complete("} finally"), "} finally {|}")
        XCTAssertEqual(complete("do"), "do {|} while ();")
    }

    func testCatchAfterABraceGetsABody() {
        XCTAssertEqual(complete("} catch (IOException e)"), "} catch (IOException e) {|}")
    }

    func testDoWhileClosesWithASemicolon() {
        XCTAssertEqual(complete("} while (x)"), "} while (x);")
    }

    func testAKeywordWithoutItsConditionIsLeftAlone() {
        XCTAssertEqual(complete("if"), "if")
    }

    func testTypeDeclarationsGetABody() {
        XCTAssertEqual(complete("public class Foo"), "public class Foo {|}")
        XCTAssertEqual(complete("interface Shape"), "interface Shape {|}")
        XCTAssertEqual(complete("public enum Color"), "public enum Color {|}")
        XCTAssertEqual(complete("record Point(int x, int y)"), "record Point(int x, int y) {|}")
        XCTAssertEqual(complete("public class Foo extends Bar implements Baz"),
                       "public class Foo extends Bar implements Baz {|}")
    }

    func testMethodsAndConstructorsGetABody() {
        XCTAssertEqual(complete("public void run()"), "public void run() {|}")
        XCTAssertEqual(complete("private static int add(int a, int b"), "private static int add(int a, int b) {|}")
        XCTAssertEqual(complete("List<String> names()"), "List<String> names() {|}")
        XCTAssertEqual(complete("void read() throws IOException"), "void read() throws IOException {|}")
        XCTAssertEqual(complete("public Foo(int x)"), "public Foo(int x) {|}")
        XCTAssertEqual(complete("@Override public String toString()"), "@Override public String toString() {|}")
    }

    func testAbstractAndNativeMethodsGetASemicolon() {
        XCTAssertEqual(complete("abstract void run()"), "abstract void run();")
        XCTAssertEqual(complete("public native int size()"), "public native int size();")
    }

    func testCallsAreNotMistakenForDeclarations() {
        XCTAssertEqual(complete("foo(x)"), "foo(x);")
        XCTAssertEqual(complete("obj.method(x)"), "obj.method(x);")
        XCTAssertEqual(complete("return compute(x)"), "return compute(x);")
        XCTAssertEqual(complete("new Thread(task)"), "new Thread(task);")
        XCTAssertEqual(complete("throw new IllegalStateException(\"bad\")"), "throw new IllegalStateException(\"bad\");")
        XCTAssertEqual(complete("var x = compute(y)"), "var x = compute(y);")
    }

    // MARK: Give up

    func testMismatchedBracketsAreLeftAlone() {
        XCTAssertNil(complete("foo(]"))
    }

    func testTextBlocksAreLeftAlone() {
        XCTAssertNil(complete("String s = \"\"\""))
    }

    func testAnOpenBlockCommentIsLeftAlone() {
        XCTAssertNil(complete("foo(/* still open"))
    }

    func testAnOpenBraceLeavesTheOuterBracketsAlone() {
        XCTAssertEqual(complete("executor.submit(() -> {"), "executor.submit(() -> {")
        XCTAssertEqual(complete("x -> {"), "x -> {")
    }

    // MARK: Empty headers, do, switch expressions, initializers

    func testAnEmptyConditionLeavesTheCaretInTheParentheses() {
        XCTAssertEqual(complete("if ("), "if (|) {}")
        XCTAssertEqual(complete("while ("), "while (|) {}")
        XCTAssertEqual(complete("for ("), "for (|) {}")
        XCTAssertEqual(complete("if ()"), "if (|) {}")
        XCTAssertEqual(complete("if ( )"), "if ( |) {}")
        XCTAssertEqual(complete("if (x > 0)"), "if (x > 0) {|}")
    }

    func testElseIfTakesACondition() {
        XCTAssertEqual(complete("else if"), "else if (|) {}")
        XCTAssertEqual(complete("else if ("), "else if (|) {}")
        XCTAssertEqual(complete("else if (x)"), "else if (x) {|}")
        XCTAssertEqual(complete("} else if (x > 0"), "} else if (x > 0) {|}")
        XCTAssertEqual(complete("else"), "else {|}")
    }

    func testElseStaysABodyWhenItIsAlsoAnExtraControlKeyword() {
        let java: Set<String> = ["if", "else", "for", "while", "do"]
        XCTAssertEqual(complete("else", extra: java), "else {|}")
        XCTAssertEqual(complete("do", extra: java), "do {|} while ();")
        XCTAssertEqual(complete("if", extra: java), "if")
    }

    func testASwitchExpressionGetsABodyAndASemicolon() {
        XCTAssertEqual(complete("switch (kind)"), "switch (kind) {|}")
        XCTAssertEqual(complete("switch (a = b)"), "switch (a = b) {|}")
        XCTAssertEqual(complete("int x = switch (n)"), "int x = switch (n) {|};")
        XCTAssertEqual(complete("= switch (x)"), "= switch (x) {|};")
        XCTAssertEqual(complete("return switch (x)"), "return switch (x) {|};")
    }

    func testArrayInitializersCloseWithABraceAndASemicolon() {
        XCTAssertEqual(complete("new int[]{1, 2"), "new int[]{1, 2};")
        XCTAssertEqual(complete("int[] a = {1, 2"), "int[] a = {1, 2};")
        XCTAssertEqual(complete("foo(new int[]{1, 2"), "foo(new int[]{1, 2});")
        XCTAssertEqual(complete("new int[]{1, 2,"), "new int[]{1, 2,")
    }

    func testAnUnclosedRecordHeaderGetsABody() {
        XCTAssertEqual(complete("record R(int a"), "record R(int a) {|}")
    }

    func testAStatementSpansLinesUntilABoundary() {
        XCTAssertEqual(complete(" b", preceding: ["foo(a,"]), "foo(a,\n b);")
        XCTAssertEqual(complete("    baz", preceding: ["foo(bar("]), "foo(bar(\n    baz));")
        XCTAssertEqual(complete("    > 0", preceding: ["if (x"]), "if (x\n    > 0) {|}")
        XCTAssertEqual(complete("    1, 2", preceding: ["int[] a = {"]), "int[] a = {\n    1, 2};")
        XCTAssertEqual(complete(" b", preceding: ["foo(\"(\","]), "foo(\"(\",\n b);")
        XCTAssertNil(complete("]", preceding: ["foo("]))
    }

    func testLookbehindStopsAtAFinishedLineAndASeparateCall() {
        XCTAssertFalse(StatementCompletionService.attaches(previousLine: "int x = 1;", toFragment: "foo("))
        XCTAssertFalse(StatementCompletionService.attaches(previousLine: "if (x) {", toFragment: "foo("))
        XCTAssertFalse(StatementCompletionService.attaches(previousLine: "foo(a", toFragment: "bar(b"))
        XCTAssertFalse(StatementCompletionService.attaches(previousLine: "x -> {", toFragment: "run();"))
        XCTAssertTrue(StatementCompletionService.attaches(previousLine: "foo(a,", toFragment: " b"))
        XCTAssertTrue(StatementCompletionService.attaches(previousLine: "foo(", toFragment: "bar"))
        XCTAssertTrue(StatementCompletionService.attaches(previousLine: "if (x", toFragment: "    > 0"))
        XCTAssertEqual(StatementCompletionService.maximumLookbehindLines, 30)
    }
}

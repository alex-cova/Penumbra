import XCTest
@testable import JavaIntelligence

final class JavaReceiverScannerTests: XCTestCase {
    /// The trigger dot is always the *last* `.` in `text` (chains like `"foo.bar."` legitimately
    /// contain earlier ones); everything before it is fed to the scanner and the returned range is
    /// decoded back to a string for a readable assertion.
    private func extract(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard let dotOffset = bytes.lastIndex(of: UInt8(ascii: ".")) else {
            fatalError("test text must contain a '.'")
        }
        guard let range = JavaReceiverScanner.receiverRange(in: bytes, dotOffset: dotOffset) else { return nil }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    func testSimpleIdentifier() {
        XCTAssertEqual(extract("foo."), "foo")
    }

    func testFieldChain() {
        XCTAssertEqual(extract("foo.bar."), "foo.bar")
    }

    func testMethodCallWithArguments() {
        XCTAssertEqual(extract("foo.bar(1, 2)."), "foo.bar(1, 2)")
    }

    func testNestedMethodCalls() {
        XCTAssertEqual(extract("foo.bar(baz.qux())."), "foo.bar(baz.qux())")
    }

    func testChainedMethodCalls() {
        XCTAssertEqual(extract("list.stream().filter(x -> x > 0)."), "list.stream().filter(x -> x > 0)")
    }

    func testArrayIndex() {
        XCTAssertEqual(extract("array[0]."), "array[0]")
    }

    func testChainedArrayIndexAndCall() {
        XCTAssertEqual(extract("matrix[0][1].toString()."), "matrix[0][1].toString()")
    }

    func testStopsAtReturnKeywordBoundary() {
        XCTAssertEqual(extract("return foo."), "foo")
    }

    func testStopsAtAssignmentBoundary() {
        XCTAssertEqual(extract("x = foo."), "foo")
    }

    func testStopsAtSemicolonBoundary() {
        XCTAssertEqual(extract("bar(); foo."), "foo")
    }

    func testStopsAtOpenBraceBoundary() {
        XCTAssertEqual(extract("{ foo."), "foo")
    }

    func testStopsAtOpenParenBoundary() {
        XCTAssertEqual(extract("bar(foo."), "foo")
    }

    func testStopsAtCommaBoundary() {
        XCTAssertEqual(extract("bar(a, foo."), "foo")
    }

    func testThisKeyword() {
        XCTAssertEqual(extract("this."), "this")
    }

    func testWhitespaceBetweenReceiverAndDot() {
        XCTAssertEqual(extract("foo ."), "foo")
    }

    func testNothingBeforeDotReturnsNil() {
        XCTAssertNil(extract("."))
    }

    func testOnlyWhitespaceBeforeDotReturnsNil() {
        XCTAssertNil(extract("  ."))
    }

    func testMismatchedClosingParenStopsCleanly() {
        // A stray unmatched ')' immediately before the dot (e.g. mid-edit) shouldn't crash or
        // scan past the buffer start; it's swallowed as a bracket-balance start and the scan
        // simply runs out of text, returning the whole prefix.
        XCTAssertEqual(extract(")."), ")")
    }

    func testGenericConstructorCall() {
        XCTAssertEqual(extract("new ArrayList<String>()."), "new ArrayList<String>()")
    }

    func testNestedGenericConstructorCall() {
        XCTAssertEqual(extract("new HashMap<String, List<Integer>>()."), "new HashMap<String, List<Integer>>()")
    }

    func testDiamondOperatorConstructorCall() {
        XCTAssertEqual(extract("new ArrayList<>()."), "new ArrayList<>()")
    }

    func testBareComparisonBeforeDotStopsAtWhitespace() {
        // "a > b." -- since "b" is directly followed by the dot, and "> " has a space right after
        // it, the whitespace-boundary rule (not the generic-list heuristic) is what stops this;
        // the receiver is just "b".
        XCTAssertEqual(extract("a > b."), "b")
    }

    func testUnclosedAngleBracketStopsCleanlyWithoutHanging() {
        // No matching '<' anywhere -- scanBackwardOverAngleBrackets must give up rather than walk
        // off the start of the buffer in an unbounded way, and the caller must fall back cleanly.
        XCTAssertEqual(extract("Foo>bar."), "bar")
    }

    func testStringLiteralReceiver() {
        XCTAssertEqual(extract("\"hello\"."), "\"hello\"")
    }

    func testStringLiteralWithEscapedQuoteReceiver() {
        XCTAssertEqual(extract("\"say \\\"hi\\\"\"."), "\"say \\\"hi\\\"\"")
    }

    func testStringLiteralMethodCallChain() {
        XCTAssertEqual(extract("\"hello\".trim()."), "\"hello\".trim()")
    }

    func testCharLiteralReceiver() {
        XCTAssertEqual(extract("'a'."), "'a'")
    }

    func testUnterminatedStringLiteralStopsCleanly() {
        // No matching opening quote -- must not hang or crash, just decline to extend further.
        XCTAssertNil(extract("hello\"."))
    }

    func testDotOffsetOutOfBoundsReturnsNil() {
        let bytes = Array("foo".utf8)
        XCTAssertNil(JavaReceiverScanner.receiverRange(in: bytes, dotOffset: 10))
    }

    func testByteAtOffsetNotADotReturnsNil() {
        let bytes = Array("foo.".utf8)
        XCTAssertNil(JavaReceiverScanner.receiverRange(in: bytes, dotOffset: 1)) // points at 'o', not '.'
    }
}

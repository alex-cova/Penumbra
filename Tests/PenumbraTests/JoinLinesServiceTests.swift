import XCTest
@testable import Penumbra

/// Pure "join lines" edit computation (⌃⇧J).
final class JoinLinesServiceTests: XCTestCase {
    private func makeService(_ text: String) -> JoinLinesService {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        return JoinLinesService(stringView: stringView, lineManager: lineManager)
    }

    private func applied(_ text: String, row: Int) -> String? {
        let service = makeService(text)
        guard let operation = service.joinOperation(atRow: row) else { return nil }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: operation.range, with: operation.replacement)
        return mutable as String
    }

    func testJoinsWithSingleSpaceCollapsingIndentation() {
        XCTAssertEqual(applied("foo\n    bar", row: 0), "foo bar")
    }

    func testDropsTrailingWhitespaceOnFirstLine() {
        XCTAssertEqual(applied("foo   \n   bar", row: 0), "foo bar")
    }

    func testNoSpaceBeforeClosingBracket() {
        XCTAssertEqual(applied("foo(\n    )", row: 0), "foo()")
    }

    func testNoSpaceAfterOpeningBracket() {
        XCTAssertEqual(applied("array = [\n    1", row: 0), "array = [1")
    }

    func testMergesTwoLineComments() {
        XCTAssertEqual(applied("// first\n// second", row: 0), "// first second")
    }

    func testLastRowHasNoJoin() {
        let service = makeService("only line")
        XCTAssertNil(service.joinOperation(atRow: 0))
    }

    func testCaretLandsAtJoinPoint() {
        let service = makeService("foo\nbar")
        let operation = service.joinOperation(atRow: 0)
        XCTAssertEqual(operation?.caretLocation, 3)
    }
}

import XCTest
@testable import Runestone

/// Pure "toggle line comment" edit computation (⌘/).
final class CommentToggleServiceTests: XCTestCase {
    private func makeService(_ text: String, prefix: String = "//") -> CommentToggleService {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        return CommentToggleService(stringView: stringView, lineManager: lineManager, commentPrefix: prefix)
    }

    private func applied(_ text: String, rows: Set<Int>, prefix: String = "//") -> String {
        let service = makeService(text, prefix: prefix)
        let direction = service.direction(forRows: rows)
        let edits = service.edits(forRows: rows, direction: direction)
        let mutable = NSMutableString(string: text)
        // Descending, matching how `TextInputView.toggleComment` applies them.
        for edit in edits.sorted(by: { $0.row > $1.row }) {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    // MARK: - Direction

    func testDirectionIsCommentWhenTheLineIsUncommented() {
        let service = makeService("foo\nbar")
        XCTAssertEqual(service.direction(forRows: [0]), .comment)
    }

    func testDirectionIsUncommentWhenEveryTouchedLineIsAlreadyCommented() {
        let service = makeService("// foo\n// bar")
        XCTAssertEqual(service.direction(forRows: [0, 1]), .uncomment)
    }

    func testDirectionIsCommentWhenAnyTouchedLineLacksThePrefix() {
        let service = makeService("// foo\nbar")
        XCTAssertEqual(service.direction(forRows: [0, 1]), .comment)
    }

    func testDirectionIgnoresBlankLinesWhenDecidingUncomment() {
        let service = makeService("// foo\n\n// bar")
        XCTAssertEqual(service.direction(forRows: [0, 1, 2]), .uncomment)
    }

    func testDirectionIsUncommentForAnAllBlankSelection() {
        let service = makeService("\n\n")
        XCTAssertEqual(service.direction(forRows: [0, 1]), .uncomment)
    }

    // MARK: - Comment

    func testCommentsAnUnindentedLine() {
        XCTAssertEqual(applied("foo", rows: [0]), "// foo")
    }

    func testCommentsAtTheIndentLevelNotColumnZero() {
        XCTAssertEqual(applied("    foo", rows: [0]), "    // foo")
    }

    func testCommentsEveryTouchedRowIncludingBlankOnes() {
        XCTAssertEqual(applied("foo\n\nbar", rows: [0, 1, 2]), "// foo\n// \n// bar")
    }

    func testCommentUsesTheConfiguredPrefix() {
        XCTAssertEqual(applied("foo", rows: [0], prefix: "#"), "# foo")
    }

    // MARK: - Uncomment

    func testUncommentsARow() {
        XCTAssertEqual(applied("// foo", rows: [0]), "foo")
    }

    func testUncommentPreservesIndentation() {
        XCTAssertEqual(applied("    // foo", rows: [0]), "    foo")
    }

    func testUncommentRemovesOneFollowingSpaceButNoMore() {
        XCTAssertEqual(applied("//   foo", rows: [0]), "  foo")
    }

    func testUncommentWithNoFollowingSpaceStillRemovesJustThePrefix() {
        XCTAssertEqual(applied("//foo", rows: [0]), "foo")
    }

    func testUncommentSkipsARowThatIsNotActuallyCommented() {
        let service = makeService("// foo\nbar")
        let edits = service.edits(forRows: [0, 1], direction: .uncomment)
        XCTAssertEqual(edits.map(\.row), [0])
    }

    // MARK: - Multi-row (non-contiguous, mirrors multi-caret)

    func testCommentsMultipleNonAdjacentRowsIndependently() {
        XCTAssertEqual(applied("foo\nbar\nbaz", rows: [0, 2]), "// foo\nbar\n// baz")
    }

    func testEmptyRowSetProducesNoEdits() {
        let service = makeService("foo")
        XCTAssertEqual(service.edits(forRows: [], direction: .comment).count, 0)
    }
}

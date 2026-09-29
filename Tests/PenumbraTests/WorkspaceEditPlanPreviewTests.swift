import XCTest
import EditorIntelligence

final class WorkspaceEditPlanPreviewTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Sample.txt")

    private func entries(_ text: String, _ query: WorkspaceSearchQuery, _ replacement: String) -> [WorkspaceEditPlanEntry] {
        ProjectReplacePlanner.entries(for: query, replacement: replacement, in: text, url: url)
    }

    private func preview(_ text: String, _ find: String, _ replacement: String, regex: Bool = false, window: Int = 60) throws -> [WorkspaceEditPreviewLine] {
        try entries(text, WorkspaceSearchQuery(text: find, isCaseSensitive: true, useRegularExpression: regex), replacement)
            .map { try XCTUnwrap($0.previewLine(window: window)) }
    }

    func testAPlainMatchSplitsTheLineAroundTheEdit() throws {
        let line = try XCTUnwrap(preview("let value = old + 1\n", "old", "new").first)
        XCTAssertEqual(line, WorkspaceEditPreviewLine(before: "let value = ", removed: "old", added: "new", after: " + 1"))
        XCTAssertEqual(line.oldLine, "let value = old + 1")
        XCTAssertEqual(line.newLine, "let value = new + 1")
    }

    func testAMatchAtTheStartAndAtTheEndOfTheLine() throws {
        let start = try XCTUnwrap(preview("old rest\n", "old", "new").first)
        XCTAssertEqual(start.before, "")
        XCTAssertEqual(start.after, " rest")
        let end = try XCTUnwrap(preview("rest old", "old", "new").first)
        XCTAssertEqual(end.before, "rest ")
        XCTAssertEqual(end.after, "")
    }

    func testEachMatchOnALinePreviewsOnlyItsOwnReplacement() throws {
        let lines = try preview("a x b x c\n", "x", "YY")
        XCTAssertEqual(lines.map(\.newLine), ["a YY b x c", "a x b YY c"])
        XCTAssertEqual(lines.map(\.oldLine), ["a x b x c", "a x b x c"])
    }

    func testAccentsAndEmojiUseUTF16Columns() throws {
        let lines = try preview("é😀 cat 😀 cat\n", "cat", "dog")
        XCTAssertEqual(lines.map(\.newLine), ["é😀 dog 😀 cat", "é😀 cat 😀 dog"])
        XCTAssertEqual(lines[1].before, "é😀 cat 😀 ")
    }

    func testACRLFLineKeepsNoLineEnding() throws {
        let lines = try preview("one cat\r\ntwo cat\r\n", "cat", "dog")
        XCTAssertEqual(lines.map(\.newLine), ["one dog", "two dog"])
    }

    func testRegexCaptureGroupsShowTheExpandedText() throws {
        let line = try XCTUnwrap(preview("get(name)\n", "get\\((\\w+)\\)", "read_$1", regex: true).first)
        XCTAssertEqual(line.removed, "get(name)")
        XCTAssertEqual(line.added, "read_name")
    }

    func testAnEmptyReplacementIsADeletion() throws {
        let line = try XCTUnwrap(preview("keep drop keep\n", " drop", "").first)
        XCTAssertEqual(line.added, "")
        XCTAssertEqual(line.newLine, "keep keep")
    }

    func testAMatchSpanningLinesHasNoPreviewLine() throws {
        let found = entries("one\ntwo\n", WorkspaceSearchQuery(text: "one\\ntwo", useRegularExpression: true), "x")
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found[0].previewLine())
    }

    func testAColumnThatDoesNotSelectTheOldTextHasNoPreviewLine() {
        let start = TextPosition(line: 0, column: 1, utf16Offset: 1)
        let end = TextPosition(line: 0, column: 4, utf16Offset: 4)
        let entry = WorkspaceEditPlanEntry(
            url: url, range: TextRange(start: start, end: end), oldText: "foo", newText: "bar", lineText: "xxfooxx"
        )
        XCTAssertNil(entry.previewLine(), "The columns select `xfo`, not the old text")
        let outside = WorkspaceEditPlanEntry(
            url: url, range: TextRange(start: start, end: TextPosition(line: 0, column: 90, utf16Offset: 90)),
            oldText: "foo", newText: "bar", lineText: "xxfooxx"
        )
        XCTAssertNil(outside.previewLine())
    }

    func testLongLinesAreCutToAWindowAroundTheMatch() throws {
        let long = String(repeating: "a", count: 100) + " hit " + String(repeating: "b", count: 100)
        let line = try XCTUnwrap(preview(long, "hit", "HIT", window: 10).first)
        XCTAssertEqual(line.before, "…" + String(repeating: "a", count: 9) + " ")
        XCTAssertEqual(line.after, " " + String(repeating: "b", count: 9) + "…")
        XCTAssertEqual(line.newLine.count, line.before.count + 3 + line.after.count)
    }

    func testTabsShowAsFourSpacesAndNewlinesInTheReplacementAsAMarker() throws {
        let line = try XCTUnwrap(preview("\tx = 1\n", "1", "1;\\n2", regex: false).first)
        XCTAssertEqual(line.before, "    x = ")
        XCTAssertEqual(line.added, "1;\\n2", "A literal backslash-n in a plain replacement is not a line break")
        let split = try XCTUnwrap(preview("a,b\n", ",", "\n").first)
        XCTAssertEqual(split.added, "⏎")
    }
}

import XCTest
@testable import EditorIntelligence

final class ProjectReplacePlannerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/A.txt")

    private func entries(_ text: String, _ query: WorkspaceSearchQuery, _ replacement: String) -> [WorkspaceEditPlanEntry] {
        ProjectReplacePlanner.entries(for: query, replacement: replacement, in: text, url: url)
    }

    /// The text after applying every entry, the way `WorkspaceEdit` would.
    private func applied(_ text: String, _ entries: [WorkspaceEditPlanEntry]) throws -> String {
        let edits = entries.map { TextEdit(range: $0.range, replacement: $0.newText) }
        return try WorkspaceEdit.apply(edits, to: text)
    }

    func testLiteralQueryIsCaseInsensitiveByDefault() throws {
        let found = entries("Foo foo FOO", WorkspaceSearchQuery(text: "foo"), "bar")
        XCTAssertEqual(found.map(\.oldText), ["Foo", "foo", "FOO"])
        XCTAssertEqual(try applied("Foo foo FOO", found), "bar bar bar")
    }

    func testCaseSensitiveQueryOnlyMatchesTheSameCase() throws {
        let query = WorkspaceSearchQuery(text: "foo", isCaseSensitive: true)
        let found = entries("Foo foo FOO", query, "bar")
        XCTAssertEqual(found.map(\.oldText), ["foo"])
    }

    func testWholeWordSkipsMatchesInsideWords() throws {
        let query = WorkspaceSearchQuery(text: "cat", matchWholeWord: true)
        let found = entries("cat concat cat.", query, "dog")
        XCTAssertEqual(try applied("cat concat cat.", found), "dog concat dog.")
    }

    func testLiteralReplacementIsNotATemplate() throws {
        // `$1` and a backslash mean nothing outside regex mode.
        let found = entries("price", WorkspaceSearchQuery(text: "price"), "$1 \\n")
        XCTAssertEqual(try applied("price", found), "$1 \\n")
    }

    func testRegexReplacementCanUseCaptureGroups() throws {
        let query = WorkspaceSearchQuery(text: "(\\w+)@(\\w+)", useRegularExpression: true)
        let found = entries("ann@home bob@work", query, "$2:$1")
        XCTAssertEqual(try applied("ann@home bob@work", found), "home:ann work:bob")
        let whole = entries("ann@home", query, "[$0]")
        XCTAssertEqual(try applied("ann@home", whole), "[ann@home]")
    }

    func testAMatchThatWouldBeReplacedByItselfIsLeftOut() {
        XCTAssertTrue(entries("foo foo", WorkspaceSearchQuery(text: "foo", isCaseSensitive: true), "foo").isEmpty)
        // A different case is a real change under a case-insensitive query.
        XCTAssertEqual(entries("Foo", WorkspaceSearchQuery(text: "foo"), "foo").count, 1)
    }

    func testAnEmptyReplacementDeletesTheMatches() throws {
        let found = entries("a-b-c", WorkspaceSearchQuery(text: "-"), "")
        XCTAssertEqual(try applied("a-b-c", found), "abc")
    }

    func testEntriesCarryLinesColumnsAndTheLineText() {
        let text = "alpha\nbeta gamma\r\ndelta gamma\n"
        let found = entries(text, WorkspaceSearchQuery(text: "gamma"), "G")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].range.start.line, 1)
        XCTAssertEqual(found[0].range.start.column, 5)
        XCTAssertEqual(found[0].lineText, "beta gamma")
        XCTAssertEqual(found[1].range.start.line, 2)
        XCTAssertEqual(found[1].range.start.column, 6)
        XCTAssertEqual(found[1].lineText, "delta gamma")
        XCTAssertEqual(found[1].range.start.utf16Offset, (text as NSString).range(of: "gamma", options: .backwards).location)
    }

    func testAMatchSpanningLinesEndsOnALaterLine() throws {
        let query = WorkspaceSearchQuery(text: "one\\ntwo", useRegularExpression: true)
        let text = "zero\none\ntwo\nthree"
        let found = entries(text, query, "1-2")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].range.start.line, 1)
        XCTAssertEqual(found[0].range.end.line, 2)
        XCTAssertEqual(found[0].range.end.column, 3)
        XCTAssertEqual(try applied(text, found), "zero\n1-2\nthree")
    }

    func testEmptyMatchesCanInsertAtLineStarts() throws {
        let query = WorkspaceSearchQuery(text: "^", useRegularExpression: true)
        let found = entries("a\nb", query, "// ")
        XCTAssertEqual(try applied("a\nb", found), "// a\nb", "`^` matches the start of the text only, without multiline")
    }

    func testEmptyOrInvalidQueriesPlanNothing() {
        XCTAssertTrue(entries("text", WorkspaceSearchQuery(text: ""), "x").isEmpty)
        XCTAssertTrue(entries("text", WorkspaceSearchQuery(text: "(", useRegularExpression: true), "x").isEmpty)
    }

    func testOffsetsAreUTF16UnitsSoEmojiAndAccentsLineUp() throws {
        let text = "é😀 foo"
        let found = entries(text, WorkspaceSearchQuery(text: "foo"), "bar")
        XCTAssertEqual(found[0].range.start.utf16Offset, 4)
        XCTAssertEqual(found[0].range.start.column, 4)
        XCTAssertEqual(try applied(text, found), "é😀 bar")
    }

    func testThePlanBuildsAWorkspaceEditThatAppliesEveryEntry() throws {
        let text = "x x x"
        let found = entries(text, WorkspaceSearchQuery(text: "x"), "yy")
        let plan = WorkspaceEditPlan(entries: found, title: "Replace")
        let edit = plan.workspaceEdit()
        XCTAssertEqual(edit.changes[url]?.count, 3)
        XCTAssertEqual(try WorkspaceEdit.apply(edit.orderedEdits(for: url), to: text), "yy yy yy")
    }

    // MARK: - Agrees with the search

    func testTheSearchAndThePlannerFindTheSameMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Sample.txt")
        let text = "Cat cat concat\nCAT catalog cat\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        for query in [
            WorkspaceSearchQuery(text: "cat"),
            WorkspaceSearchQuery(text: "cat", isCaseSensitive: true),
            WorkspaceSearchQuery(text: "cat", matchWholeWord: true),
            WorkspaceSearchQuery(text: "c.t\\b", useRegularExpression: true)
        ] {
            let hits = await ProjectSearchEngine().search(query, in: directory)
            let planned = ProjectReplacePlanner.entries(for: query, replacement: "#", in: text, url: file)
            XCTAssertEqual(planned.map(\.range.start.utf16Offset), hits.map(\.range.start.utf16Offset), "\(query)")
            XCTAssertEqual(planned.map(\.range.end.utf16Offset), hits.map(\.range.end.utf16Offset), "\(query)")
            XCTAssertEqual(planned.map(\.range.start.line), hits.map(\.line), "\(query)")
        }
    }

    /// Replace plans the files the (filtered) search lists, so a filter set on both sides can
    /// never let Replace reach a file Find did not show.
    func testAFilterNarrowsTheFilesAReplaceWillPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("build"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["A.java", "B.kt", "build/C.java"]
        for name in files {
            try "cat and cat\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let query = WorkspaceSearchQuery(text: "cat")
        let filter = ProjectSearchFilter(mask: FileMask("*.java, !build/"))

        let hits = await ProjectSearchEngine().search(query, in: directory, filter: filter)
        var urls: [URL] = []
        for hit in hits where !urls.contains(hit.url) { urls.append(hit.url) }
        var entries: [WorkspaceEditPlanEntry] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            entries += ProjectReplacePlanner.entries(for: query, replacement: "dog", in: text, url: url)
        }

        XCTAssertEqual(Set(entries.map { $0.url.lastPathComponent }), ["A.java"])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.range.start.utf16Offset), hits.map(\.range.start.utf16Offset))
    }
}

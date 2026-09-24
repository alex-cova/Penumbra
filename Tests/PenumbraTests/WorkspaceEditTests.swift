import XCTest
import EditorIntelligence

final class WorkspaceEditTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/p/A.java")
    private let b = URL(fileURLWithPath: "/p/B.java")

    private func pos(_ line: Int, _ column: Int) -> TextPosition {
        TextPosition(line: line, column: column, utf16Offset: 0)
    }

    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(range: TextRange(start: pos(l1, c1), end: pos(l2, c2)), replacement: text)
    }

    func testOrderedEditsRunFromEndToStart() {
        let e1 = edit(0, 0, 0, 1, "x")
        let e2 = edit(2, 4, 2, 6, "y")
        let e3 = edit(0, 5, 0, 7, "z")
        let workspaceEdit = WorkspaceEdit(changes: [a: [e1, e2, e3]])
        XCTAssertEqual(workspaceEdit.orderedEdits(for: a), [e2, e3, e1])
        XCTAssertTrue(workspaceEdit.orderedEdits(for: b).isEmpty)
    }

    func testValidationAcceptsAdjacentEditsAndFlagsOverlap() {
        let adjacent = WorkspaceEdit(changes: [a: [edit(0, 0, 0, 3, "x"), edit(0, 3, 0, 5, "y")]])
        XCTAssertTrue(adjacent.validate().isEmpty)

        let overlapping = WorkspaceEdit(changes: [a: [edit(0, 0, 0, 4, "x"), edit(0, 3, 0, 5, "y")], b: [edit(1, 0, 1, 1, "q")]])
        let issues = overlapping.validate()
        XCTAssertEqual(issues.count, 1)
        guard case .overlappingEdits(let url, _, _) = issues[0] else { return XCTFail("expected overlap") }
        XCTAssertEqual(url, a)
    }

    func testValidationFlagsInvertedRangeAndDuplicateRenames() {
        let inverted = WorkspaceEdit(
            changes: [a: [edit(0, 5, 0, 2, "x")]],
            fileRenames: [(a, b), (a, URL(fileURLWithPath: "/p/C.java")), (URL(fileURLWithPath: "/p/D.java"), b)]
        )
        let issues = inverted.validate()
        XCTAssertTrue(issues.contains(.invalidRange(url: a, range: inverted.changes[a]![0].range)))
        XCTAssertTrue(issues.contains(.duplicateFileRenameSource(a)))
        XCTAssertTrue(issues.contains(.duplicateFileRenameTarget(b)))
    }

    func testApplyToStringUsesLineAndColumnAndKeepsOtherText() throws {
        let text = "class Foo {\n  Foo f;\r\n  Foo() {}\n}\n"
        let edits = [edit(0, 6, 0, 9, "Bar"), edit(1, 2, 1, 5, "Bar"), edit(2, 2, 2, 5, "Bar")]
        let result = try WorkspaceEdit.apply(edits, to: text)
        XCTAssertEqual(result, "class Bar {\n  Bar f;\r\n  Bar() {}\n}\n")
    }

    func testApplyRejectsOutOfBoundsAndOverlap() {
        XCTAssertThrowsError(try WorkspaceEdit.apply([edit(3, 0, 3, 1, "x")], to: "a\nb\n")) {
            XCTAssertEqual($0 as? WorkspaceEdit.ApplyError, .rangeOutOfBounds)
        }
        XCTAssertThrowsError(try WorkspaceEdit.apply([edit(0, 0, 0, 5, "x")], to: "abc")) {
            XCTAssertEqual($0 as? WorkspaceEdit.ApplyError, .rangeOutOfBounds)
        }
        XCTAssertThrowsError(try WorkspaceEdit.apply([edit(0, 0, 0, 2, "x"), edit(0, 1, 0, 3, "y")], to: "abcd")) {
            XCTAssertEqual($0 as? WorkspaceEdit.ApplyError, .overlappingEdits)
        }
    }

    func testPlanWorkspaceEditSelection() {
        let range = TextRange(start: pos(0, 0), end: pos(0, 3))
        let exact = RenamePlanEntry(url: a, range: range, oldText: "Foo", newText: "Bar", lineText: "Foo")
        let ambiguous = RenamePlanEntry(url: b, range: range, oldText: "Foo", newText: "Bar", lineText: "Foo", isAmbiguous: true)
        let readOnly = RenamePlanEntry(url: b, range: range, oldText: "Foo", newText: "Bar", lineText: "Foo", isReadOnly: true)
        let plan = RenamePlan(entries: [exact, ambiguous, readOnly], fileRenames: [(a, b)], warnings: ["w"])

        let defaults = plan.workspaceEdit()
        XCTAssertEqual(defaults.affectedURLs, [a])
        XCTAssertEqual(defaults.fileRenames.count, 1)
        XCTAssertEqual(defaults.warnings, ["w"])

        let picked = plan.workspaceEdit(including: [ambiguous.id, readOnly.id])
        XCTAssertEqual(picked.affectedURLs, [b])
        XCTAssertEqual(picked.editCount, 1, "read-only entries are never applied")
        XCTAssertFalse(plan.isBlocked)
    }
}

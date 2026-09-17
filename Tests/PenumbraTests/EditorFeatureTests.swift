import XCTest
import AppKit
import Penumbra
import EditorIntelligence

final class OutlineBuilderTests: XCTestCase {
    func testBuildsNestedOutlineFromEnclosingRanges() {
        let documentID = DocumentID()
        let outer = Symbol(
            name: "Outer",
            kind: .type,
            documentID: documentID,
            range: makeRange(start: 0, end: 100)
        )
        let inner = Symbol(
            name: "inner",
            kind: .function,
            documentID: documentID,
            range: makeRange(start: 10, end: 50)
        )
        let items = OutlineBuilder.build(from: [outer, inner])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Outer")
        XCTAssertEqual(items.first?.children.count, 1)
        XCTAssertEqual(items.first?.children.first?.title, "inner")
    }
}

final class WorkspaceSearchEngineTests: XCTestCase {
    func testFindsMatchesAcrossWorkspaceDocuments() async {
        let workspace = Workspace()
        let first = makeDocument(name: "A.swift", text: "let alpha = 1\n")
        let second = makeDocument(name: "B.swift", text: "let beta = 2\n")
        await workspace.openDocument(first)
        await workspace.openDocument(second)

        let engine = WorkspaceSearchEngine()
        let results = await engine.search(WorkspaceSearchQuery(text: "let"), in: workspace)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.documentName == "A.swift" }))
        XCTAssertTrue(results.contains(where: { $0.documentName == "B.swift" }))
    }

    func testSearchesElidedDocumentWithoutFullText() async {
        let prefix = String(repeating: "aaaa\n", count: 200)
        let text = prefix + "NEEDLE\n" + String(repeating: "bbbb\n", count: 200)
        let utf16Length = (text as NSString).length
        let reader = TextRangeReader(utf16Length: utf16Length) { offset, length in
            let ns = text as NSString
            return ns.substring(with: NSRange(location: offset, length: min(length, ns.length - offset)))
        }
        let snapshot = TextSnapshot(version: 0, utf16Length: utf16Length, text: nil, rangeReader: reader)
        let document = Document(
            displayName: "big.txt",
            contentSnapshot: snapshot,
            selection: Selection(range: makeRange(start: 0, end: 0)),
            cursor: Cursor(position: TextPosition(line: 0, column: 0, utf16Offset: 0)),
            viewport: Viewport(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertTrue(document.contentSnapshot.isElided)
        XCTAssertEqual(document.text, "")
        let workspace = Workspace()
        await workspace.openDocument(document)
        let engine = WorkspaceSearchEngine()
        let results = await engine.search(WorkspaceSearchQuery(text: "NEEDLE"), in: workspace)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.preview, "NEEDLE")
        XCTAssertEqual(results.first?.documentName, "big.txt")
    }
}

@MainActor
final class TextEditApplicatorTests: XCTestCase {
    func testAppliesMultipleEditsWithoutOffsetShift() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "abcdef"
        TextEditApplicator.apply([
            TextEdit(range: makeRange(start: 0, end: 3), replacement: "X"),
            TextEdit(range: makeRange(start: 3, end: 6), replacement: "Y")
        ], in: textView)
        XCTAssertEqual(textView.text, "XY")
    }

    func testApplyPreservesMultiCaretSelectionShiftedByEditDelta() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "one two three"
        textView.selectedRanges = [
            NSRange(location: 4, length: 0), // caret in "two"
            NSRange(location: 9, length: 0)  // caret in "three"
        ]
        TextEditApplicator.apply([
            TextEdit(range: makeRange(start: 0, end: 3), replacement: "1")
        ], in: textView)
        XCTAssertEqual(textView.text, "1 two three")
        // Both carets were after the edited range and shift left by the edit's delta (3 -> 1
        // character), instead of collapsing to wherever the single `replace` call landed.
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 2, length: 0),
            NSRange(location: 7, length: 0)
        ])
    }

    func testApplyGroupsMultipleEditsIntoOneUndo() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "abcdef"
        TextEditApplicator.apply([
            TextEdit(range: makeRange(start: 0, end: 3), replacement: "X"),
            TextEdit(range: makeRange(start: 3, end: 6), replacement: "Y")
        ], in: textView)
        XCTAssertEqual(textView.text, "XY")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "abcdef")
    }
}

private func makeRange(start: Int, end: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: 0, column: start, utf16Offset: start),
        end: TextPosition(line: 0, column: end, utf16Offset: end)
    )
}

private func makeDocument(name: String, text: String) -> Document {
    Document(
        displayName: name,
        contentSnapshot: TextSnapshot(version: 1, text: text),
        selection: Selection(range: makeRange(start: 0, end: 0)),
        cursor: Cursor(position: TextPosition(line: 0, column: 0, utf16Offset: 0)),
        viewport: Viewport(x: 0, y: 0, width: 800, height: 600)
    )
}

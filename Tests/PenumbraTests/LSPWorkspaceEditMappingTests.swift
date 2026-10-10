import EditorIntelligenceLSP
import LanguageServerProtocol
import XCTest

final class LSPWorkspaceEditMappingTests: XCTestCase {
    func testDocumentChangesWinOverTheChangesMap() {
        let range = LSPRange(start: Position(line: 1, character: 2), end: Position(line: 1, character: 5))
        let edit = WorkspaceEdit(
            changes: ["file:///old.swift": [TextEdit(range: range, newText: "ignored")]],
            documentChanges: [
                .textDocumentEdit(TextDocumentEdit(
                    textDocument: VersionedTextDocumentIdentifier(uri: "file:///New.swift", version: 3),
                    edits: [TextEdit(range: range, newText: "Widget")]
                ))
            ]
        )
        let changes = LSPWorkspaceEditMapping.changes(from: edit)
        XCTAssertEqual(Array(changes.keys), ["file:///New.swift"])
        XCTAssertEqual(changes["file:///New.swift"]?.first?.newText, "Widget")
        XCTAssertEqual(changes["file:///New.swift"]?.first?.range.start.line, 1)
        XCTAssertEqual(changes["file:///New.swift"]?.first?.range.start.character, 2)
    }

    func testChangesMapIsUsedWhenThereAreNoDocumentChanges() {
        let range = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1))
        let edit = WorkspaceEdit(
            changes: ["file:///A.swift": [TextEdit(range: range, newText: "B")]],
            documentChanges: nil
        )
        XCTAssertEqual(LSPWorkspaceEditMapping.changes(from: edit)["file:///A.swift"]?.first?.newText, "B")
    }
}

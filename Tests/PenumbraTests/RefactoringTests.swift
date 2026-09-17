import XCTest
import EditorIntelligence

final class RefactoringTests: XCTestCase {
    func testRenameOperationProducesEdits() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = Symbol(
            name: "foo",
            kind: .function,
            documentID: documentID,
            range: makeRange(line: 0, startColumn: 0, endColumn: 3)
        )
        await index.index([symbol], for: documentID)
        let operation = RenameOperation()
        let context = makeRefactoringContext(documentID: documentID, text: "foo()", offset: 1, index: index)
        let result = await operation.apply(context: context, parameters: ["newName": "bar"])
        XCTAssertEqual(result.edits.count, 1)
        XCTAssertEqual(result.edits.first?.replacement, "bar")
        XCTAssertEqual(result.affectedDocuments, [documentID])
    }

    func testRefactoringEngineDiscoversAvailableOperations() async {
        let operation = RenameOperation()
        let engine = RefactoringEngine(operations: [operation])
        let context = makeRefactoringContext(documentID: DocumentID(), text: "foo()", offset: 1)
        let available = await engine.availableOperations(for: context)
        XCTAssertEqual(available.map { $0.name }, ["Rename"])
    }

    func testRefactoringEngineAppliesOperation() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = Symbol(
            name: "foo",
            kind: .function,
            documentID: documentID,
            range: makeRange(line: 0, startColumn: 0, endColumn: 3)
        )
        await index.index([symbol], for: documentID)
        let engine = RefactoringEngine(operations: [RenameOperation()])
        let context = makeRefactoringContext(documentID: documentID, text: "foo()", offset: 1, index: index)
        let result = await engine.apply(operationName: "Rename", context: context, parameters: ["newName": "bar"])
        XCTAssertEqual(result?.edits.count, 1)
    }
}

private func makeRefactoringContext(documentID: DocumentID, text: String, offset: Int, index: SymbolIndex? = nil) -> RefactoringContext {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: documentID,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
    return RefactoringContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position)),
        index: index
    )
}

private func makeRange(line: Int, startColumn: Int, endColumn: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: line, column: startColumn, utf16Offset: startColumn),
        end: TextPosition(line: line, column: endColumn, utf16Offset: endColumn)
    )
}
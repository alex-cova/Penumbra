import XCTest
import EditorIntelligence

final class RefactoringTests: XCTestCase {
    func testRefactoringEngineDiscoversAvailableOperations() async {
        let engine = RefactoringEngine(operations: [StubOperation(), StubOperation(name: "Never", applicable: false)])
        let context = makeRefactoringContext(documentID: DocumentID(), text: "foo()", offset: 1)
        let available = await engine.availableOperations(for: context)
        XCTAssertEqual(available.map { $0.name }, ["Stub"])
    }

    func testRefactoringEngineAppliesOperation() async {
        let engine = RefactoringEngine(operations: [StubOperation()])
        let context = makeRefactoringContext(documentID: DocumentID(), text: "foo()", offset: 1)
        let result = await engine.apply(operationName: "Stub", context: context)
        XCTAssertEqual(result?.summary, "stubbed")
        let missing = await engine.apply(operationName: "Nope", context: context)
        XCTAssertNil(missing)
    }
}

private struct StubOperation: RefactoringOperation {
    var name = "Stub"
    var applicable = true

    func canApply(context: RefactoringContext) async -> Bool { applicable }

    func apply(context: RefactoringContext, parameters: [String: String]) async -> RefactoringResult {
        RefactoringResult(operationName: name, summary: "stubbed", edits: [])
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

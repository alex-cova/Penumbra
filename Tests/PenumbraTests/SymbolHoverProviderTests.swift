import XCTest
import EditorIntelligence

final class SymbolHoverProviderTests: XCTestCase {
    func testReturnsSymbolDocumentation() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let symbol = Symbol(
            name: "greet",
            kind: .function,
            documentID: documentID,
            range: TextRange(start: position, end: position),
            documentation: "Greets the user."
        )
        await index.index([symbol], for: documentID)

        let provider = SymbolHoverProvider(index: index)
        let context = makeHoverContext(documentID: documentID, text: "greet()", offset: 2)
        let result = await provider.provide(context: context)
        XCTAssertEqual(result?.contents, "Greets the user.")
    }

    func testFallsBackToSignatureThenName() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let symbol = Symbol(
            name: "add",
            kind: .function,
            documentID: documentID,
            range: TextRange(start: position, end: position),
            signature: "add(_ a: Int, _ b: Int) -> Int"
        )
        await index.index([symbol], for: documentID)

        let provider = SymbolHoverProvider(index: index)
        let context = makeHoverContext(documentID: documentID, text: "add(1, 2)", offset: 1)
        let result = await provider.provide(context: context)
        XCTAssertEqual(result?.contents, "add(_ a: Int, _ b: Int) -> Int")
    }

    func testReturnsNilForUnknownWord() async {
        let index = SymbolIndex()
        let provider = SymbolHoverProvider(index: index)
        let context = makeHoverContext(documentID: DocumentID(), text: "unknown", offset: 2)
        let result = await provider.provide(context: context)
        XCTAssertNil(result)
    }
}

private func makeHoverContext(documentID: DocumentID, text: String, offset: Int) -> HoverContext {
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
    return HoverContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position))
    )
}

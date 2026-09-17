import XCTest
import EditorIntelligence

final class CompletionProviderTests: XCTestCase {
    func testSymbolProviderQueriesIndex() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = makeSymbol(name: "hello", kind: .function, documentID: documentID)
        await index.index([symbol], for: documentID)

        let provider = SymbolCompletionProvider(index: index)
        let context = makeContext(prefix: "he", documentID: documentID)
        let items = await provider.provide(context: context)
        XCTAssertEqual(items.map(\.label), ["hello"])
        XCTAssertEqual(items.first?.kind, .function)
    }

    func testWordProviderOnlyReturnsWordSymbols() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let word = makeSymbol(name: "hello", kind: .word, documentID: documentID)
        let function = makeSymbol(name: "helloWorld", kind: .function, documentID: documentID)
        await index.index([word, function], for: documentID)

        let provider = WordCompletionProvider(index: index)
        let context = makeContext(prefix: "he", documentID: documentID)
        let items = await provider.provide(context: context)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .text)
    }

    func testSnippetProviderMatchesPrefix() async {
        let provider = SnippetCompletionProvider()
        let context = makeContext(prefix: "fu", documentID: DocumentID())
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.contains { $0.label == "func" })
    }
}

private func makeContext(prefix: String, documentID: DocumentID) -> CompletionContext {
    let snapshot = TextSnapshot(version: 0, text: "\(prefix)")
    let position = TextPosition(line: 0, column: prefix.count, utf16Offset: prefix.count)
    let document = Document(
        id: documentID,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
    return CompletionContext(
        document: document,
        cursor: Cursor(position: position),
        trigger: .keystroke(prefix),
        prefix: prefix,
        range: TextRange(start: position, end: position)
    )
}

private func makeSymbol(name: String, kind: SymbolKind, documentID: DocumentID) -> Symbol {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Symbol(
        name: name,
        kind: kind,
        documentID: documentID,
        range: TextRange(start: position, end: position)
    )
}
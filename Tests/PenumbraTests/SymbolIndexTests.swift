import XCTest
import EditorIntelligence

final class SymbolIndexTests: XCTestCase {
    func testIndexAndPrefixSearch() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = makeSymbol(name: "foo", kind: .function, documentID: documentID)
        await index.index([symbol], for: documentID)
        let results = await index.search(prefix: "fo")
        XCTAssertEqual(results.map(\.name), ["foo"])
    }

    func testIncrementalUpdateReplacesDocumentSymbols() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let first = makeSymbol(name: "foo", kind: .function, documentID: documentID)
        let second = makeSymbol(name: "bar", kind: .function, documentID: documentID)
        await index.index([first], for: documentID)
        await index.index([second], for: documentID)
        let fooResults = await index.search(prefix: "fo")
        XCTAssertTrue(fooResults.isEmpty)
        let barResults = await index.search(prefix: "ba")
        XCTAssertEqual(barResults.map(\.name), ["bar"])
    }

    func testRemoveDocument() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = makeSymbol(name: "foo", kind: .function, documentID: documentID)
        await index.index([symbol], for: documentID)
        await index.remove(documentID: documentID)
        let results = await index.search(prefix: "foo")
        XCTAssertTrue(results.isEmpty)
    }

    func testExactSearch() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let foo = makeSymbol(name: "foo", kind: .function, documentID: documentID)
        let foobar = makeSymbol(name: "foobar", kind: .function, documentID: documentID)
        await index.index([foo, foobar], for: documentID)
        let results = await index.search(exact: "foo")
        XCTAssertEqual(results.map(\.name), ["foo"])
    }

    func testSymbolsFromDocument() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let symbol = makeSymbol(name: "foo", kind: .function, documentID: documentID)
        await index.index([symbol], for: documentID)
        let results = await index.symbols(in: documentID)
        XCTAssertEqual(results.count, 1)
    }
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

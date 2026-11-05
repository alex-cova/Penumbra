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

    /// F-14: snippet triggers take the same matcher-compatible path as symbols and words,
    /// so camel-hump queries reach multi-word snippet prefixes.
    func testSnippetProviderReturnsCamelHumpMatches() async {
        let provider = SnippetCompletionProvider(snippets: [
            Snippet(prefix: "getName", body: "getName"),
            Snippet(prefix: "setName", body: "setName"),
        ])
        let items = await provider.provide(context: makeContext(prefix: "gN", documentID: DocumentID()))
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("getName"), "camel-hump recall: \(labels)")
        XCTAssertFalse(labels.contains("setName"))
    }

    /// F-14: later-word-start queries reach snippet prefixes too (`Name` in `getName`).
    func testSnippetProviderReturnsWordStartMatches() async {
        let provider = SnippetCompletionProvider(snippets: [
            Snippet(prefix: "getName", body: "getName"),
            Snippet(prefix: "setName", body: "setName"),
        ])
        let items = await provider.provide(context: makeContext(prefix: "Name", documentID: DocumentID()))
        XCTAssertTrue(items.map(\.label).contains("getName"))
    }

    /// F-03: the generic providers must serve what the ranker can match. A literal-prefix
    /// pre-filter can never reach camel-hump candidates.
    func testSymbolProviderReturnsCamelHumpMatches() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        await index.index([
            makeSymbol(name: "getName", kind: .function, documentID: documentID),
            makeSymbol(name: "getValue", kind: .function, documentID: documentID),
            makeSymbol(name: "setName", kind: .function, documentID: documentID),
        ], for: documentID)

        let provider = SymbolCompletionProvider(index: index)
        let items = await provider.provide(context: makeContext(prefix: "gN", documentID: documentID))
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("getName"), "camel-hump recall: \(labels)")
        XCTAssertFalse(labels.contains("setName"))
    }

    /// F-03: later-word-start matches (`Name` in `getName`) must survive the pre-filter too.
    func testSymbolProviderReturnsWordStartMatches() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        await index.index([
            makeSymbol(name: "getName", kind: .function, documentID: documentID),
            makeSymbol(name: "setName", kind: .function, documentID: documentID),
        ], for: documentID)

        let provider = SymbolCompletionProvider(index: index)
        let items = await provider.provide(context: makeContext(prefix: "Name", documentID: documentID))
        XCTAssertTrue(items.map(\.label).contains("getName"))
    }

    /// F-03: words take the same matcher-compatible path (`fb` reaches `FooBar`).
    func testWordProviderReturnsCamelHumpMatches() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        await index.index([
            makeSymbol(name: "FooBar", kind: .word, documentID: documentID),
            makeSymbol(name: "FooBaz", kind: .word, documentID: documentID),
        ], for: documentID)

        let provider = WordCompletionProvider(index: index)
        let items = await provider.provide(context: makeContext(prefix: "fb", documentID: documentID))
        XCTAssertTrue(items.map(\.label).contains("FooBar"))
    }

    /// F-03: the cap keeps what the ranker prefers. Prefix-tier candidates outrank word-start
    /// ones, so a full cap of prefix matches evicts every word-start match — deterministically.
    func testSymbolProviderCapKeepsBestTiersFirst() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        var symbols = (0 ..< 500).map { makeSymbol(name: "get\($0)", kind: .function, documentID: documentID) }
        symbols += (0 ..< 100).map { makeSymbol(name: "myGet\($0)", kind: .function, documentID: documentID) }
        await index.index(symbols, for: documentID)

        let provider = SymbolCompletionProvider(index: index)
        let items = await provider.provide(context: makeContext(prefix: "get", documentID: documentID))
        // 500 is the provider's pre-rank candidate budget (`WordCompletionProvider.maxCandidates`).
        XCTAssertEqual(items.count, 500)
        XCTAssertTrue(items.allSatisfy { $0.label.hasPrefix("get") }, "word-start matches lose the cap to prefix matches")
    }

    /// F-03: candidate generation does not depend on insertion order.
    func testMatchingSearchIsDeterministicAcrossInsertionOrders() async {
        let names = ["getName", "getValue", "setName", "getId", "fetchData", "getaway"]
        let first = SymbolIndex()
        let second = SymbolIndex()
        let firstID = DocumentID()
        let secondID = DocumentID()
        await first.index(names.map { makeSymbol(name: $0, kind: .function, documentID: firstID) }, for: firstID)
        await second.index(names.reversed().map { makeSymbol(name: $0, kind: .function, documentID: secondID) }, for: secondID)
        let left = await first.search(matching: "get")
        let right = await second.search(matching: "get")
        XCTAssertEqual(left.map(\.name), right.map(\.name))
        XCTAssertEqual(left.map(\.name), ["getId", "getName", "getValue", "getaway"])
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
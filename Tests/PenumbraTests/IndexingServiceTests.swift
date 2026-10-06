import XCTest
import EditorIntelligence

final class IndexingServiceTests: XCTestCase {
    func testIndexesDocumentOnOpen() async throws {
        let parser = MockLanguageParser()
        let service = IndexingService(parser: parser)
        let workspace = Workspace()
        let document = makeDocument(text: "hello world")
        let task = await service.connect(to: workspace)
        await workspace.openDocument(document)
        try await Task.sleep(nanoseconds: 100_000_000)
        let index = await service.index
        let results = await index.search(prefix: "foo")
        XCTAssertEqual(results.map(\.name), ["foo"])
        task.cancel()
    }

    func testRemovesDocumentOnClose() async throws {
        let parser = MockLanguageParser()
        let service = IndexingService(parser: parser)
        let workspace = Workspace()
        let document = makeDocument(text: "hello world")
        let task = await service.connect(to: workspace)
        await workspace.openDocument(document)
        try await Task.sleep(nanoseconds: 100_000_000)
        await workspace.closeDocument(document.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        let index = await service.index
        let results = await index.search(prefix: "foo")
        XCTAssertTrue(results.isEmpty)
        task.cancel()
    }

    func testSkipsOverlongWords() async {
        let blob = String(repeating: "QUJD", count: 300)  // 1,200 characters, past maxNameLength
        let service = IndexingService(parser: LongWordParser(words: [blob, "short"]))
        await service.indexDocument(makeDocument(text: blob))
        let index = await service.index
        let words = await index.search(prefix: "").filter { $0.kind == .word }.map(\.name)
        XCTAssertEqual(words, ["short"])
    }

    func testCoalescesBurstOfEditsIntoOneParse() async throws {
        let parser = CountingParser()
        let service = IndexingService(parser: parser, debounceMilliseconds: 50)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        let id = DocumentID()
        for version in 1...5 {
            workspace.eventBus.send(.documentEdited(makeDocument(id: id, version: version, text: "v\(version)"), []))
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let parses = await parser.count
        let versions = await parser.versions
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(versions, [5])
        task.cancel()
    }

    func testCloseCancelsPendingEdit() async throws {
        let parser = CountingParser()
        let service = IndexingService(parser: parser, debounceMilliseconds: 100)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        let document = makeDocument(id: DocumentID(), version: 1, text: "x")
        workspace.eventBus.send(.documentEdited(document, []))
        workspace.eventBus.send(.documentClosed(document.id))
        try await Task.sleep(nanoseconds: 400_000_000)
        let parses = await parser.count
        let symbols = await service.index.allSymbols()
        XCTAssertEqual(parses, 0)
        XCTAssertTrue(symbols.isEmpty)
        task.cancel()
    }
}

private actor CountingParser: LanguageParser {
    private(set) var count = 0
    private(set) var versions: [Int] = []
    func parse(document: Document) async -> SyntaxTree {
        count += 1
        versions.append(document.version)
        return MockSyntaxTree(symbols: [], words: ["word\(document.version)"], imports: [])
    }
}

private struct LongWordParser: LanguageParser {
    let words: [String]
    func parse(document: Document) async -> SyntaxTree {
        MockSyntaxTree(symbols: [], words: words, imports: [])
    }
}

private func makeDocument(id: DocumentID = DocumentID(), version: Int = 0, text: String) -> Document {
    let snapshot = TextSnapshot(version: version, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: id,
        url: URL(fileURLWithPath: "/tmp/test.js"),
        displayName: "test.js",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
        languageIdentifier: "javascript"
    )
}

private struct MockSyntaxTree: SyntaxTree {
    let symbols: [Symbol]
    let words: [String]
    let imports: [String]
}

private struct MockLanguageParser: LanguageParser {
    func parse(document: Document) async -> SyntaxTree {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let symbol = Symbol(
            name: "foo",
            kind: .function,
            documentID: document.id,
            range: TextRange(start: position, end: position)
        )
        return MockSyntaxTree(symbols: [symbol], words: ["hello"], imports: [])
    }
}

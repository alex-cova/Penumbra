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
}

private func makeDocument(text: String) -> Document {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: DocumentID(),
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

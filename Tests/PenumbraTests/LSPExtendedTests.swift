import XCTest
import EditorIntelligence

final class LSPExtendedTests: XCTestCase {
    func testSemanticTokenDecoder() {
        let data: [UInt32] = [0, 0, 3, 1, 0, 1, 5, 2, 0, 0]
        let tokens = LSPSemanticTokenDecoder.decode(data)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].length, 3)
        XCTAssertEqual(tokens[1].line, 1)
        XCTAssertEqual(tokens[1].character, 5)
    }

    func testSemanticTokenStorageDelta() {
        let storage = SemanticTokenStorage()
        storage.setData(LSPSemanticTokens(resultId: "1", data: [0, 0, 2, 1, 0]))
        XCTAssertTrue(storage.hasReceivedData)
        XCTAssertEqual(storage.allTokens().count, 1)
        storage.applyDelta(LSPSemanticTokensDelta(
            resultId: "2",
            data: [],
            edits: [LSPSemanticTokensEdit(start: 0, deleteCount: 5, data: [0, 0, 4, 1, 0])]
        ))
        XCTAssertEqual(storage.allTokens().count, 1)
        XCTAssertEqual(storage.allTokens().first?.length, 4)
    }

    func testLSPDefinitionProviderUsesClient() async {
        let client = MockExtendedLSPClient(definitions: [
            LSPLocation(
                uri: "file:///test.swift",
                range: LSPRange(
                    start: LSPPosition(line: 1, character: 0),
                    end: LSPPosition(line: 1, character: 4)
                )
            )
        ])
        let provider = LSPDefinitionProvider(client: client)
        let document = makeDocument(text: "foo")
        let context = NavigationContext(
            document: document,
            cursor: document.cursor,
            selection: document.selection
        )
        let result = await provider.provide(context: context)
        if case .single(let location) = result {
            XCTAssertEqual(location.displayName, "file:///test.swift")
        } else {
            XCTFail("Expected single navigation result")
        }
    }
}

private actor MockExtendedLSPClient: LSPClient {
    let definitions: [LSPLocation]
    init(definitions: [LSPLocation]) { self.definitions = definitions }
    func requestDiagnostics(for document: Document) async throws -> [LSPDiagnostic] { [] }
    func requestHover(for document: Document, at position: TextPosition) async throws -> LSPHover? { nil }
    func requestCompletions(for document: Document, at position: TextPosition) async throws -> [LSPCompletionItem] { [] }
    func requestDefinition(for document: Document, at position: TextPosition) async throws -> [LSPLocation] { definitions }
}

private func makeDocument(text: String) -> Document {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: DocumentID(),
        url: nil,
        displayName: "test",
        contentSnapshot: TextSnapshot(version: 0, text: text),
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
}

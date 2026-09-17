import XCTest
import EditorIntelligence

final class LSPBridgeTests: XCTestCase {
    func testLSPDiagnosticProvider() async {
        let client = MockLSPClient(
            diagnostics: [
                LSPDiagnostic(
                    range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
                    severity: 1,
                    message: "Syntax error"
                )
            ]
        )
        let provider = LSPDiagnosticProvider(client: client)
        let document = makeDocument(text: "foo")
        let diagnostics = await provider.diagnostics(for: document)
        let first = diagnostics.first
        XCTAssertEqual(first?.severity, .error)
        XCTAssertEqual(first?.message, "Syntax error")
    }

    func testLSPHoverProvider() async {
        let client = MockLSPClient(hover: LSPHover(contents: "Hover info"))
        let provider = LSPHoverProvider(client: client)
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await provider.provide(context: context)
        XCTAssertEqual(result?.contents, "Hover info")
    }

    func testLSPCompletionProvider() async {
        let client = MockLSPClient(completions: [LSPCompletionItem(label: "foo")])
        let provider = LSPCompletionProvider(client: client)
        let context = makeCompletionContext(prefix: "fo")
        let items = await provider.provide(context: context)
        XCTAssertEqual(items.first?.label, "foo")
    }
}

private actor MockLSPClient: LSPClient {
    var diagnostics: [LSPDiagnostic]
    var hover: LSPHover?
    var completions: [LSPCompletionItem]

    init(
        diagnostics: [LSPDiagnostic] = [],
        hover: LSPHover? = nil,
        completions: [LSPCompletionItem] = []
    ) {
        self.diagnostics = diagnostics
        self.hover = hover
        self.completions = completions
    }

    func requestDiagnostics(for document: Document) async throws -> [LSPDiagnostic] {
        diagnostics
    }

    func requestHover(for document: Document, at position: TextPosition) async throws -> LSPHover? {
        hover
    }

    func requestCompletions(for document: Document, at position: TextPosition) async throws -> [LSPCompletionItem] {
        completions
    }
}

private func makeDocument(text: String) -> Document {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: DocumentID(),
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
}

private func makeHoverContext(text: String, offset: Int) -> HoverContext {
    let document = makeDocument(text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    return HoverContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position))
    )
}

private func makeCompletionContext(prefix: String) -> CompletionContext {
    let document = makeDocument(text: prefix)
    let position = TextPosition(line: 0, column: prefix.count, utf16Offset: prefix.count)
    return CompletionContext(
        document: document,
        cursor: Cursor(position: position),
        trigger: .keystroke(prefix),
        prefix: prefix,
        range: TextRange(start: position, end: position)
    )
}
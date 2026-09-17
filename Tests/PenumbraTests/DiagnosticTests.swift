import XCTest
import EditorIntelligence

final class DiagnosticTests: XCTestCase {
    func testDiagnosticEngineMergesAndDeduplicates() async {
        let range = makeRange(line: 0, startColumn: 0, endColumn: 3)
        let diagnostic = Diagnostic(
            severity: .error,
            message: "expected error",
            range: range,
            source: "Mock",
            code: "mock"
        )
        let first = MockDiagnosticProvider(name: "First", diagnostics: [diagnostic])
        let second = MockDiagnosticProvider(name: "Second", diagnostics: [diagnostic])
        let engine = DiagnosticEngine(providers: [first, second])
        let document = makeDocument(id: DocumentID(), text: "foo")
        let report = await engine.diagnostics(for: document)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testDuplicateSymbolProvider() async {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let first = Symbol(name: "greet", kind: .function, documentID: documentID, range: makeRange(line: 0, startColumn: 0, endColumn: 5))
        let second = Symbol(name: "greet", kind: .function, documentID: documentID, range: makeRange(line: 1, startColumn: 0, endColumn: 5))
        await index.index([first, second], for: documentID)

        let provider = DuplicateSymbolDiagnosticProvider(index: index)
        let document = makeDocument(id: documentID, text: "greet\ngreet")
        let diagnostics = await provider.diagnostics(for: document)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.message, "Duplicate symbol 'greet'")
        XCTAssertEqual(diagnostics.first?.severity, .warning)
    }

    func testDiagnosticSorting() async {
        let info = Diagnostic(severity: .information, message: "info", range: makeRange(line: 0, startColumn: 0, endColumn: 1), source: "A")
        let error = Diagnostic(severity: .error, message: "error", range: makeRange(line: 0, startColumn: 2, endColumn: 3), source: "A")
        let warning = Diagnostic(severity: .warning, message: "warning", range: makeRange(line: 0, startColumn: 4, endColumn: 5), source: "A")
        let provider = MockDiagnosticProvider(name: "Sorted", diagnostics: [info, error, warning])
        let engine = DiagnosticEngine(providers: [provider])
        let document = makeDocument(id: DocumentID(), text: "abc")
        let report = await engine.diagnostics(for: document)
        let severities: [EditorIntelligence.DiagnosticSeverity] = report.diagnostics.map(\.severity)
        XCTAssertEqual(severities, [.error, .warning, .information])
    }
}

private actor MockDiagnosticProvider: DiagnosticProvider {
    let name: String
    let diagnostics: [Diagnostic]

    init(name: String, diagnostics: [Diagnostic]) {
        self.name = name
        self.diagnostics = diagnostics
    }

    func diagnostics(for document: Document) async -> [Diagnostic] {
        diagnostics
    }
}

private func makeDocument(id: DocumentID, text: String) -> Document {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: id,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
}

private func makeRange(line: Int, startColumn: Int, endColumn: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: line, column: startColumn, utf16Offset: startColumn),
        end: TextPosition(line: line, column: endColumn, utf16Offset: endColumn)
    )
}

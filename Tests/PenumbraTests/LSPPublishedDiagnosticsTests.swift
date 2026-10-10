import EditorIntelligenceLSP
import LanguageServerProtocol
import XCTest

final class LSPPublishedDiagnosticsTests: XCTestCase {
    func testAPushReplacesTheFileAndAnEmptyPushClearsIt() {
        var store = LSPPublishedDiagnostics()
        let range = LSPRange(start: Position(line: 2, character: 1), end: Position(line: 2, character: 4))
        store.apply(PublishDiagnosticsParams(
            uri: "file:///A.swift",
            version: 3,
            diagnostics: [Diagnostic(range: range, message: "unused")]
        ))
        XCTAssertEqual(store.diagnostics(for: "file:///A.swift").map(\.message), ["unused"])
        XCTAssertEqual(store.version(for: "file:///A.swift"), 3)
        XCTAssertEqual(store.diagnostics(for: "file:///A.swift").first?.range.start.line, 2)

        store.apply(PublishDiagnosticsParams(uri: "file:///A.swift", diagnostics: []))
        XCTAssertTrue(store.diagnostics(for: "file:///A.swift").isEmpty)
        XCTAssertNil(store.version(for: "file:///A.swift"))
    }

    func testDocumentSymbolsKeepTheirChildrenAndInlayLabelsFlatten() {
        let name = LSPRange(start: Position(line: 0, character: 6), end: Position(line: 0, character: 9))
        let body = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 2, character: 1))
        let symbol = LSPOutlineSymbol(DocumentSymbol(
            name: "Box", kind: .class, range: body, selectionRange: name,
            children: [DocumentSymbol(name: "width", kind: .property, range: name, selectionRange: name)]
        ))
        XCTAssertEqual(symbol.name, "Box")
        XCTAssertEqual(symbol.children.map(\.name), ["width"])

        let hint = LSPRenderedInlayHint(LanguageServerProtocol.InlayHint(
            position: Position(line: 4, character: 8),
            label: .optionB([InlayHintLabelPart(value: "name"), InlayHintLabelPart(value: ":")]),
            kind: .parameter
        ))
        XCTAssertEqual(hint, LSPRenderedInlayHint(line: 4, character: 8, label: "name:", kind: "parameter"))
    }
}

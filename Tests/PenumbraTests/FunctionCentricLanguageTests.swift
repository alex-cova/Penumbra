import EditorIntelligence
@testable import EditorIntelligenceLSP
import Foundation
@testable import Penumbra
import XCTest

/// F26: a language made of functions (Python, Rust, Go) outlines and renders with the right kinds,
/// and no Java default decides anything for it.
final class FunctionCentricLanguageTests: XCTestCase {
    // CRLF line ends and non-BMP / accented characters before every symbol, so offsets are real UTF-16.
    private let source = "# héllo 🙂\r\nDEBUG = True\r\n\r\ndef main():\r\n    pass\r\n\r\nclass Config:\r\n    def load(self):\r\n        pass\r\n"

    private func lspRange(of needle: String, endingAfter end: String? = nil) -> LSPRange {
        let ns = source as NSString
        let start = ns.range(of: needle)
        precondition(start.location != NSNotFound, needle)
        let stop = end.map { NSMaxRange(ns.range(of: $0, range: NSRange(location: start.location, length: ns.length - start.location))) } ?? NSMaxRange(start)
        return LSPRange(start: position(at: start.location), end: position(at: stop))
    }

    /// UTF-16 offset to (line, character), lines ending in `\r\n`.
    private func position(at offset: Int) -> LSPPosition {
        let ns = source as NSString
        var line = 0
        var lineStart = 0
        var index = 0
        while index < offset {
            if ns.character(at: index) == 0x0D, index + 1 < ns.length, ns.character(at: index + 1) == 0x0A {
                index += 2
                if index <= offset { line += 1; lineStart = index }
            } else {
                index += 1
            }
        }
        return LSPPosition(line: line, character: offset - lineStart)
    }

    private struct PythonServer: LSPClient {
        let symbols: [LSPDocumentSymbol]
        func requestDiagnostics(for document: Document) async throws -> [LSPDiagnostic] { [] }
        func requestHover(for document: Document, at position: TextPosition) async throws -> LSPHover? { nil }
        func requestCompletions(for document: Document, at position: TextPosition) async throws -> [LSPCompletionItem] { [] }
        func requestDocumentSymbolTree(for document: Document) async throws -> [LSPDocumentSymbol] { symbols }
    }

    private func pythonSymbols() -> [LSPDocumentSymbol] {
        [
            LSPDocumentSymbol(name: "DEBUG", kind: 13, range: lspRange(of: "DEBUG = True"), selectionRange: lspRange(of: "DEBUG")),
            LSPDocumentSymbol(
                name: "main", detail: "()", kind: 12,
                range: lspRange(of: "def main():", endingAfter: "pass"), selectionRange: lspRange(of: "main")
            ),
            LSPDocumentSymbol(
                name: "Config", kind: 5, range: lspRange(of: "class Config:", endingAfter: "pass\r\n"), selectionRange: lspRange(of: "Config"),
                children: [LSPDocumentSymbol(
                    name: "load", kind: 6, range: lspRange(of: "def load(self):", endingAfter: "pass\r\n"), selectionRange: lspRange(of: "load")
                )]
            )
        ]
    }

    private func document(_ text: String? = nil) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: "/tmp/app.py"), displayName: "app.py",
            contentSnapshot: TextSnapshot(version: 1, text: text ?? source),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "python"
        )
    }

    private func service(symbols: [LSPDocumentSymbol]) -> LSPLanguageService {
        LSPLanguageService(
            configuration: LSPLanguageConfiguration(
                name: "pylsp", languageIdentifiers: ["python"], enabledFeatures: [.structure], diagnosticSource: DiagnosticSourceID(rawValue: "pylsp")
            ),
            connections: LSPConnectionBox(client: PythonServer(symbols: symbols))
        )
    }

    // MARK: - Outline

    func testAFunctionCentricFileOutlinesWithFunctionsClassesAndVariables() async throws {
        let provider = try XCTUnwrap(service(symbols: pythonSymbols()).providers.structure)
        let loaded = await provider.allStructure(forSource: source, document: document())
        let roots = try XCTUnwrap(loaded)
        XCTAssertEqual(roots.map(\.kind), [.variable, .function, .type])
        XCTAssertEqual(roots.map(\.title), ["DEBUG", "main ()", "Config"])
        XCTAssertEqual(roots[2].children.map(\.kind), [.method], "a method of a class stays a method; a top-level def is a function")

        let ns = source as NSString
        for (node, name) in zip(roots, ["DEBUG", "main", "Config"]) {
            XCTAssertEqual(node.nameRange.count, name.utf16.count, name)
            XCTAssertEqual(ns.substring(with: NSRange(location: node.nameRange.lowerBound, length: node.nameRange.count)), name,
                           "\(name): the range lands on the name after multibyte text and CRLFs")
        }
        let load = roots[2].children[0]
        XCTAssertEqual(ns.substring(with: NSRange(location: load.nameRange.lowerBound, length: load.nameRange.count)), "load")
        XCTAssertTrue(roots[2].bodyRange.contains(load.nameRange.lowerBound))
    }

    func testTheCaretOutlineIsTheInnermostTypeElseAModuleOfTheFilesSymbols() async throws {
        let provider = try XCTUnwrap(service(symbols: pythonSymbols()).providers.structure)
        let loadOffset = (source as NSString).range(of: "load").location
        let inClass = await provider.structure(forSource: source, document: document(), atUTF16Offset: loadOffset)
        XCTAssertEqual(inClass?.title, "Config")
        XCTAssertEqual(inClass?.kind, .type)

        let functionsOnly = [pythonSymbols()[1]]
        let scripty = try XCTUnwrap(service(symbols: functionsOnly).providers.structure)
        let moduleNode = await scripty.structure(forSource: source, document: document(), atUTF16Offset: 0)
        let module = try XCTUnwrap(moduleNode)
        XCTAssertEqual(module.kind, .module, "a file with no types is outlined as a module")
        XCTAssertEqual(module.title, "app.py")
        XCTAssertEqual(module.children.map(\.kind), [.function])
    }

    func testWithoutADocumentOrAConnectionThereIsNoOutline() async throws {
        let connected = try XCTUnwrap(service(symbols: pythonSymbols()).providers.structure)
        let noDocument = await connected.allStructure(forSource: source, document: nil)
        XCTAssertNil(noDocument, "source alone cannot ask a server")
        let other = Document(
            url: nil, displayName: "A.java", contentSnapshot: TextSnapshot(version: 1, text: "class A {}"),
            selection: Selection(range: TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0), end: TextPosition(line: 0, column: 0, utf16Offset: 0))),
            cursor: Cursor(position: TextPosition(line: 0, column: 0, utf16Offset: 0)),
            viewport: Viewport(x: 0, y: 0, width: 1, height: 1), languageIdentifier: "java"
        )
        let otherLanguage = await connected.allStructure(forSource: "class A {}", document: other)
        XCTAssertNil(otherLanguage)

        let offline = LSPLanguageService(
            configuration: LSPLanguageConfiguration(name: "pylsp", languageIdentifiers: ["python"], enabledFeatures: [.structure], diagnosticSource: DiagnosticSourceID(rawValue: "pylsp")),
            connections: LSPConnectionBox()
        )
        let disconnected = await offline.providers.structure?.allStructure(forSource: source, document: document())
        XCTAssertNil(disconnected)
        await LanguageServiceConformance.check(offline)
    }

    func testAProviderThatReadsOnlyTextKeepsWorkingThroughTheDocumentEntryPoint() async {
        struct TextOnly: StructureProviding {
            func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode? {
                StructureNode(id: "t", title: "text:\(source.count)", kind: .type, nameRange: 0..<1, bodyRange: 0..<1)
            }
            func allStructure(forSource source: String) async -> [StructureNode]? { [] }
        }
        let provider = TextOnly()
        let viaDocument = await provider.structure(forSource: "abc", document: document(), atUTF16Offset: 0)
        XCTAssertEqual(viaDocument?.title, "text:3", "the default ignores the document")
        let all = await provider.allStructure(forSource: "abc", document: nil)
        XCTAssertEqual(all?.count, 0)
    }

    // MARK: - Kinds

    func testSymbolKindsMapToTheEditorsVocabulary() {
        let expected: [(Int, StructureKind)] = [
            (1, .module), (2, .module), (3, .module), (4, .module), (5, .type), (6, .method), (7, .field), (8, .field), (9, .constructor),
            (10, .type), (11, .type), (12, .function), (13, .variable), (14, .variable), (22, .enumConstant), (23, .type), (25, .function)
        ]
        for (number, kind) in expected {
            XCTAssertEqual(LSPSymbolKinds.structureKind(number), kind, "LSP SymbolKind \(number)")
        }
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(12), .function, "a call hierarchy of Python functions is not made of methods")
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(23), .structType)
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(11), .interfaceType)
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(10), .enumType)
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(6), .method)
        XCTAssertEqual(LSPSymbolKinds.hierarchyKind(5), .classType)
    }

    func testLineOffsetsHandleEveryLineEnding() {
        let offsets = LineOffsets("a\r\nbc\rd\ne")
        XCTAssertEqual(offsets.offset(LSPPosition(line: 0, character: 1)), 1)
        XCTAssertEqual(offsets.offset(LSPPosition(line: 1, character: 1)), 4)
        XCTAssertEqual(offsets.offset(LSPPosition(line: 2, character: 0)), 6)
        XCTAssertEqual(offsets.offset(LSPPosition(line: 3, character: 0)), 8)
        XCTAssertEqual(offsets.offset(LSPPosition(line: 9, character: 0)), 9, "past the end clamps")
    }

    // MARK: - Inline completion has no Java default

    private struct Marking: InlineCompletionValidating {
        let mark: String
        func validate(_ suggestion: InlineSuggestion, in document: Document, at position: TextPosition) async -> InlineSuggestion? {
            InlineSuggestion(text: suggestion.text + mark)
        }
    }

    private struct OneShot: InlineCompletionModel {
        func complete(_ request: InlineCompletionRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("run()"); $0.finish() }
        }
    }

    func testTheValidatorOfTheDocumentsOwnLanguageChecksItsSuggestion() async {
        let engine = InlineCompletionEngine(
            model: OneShot(), validators: ["java": Marking(mark: "J"), "python": Marking(mark: "P")], debounceInterval: 0
        )
        func suggest(_ language: String) async -> String? {
            var doc = document(language == "java" ? "x." : "x.")
            doc = Document(
                id: doc.id, url: nil, displayName: "x", contentSnapshot: doc.contentSnapshot, selection: doc.selection,
                cursor: doc.cursor, viewport: doc.viewport, languageIdentifier: language
            )
            let position = TextPosition(line: 0, column: 2, utf16Offset: 2)
            return await engine.suggest(request: InlineCompletionRequest(prefix: "x.", suffix: ""), document: doc, position: position)?.text
        }
        let java = await suggest("java")
        let python = await suggest("python")
        let other = await suggest("go")
        XCTAssertEqual(java, "run()J")
        XCTAssertEqual(python, "run()P")
        XCTAssertEqual(other, "run()", "a language with no validator is shown as the model wrote it")
    }

    func testNoLanguageIsValidationGradeUntilTheHostSaysSo() {
        var settings = InlineCompletionSettings()
        settings.isEnabled = true
        XCTAssertFalse(settings.isEnabled(for: "java"), "the framework has no opinion about which languages have a validator")
        settings.languageIDs = ["java"]
        XCTAssertTrue(settings.isEnabled(for: "java"))
        XCTAssertFalse(settings.isEnabled(for: "python"))
        settings.otherLanguagesEnabled = true
        XCTAssertTrue(settings.isEnabled(for: "python"))
    }
}

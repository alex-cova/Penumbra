import XCTest
import TestTreeSitterLanguages
import TreeSitter
import EditorIntelligence
@testable import Penumbra

/// Covers the ``Symbol/containerRange`` addition and ``BreadcrumbProvider/breadcrumbLocations(from:cursorOffset:)``
/// nesting that depends on it.
final class BreadcrumbContainerRangeTests: XCTestCase {
    private func parse(_ text: String, identifier: String = "javascript") async -> [EditorIntelligence.Symbol] {
        let language = TreeSitterLanguage(tree_sitter_javascript())
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            id: DocumentID(),
            url: URL(fileURLWithPath: "/tmp/a.js"),
            displayName: "a.js",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: identifier
        )
        return await parser.parse(document: document).symbols
    }

    func testDeclarationSymbolsCarryContainerRange() async {
        let text = """
        class Person {
            greet() {
                return 1;
            }
        }
        """
        let symbols = await parse(text)
        let declarations = symbols.filter { $0.containerRange != nil }
        XCTAssertTrue(declarations.contains { $0.name == "Person" && $0.kind == SymbolKind.type })
        XCTAssertTrue(declarations.contains { $0.name == "greet" && $0.kind == SymbolKind.function })
        // A declaration's container spans further than its name.
        let greet = declarations.first { $0.name == "greet" }!
        XCTAssertGreaterThan(
            greet.containerRange!.end.utf16Offset - greet.containerRange!.start.utf16Offset,
            greet.range.end.utf16Offset - greet.range.start.utf16Offset
        )
    }

    func testBreadcrumbNestsTypeThenMethodViaContainerRange() async {
        let text = """
        class Person {
            greet() {
                return 1;
            }
        }
        """
        let symbols = await parse(text)
        // Offset of "return" — inside greet()'s body.
        let cursorOffset = (text as NSString).range(of: "return").location
        let crumbs = BreadcrumbProvider.breadcrumbLocations(from: symbols, cursorOffset: cursorOffset)
        XCTAssertEqual(crumbs.map { $0.displayName }, ["Person", "greet"])
    }

    func testBreadcrumbFallsBackWhenNoContainerRanges() {
        // Legacy-shaped symbols (name range only) still produce a trail.
        let doc = DocumentID()
        func pos(_ o: Int) -> TextPosition { TextPosition(line: 0, column: o, utf16Offset: o) }
        let outer = EditorIntelligence.Symbol(
            name: "Outer", kind: .type, documentID: doc,
            range: TextRange(start: pos(0), end: pos(40))
        )
        let inner = EditorIntelligence.Symbol(
            name: "inner", kind: .function, documentID: doc,
            range: TextRange(start: pos(10), end: pos(30))
        )
        let crumbs = BreadcrumbProvider.breadcrumbLocations(from: [inner, outer], cursorOffset: 20)
        XCTAssertEqual(crumbs.map { $0.displayName }, ["Outer", "inner"])
    }
}

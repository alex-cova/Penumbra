import XCTest
import TestTreeSitterLanguages
import TreeSitter
import EditorIntelligence
@testable import Penumbra

final class TreeSitterLanguageParserTests: XCTestCase {
    func testParsesJavaScriptIdentifiers() async {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let text = "function hello() { return 42; }\nclass Person {}"
        let document = makeDocument(text: text)
        let tree = await parser.parse(document: document)
        let names = tree.symbols.map(\.name)
        XCTAssertTrue(names.contains("hello"))
        XCTAssertTrue(names.contains("Person"))
        XCTAssertTrue(tree.words.contains("function"))
    }

    func testExtractsJavaScriptImports() async {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let text = "import { foo } from 'bar';"
        let document = makeDocument(text: text)
        let tree = await parser.parse(document: document)
        XCTAssertTrue(tree.imports.contains("bar"))
    }
}

private func makeJavaScriptLanguage() -> TreeSitterLanguage {
    TreeSitterLanguage(
        tree_sitter_javascript(),
        highlightsQuery: nil,
        injectionsQuery: nil,
        indentationScopes: nil
    )
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

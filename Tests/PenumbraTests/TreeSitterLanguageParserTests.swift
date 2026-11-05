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

    /// F-01: identifiers inside tree-sitter ERROR recovery are the parser guessing, not code.
    /// They must not enter the index; valid siblings around the breakage still do.
    func testBrokenCodeIdentifiersAreNotIndexed() async {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let text = "function hello() { return 1; }\nconst x = @@@bogus;\nworld();\n"
        let document = makeDocument(text: text)
        let tree = await parser.parse(document: document)
        let names = tree.symbols.map(\.name)
        XCTAssertTrue(names.contains("hello"), "valid declarations survive the breakage: \(names)")
        XCTAssertTrue(names.contains("world"), "valid references survive the breakage: \(names)")
        XCTAssertFalse(names.contains("bogus"), "identifier inside ERROR recovery is not indexed: \(names)")
    }

    /// F-01 legacy path: the same pruning applies when no language configuration is present
    /// and bare identifiers are the only symbols.
    func testBrokenCodeIdentifiersAreNotIndexedWithoutConfiguration() {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let rawParser = TreeSitterParser(encoding: .treeSitterUTF16)
        rawParser.language = mode.language.languagePointer
        let text = "function hello() { return 1; }\nconst x = @@@bogus;\nworld();\n"
        let tree = rawParser.parse(text as NSString)
        XCTAssertNotNil(tree, "fixture must parse")
        let syntax = TreeSitterSyntaxTree(
            tree: tree,
            documentID: DocumentID(),
            text: text,
            languageConfiguration: nil
        )
        let names = syntax.symbols.map(\.name)
        XCTAssertTrue(names.contains("hello"), "valid declarations survive the breakage: \(names)")
        XCTAssertFalse(names.contains("bogus"), "identifier inside ERROR recovery is not indexed: \(names)")
    }

    /// F-02: re-parsing an unchanged snapshot reuses the cached extraction instead of walking
    /// the tree and text again.
    func testUnchangedSnapshotReusesCachedExtraction() async {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let id = DocumentID()
        let text = "function hello() { return 1; }\n"
        _ = await parser.parse(document: makeDocument(text: text, id: id))
        let afterFirst = await parser.extractionCount
        XCTAssertEqual(afterFirst, 1)
        let second = await parser.parse(document: makeDocument(text: text, id: id))
        let afterSecond = await parser.extractionCount
        XCTAssertEqual(afterSecond, 1, "unchanged text must not re-extract")
        XCTAssertTrue(second.symbols.map(\.name).contains("hello"))
    }

    /// F-02: an edited snapshot re-extracts exactly once.
    func testEditedSnapshotReExtractsOnce() async {
        let language = makeJavaScriptLanguage()
        let mode = TreeSitterLanguageMode(language: language)
        let parser = TreeSitterLanguageParser(languageMode: mode)
        let id = DocumentID()
        _ = await parser.parse(document: makeDocument(text: "function hello() {}\n", id: id))
        _ = await parser.parse(document: makeDocument(text: "function hello() {}\nfunction world() {}\n", id: id))
        let count = await parser.extractionCount
        XCTAssertEqual(count, 2)
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
    makeDocument(text: text, id: DocumentID(), languageIdentifier: "javascript")
}

private func makeDocument(text: String, id: DocumentID, languageIdentifier: String = "javascript") -> Document {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return Document(
        id: id,
        url: URL(fileURLWithPath: "/tmp/test.js"),
        displayName: "test.js",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
        languageIdentifier: languageIdentifier
    )
}

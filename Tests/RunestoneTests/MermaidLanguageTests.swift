import Foundation
import XCTest
import RunestoneLanguages
import TreeSitter
import TreeSitterMermaid
@testable import Runestone

final class MermaidLanguageTests: XCTestCase {
    func testMermaidLanguageCanBeCreated() {
        let language = TreeSitterLanguage.mermaid
        XCTAssertNotNil(language.highlightsQuery)
        XCTAssertNil(language.injectionsQuery)
        language.prepare()
        XCTAssertNotNil(language.internalLanguage.highlightsQuery)
    }

    func testMermaidParserProducesTree() {
        let text: NSString = """
        flowchart TD
            A[Start] --> B{Decision}
            B -->|Yes| C[OK]
            B -->|No| D[Cancel]
        """
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_mermaid())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testMermaidHighlightCaptures() {
        let text = """
        flowchart TD
            A[Start] --> B{Decision}
        """
        let language = TreeSitterLanguage.mermaid
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let byteRange = ByteRange(from: 0, to: text.byteCount)
        let captures = languageMode.captures(in: byteRange)
        let names = Set(captures.map(\.name))

        XCTAssertTrue(names.contains("keyword"), "Expected keyword capture, got \(names)")
        XCTAssertTrue(names.contains("field") || names.contains("operator"),
                      "Expected field/operator capture, got \(names)")
    }
}

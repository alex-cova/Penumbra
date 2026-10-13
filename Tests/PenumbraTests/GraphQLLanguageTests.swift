import Foundation
import XCTest
import PenumbraGraphQLLanguage
import TreeSitter
import TreeSitterGraphQL
@testable import Penumbra

final class GraphQLLanguageTests: XCTestCase {
    func testGraphQLLanguageCanBeCreated() {
        let language = TreeSitterLanguage.graphQL
        XCTAssertNotNil(language.highlightsQuery)
        XCTAssertNil(language.injectionsQuery)
    }

    func testGraphQLParserProducesTree() {
        let text: NSString = "query GetUser($id: ID!) { user(id: $id) { name email } }"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_graphql())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testGraphQLHighlightCaptures() {
        let text = "query GetUser($id: ID!) { user(id: $id) { name email } }"
        let language = TreeSitterLanguage.graphQL
        let internalLanguage = language.internalLanguage
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager)
        languageMode.parse()
        let byteRange = ByteRange(from: 0, to: text.byteCount)
        let captures = languageMode.captures(in: byteRange)
        let names = Set(captures.map { $0.name })

        XCTAssertTrue(names.contains("keyword"), "Expected keyword capture")
        XCTAssertTrue(names.contains("type"), "Expected type capture")
        XCTAssertTrue(names.contains("variable"), "Expected variable capture")
        XCTAssertTrue(names.contains("property"), "Expected property capture")
        XCTAssertTrue(names.contains("punctuation.bracket"), "Expected punctuation.bracket capture")
    }

    func testGraphQLDescriptionsNullCommasAndDirectives() {
        let text = """
        \"\"\"
        A user.
        \"\"\"
        type User {
          name: String @deprecated(reason: "old")
        }
        query Get($id: ID = null) {
          user(id: $id, ok: true) { name }
        }
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "A user"), "comment")
        XCTAssertEqual(paintedCapture(in: text, covering: "null"), "constant.builtin")
        XCTAssertEqual(paintedCapture(in: text, covering: ","), "punctuation.delimiter")
        XCTAssertEqual(paintedCapture(in: text, covering: "@deprecated"), "attribute")
    }

    private func paintedCapture(in text: String, covering word: String) -> String? {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.graphQL.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager)
        languageMode.parse()
        let ns = text as NSString
        let found = ns.range(of: word)
        guard found.location != NSNotFound else { return nil }
        let theme = DefaultTheme()
        return languageMode.captures(in: ByteRange(from: 0, to: text.byteCount)).last { capture in
            let range = NSRange(capture.byteRange)
            guard range.location <= found.location, range.upperBound >= found.upperBound else { return false }
            return theme.textColor(for: capture.name) != nil
        }?.name
    }

    func testGraphQLIndentationStrategyInsideSelectionSet() {
        let text = "query GetUser { user { name } }"
        let languageMode = makeGraphQLLanguageMode(text: text)
        let caretPosition = LinePosition(row: 0, column: 18)
        let strategy = languageMode.strategyForInsertingLineBreak(
            from: caretPosition,
            to: caretPosition,
            using: .space(length: 2))
        XCTAssertEqual(strategy.indentLevel, 1)
        XCTAssertFalse(strategy.insertExtraLineBreak)
    }

    private func makeGraphQLLanguageMode(text: String) -> TreeSitterInternalLanguageMode {
        let language = TreeSitterLanguage.graphQL
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager)
        languageMode.parse()
        return languageMode
    }
}

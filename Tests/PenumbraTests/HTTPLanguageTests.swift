import Foundation
import XCTest
import PenumbraLanguages
import TreeSitter
import TreeSitterHTTP
@testable import Penumbra

final class HTTPLanguageTests: XCTestCase {
    func testHTTPLanguageCanBeCreated() {
        let language = TreeSitterLanguage.http
        XCTAssertNotNil(language.highlightsQuery)
        XCTAssertNotNil(language.injectionsQuery)
        language.prepare()
        XCTAssertNotNil(language.internalLanguage.highlightsQuery)
        XCTAssertNotNil(language.internalLanguage.injectionsQuery)
    }

    func testHTTPParserProducesTree() {
        let text: NSString = """
        GET https://example.com/api HTTP/1.1
        Content-Type: application/json

        {"ok": true}
        """
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_http())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testHTTPParserAcceptsOriginFormRequest() {
        let text: NSString = """
        GET /api HTTP/1.1
        Host: example.com
        """
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_http())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testHTTPParserAcceptsResponseStatusLine() {
        let text: NSString = """
        HTTP/1.1 200 OK
        Content-Type: text/plain

        hello
        """
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_http())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testHTTPHighlightCaptures() {
        let text = """
        GET https://example.com/api HTTP/1.1
        Content-Type: application/json

        {"ok": true}
        """
        let language = TreeSitterLanguage.http
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

        XCTAssertTrue(names.contains("function.method"), "Expected function.method capture, got \(names)")
        XCTAssertTrue(names.contains("constant"), "Expected constant capture, got \(names)")
        XCTAssertTrue(names.contains("string.special.url") || names.contains("string"),
                      "Expected URL/string capture, got \(names)")
    }

    func testHTTPJSONBodyInjection() {
        let text = """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {
          "ok": true,
          "count": 42
        }
        """
        let language = TreeSitterLanguage.http
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: BundledLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let byteRange = ByteRange(from: 0, to: text.byteCount)
        let captures = languageMode.captures(in: byteRange)
        let names = Set(captures.map(\.name))

        XCTAssertTrue(names.contains("property") || names.contains("string") || names.contains("number"),
                      "Expected JSON captures from injected json_body, got \(names)")
    }
}

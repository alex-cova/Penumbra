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
        let names = captureNames(in: """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {
          "ok": true,
          "count": 42
        }
        """)

        XCTAssertTrue(names.contains("property"), "Expected property capture, got \(names)")
        XCTAssertTrue(names.contains("string"), "Expected string capture, got \(names)")
        XCTAssertTrue(names.contains("number"), "Expected number capture, got \(names)")
        XCTAssertTrue(names.contains("punctuation.delimiter"), "Expected punctuation.delimiter capture, got \(names)")
        XCTAssertEqual(paintedCapture(in: """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {
          "ok": true,
          "count": 42
        }
        """, covering: "}", backwards: true), "punctuation.bracket")
    }

    func testHTTPJSONArrayBodyInjection() {
        let names = captureNames(in: """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        [1, true, null]

        """)

        XCTAssertTrue(names.contains("number"), "Expected number capture, got \(names)")
        XCTAssertTrue(names.contains("boolean"), "Expected boolean capture, got \(names)")
        XCTAssertTrue(names.contains("constant.builtin"), "Expected constant.builtin capture, got \(names)")
        let lastLine = """
        POST https://example.com/api HTTP/1.1

        [1, true, null]
        """
        XCTAssertEqual(paintedCapture(in: lastLine, covering: "true"), "boolean")
        XCTAssertEqual(paintedCapture(in: lastLine, covering: "null"), "constant.builtin")
    }

    func testHTTPURLStaysAURL() {
        let text = """
        GET https://example.com/api HTTP/1.1
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "https://example.com/api"), "string.special.url")
        XCTAssertEqual(paintedCapture(in: "GET query.example.com/x HTTP/1.1\n", covering: "query.example.com/x"), "string.special.url")
    }

    func testHTTPCompactJSONBodyInjection() {
        let names = captureNames(in: """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {"ok": true}

        """)

        XCTAssertTrue(names.contains("property"), "Expected property capture, got \(names)")
    }

    func testHTTPCompactJSONOnTheLastLine() {
        let names = captureNames(in: """
        POST https://dev.exanple.com/stock-reports/v1/history
        Authorization: auth
        Content-Type: application/json

        {"productUuid":"3KcGtoRg0BpI3vFyCnshk7J2J3c","from":"2026-10-12","until":"2026-10-12"}
        """)

        XCTAssertTrue(names.contains("property"), "Expected property capture, got \(names)")
        XCTAssertTrue(names.contains("string"), "Expected string capture, got \(names)")
        XCTAssertTrue(names.contains("punctuation.delimiter"), "Expected punctuation.delimiter capture, got \(names)")
        XCTAssertEqual(paintedCapture(in: """
        POST https://dev.exanple.com/stock-reports/v1/history
        Authorization: auth
        Content-Type: application/json

        {"productUuid":"3KcGtoRg0BpI3vFyCnshk7J2J3c","from":"2026-10-12","until":"2026-10-12"}
        """, covering: "}", backwards: true), "punctuation.bracket")
    }

    func testHTTPGraphQLOperationInjection() {
        let names = captureNames(in: """
        POST https://example.com/graphql HTTP/1.1

        query {
          user {
            name
          }
        }
        """)

        XCTAssertTrue(names.contains("keyword"), "Expected keyword capture, got \(names)")
        XCTAssertTrue(names.contains("property"), "Expected property capture, got \(names)")
    }

    func testHTTPAnonymousGraphQLSelectionInjection() {
        let names = captureNames(in: """
        GRAPHQL https://example.com/graphql

        { me { id } }

        """)

        XCTAssertTrue(names.contains("property"), "Expected property capture, got \(names)")
        XCTAssertFalse(names.contains("string"), "Anonymous GraphQL should not be highlighted as JSON, got \(names)")
        XCTAssertEqual(paintedCapture(in: """
        GRAPHQL https://example.com/graphql

        { me { id } }
        """, covering: "me"), "property")
    }

    func testHTTPGraphQLSubscriptionInjection() {
        let names = captureNames(in: """
        POST https://example.com/graphql HTTP/1.1

        subscription {
          event {
            id
          }
        }
        """)

        XCTAssertTrue(names.contains("keyword"), "Expected keyword capture, got \(names)")
    }

    func testHTTPGraphQLVariablesInjection() {
        let text = """
        POST https://example.com/graphql HTTP/1.1

        query {
          user {
            name
          }
        }

        {
          "id": "1"
        }
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "\"id\""), "property")
        XCTAssertEqual(paintedCapture(in: text, covering: "}", backwards: true), "punctuation.bracket")
    }

    func testTemplateInAJSONValueKeepsTheOtherColors() {
        let text = """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {
          "id": {{id}},
          "name": "x",
          "count": 42
        }
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "\"name\""), "property")
        XCTAssertEqual(paintedCapture(in: text, covering: "42"), "number")
        XCTAssertEqual(paintedCapture(in: text, covering: "}", backwards: true), "punctuation.bracket")
    }

    func testTemplateInACompactJSONBody() {
        let text = """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {"id": {{id}}, "name": "x"}

        """
        XCTAssertEqual(paintedCapture(in: text, covering: "\"name\""), "property")
    }

    func testTemplateInAGraphQLArgumentKeepsTheSelectionColored() {
        let text = """
        POST https://example.com/graphql HTTP/1.1

        query {
          user(id: {{id}}) {
            name
          }
        }
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "query"), "keyword")
        XCTAssertEqual(paintedCapture(in: text, covering: "name"), "property")
    }

    func testSchemeDirectiveLineIsNotAPlainComment() {
        let text = """
        ###@scheme:https://example.com/graphql
        GRAPHQL https://example.com/graphql

        { me { id } }
        """
        XCTAssertEqual(paintedCapture(in: text, covering: "@scheme"), "keyword")
        let separator = """
        ### Create a user
        POST https://example.com/users
        """
        XCTAssertEqual(paintedCapture(in: separator, covering: "Create"), "comment")
    }

    func testBodyThatIsOnlyATemplateIsNotInjected() {
        let names = captureNames(in: """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {{payload}}
        """)
        XCTAssertFalse(names.contains("property"), "A lone template has no language, got \(names)")
    }

    private func captureNames(in text: String) -> Set<String> {
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
        return Set(languageMode.captures(in: byteRange).map(\.name))
    }

    /// The capture painted on `word`. Captures arrive outermost first, so the last one that
    /// covers the word and has a theme color is the one the highlighter leaves in place.
    private func paintedCapture(in text: String, covering word: String, backwards: Bool = false) -> String? {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.http.internalLanguage,
            languageProvider: BundledLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let ns = text as NSString
        let found = ns.range(of: word, options: backwards ? .backwards : [])
        guard found.location != NSNotFound else { return nil }
        let theme = DefaultTheme()
        let captures = languageMode.captures(in: ByteRange(from: 0, to: text.byteCount))
        return captures.last { capture in
            let range = NSRange(capture.byteRange)
            guard range.location <= found.location, range.upperBound >= found.upperBound else { return false }
            return theme.textColor(for: capture.name) != nil
        }?.name
    }
}

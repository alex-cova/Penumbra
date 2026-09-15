import Foundation
import XCTest
import RunestoneLanguages
import TreeSitter
import TreeSitterCSS
import TreeSitterTypeScript
@testable import Runestone

final class LanguagePackTests: XCTestCase {
    func testBundledLanguagesCompileQueries() {
        let languages: [(String, TreeSitterLanguage)] = [
            ("javascript", .javaScript),
            ("json", .json),
            ("python", .python),
            ("yaml", .yaml),
            ("html", .html),
            ("css", .css),
            ("typescript", .typeScript),
            ("swift", .swift)
        ]
        for (name, language) in languages {
            XCTAssertNotNil(language.highlightsQuery, name)
            language.prepare()
            XCTAssertNotNil(
                language.internalLanguage.highlightsQuery,
                "\(name) highlights query failed to compile"
            )
            if name == "javascript" || name == "html" {
                XCTAssertNotNil(
                    language.internalLanguage.injectionsQuery,
                    "\(name) injections query failed to compile"
                )
            }
        }
    }

    /// `TextView.toggleComment()` is a silent no-op for any language without
    /// `lineCommentPrefix` set — locks in the real, bundled comment token for every language that
    /// has one, and explicitly documents the ones that genuinely don't (JSON/HTML/CSS have no
    /// line-comment syntax at all).
    func testBundledLanguagesHaveTheirRealLineCommentPrefix() {
        let withPrefix: [(String, TreeSitterLanguage, String)] = [
            ("javascript", .javaScript, "//"),
            ("typescript", .typeScript, "//"),
            ("python", .python, "#"),
            ("yaml", .yaml, "#"),
            ("swift", .swift, "//"),
            ("go", .go, "//"),
            ("java", .java, "//"),
            ("kotlin", .kotlin, "//"),
            ("bash", .bash, "#"),
            ("sql", .sql, "--"),
            ("toml", .toml, "#"),
            ("http", .http, "#"),
            ("mermaid", .mermaid, "%%"),
            ("graphql", .graphQL, "#")
        ]
        for (name, language, expected) in withPrefix {
            XCTAssertEqual(language.lineCommentPrefix, expected, name)
        }

        // No standard single-line comment syntax in these languages.
        let withoutPrefix: [(String, TreeSitterLanguage)] = [
            ("json", .json),
            ("html", .html),
            ("css", .css)
        ]
        for (name, language) in withoutPrefix {
            XCTAssertNil(language.lineCommentPrefix, name)
        }
    }

    func testBundledIdentifierLookup() {
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "javascript"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "typescript"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "json"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "python"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "yaml"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "html"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "css"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "swift"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "http"))
        XCTAssertNotNil(TreeSitterLanguage.bundled(forIdentifier: "mermaid"))
        XCTAssertNil(TreeSitterLanguage.bundled(forIdentifier: "markdown"))
    }

    func testJavaScriptHighlightCaptures() {
        let text = "const name = \"Ada\";\nfunction greet() { return name; }\n"
        let captures = captureNames(language: .javaScript, text: text)
        XCTAssertTrue(captures.contains("keyword"), "Expected keyword, got \(captures)")
        XCTAssertTrue(captures.contains("string"), "Expected string, got \(captures)")
        XCTAssertTrue(captures.contains("function"), "Expected function, got \(captures)")
    }

    func testJSONHighlightCaptures() {
        let text = "{ \"ok\": true, \"n\": 1 }"
        let captures = captureNames(language: .json, text: text)
        XCTAssertTrue(captures.contains("string"), "Expected string, got \(captures)")
        XCTAssertTrue(captures.contains("number"), "Expected number, got \(captures)")
        XCTAssertTrue(captures.contains("constant.builtin"), "Expected constant.builtin, got \(captures)")
    }

    func testPythonHighlightCaptures() {
        let text = "def greet(name):\n    return f\"hi {name}\"\n"
        let captures = captureNames(language: .python, text: text)
        XCTAssertTrue(captures.contains("keyword"), "Expected keyword, got \(captures)")
        XCTAssertTrue(captures.contains("function"), "Expected function, got \(captures)")
        XCTAssertTrue(captures.contains("string"), "Expected string, got \(captures)")
    }

    func testHTMLInjectsJavaScriptAndCSS() {
        let text = "<style>h1 { color: red; }</style><script>const x = 1;</script>"
        let languageMode = makeLanguageMode(
            language: .html,
            text: text,
            languageProvider: HTMLLanguageProvider()
        )
        let captures = Set(languageMode.captures(in: ByteRange(from: 0, to: (text as NSString).byteCount)).map(\.name))
        XCTAssertTrue(captures.contains("keyword"), "Expected HTML tag captures, got \(captures)")
        XCTAssertTrue(captures.contains("property") || captures.contains("function"),
                      "Expected CSS property or JS function from injections, got \(captures)")
        XCTAssertTrue(captures.contains("number") || captures.contains("constant.builtin") || captures.contains("keyword"),
                      "Expected injected JS/CSS tokens, got \(captures)")
    }

    func testCSSParserProducesTree() {
        let text: NSString = "h1 { color: red; }"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_css())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testTypeScriptParserProducesTree() {
        let text: NSString = "function greet(name: string): string { return name; }"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_typescript())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testTypeScriptHighlightCapturesTypes() {
        let text = "function greet(name: string): string { return name; }\n"
        let captures = captureNames(language: .typeScript, text: text)
        XCTAssertTrue(captures.contains("keyword"), "Expected keyword, got \(captures)")
        XCTAssertTrue(captures.contains("type") || captures.contains("type.builtin"),
                      "Expected type capture, got \(captures)")
    }

    func testCSSHighlightCaptures() {
        let text = "h1 { color: red; }\n"
        let captures = captureNames(language: .css, text: text)
        XCTAssertTrue(captures.contains("keyword"), "Expected selector/keyword, got \(captures)")
        XCTAssertTrue(captures.contains("property"), "Expected property, got \(captures)")
    }

    func testYAMLHighlightCaptures() {
        let text = "name: Ada\ncount: 7\n"
        let captures = captureNames(language: .yaml, text: text)
        XCTAssertTrue(
            captures.contains("property") || captures.contains("string") || captures.contains("number"),
            "Expected YAML captures, got \(captures)"
        )
    }

    func testBundledLanguageProviderResolvesHTMLInjections() {
        let provider = BundledLanguageProvider()
        XCTAssertNotNil(provider.treeSitterLanguage(named: "javascript"))
        XCTAssertNotNil(provider.treeSitterLanguage(named: "css"))
        XCTAssertNotNil(provider.treeSitterLanguage(named: "swift"))
    }

    func testSwiftHighlightCapturesSwiftUI() {
        let text = """
        import SwiftUI

        struct ContentView: View {
            @State private var count = 0

            var body: some View {
                VStack {
                    Text("Count: \\(count)")
                    Button("Increment") { count += 1 }
                }
                .padding()
            }
        }
        """
        let captures = captureNames(language: .swift, text: text)
        XCTAssertTrue(captures.contains("attribute"), "Expected attribute, got \(captures)")
        XCTAssertTrue(captures.contains("keyword.import"), "Expected keyword.import, got \(captures)")
        XCTAssertTrue(captures.contains("type") || captures.contains("type.builtin"),
                      "Expected type capture, got \(captures)")
        XCTAssertTrue(captures.contains("function.call"), "Expected function.call, got \(captures)")
        XCTAssertTrue(captures.contains("keyword"), "Expected keyword, got \(captures)")
    }

    private func captureNames(language: TreeSitterLanguage, text: String) -> Set<String> {
        let languageMode = makeLanguageMode(language: language, text: text)
        let byteRange = ByteRange(from: 0, to: (text as NSString).byteCount)
        return Set(languageMode.captures(in: byteRange).map(\.name))
    }

    private func makeLanguageMode(
        language: TreeSitterLanguage,
        text: String,
        languageProvider: TreeSitterLanguageProvider? = nil
    ) -> TreeSitterInternalLanguageMode {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: languageProvider,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        return languageMode
    }
}

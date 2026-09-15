@preconcurrency import AppKit
import Foundation
import XCTest
import RunestoneMarkdownLanguage
import TreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
@testable import Runestone

final class MarkdownLanguageTests: XCTestCase {
    func testMarkdownLanguageCanBeCreated() {
        let language = TreeSitterLanguage.markdown
        XCTAssertNotNil(language.highlightsQuery)
        XCTAssertNotNil(language.injectionsQuery)
    }

    func testMarkdownInlineLanguageCanBeCreated() {
        let language = TreeSitterLanguage.markdownInline
        XCTAssertNotNil(language.highlightsQuery)
        XCTAssertNotNil(language.injectionsQuery)
    }

    func testMarkdownParserProducesTree() {
        let text: NSString = "# Hello\n\nThis is **bold** text.\n"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_markdown())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testMarkdownInlineParserProducesTree() {
        let text: NSString = "This is **bold** and _italic_ with a [link](https://example.com)."
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_markdown_inline())
        let tree = parser.parse(text)
        XCTAssertNotNil(tree)
        XCTAssertFalse(tree?.rootNode.expressionString?.isEmpty ?? true)
    }

    func testMarkdownHighlightCaptures() {
        let text = "# Heading\n\n* item one\n* item two\n"
        let languageMode = makeMarkdownLanguageMode(text: text)
        let byteRange = ByteRange(from: 0, to: (text as NSString).byteCount)
        let captures = languageMode.captures(in: byteRange)
        let names = Set(captures.map { $0.name })

        XCTAssertTrue(names.contains("punctuation.special"), "Expected punctuation.special capture for the heading/list markers")
    }

    func testMarkdownInlineInjectionIsResolvedThroughLanguageProvider() {
        let text = "# Hello **World**\n"
        let languageMode = makeMarkdownLanguageMode(text: text, languageProvider: MarkdownLanguageProvider())
        let byteRange = ByteRange(from: 0, to: (text as NSString).byteCount)
        let captures = languageMode.captures(in: byteRange)
        let names = Set(captures.map { $0.name })

        XCTAssertTrue(names.contains("markup.heading"), "Expected markup.heading capture from the block grammar")
        XCTAssertTrue(names.contains("markup.bold"), "Expected markup.bold capture from the injected markdown_inline grammar")
    }

    func testRepeatedHighlightQueriesAreStable() {
        let text = "# Heading\n\n* item one\n* item two\n"
        let languageMode = makeMarkdownLanguageMode(text: text)
        let byteRange = ByteRange(from: 0, to: (text as NSString).byteCount)
        let first = languageMode.captures(in: byteRange).map(\.name)
        let second = languageMode.captures(in: byteRange).map(\.name)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testCaptureWindowServesAdjacentRangesWithoutDroppingTokens() {
        let originalWindow = TreeSitterPerformanceConstants.highlightQueryWindowUTF16Length
        TreeSitterPerformanceConstants.highlightQueryWindowUTF16Length = 96
        defer { TreeSitterPerformanceConstants.highlightQueryWindowUTF16Length = originalWindow }

        let prefix = "alpha **one**\n\n"
        let middle = String(repeating: "plain paragraph without marks.\n\n", count: 8)
        let suffix = "omega **two**\n"
        let text = prefix + middle + suffix
        let languageMode = makeMarkdownLanguageMode(text: text, languageProvider: MarkdownLanguageProvider())
        let firstRange = ByteRange(utf16Range: NSRange(location: 0, length: prefix.utf16.count))
        let lastLocation = (text as NSString).range(of: "omega").location
        let lastRange = ByteRange(utf16Range: NSRange(location: lastLocation, length: suffix.utf16.count))

        XCTAssertTrue(languageMode.captures(in: firstRange).contains { $0.name == "markup.bold" })
        XCTAssertTrue(languageMode.captures(in: lastRange).contains { $0.name == "markup.bold" })
    }

    @MainActor
    func testInsertAtStartAndEndKeepsInlineHighlights() {
        let body = (0..<12).map { "Paragraph \($0) with **bold** words.\n\n" }.joined()
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(TextViewState(
            text: body,
            language: .markdown,
            languageProvider: MarkdownLanguageProvider(),
            parsePolicy: .eager
        ))
        let firstRange = NSRange(location: 0, length: 36)
        XCTAssertTrue(textView.syntaxHighlightCaptures(in: firstRange).contains { $0.name == "markup.bold" })

        textView.replace(NSRange(location: (body as NSString).length, length: 0), withText: " tail")
        XCTAssertTrue(textView.syntaxHighlightCaptures(in: firstRange).contains { $0.name == "markup.bold" })

        textView.replace(NSRange(location: 0, length: 0), withText: "head ")
        let shiftedFirst = NSRange(location: 5, length: 36)
        XCTAssertTrue(textView.syntaxHighlightCaptures(in: shiftedFirst).contains { $0.name == "markup.bold" })
    }

    func testMarkdownLanguageProviderResolvesMarkdownInline() {
        let provider = MarkdownLanguageProvider()
        XCTAssertNotNil(provider.treeSitterLanguage(named: "markdown_inline"))
        XCTAssertNil(provider.treeSitterLanguage(named: "html"))
    }

    private func makeMarkdownLanguageMode(text: String, languageProvider: TreeSitterLanguageProvider? = nil) -> TreeSitterInternalLanguageMode {
        let language = TreeSitterLanguage.markdown
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: languageProvider,
            stringView: stringView,
            lineManager: lineManager)
        languageMode.parse()
        return languageMode
    }
}

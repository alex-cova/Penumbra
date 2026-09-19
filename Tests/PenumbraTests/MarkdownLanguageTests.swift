@preconcurrency import AppKit
import Foundation
import XCTest
import PenumbraMarkdownLanguage
import TreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
@testable import Penumbra

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

        XCTAssertTrue(names.contains("markup.heading.1"), "Expected markup.heading.1 capture from the block grammar")
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

    // A node name that doesn't exist in the grammar makes `ts_query_new` fail, and
    // `TreeSitterInternalLanguage` swallows that into a nil query (with a DEBUG-only print) — i.e.
    // one typo silently disables *all* highlighting for the language.
    func testMarkdownQueriesCompile() {
        let block = TreeSitterLanguage.markdown.internalLanguage
        XCTAssertNotNil(block.highlightsQuery, "Block/highlights.scm failed to compile — a node name likely doesn't exist in the grammar")
        XCTAssertNotNil(block.injectionsQuery, "Block/injections.scm failed to compile")
        let inline = TreeSitterLanguage.markdownInline.internalLanguage
        XCTAssertNotNil(inline.highlightsQuery, "Inline/highlights.scm failed to compile — a node name likely doesn't exist in the grammar")
        XCTAssertNotNil(inline.injectionsQuery, "Inline/injections.scm failed to compile")
    }

    func testBlockGrammarExposesNodesUsedByQueries() {
        let text: NSString = """
        # H1

        - [x] done

        | a | b |
        | - | - |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        [ref]: https://example.com
        """
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_markdown())
        let expression = parser.parse(text)?.rootNode.expressionString ?? ""
        for node in ["atx_heading", "atx_h1_marker", "task_list_marker_checked", "pipe_table_header",
                     "pipe_table_delimiter_row", "info_string", "language", "link_reference_definition"] {
            XCTAssertTrue(expression.contains(node), "grammar no longer produces \(node):\n\(expression)")
        }
    }

    func testInlineGrammarExposesNodesUsedByQueries() {
        let text: NSString = "~~gone~~ <a@b.co> [full][ref] [collapsed][] &amp; `code`"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_markdown_inline())
        let expression = parser.parse(text)?.rootNode.expressionString ?? ""
        for node in ["strikethrough", "email_autolink", "full_reference_link", "collapsed_reference_link",
                     "entity_reference", "code_span"] {
            XCTAssertTrue(expression.contains(node), "grammar no longer produces \(node):\n\(expression)")
        }
    }

    func testMarkdownLanguageProviderResolvesMarkdownInline() {
        let provider = MarkdownLanguageProvider()
        XCTAssertNotNil(provider.treeSitterLanguage(named: "markdown_inline"))
        XCTAssertNil(provider.treeSitterLanguage(named: "html"))
    }

    func testMarkdownLanguageProviderReusesInlineLanguageInstance() {
        // Every `(inline)` node asks the provider for this language; recompiling its queries per
        // paragraph made long documents pay for it hundreds of times.
        let provider = MarkdownLanguageProvider()
        let first = provider.treeSitterLanguage(named: "markdown_inline")
        let second = provider.treeSitterLanguage(named: "markdown_inline")
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testMarkdownLanguageProviderChainsToFenceLanguageProvider() {
        final class StubProvider: TreeSitterLanguageProvider {
            var requested: [String] = []
            func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
                requested.append(languageName)
                return nil
            }
        }
        let stub = StubProvider()
        let provider = MarkdownLanguageProvider(fenceLanguageProvider: stub)
        XCTAssertNotNil(provider.treeSitterLanguage(named: "markdown_inline"))
        XCTAssertNil(provider.treeSitterLanguage(named: "swift"))
        XCTAssertEqual(stub.requested, ["swift"], "markdown_inline must be answered locally, everything else forwarded")
    }

    // MARK: - Headings

    func testAtxHeadingLevelsAreCapturedIndividually() {
        let names = captureNames(in: "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n")
        for level in 1...6 {
            XCTAssertTrue(names.contains("markup.heading.\(level)"), "Missing markup.heading.\(level) in \(names)")
        }
    }

    func testSetextHeadingLevelsAreCaptured() {
        let names = captureNames(in: "Title\n=====\n\nSubtitle\n--------\n")
        XCTAssertTrue(names.contains("markup.heading.1"), "\(names)")
        XCTAssertTrue(names.contains("markup.heading.2"), "\(names)")
    }

    func testHeadingCaptureCoversTheMarker() {
        // The whole heading node is captured, not just its text, so a scaled heading font also
        // covers the `#` and the whole line grows together.
        let text = "# One\n"
        let heading = captures(in: text).first { $0.name == "markup.heading.1" }
        XCTAssertNotNil(heading)
        XCTAssertEqual(heading?.byteRange.lowerBound, ByteCount(0))
    }

    func testBoldInsideHeadingIsStillCaptured() {
        let names = captureNames(in: "# Hello **World**\n", languageProvider: MarkdownLanguageProvider())
        XCTAssertTrue(names.contains("markup.heading.1"), "\(names)")
        XCTAssertTrue(names.contains("markup.bold"), "\(names)")
    }

    // End-to-end through the real highlighter: grammar → captures → PaletteTheme → applied fonts.
    func testHeadingIsScaledAndBoldInsideItKeepsTheHeadingSize() throws {
        let heading = "# Hello **World**\n"
        let body = "plain **bold** text\n"
        let text = heading + "\n" + body
        let theme = PaletteTheme(size: 13, palette: ThemeCatalog.palette(id: ThemeCatalog.defaultDarkID, fallbackDark: true),
                                 postscriptName: "Menlo-Regular")
        let languageMode = makeMarkdownLanguageMode(text: text, languageProvider: MarkdownLanguageProvider())
        let highlighter = languageMode.createLineSyntaxHighlighter()
        highlighter.theme = theme

        func highlight(_ line: String, startingAtByte start: ByteCount) -> NSMutableAttributedString {
            let attributed = NSMutableAttributedString(string: line, attributes: [.font: theme.font, .foregroundColor: theme.textColor])
            let byteRange = ByteRange(from: start, to: start + (line as NSString).byteCount)
            highlighter.syntaxHighlight(LineSyntaxHighlighterInput(attributedString: attributed, byteRange: byteRange))
            return attributed
        }
        func font(_ attributed: NSAttributedString, at index: Int) throws -> NSFont {
            try XCTUnwrap(attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        }

        let headingLine = highlight(heading, startingAtByte: 0)
        let expectedH1 = (theme.font.pointSize * 1.6).rounded()
        XCTAssertEqual(try font(headingLine, at: 2).pointSize, expectedH1, "heading text should be scaled")
        XCTAssertEqual(try font(headingLine, at: 0).pointSize, expectedH1, "the # marker scales with its line")
        let boldInHeading = try font(headingLine, at: 10)
        XCTAssertEqual(boldInHeading.pointSize, expectedH1, "bold inside a heading must not snap back to body size")
        XCTAssertTrue(boldInHeading.fontDescriptor.symbolicTraits.contains(.bold))

        let bodyStart = ((heading + "\n") as NSString).byteCount
        let bodyLine = highlight(body, startingAtByte: bodyStart)
        let boldInBody = try font(bodyLine, at: 8)
        XCTAssertEqual(boldInBody.pointSize, theme.font.pointSize, "body text is unaffected by heading scaling")
        XCTAssertTrue(boldInBody.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: - Block constructs

    func testTaskListMarkersAreCaptured() {
        let names = captureNames(in: "- [x] done\n- [ ] todo\n")
        XCTAssertTrue(names.contains("markup.list.checked"), "\(names)")
        XCTAssertTrue(names.contains("markup.list.unchecked"), "\(names)")
        XCTAssertTrue(names.contains("markup.list"), "\(names)")
    }

    func testPipeTableIsCaptured() {
        let names = captureNames(in: "| a | b |\n| - | - |\n| 1 | 2 |\n")
        XCTAssertTrue(names.contains("markup.table.header"), "\(names)")
        XCTAssertTrue(names.contains("punctuation.delimiter"), "\(names)")
    }

    func testFenceInfoStringLanguageIsCaptured() {
        XCTAssertTrue(captureNames(in: "```swift\nlet x = 1\n```\n").contains("type"))
    }

    func testFencedCodeBlockIsNotBlanketRawCaptured() {
        // A capture over the whole fence would paint every token the injected grammar doesn't
        // capture (identifiers, whitespace) in the raw colour, defeating fence highlighting.
        let names = captureNames(in: "```swift\nlet x = 1\n```\n")
        XCTAssertFalse(names.contains("markup.raw"), "\(names)")
    }

    func testIndentedCodeBlockIsStillRaw() {
        XCTAssertTrue(captureNames(in: "para\n\n    indented code\n").contains("markup.raw"))
    }

    // MARK: - Inline constructs (resolved through the injected markdown_inline layer)

    func testInlineConstructsAreCaptured() {
        let provider = MarkdownLanguageProvider()
        XCTAssertTrue(captureNames(in: "some ~~gone~~ text\n", languageProvider: provider).contains("markup.strikethrough"))
        XCTAssertTrue(captureNames(in: "mail <a@b.co> now\n", languageProvider: provider).contains("markup.link.url"))
        XCTAssertTrue(captureNames(in: "[full][ref] and [collapsed][]\n\n[ref]: https://example.com\n", languageProvider: provider)
            .contains("markup.link.label"))
        XCTAssertTrue(captureNames(in: "fish &amp; chips\n", languageProvider: provider).contains("string.escape"))
        XCTAssertTrue(captureNames(in: "some `code` here\n", languageProvider: provider).contains("markup.raw"))
    }

    private func captures(in text: String, languageProvider: TreeSitterLanguageProvider? = nil) -> [TreeSitterCapture] {
        let languageMode = makeMarkdownLanguageMode(text: text, languageProvider: languageProvider)
        return languageMode.captures(in: ByteRange(from: 0, to: (text as NSString).byteCount))
    }

    private func captureNames(in text: String, languageProvider: TreeSitterLanguageProvider? = nil) -> Set<String> {
        Set(captures(in: text, languageProvider: languageProvider).map(\.name))
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

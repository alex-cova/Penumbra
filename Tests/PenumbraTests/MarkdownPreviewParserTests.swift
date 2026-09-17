import AppKit
import XCTest
@testable import Penumbra

/// Coverage for `MarkdownPreviewIntentWalker` (block structure: quotes, lists, tables) and
/// `MarkdownPreviewInlineStyler` (bold/italic/code/strikethrough/link). Before this walker
/// replaced the line-scanning parser, none of nested quotes, tables, task lists, or nested lists
/// had any test coverage at all — `testParseHeadingsListsAndFences` in `MarkdownPreviewTests.swift`
/// was the only parser test.
final class MarkdownPreviewParserTests: XCTestCase {
    // MARK: - Blockquotes

    func testNestedBlockquoteDepths() {
        let source = "> Outer\n>> Nested\n>>> Triple"
        let document = MarkdownPreviewDocument.parse(source)

        func paragraphDepth(containing text: String) -> Int? {
            document.blocks.first { block in
                if case .paragraph(let attributed) = block.kind {
                    return String(attributed.characters).contains(text)
                }
                return false
            }?.quoteDepth
        }

        XCTAssertEqual(paragraphDepth(containing: "Outer"), 1)
        XCTAssertEqual(paragraphDepth(containing: "Nested"), 2)
        XCTAssertEqual(paragraphDepth(containing: "Triple"), 3)

        // No literal `>` markers should leak into the rendered text.
        for block in document.blocks {
            if case .paragraph(let attributed) = block.kind {
                XCTAssertFalse(String(attributed.characters).contains(">"))
            }
        }
    }

    func testBlockquoteContainsHeadingAndFenceWithQuoteDepth() {
        let source = "> ## Quoted heading\n>\n> ```swift\n> let x = 1\n> ```"
        let document = MarkdownPreviewDocument.parse(source)

        let heading = document.blocks.first { if case .heading = $0.kind { return true }; return false }
        XCTAssertEqual(heading?.quoteDepth, 1)
        if case .heading(let level, let text) = heading?.kind {
            XCTAssertEqual(level, 2)
            XCTAssertTrue(String(text.characters).contains("Quoted heading"))
        } else {
            XCTFail("Expected a heading block")
        }

        let code = document.blocks.first { if case .codeBlock = $0.kind { return true }; return false }
        XCTAssertEqual(code?.quoteDepth, 1)
        if case .codeBlock(let language, let codeSource) = code?.kind {
            XCTAssertEqual(language, "swift")
            XCTAssertTrue(codeSource.contains("let x = 1"))
        } else {
            XCTFail("Expected a code block")
        }
    }

    // MARK: - Tables

    func testTableParsesColumnsAlignmentHeaderAndRows() {
        let source = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a    | b      | c     |
        | d    | e      | f     |
        """
        let document = MarkdownPreviewDocument.parse(source)
        guard let table = document.blocks.compactMap({ block -> MarkdownPreviewTable? in
            if case .table(let table) = block.kind { return table }
            return nil
        }).first else {
            return XCTFail("Expected a table block")
        }

        XCTAssertEqual(table.columns.map(\.alignment), [.leading, .center, .trailing])
        XCTAssertEqual(table.header.map { String($0.characters) }, ["Left", "Center", "Right"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0].map { String($0.characters) }, ["a", "b", "c"])
        XCTAssertEqual(table.rows[1].map { String($0.characters) }, ["d", "e", "f"])
    }

    func testRaggedTableRowsArePaddedToColumnCount() {
        let source = """
        | One | Two | Three |
        |-----|-----|-------|
        | a   | b   |
        """
        let document = MarkdownPreviewDocument.parse(source)
        guard let table = document.blocks.compactMap({ block -> MarkdownPreviewTable? in
            if case .table(let table) = block.kind { return table }
            return nil
        }).first else {
            return XCTFail("Expected a table block")
        }
        XCTAssertEqual(table.rows.first?.count, 3, "A ragged row must still be padded to the full column count")
    }

    // MARK: - Lists

    func testTaskListMarkersAreStrippedAndChecked() {
        let source = "- [x] Done\n- [ ] Not done"
        let document = MarkdownPreviewDocument.parse(source)
        guard let list = document.blocks.compactMap({ block -> MarkdownPreviewList? in
            if case .list(let list) = block.kind { return list }
            return nil
        }).first else {
            return XCTFail("Expected a list block")
        }

        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].marker, .task(checked: true))
        XCTAssertEqual(list.items[1].marker, .task(checked: false))
        XCTAssertEqual(String(list.items[0].text.characters), "Done")
        XCTAssertEqual(String(list.items[1].text.characters), "Not done")
        XCTAssertFalse(String(list.items[0].text.characters).contains("["))
    }

    func testNestedListItemLevels() {
        let source = "- a\n- b\n  - c"
        let document = MarkdownPreviewDocument.parse(source)
        guard let list = document.blocks.compactMap({ block -> MarkdownPreviewList? in
            if case .list(let list) = block.kind { return list }
            return nil
        }).first else {
            return XCTFail("Expected a list block")
        }

        XCTAssertEqual(list.items.map { String($0.text.characters) }, ["a", "b", "c"])
        XCTAssertEqual(list.items.map(\.level), [0, 0, 1])
    }

    func testOrderedListPreservesStartingOrdinal() {
        let source = "3. three\n4. four"
        let document = MarkdownPreviewDocument.parse(source)
        guard let list = document.blocks.compactMap({ block -> MarkdownPreviewList? in
            if case .list(let list) = block.kind { return list }
            return nil
        }).first else {
            return XCTFail("Expected a list block")
        }
        XCTAssertEqual(list.items.map(\.marker), [.ordered(3), .ordered(4)])
    }

    // MARK: - Headings / thematic breaks / images

    func testSetextHeadingIsRecognized() {
        let source = "Setext Title\n============"
        let document = MarkdownPreviewDocument.parse(source)
        XCTAssertTrue(document.blocks.contains { block in
            if case .heading(let level, let text) = block.kind {
                return level == 1 && String(text.characters).contains("Setext Title")
            }
            return false
        })
    }

    func testThematicBreakVariants() {
        for marker in ["***", "___", "---"] {
            let document = MarkdownPreviewDocument.parse("Above\n\n\(marker)\n\nBelow")
            XCTAssertTrue(
                document.blocks.contains { if case .thematicBreak = $0.kind { return true }; return false },
                "Expected a thematic break for '\(marker)'"
            )
        }
    }

    func testImageWithTitleDoesNotGlueOntoReference() {
        let document = MarkdownPreviewDocument.parse(#"![A sample diagram](https://example.com/image.png "Sample image title")"#)
        XCTAssertTrue(document.blocks.contains { block in
            if case .image(let alt, let reference) = block.kind {
                return alt == "A sample diagram" && reference == "https://example.com/image.png"
            }
            return false
        })
    }

    // MARK: - Inline styling

    private let style = MarkdownPreviewStyle()

    private func inline(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    func testBoldRunGetsBoldTrait() {
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("**bold**"), baseFont: .systemFont(ofSize: 14), color: .labelColor, style: style
        )
        guard let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return XCTFail("Expected a font attribute")
        }
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testItalicRunGetsItalicTrait() {
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("*italic*"), baseFont: .systemFont(ofSize: 14), color: .labelColor, style: style
        )
        guard let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return XCTFail("Expected a font attribute")
        }
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
    }

    func testInlineCodeUsesMonospacedFont() {
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("`code`"), baseFont: .systemFont(ofSize: 14), color: .labelColor, style: style
        )
        guard let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return XCTFail("Expected a font attribute")
        }
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testStrikethroughRunCarriesStrikethroughAttribute() {
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("~~strike~~"), baseFont: .systemFont(ofSize: 14), color: .labelColor, style: style
        )
        let strike = styled.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
    }

    func testLinkRunCarriesLinkColorAndURL() {
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("[text](https://example.com)"), baseFont: .systemFont(ofSize: 14), color: .labelColor, style: style
        )
        let color = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let link = styled.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(color, style.linkColor)
        XCTAssertEqual(link?.absoluteString, "https://example.com")
    }

    /// Guards "base font/color applied only where absent": a bold run inside a heading must stay
    /// at the *heading's* size (derived from the heading's own base font), not silently reset to
    /// the smaller body size.
    func testBoldInsideHeadingKeepsHeadingSize() {
        let headingFont = NSFontManager.shared.convert(.systemFont(ofSize: 14), toSize: 28)
        let styled = MarkdownPreviewInlineStyler.attributedString(
            inline("**Bold Heading**"), baseFont: headingFont, color: .labelColor, style: style
        )
        guard let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return XCTFail("Expected a font attribute")
        }
        XCTAssertEqual(font.pointSize, 28)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
}

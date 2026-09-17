import AppKit
import XCTest
@testable import Penumbra

/// Coverage for GFM-style footnotes (`[^1]` inline references, `[^1]:` definitions): extraction
/// from raw source (`MarkdownPreviewFootnotes.extract`), renumbering by first-reference order and
/// inline marker substitution (`MarkdownPreviewFootnotes.numberReferences`), the trailing
/// `.footnotes` block produced by `MarkdownPreviewDocument.parse`, its layout, and its styling.
final class MarkdownPreviewFootnoteTests: XCTestCase {
    private func footnotesBlock(in document: MarkdownPreviewDocument) -> [MarkdownPreviewFootnote]? {
        document.blocks.compactMap { block -> [MarkdownPreviewFootnote]? in
            if case .footnotes(let footnotes) = block.kind { return footnotes }
            return nil
        }.first
    }

    private func allBodyText(in document: MarkdownPreviewDocument) -> String {
        document.blocks.map { block -> String in
            switch block.kind {
            case .paragraph(let text), .heading(_, let text):
                return String(text.characters)
            case .codeBlock(_, let source):
                return source
            default:
                return ""
            }
        }.joined(separator: "\n")
    }

    // MARK: - Basic extraction

    func testFootnoteDefinitionProducesTrailingFootnotesBlockAndLeavesNoRawText() {
        let source = "Body text with a reference[^1] inline.\n\n[^1]: This is the footnote text."
        let document = MarkdownPreviewDocument.parse(source)

        guard let footnotes = footnotesBlock(in: document) else {
            return XCTFail("Expected a trailing .footnotes block")
        }
        XCTAssertEqual(footnotes.count, 1)
        XCTAssertEqual(footnotes[0].number, 1)
        XCTAssertEqual(String(footnotes[0].text.characters), "This is the footnote text.")

        XCTAssertFalse(allBodyText(in: document).contains("[^1]:"), "The raw definition line must not leak into a body block")
    }

    func testFootnotesBlockIsPrecededByThematicBreak() {
        let source = "Text[^1]\n\n[^1]: Note."
        let document = MarkdownPreviewDocument.parse(source)
        guard case .footnotes = document.blocks.last?.kind else {
            return XCTFail("Expected the last block to be .footnotes")
        }
        guard document.blocks.count >= 2, case .thematicBreak = document.blocks[document.blocks.count - 2].kind else {
            return XCTFail("Expected a thematic break immediately before the footnotes block")
        }
    }

    // MARK: - Regression: definitions must not leak across fence-split prose segments

    func testDefinitionAfterCodeFenceProducesExactlyOneEntryNoDuplicates() {
        let source = """
        Reference[^1] before a fence.

        ```swift
        let x = 1
        ```

        [^1]: Defined after the fence.
        """
        let document = MarkdownPreviewDocument.parse(source)
        guard let footnotes = footnotesBlock(in: document) else {
            return XCTFail("Expected a .footnotes block")
        }
        XCTAssertEqual(footnotes.count, 1)

        let paragraphCount = document.blocks.filter {
            if case .paragraph(let text) = $0.kind { return String(text.characters).contains("Defined after the fence") }
            return false
        }.count
        XCTAssertEqual(paragraphCount, 0, "The definition text must not also render as an ordinary paragraph")
    }

    // MARK: - Inline marker substitution

    func testInlineReferenceBecomesNumberedFootnoteMarkerRun() {
        let source = "See[^note] here.\n\n[^note]: Body."
        let document = MarkdownPreviewDocument.parse(source)
        guard case .paragraph(let text) = document.blocks.first?.kind else {
            return XCTFail("Expected a paragraph block")
        }

        let markerRun = text.runs.first { $0.footnoteMarker != nil }
        guard let markerRun else { return XCTFail("Expected a run tagged with footnoteMarker") }
        XCTAssertEqual(markerRun.footnoteMarker, 1)
        XCTAssertEqual(String(text[markerRun.range].characters), "1")
        XCTAssertNil(markerRun.link, "A footnote marker must not also be a clickable link")
        XCTAssertFalse(String(text.characters).contains("[^note]"))
    }

    // MARK: - Numbering order

    func testNumberingFollowsFirstReferenceOrderNotDefinitionOrder() {
        let source = """
        First[^b] then second[^a].

        [^a]: Defined first in source.
        [^b]: Defined second in source.
        """
        let document = MarkdownPreviewDocument.parse(source)
        guard let footnotes = footnotesBlock(in: document) else {
            return XCTFail("Expected a .footnotes block")
        }
        XCTAssertEqual(footnotes.count, 2)
        // `[^b]` is referenced first in the body, so it must be numbered 1 despite being defined second.
        XCTAssertEqual(footnotes.first { $0.label == "b" }?.number, 1)
        XCTAssertEqual(footnotes.first { $0.label == "a" }?.number, 2)
    }

    // MARK: - Undefined reference

    func testReferenceWithNoDefinitionStaysLiteral() {
        let source = "A stray reference[^missing] with no definition."
        let document = MarkdownPreviewDocument.parse(source)
        XCTAssertNil(footnotesBlock(in: document))
        guard case .paragraph(let text) = document.blocks.first?.kind else {
            return XCTFail("Expected a paragraph block")
        }
        XCTAssertTrue(String(text.characters).contains("[^missing]"))
        XCTAssertTrue(text.runs.allSatisfy { $0.footnoteMarker == nil })
    }

    // MARK: - Continuation lines

    func testIndentedAndLazyContinuationLinesJoinIntoOneParagraph() {
        let source = """
        Ref[^1].

        [^1]: First line of the note
            continued with an indented line
        and a lazy continuation line.
        """
        let document = MarkdownPreviewDocument.parse(source)
        guard let footnotes = footnotesBlock(in: document) else {
            return XCTFail("Expected a .footnotes block")
        }
        XCTAssertEqual(footnotes.count, 1)
        let text = String(footnotes[0].text.characters)
        XCTAssertTrue(text.contains("First line of the note"))
        XCTAssertTrue(text.contains("continued with an indented line"))
        XCTAssertTrue(text.contains("and a lazy continuation line."))
    }

    // MARK: - Fenced code protection

    func testDefinitionLikeLineInsideFencedCodeBlockIsNotExtracted() {
        let source = """
        ```text
        [^1]: This looks like a footnote but is code.
        ```
        """
        let document = MarkdownPreviewDocument.parse(source)
        XCTAssertNil(footnotesBlock(in: document), "A definition-shaped line inside a fence must not be extracted")

        guard case .codeBlock(_, let codeSource) = document.blocks.first?.kind else {
            return XCTFail("Expected a code block")
        }
        XCTAssertTrue(codeSource.contains("[^1]: This looks like a footnote but is code."))
    }

    // MARK: - Styling

    func testFootnoteMarkerRunGetsSmallerFontThanBaseFont() {
        var footnoteMarker = AttributedString("1")
        footnoteMarker.footnoteMarker = 1
        let baseFont = NSFont.systemFont(ofSize: 14)
        let style = MarkdownPreviewStyle()

        let styled = MarkdownPreviewInlineStyler.attributedString(
            footnoteMarker, baseFont: baseFont, color: .labelColor, style: style
        )
        guard let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return XCTFail("Expected a font attribute")
        }
        XCTAssertLessThan(font.pointSize, baseFont.pointSize)
    }

    // MARK: - Layout

    func testFootnotesLayoutProducesMarkerBeforeTextPerEntry() {
        let source = "One[^1] two[^2].\n\n[^1]: First note.\n[^2]: Second note."
        let document = MarkdownPreviewDocument.parse(source)
        let style = MarkdownPreviewStyle()
        let layout = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)

        guard let footnotesLayout = layout.blockLayouts.first(where: {
            if case .footnotes = $0.block.kind { return true }
            return false
        }) else {
            return XCTFail("Expected a .footnotes block layout")
        }
        XCTAssertEqual(footnotesLayout.markerFrames.count, 2)
        XCTAssertEqual(footnotesLayout.textFrames.count, 2)
        XCTAssertLessThan(footnotesLayout.markerFrames[0].minX, footnotesLayout.textFrames[0].minX)
    }

    // MARK: - Accessibility

    func testAccessibilityDescriptionCoversFootnotesBlock() {
        let source = "Ref[^1].\n\n[^1]: The note text."
        let document = MarkdownPreviewDocument.parse(source)
        let description = document.accessibilityDescriptions.last ?? ""
        XCTAssertTrue(description.contains("Footnotes"))
        XCTAssertTrue(description.contains("The note text."))
    }
}

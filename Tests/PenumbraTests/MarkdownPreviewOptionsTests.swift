import AppKit
import CoreText
import XCTest
@testable import Penumbra

/// Reading options a host exposes as settings (`MarkdownPreviewOptions`) and the layout features
/// behind them: numbered headings, heading alignment, paragraph indent and justification, a
/// line-length limit, table density, typeface and size.
final class MarkdownPreviewOptionsTests: XCTestCase {
    private func headings(_ markdown: String) -> [String] {
        let document = MarkdownPreviewDocument.parse(markdown)
        let numbers = MarkdownPreviewLayout.headingNumbers(for: document.blocks)
        return document.blocks.indices.compactMap { numbers[$0] }
    }

    func testHeadingNumbersSkipASingleTitle() {
        XCTAssertEqual(
            headings("# Title\n\n## Intro\n\n### Scope\n\n### Terms\n\n## Design\n\n### Parts\n"),
            ["1", "1.1", "1.2", "2", "2.1"]
        )
    }

    func testHeadingNumbersStartAtTheTopLevelWhenItRepeats() {
        XCTAssertEqual(headings("# One\n\n## A\n\n# Two\n\n## B\n\n## C\n"), ["1", "1.1", "2", "2.1", "2.2"])
    }

    func testHeadingNumbersShowASkippedLevelAsZero() {
        XCTAssertEqual(headings("## A\n\n#### Deep\n\n## B\n"), ["1", "1.0.1", "2"])
    }

    @MainActor
    private func layout(_ markdown: String, style: MarkdownPreviewStyle, width: CGFloat = 900,
                        cache: MarkdownPreviewMeasureCache? = nil) -> MarkdownPreviewLayout {
        MarkdownPreviewLayout.layout(
            document: MarkdownPreviewDocument.parse(markdown), style: style, width: width, cache: cache
        )
    }

    /// Origin of the first typeset line of `block`'s text, relative to its text frame.
    private func firstLineOrigin(_ block: MarkdownPreviewBlockLayout) throws -> CGPoint {
        let frame = try XCTUnwrap(block.text?.frames.first)
        var origin = CGPoint.zero
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &origin)
        return origin
    }

    @MainActor
    func testLineLengthLimitCentersANarrowerColumn() {
        var style = MarkdownPreviewStyle()
        let text = String(repeating: "Some words in a paragraph. ", count: 40)
        let full = layout(text, style: style, width: 2000).blockLayouts[0].frame
        XCTAssertEqual(full.minX, style.contentInset)

        style.maxLineLength = 70
        let column = layout(text, style: style, width: 2000).blockLayouts[0].frame
        XCTAssertEqual(column.width, 70 * style.averageCharacterWidth, accuracy: 2)
        XCTAssertEqual(column.midX, 1000, accuracy: 1, "centered")
        XCTAssertGreaterThan(column.height, full.height, "wraps more")

        // Narrower than the limit: the usual margins.
        let narrow = layout(text, style: style, width: 300).blockLayouts[0].frame
        XCTAssertEqual(narrow.minX, style.contentInset)
    }

    @MainActor
    func testParagraphIndentOnlyWhenAParagraphFollowsAParagraph() throws {
        var style = MarkdownPreviewStyle()
        style.paragraphIndent = 28
        let blocks = layout("# Head\n\nFirst paragraph.\n\nSecond paragraph.\n", style: style).blockLayouts
        XCTAssertEqual(try firstLineOrigin(blocks[1]).x, 0, accuracy: 0.5, "after a heading")
        XCTAssertEqual(try firstLineOrigin(blocks[2]).x, 28, accuracy: 0.5, "after a paragraph")
    }

    @MainActor
    func testCenteredHeadingsAndNumbersReachTheTypesetText() throws {
        var style = MarkdownPreviewStyle()
        let plain = layout("# One\n\n# Two\n", style: style).blockLayouts[0]
        XCTAssertEqual(try firstLineOrigin(plain).x, 0, accuracy: 0.5)

        style.headingAlignment = .center
        let centered = layout("# One\n\n# Two\n", style: style).blockLayouts[0]
        XCTAssertGreaterThan(try firstLineOrigin(centered).x, 100)

        // Turning numbering on with the same measure cache must not reuse the unnumbered text.
        let cache = MarkdownPreviewMeasureCache()
        style.headingAlignment = .natural
        let before = layout("# One\n\n# Two\n", style: style, cache: cache).blockLayouts[0]
        style.numbersHeadings = true
        let after = layout("# One\n\n# Two\n", style: style, cache: cache).blockLayouts[0]
        let length = { (block: MarkdownPreviewBlockLayout) in
            CTFrameGetStringRange(block.text!.frames[0]).length
        }
        XCTAssertEqual(length(before), 3)
        XCTAssertEqual(length(after), 6, "\"1  One\"")
    }

    @MainActor
    func testOptionsMapOntoTheStyle() {
        let base = MarkdownPreviewStyle()
        XCTAssertEqual(MarkdownPreviewOptions().applied(to: base), base, "defaults change nothing")

        let options = MarkdownPreviewOptions(
            typeface: .serif, fontSize: 18, lineSpacing: .relaxed, maxLineLength: 80,
            headingAlignment: .center, numbersHeadings: true, indentsParagraphs: true,
            justifiesParagraphs: true, tableDensity: .compact
        )
        let style = options.applied(to: base)
        XCTAssertEqual(style.bodyFont.pointSize, 18)
        XCTAssertNotEqual(style.bodyFont.fontName, NSFont.systemFont(ofSize: 18).fontName, "New York, not SF")
        XCTAssertEqual(style.codeFont.pointSize, 17)
        XCTAssertGreaterThan(style.lineSpacing, base.lineSpacing)
        XCTAssertEqual(style.maxLineLength, 80)
        XCTAssertEqual(style.headingAlignment, .center)
        XCTAssertTrue(style.numbersHeadings)
        XCTAssertEqual(style.paragraphIndent, 36)
        XCTAssertTrue(style.justifiesParagraphs)
        XCTAssertLessThan(style.tableCellPadding, base.tableCellPadding)

        XCTAssertEqual(MarkdownPreviewOptions(maxLineLength: 5).applied(to: base).maxLineLength, 40, "clamped")
        let missing = MarkdownPreviewOptions(typeface: .custom("No Such Family 123")).applied(to: base)
        XCTAssertEqual(missing.bodyFont.familyName, NSFontManager.shared.convert(base.bodyFont, toSize: base.bodyFont.pointSize).familyName, "falls back to the editor font")
    }
}

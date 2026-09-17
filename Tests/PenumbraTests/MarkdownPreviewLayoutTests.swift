import AppKit
import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewLayout`'s block positioning (quote/list indent) and the quote-band
/// decorations that make `>`, `>>`, `>>>` read as visually nested rather than one flat tint.
final class MarkdownPreviewLayoutTests: XCTestCase {
    func testQuoteDecorationsProduceOneBandPerDepthNestedLeftToRight() {
        let document = MarkdownPreviewDocument.parse("> Outer\n>> Nested\n>>> Triple")
        let style = MarkdownPreviewStyle()
        let layout = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)

        // Every block in this source is quoted at depth >= its own level, and the deepest block
        // is quoted at every shallower depth too, so depths 1, 2, 3 each get exactly one band.
        let depths = layout.quoteDecorations.map(\.depth).sorted()
        XCTAssertEqual(depths, [1, 2, 3])

        let byDepth = Dictionary(uniqueKeysWithValues: layout.quoteDecorations.map { ($0.depth, $0) })
        guard let depth1 = byDepth[1], let depth2 = byDepth[2], let depth3 = byDepth[3] else {
            return XCTFail("Expected a band at each depth")
        }
        // Deeper quote levels indent further right.
        XCTAssertLessThan(depth1.band.minX, depth2.band.minX)
        XCTAssertLessThan(depth2.band.minX, depth3.band.minX)
    }

    func testQuoteDecorationsAreEmptyWithoutAnyBlockquote() {
        let document = MarkdownPreviewDocument.parse("A plain paragraph.")
        let layout = MarkdownPreviewLayout.layout(document: document, style: MarkdownPreviewStyle(), width: 400)
        XCTAssertTrue(layout.quoteDecorations.isEmpty)
    }

    func testQuotedBlockIndentsFurtherThanTopLevelContent() {
        let document = MarkdownPreviewDocument.parse("Top level\n\n> Quoted")
        let style = MarkdownPreviewStyle()
        let layout = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)

        let topLevel = layout.blockLayouts.first { $0.block.quoteDepth == 0 }
        let quoted = layout.blockLayouts.first { $0.block.quoteDepth == 1 }
        guard let topLevel, let quoted else {
            return XCTFail("Expected both a top-level and a quoted block")
        }
        XCTAssertLessThan(topLevel.frame.minX, quoted.frame.minX)
    }

    func testNestedListItemIndentsMoreThanTopLevelItem() {
        let document = MarkdownPreviewDocument.parse("- a\n  - b")
        let style = MarkdownPreviewStyle()
        let layout = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)

        guard let listLayout = layout.blockLayouts.first(where: {
            if case .list = $0.block.kind { return true }
            return false
        }), case .list(let list) = listLayout.block.kind else {
            return XCTFail("Expected a list block")
        }
        XCTAssertEqual(list.items.map(\.level), [0, 1])
        XCTAssertEqual(listLayout.markerFrames.count, 2)
        XCTAssertLessThan(listLayout.markerFrames[0].minX, listLayout.markerFrames[1].minX)
    }
}

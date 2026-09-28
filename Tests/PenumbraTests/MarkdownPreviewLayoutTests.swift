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

    // MARK: - Measure cache

    private func sections(_ count: Int, editing edited: Int? = nil) -> String {
        (0 ..< count).map { index in
            "## Heading \(index)\n\nParagraph \(index) with **bold** and `code`\(index == edited ? " (edited)" : "").\n\n- item \(index)\n- [x] done \(index)"
        }.joined(separator: "\n\n")
    }

    func testRelayoutAfterAnEditMeasuresOnlyTheChangedBlock() {
        let cache = MarkdownPreviewMeasureCache()
        let style = MarkdownPreviewStyle()
        let before = MarkdownPreviewLayout.layout(document: .parse(sections(10)), style: style, width: 400, cache: cache)
        XCTAssertEqual(cache.lastMissCount, before.blockLayouts.count)

        let after = MarkdownPreviewLayout.layout(document: .parse(sections(10, editing: 4)), style: style, width: 400, cache: cache)
        XCTAssertEqual(cache.lastMissCount, 1)
        XCTAssertTrue(before.blockLayouts[0].text === after.blockLayouts[0].text, "Unchanged blocks keep their typeset text")
    }

    func testIdenticalBlocksShareOneMeasurement() {
        let cache = MarkdownPreviewMeasureCache()
        _ = MarkdownPreviewLayout.layout(document: .parse("A\n\n> x\n\nA\n\nA"), style: MarkdownPreviewStyle(), width: 400, cache: cache)
        XCTAssertEqual(cache.lastMissCount, 2)
    }

    func testCachedLayoutMatchesAFreshLayout() {
        let cache = MarkdownPreviewMeasureCache()
        let style = MarkdownPreviewStyle()
        _ = MarkdownPreviewLayout.layout(document: .parse(sections(8)), style: style, width: 400, cache: cache)
        let document = MarkdownPreviewDocument.parse(sections(8, editing: 2) + "\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        let cached = MarkdownPreviewLayout.layout(document: document, style: style, width: 400, cache: cache)
        let fresh = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)
        XCTAssertEqual(cached, fresh)
    }

    func testStyleOrWidthChangeRemeasures() {
        let cache = MarkdownPreviewMeasureCache()
        let document = MarkdownPreviewDocument.parse(sections(3))
        var style = MarkdownPreviewStyle()
        _ = MarkdownPreviewLayout.layout(document: document, style: style, width: 400, cache: cache)
        _ = MarkdownPreviewLayout.layout(document: document, style: style, width: 300, cache: cache)
        XCTAssertEqual(cache.lastMissCount, document.blocks.count)
        style.bodyFont = .systemFont(ofSize: 20)
        _ = MarkdownPreviewLayout.layout(document: document, style: style, width: 300, cache: cache)
        XCTAssertEqual(cache.lastMissCount, document.blocks.count)
    }

    func testTypesetTextPaintsLikeTheUncachedPath() {
        let document = MarkdownPreviewDocument.parse(sections(2) + "\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nText[^1]\n\n[^1]: Note")
        let style = MarkdownPreviewStyle(bodyColor: .black, backgroundColor: .white)
        let typeset = MarkdownPreviewLayout.layout(document: document, style: style, width: 400)
        var plain = typeset
        for index in plain.blockLayouts.indices {
            plain.blockLayouts[index].text = nil
        }
        XCTAssertEqual(render(typeset, style: style), render(plain, style: style))
    }

    private func render(_ layout: MarkdownPreviewLayout, style: MarkdownPreviewStyle) -> Data {
        let width = Int(layout.contentSize.width)
        let height = Int(layout.contentSize.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        MarkdownPreviewCGRenderer.draw(layout: layout, style: style, rasterImages: [:], in: context,
                                       bounds: CGRect(origin: .zero, size: layout.contentSize))
        return Data(bytes: context.data!, count: width * height * 4)
    }
}

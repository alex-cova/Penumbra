import AppKit
import CoreText
import XCTest
@testable import Runestone

@MainActor
final class MetalDecorationTests: XCTestCase {
    private let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
    private var nextRevision: UInt64 = 1

    // MARK: - Highlights

    func testStandardHighlightSpansCTLineOffsets() throws {
        let atlas = try makeAtlas()
        let line = makeLine("hello world")
        let highlight = HighlightedRangeFragment(
            range: NSRange(location: 2, length: 3),
            containsStart: true,
            containsEnd: true,
            color: .systemYellow,
            cornerRadius: 4,
            style: .standard
        )
        let spec = makeSpec(line: line, frame: CGRect(x: 100, y: 40, width: 320, height: 18), highlighted: [highlight])
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 2, budget: &budget)

        XCTAssertEqual(geometry.underlaySolids.count, 1)
        let solid = try XCTUnwrap(geometry.underlaySolids.first)
        let expectedStart = 100 + CTLineGetOffsetForStringIndex(line, 2, nil)
        let expectedEnd = 100 + CTLineGetOffsetForStringIndex(line, 5, nil)
        XCTAssertEqual(Double(solid.origin.x), Double(expectedStart), accuracy: 0.01)
        XCTAssertEqual(Double(solid.origin.y), 40, accuracy: 0.01)
        XCTAssertEqual(Double(solid.size.x), Double(expectedEnd - expectedStart), accuracy: 0.01)
        XCTAssertEqual(Double(solid.size.y), 18, accuracy: 0.01)
        XCTAssertEqual(solid.roundedCornersMask, SolidInstance.allCornersMask)
        XCTAssertGreaterThan(solid.fillColor.w, 0)
        XCTAssertEqual(solid.strokeWidth, 0)
    }

    func testStandardHighlightExtendsToCanvasEdgeAtLineEnd() throws {
        let atlas = try makeAtlas()
        let line = makeLine("abc")
        let highlight = HighlightedRangeFragment(
            range: NSRange(location: 1, length: 2),
            containsStart: false,
            containsEnd: true,
            color: .systemYellow,
            cornerRadius: 4,
            style: .standard
        )
        var decorations = decorations(highlighted: [highlight])
        decorations.fragmentRangeUpperBound = 3
        decorations.endsWithLineBreak = true
        let spec = makeSpec(line: line, frame: CGRect(x: 0, y: 0, width: 500, height: 18), decorations: decorations)
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 1, budget: &budget)

        let solid = try XCTUnwrap(geometry.underlaySolids.first)
        let start = CTLineGetOffsetForStringIndex(line, 1, nil)
        XCTAssertEqual(Double(solid.origin.x + solid.size.x), 500, accuracy: 0.01, "highlight should reach the canvas edge")
        XCTAssertEqual(Double(solid.origin.x), Double(start), accuracy: 0.01)
    }

    func testUnderlineHighlightSitsAtBottomAcrossOffsets() throws {
        let atlas = try makeAtlas()
        let line = makeLine("underline me")
        let highlight = HighlightedRangeFragment(
            range: NSRange(location: 0, length: 9),
            containsStart: true,
            containsEnd: true,
            color: .systemBlue,
            cornerRadius: 0,
            style: .underline(color: .systemBlue)
        )
        let spec = makeSpec(line: line, frame: CGRect(x: 10, y: 0, width: 300, height: 20), highlighted: [highlight])
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 1, budget: &budget)

        let solid = try XCTUnwrap(geometry.underlaySolids.first)
        let start = 10 + CTLineGetOffsetForStringIndex(line, 0, nil)
        let end = 10 + CTLineGetOffsetForStringIndex(line, 9, nil)
        XCTAssertEqual(Double(solid.origin.x), Double(start), accuracy: 0.01)
        XCTAssertEqual(Double(solid.size.x), Double(end - start), accuracy: 0.01)
        XCTAssertEqual(Double(solid.size.y), Double(MetalDecorationBuilder.squiggleLineWidth), accuracy: 0.01)
        // Bottom-aligned: within a couple of points of the fragment's bottom edge.
        XCTAssertLessThan(abs(Double(solid.origin.y + solid.size.y) - 18), 2.0)
    }

    func testSquiggleHighlightEmitsRibbonWithinRange() throws {
        let atlas = try makeAtlas()
        let line = makeLine("squiggle")
        let highlight = HighlightedRangeFragment(
            range: NSRange(location: 0, length: 8),
            containsStart: true,
            containsEnd: true,
            color: .systemRed,
            cornerRadius: 0,
            style: .squiggle(color: .systemRed)
        )
        let spec = makeSpec(line: line, frame: CGRect(x: 5, y: 0, width: 200, height: 18), highlighted: [highlight])
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 1, budget: &budget)

        XCTAssertTrue(geometry.underlaySolids.isEmpty, "squiggles are triangles, not solids")
        XCTAssertFalse(geometry.underlayTriangles.isEmpty)
        XCTAssertEqual(geometry.underlayTriangles.count % 3, 0, "triangle list")
        let startX = 5 + CTLineGetOffsetForStringIndex(line, 0, nil)
        let endX = 5 + CTLineGetOffsetForStringIndex(line, 8, nil)
        let xs = geometry.underlayTriangles.map { CGFloat($0.position.x) }
        XCTAssertGreaterThanOrEqual(xs.min() ?? 0, startX - 1)
        XCTAssertLessThanOrEqual(xs.max() ?? 0, endX + 1)
    }

    func testOutlineHighlightProducesStrokeAndOptionalFill() throws {
        let atlas = try makeAtlas()
        let line = makeLine("outline")
        func geometry(fill: Bool) -> SolidInstance {
            let highlight = HighlightedRangeFragment(
                range: NSRange(location: 0, length: 7),
                containsStart: true,
                containsEnd: true,
                color: .systemGreen,
                cornerRadius: 2.5,
                style: .outline(color: .systemGreen, fill: fill)
            )
            let spec = makeSpec(line: line, frame: CGRect(x: 0, y: 0, width: 200, height: 18), highlighted: [highlight])
            var budget = GlyphRasterBudget()
            return MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 1, budget: &budget).underlaySolids[0]
        }
        let filled = geometry(fill: true)
        let stroked = geometry(fill: false)
        XCTAssertEqual(filled.strokeWidth, 0.5)
        XCTAssertGreaterThan(filled.strokeColor.w, 0)
        XCTAssertGreaterThan(filled.fillColor.w, 0)
        XCTAssertEqual(stroked.fillColor.w, 0, "no fill when fill: false")
        XCTAssertGreaterThan(stroked.strokeColor.w, 0)
    }

    // MARK: - Marked text

    func testMarkedRangeFillMatchesOffsets() throws {
        let atlas = try makeAtlas()
        let line = makeLine("marked text")
        var decorations = decorations()
        decorations.markedRange = NSRange(location: 0, length: 6)
        decorations.markedColor = .systemPurple
        decorations.markedRadius = 3
        let spec = makeSpec(line: line, frame: CGRect(x: 12, y: 4, width: 200, height: 18), decorations: decorations)
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 1, budget: &budget)

        let solid = try XCTUnwrap(geometry.underlaySolids.first)
        let start = 12 + CTLineGetOffsetForStringIndex(line, 0, nil)
        let end = 12 + CTLineGetOffsetForStringIndex(line, 6, nil)
        XCTAssertEqual(Double(solid.origin.x), Double(start), accuracy: 0.01)
        XCTAssertEqual(Double(solid.size.x), Double(end - start), accuracy: 0.01)
        XCTAssertEqual(solid.cornerRadius, 3)
    }

    // MARK: - Fold placeholder

    func testFoldPlaceholderChipUsesSystem11MediumNotThemeFont() throws {
        let atlas = try makeAtlas()
        let line = makeLine("collapsed")
        var decorations = decorations()
        decorations.foldPlaceholder = "\u{22EF}"
        let bigFont = CTFontCreateWithName("Menlo" as CFString, 48, nil)
        let spec = makeSpec(
            line: line,
            frame: CGRect(x: 0, y: 0, width: 400, height: 60),
            decorations: decorations,
            fallbackFont: bigFont
        )
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 2, budget: &budget)

        XCTAssertFalse(geometry.overlaySolids.isEmpty, "fold chip background")
        XCTAssertFalse(geometry.overlayGlyphs.isEmpty, "fold placeholder text")
        // The glyph must be sized from the 11 pt medium system font, not the 48 pt theme font.
        let tallestGlyph = geometry.overlayGlyphs.map { CGFloat($0.size.y) }.max() ?? 0
        XCTAssertLessThan(tallestGlyph, 24, "fold text should be ~11 pt, not 48 pt")
        // Chip starts after the typeset content.
        let endOfLineX = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let chip = try XCTUnwrap(geometry.overlaySolids.first)
        XCTAssertGreaterThanOrEqual(Double(chip.origin.x), Double(endOfLineX))
    }

    // MARK: - Invisible characters

    func testInvisibleTabSymbolEmittedForResolvedLayout() throws {
        let atlas = try makeAtlas()
        let string = "a\tb"
        let line = makeLine(string)
        let configuration = InvisibleCharacterConfiguration()
        configuration.showTabs = true
        configuration.font = NSFont.systemFont(ofSize: 12)
        let fragment = LineFragment(
            id: LineFragmentID(lineId: "l", lineFragmentIndex: 0),
            index: 0,
            visibleRange: NSRange(location: 0, length: (string as NSString).length),
            line: line,
            descent: 3,
            baseSize: CGSize(width: 40, height: 16),
            scaledSize: CGSize(width: 40, height: 18),
            yPosition: 0
        )
        let layout = InvisibleCharacterLayout.resolve(fragmentString: string, lineFragment: fragment, configuration: configuration)
        XCTAssertEqual(layout.symbols.count, 1)
        let mark = try XCTUnwrap(layout.symbols.first)
        XCTAssertEqual(mark.string, configuration.tabSymbol)
        XCTAssertEqual(Double(mark.x), Double(CTLineGetOffsetForStringIndex(line, 1, nil)), accuracy: 0.01)

        var decorations = decorations()
        decorations.invisibles = layout
        let spec = makeSpec(line: line, frame: CGRect(x: 0, y: 0, width: 200, height: 18), decorations: decorations)
        var budget = GlyphRasterBudget()
        let geometry = MetalDecorationBuilder.build(spec: spec, atlas: atlas, scale: 2, budget: &budget)
        XCTAssertFalse(geometry.symbolGlyphs.isEmpty, "the tab symbol should rasterize into the atlas")
    }

    func testInvisibleLayoutIsEmptyWhenFeatureOff() {
        let line = makeLine("plain text")
        let configuration = InvisibleCharacterConfiguration()
        let fragment = LineFragment(
            id: LineFragmentID(lineId: "l", lineFragmentIndex: 0),
            index: 0,
            visibleRange: NSRange(location: 0, length: 10),
            line: line,
            descent: 3,
            baseSize: CGSize(width: 60, height: 16),
            scaledSize: CGSize(width: 60, height: 18),
            yPosition: 0
        )
        let layout = InvisibleCharacterLayout.resolve(fragmentString: "plain text", lineFragment: fragment, configuration: configuration)
        XCTAssertTrue(layout.isEmpty)
    }
}

private extension MetalDecorationTests {
    func makeLine(_ string: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    }

    func decorations(highlighted: [HighlightedRangeFragment] = []) -> LineFragmentDecorations {
        LineFragmentDecorations(
            highlighted: highlighted,
            markedRange: nil,
            markedColor: .windowBackgroundColor,
            markedRadius: 0,
            unfocusedAlpha: 1,
            focusedRanges: [],
            foldPlaceholder: nil
        )
    }

    func makeSpec(
        line: CTLine,
        frame: CGRect,
        highlighted: [HighlightedRangeFragment] = [],
        decorations: LineFragmentDecorations? = nil,
        fallbackFont: CTFont? = nil
    ) -> LineFragmentPaintSpec {
        defer { nextRevision += 1 }
        return LineFragmentPaintSpec(
            id: LineFragmentID(lineId: "line", lineFragmentIndex: 0),
            lineID: DocumentLineNodeID(value: 1),
            frame: frame,
            line: line,
            descent: 3,
            baseSize: CGSize(width: frame.width, height: frame.height - 2),
            scaledSize: CGSize(width: frame.width, height: frame.height),
            decorations: decorations ?? self.decorations(highlighted: highlighted),
            fallbackFont: fallbackFont ?? font,
            fallbackColor: .labelColor,
            appearance: nil,
            lineRevision: nextRevision
        )
    }

    func makeAtlas() throws -> GlyphAtlas {
        guard MetalContext.isAvailable,
              let device = MetalContext.shared.device,
              let queue = MetalContext.shared.commandQueue else {
            throw XCTSkip("Metal is not available")
        }
        return GlyphAtlas(device: device, commandQueue: queue, hasUnifiedMemory: device.hasUnifiedMemory)
    }
}

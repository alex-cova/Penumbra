import AppKit
import CoreText
import Metal
import XCTest
@testable import Runestone

@MainActor
final class GlyphRunExtractorTests: XCTestCase {
    func testASCIIGlyphCountAndPositionsMatchCTLineOffsets() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let string = "Hello"
        let line = makeLine(string, font: font)
        let metrics = lineMetrics(line)
        let gutter: CGFloat = 24
        let frame = CGRect(x: gutter, y: 10, width: metrics.base.width, height: metrics.scaled.height)
        let result = extract(
            line: line,
            font: font,
            atlas: atlas,
            fragmentFrame: frame,
            metrics: metrics
        )
        XCTAssertEqual(result.glyphs.count, string.utf16.count)
        let firstIndex = try XCTUnwrap(result.glyphs.first?.stringIndex)
        let lastIndex = try XCTUnwrap(result.glyphs.last?.stringIndex)
        let firstOffset = CTLineGetOffsetForStringIndex(line, 0, nil)
        let lastOffset = CTLineGetOffsetForStringIndex(line, string.utf16.count - 1, nil)
        XCTAssertEqual(firstIndex, 0)
        XCTAssertEqual(lastIndex, string.utf16.count - 1)
        XCTAssertEqual(result.glyphs[0].contentOrigin.x, gutter + firstOffset, accuracy: 0.05)
        XCTAssertEqual(result.glyphs[result.glyphs.count - 1].contentOrigin.x, gutter + lastOffset, accuracy: 0.05)
    }

    func testBaselineYMatchesCaretVerticalCentering() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let line = makeLine("Ag", font: font)
        var metrics = lineMetrics(line)
        metrics.scaled = CGSize(width: metrics.base.width, height: metrics.base.height * 1.5)
        let expected = (metrics.scaled.height + metrics.base.height) / 2 - metrics.descent
        let paddingTop = (metrics.scaled.height - metrics.base.height) / 2
        XCTAssertEqual(expected, paddingTop + metrics.base.height - metrics.descent, accuracy: 0.0001)
        let result = extract(line: line, font: font, atlas: atlas, metrics: metrics)
        XCTAssertEqual(result.baselineY, expected, accuracy: 0.0001)
        XCTAssertEqual(
            GlyphRunExtractor.baselineY(baseSize: metrics.base, scaledSize: metrics.scaled, descent: metrics.descent),
            paddingTop + metrics.base.height - metrics.descent,
            accuracy: 0.0001
        )
    }

    func testHoeflerLigatureCollapsesFi() throws {
        guard let nsFont = NSFont(name: "HoeflerText-Regular", size: 24) else {
            throw XCTSkip("Hoefler Text is not available")
        }
        let atlas = try makeAtlas()
        let font = nsFont as CTFont
        let ligatured = makeLine("fi", font: font, extra: [kCTLigatureAttributeName as NSAttributedString.Key: 2])
        let disabled = makeLine("fi", font: font, extra: [kCTLigatureAttributeName as NSAttributedString.Key: 0])
        let ligaturedResult = extract(line: ligatured, font: font, atlas: atlas, metrics: lineMetrics(ligatured))
        let disabledResult = extract(line: disabled, font: font, atlas: atlas, metrics: lineMetrics(disabled))
        XCTAssertEqual(ctGlyphCount(ligatured), 1)
        XCTAssertEqual(ligaturedResult.glyphs.count, 1)
        XCTAssertEqual(disabledResult.glyphs.count, 2)
    }

    func testCombiningMarkProducesMultipleGlyphs() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let preferred = "e\u{0301}"
        let preferredLine = makeLine(preferred, font: font)
        let preferredResult = extract(
            line: preferredLine,
            font: font,
            atlas: atlas,
            metrics: lineMetrics(preferredLine)
        )
        XCTAssertEqual(preferredResult.glyphs.count, ctGlyphCount(preferredLine))
        if preferredResult.glyphs.count >= 2 {
            return
        }
        // Core Text composes U+0065 U+0301 for Menlo; stacked marks still produce multiple glyphs.
        let stacked = "e\u{0327}\u{0301}"
        let stackedLine = makeLine(stacked, font: font)
        guard ctGlyphCount(stackedLine) >= 2 else {
            throw XCTSkip("No combining-mark sequence produced multiple glyphs")
        }
        let stackedResult = extract(
            line: stackedLine,
            font: font,
            atlas: atlas,
            metrics: lineMetrics(stackedLine)
        )
        XCTAssertGreaterThanOrEqual(stackedResult.glyphs.count, 2)
    }

    func testEmojiZWJUsesAppleColorEmoji() throws {
        let font = try makeAppleColorEmojiFont(pointSize: 32)
        let atlas = try makeAtlas()
        let string = "👨‍👩‍👧‍👦"
        let line = makeLine(string, font: font)
        XCTAssertGreaterThan(ctGlyphCount(line), 0, "Apple Color Emoji must shape the ZWJ sequence")
        let result = extract(line: line, font: font, atlas: atlas, metrics: lineMetrics(line), scale: 1)
        XCTAssertFalse(result.glyphs.isEmpty)
        XCTAssertTrue(result.glyphs.allSatisfy(\.isColor))
        XCTAssertTrue(result.skips.isEmpty)
    }

    func testItalicSymbolicTraitsUsesMenloItalicFace() throws {
        let atlas = try makeAtlas()
        let regular = makeMenlo(pointSize: 16)
        let italicDescriptor = (regular as NSFont).fontDescriptor.withSymbolicTraits(.italic)
        guard let italicFont = NSFont(descriptor: italicDescriptor, size: 16) else {
            throw XCTSkip("Menlo italic face is not available")
        }
        let italicName = CTFontCopyPostScriptName(italicFont as CTFont) as String
        guard italicName == "Menlo-Italic" else {
            throw XCTSkip("withSymbolicTraits did not select Menlo-Italic (got \(italicName))")
        }
        XCTAssertEqual(CTFontGetMatrix(italicFont as CTFont).c, 0, accuracy: 0.0001)
        let regularLine = makeLine("A", font: regular)
        let italicLine = makeLine("A", font: italicFont as CTFont)
        let regularResult = extract(line: regularLine, font: regular, atlas: atlas, metrics: lineMetrics(regularLine))
        let italicResult = extract(
            line: italicLine,
            font: italicFont as CTFont,
            atlas: atlas,
            metrics: lineMetrics(italicLine)
        )
        let regularGlyph = try XCTUnwrap(regularResult.glyphs.first)
        let italicGlyph = try XCTUnwrap(italicResult.glyphs.first)
        let regularKey = GlyphKey.make(font: regular, glyph: regularGlyph.glyph, scale: 2, isColor: false)
        let italicKey = GlyphKey.make(font: italicFont as CTFont, glyph: italicGlyph.glyph, scale: 2, isColor: false)
        XCTAssertNotEqual(regularKey.fontID, italicKey.fontID)
        XCTAssertNotEqual(regularKey, italicKey)
    }

    func testShearedFontQuadWidthIsShearNotShearSquared() throws {
        let atlas = try makeAtlas()
        let regular = makeMenlo(pointSize: 16)
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        let sheared = CTFontCreateCopyWithAttributes(regular, 0, &shear, nil)
        let regularLine = makeLine("A", font: regular)
        let shearedLine = makeLine("A", font: sheared)
        let regularResult = extract(line: regularLine, font: regular, atlas: atlas, metrics: lineMetrics(regularLine))
        let shearedResult = extract(line: shearedLine, font: sheared, atlas: atlas, metrics: lineMetrics(shearedLine))
        let regularGlyph = try XCTUnwrap(regularResult.glyphs.first)
        let shearedGlyph = try XCTUnwrap(shearedResult.glyphs.first)
        let regularKey = GlyphKey.make(font: regular, glyph: regularGlyph.glyph, scale: 2, isColor: false)
        let shearedKey = GlyphKey.make(font: sheared, glyph: shearedGlyph.glyph, scale: 2, isColor: false)
        XCTAssertNotEqual(regularKey.matrixHash, shearedKey.matrixHash)

        var glyph = shearedGlyph.glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(sheared, .default, &glyph, &bounds, 1)
        let fontMatrix = CTFontGetMatrix(sheared)
        let doubleSheared = bounds.applying(fontMatrix)
        let scale: CGFloat = 2
        let pad = CGFloat(GlyphRasterizer.padPixels) / scale
        let singleWidth = bounds.width + 2 * pad
        let doubleWidth = doubleSheared.width + 2 * pad
        XCTAssertGreaterThan(doubleWidth - singleWidth, 1, "Shear² extra width must be distinguishable")
        XCTAssertEqual(CGFloat(shearedGlyph.instance.size.x), singleWidth, accuracy: 1.0)
        XCTAssertLessThan(
            abs(CGFloat(shearedGlyph.instance.size.x) - singleWidth),
            abs(CGFloat(shearedGlyph.instance.size.x) - doubleWidth)
        )
    }

    func testVerticalFormsRunMatrixIsAppliedOnce() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let line = makeLine(
            "A",
            font: font,
            extra: [kCTVerticalFormsAttributeName as NSAttributedString.Key: true]
        )
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else {
            throw XCTSkip("kCTVerticalFormsAttributeName produced no CTRun")
        }
        let runMatrix = CTRunGetTextMatrix(run)
        let rawAttributes = CTRunGetAttributes(run) as NSDictionary
        guard rawAttributes[kCTFontAttributeName] != nil else {
            throw XCTSkip("Vertical-forms run has no font")
        }
        let runFont = rawAttributes[kCTFontAttributeName] as! CTFont
        let fontMatrix = CTFontGetMatrix(runFont)
        guard !runMatrix.isIdentity, !affineEqual(runMatrix, fontMatrix) else {
            throw XCTSkip("kCTVerticalFormsAttributeName did not produce a non-identity extra run matrix")
        }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(runFont, .default, &glyph, &bounds, 1)
        let extra = runMatrix.concatenating(fontMatrix.inverted())
        let single = bounds.applying(extra)
        let doubled = single.applying(extra)
        let result = extract(line: line, font: runFont, atlas: atlas, metrics: lineMetrics(line))
        let extracted = try XCTUnwrap(result.glyphs.first)
        let scale: CGFloat = 2
        let pad = CGFloat(GlyphRasterizer.padPixels) / scale
        XCTAssertEqual(extracted.matrixHash, GlyphKey.matrixHash(fontMatrix: fontMatrix, runMatrix: extra))
        XCTAssertEqual(CGFloat(extracted.instance.size.x), single.width + 2 * pad, accuracy: 1.5)
        XCTAssertLessThan(
            abs(CGFloat(extracted.instance.size.x) - (single.width + 2 * pad)),
            abs(CGFloat(extracted.instance.size.x) - (doubled.width + 2 * pad))
        )
        let key = GlyphKey.make(
            font: runFont,
            glyph: extracted.glyph,
            scale: scale,
            runMatrix: extra,
            isColor: false
        )
        guard let slot = atlas.cached(key), let pixels = atlas.copyPixels(from: slot) else {
            XCTFail("Vertical-forms glyph must be in the atlas")
            return
        }
        XCTAssertTrue(pixels.contains { $0 > 0 }, "Rotated glyph ink must land inside the tile")
    }

    func testWrappingOffLongLineRebuildsInstancesWhenEmitRectMoves() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let string = String(repeating: "A", count: 200)
        let line = makeLine(string, font: font)
        let metrics = lineMetrics(line)
        let frame = CGRect(x: 24, y: 0, width: metrics.base.width, height: metrics.scaled.height)
        let canvasA = CGRect(x: 0, y: 0, width: 180, height: 40)
        let canvasB = CGRect(x: 400, y: 0, width: 180, height: 40)
        let first = extract(
            line: line,
            font: font,
            atlas: atlas,
            fragmentFrame: frame,
            metrics: metrics,
            emitRect: MetalProjection.emitRect(canvasFrame: canvasA),
            atlasWarmRect: .null
        )
        let second = extract(
            line: line,
            font: font,
            atlas: atlas,
            fragmentFrame: frame,
            metrics: metrics,
            emitRect: MetalProjection.emitRect(canvasFrame: canvasB),
            atlasWarmRect: .null
        )
        XCTAssertFalse(first.glyphs.isEmpty)
        XCTAssertFalse(second.glyphs.isEmpty)
        let keyA = GlyphExtractCacheKey(revision: 1, emitRect: MetalProjection.emitRect(canvasFrame: canvasA))
        let keyB = GlyphExtractCacheKey(revision: 1, emitRect: MetalProjection.emitRect(canvasFrame: canvasB))
        XCTAssertEqual(keyA.revision, keyB.revision)
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertTrue(GlyphExtractCacheKey.shouldRebuild(previous: keyA, revision: 1, emitRect: keyB.emitRect))
        let firstOrigins = first.instances.map(\.origin.x)
        let secondOrigins = second.instances.map(\.origin.x)
        XCTAssertNotEqual(firstOrigins, secondOrigins)
    }

    func testShadowRunFallsBackToOneRunTile() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 2
        let line = makeLine("Hi", font: font, extra: [.shadow: shadow])
        let result = extract(line: line, font: font, atlas: atlas, metrics: lineMetrics(line))
        XCTAssertTrue(result.skips.isEmpty, "the shadow run should be rasterized, not dropped")
        XCTAssertEqual(result.glyphs.count, 1, "one BGRA tile for the whole run")
        let fallback = try XCTUnwrap(result.glyphs.first)
        XCTAssertTrue(fallback.isColor)
        XCTAssertEqual(fallback.instance.color, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertGreaterThan(fallback.instance.size.x, 0)
        XCTAssertEqual(atlas.colorPageCount, 1, "tile lands on a BGRA color page")
    }

    func testShadowRunFallbackTileIsCachedByKey() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        let line = makeLine("cache", font: font, extra: [.shadow: shadow])
        let metrics = lineMetrics(line)
        _ = extract(line: line, font: font, atlas: atlas, metrics: metrics)
        let missesAfterFirst = atlas.missCount
        let second = extract(line: line, font: font, atlas: atlas, metrics: metrics)
        XCTAssertEqual(second.glyphs.count, 1)
        XCTAssertEqual(atlas.missCount, missesAfterFirst, "second extract must reuse the cached run tile")
    }

    func testOversizeGlyphFallsBackToRunTile() throws {
        let atlas = try makeAtlas()
        // 400 pt glyphs exceed the 256 px per-glyph cap even at 1x.
        let font = makeMenlo(pointSize: 400)
        let line = makeLine("W", font: font)
        let result = extract(line: line, font: font, atlas: atlas, metrics: lineMetrics(line), scale: 1)
        XCTAssertTrue(result.skips.isEmpty)
        XCTAssertEqual(result.glyphs.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.glyphs.first).isColor)
    }

    func testShadowRunFallbackRespectsPerFrameRasterCap() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1
        let line = makeLine("x", font: font, extra: [.shadow: shadow])
        var exhausted = GlyphRasterBudget(limit: 0)
        let request = GlyphExtractRequest(
            line: line,
            fragmentFrame: CGRect(origin: .zero, size: lineMetrics(line).scaled),
            descent: lineMetrics(line).descent,
            baseSize: lineMetrics(line).base,
            scaledSize: lineMetrics(line).scaled,
            unfocusedAlpha: 1,
            focusedRanges: [],
            scale: 2,
            emitRect: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000),
            atlasWarmRect: .infinite,
            fallbackFont: font,
            fallbackColor: .white,
            appearance: nil
        )
        let result = GlyphRunExtractor.extract(request, atlas: atlas, budget: &exhausted)
        XCTAssertTrue(result.glyphs.isEmpty)
        XCTAssertEqual(result.skips.map(\.reason), [.rasterCap])
    }

    func testFocusAlphaDimsUnfocusedGlyphs() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let line = makeLine("AB", font: font, extra: [.foregroundColor: NSColor.white])
        let metrics = lineMetrics(line)
        let result = extract(
            line: line,
            font: font,
            atlas: atlas,
            metrics: metrics,
            unfocusedAlpha: 0.5,
            focusedRanges: [NSRange(location: 0, length: 1)]
        )
        XCTAssertEqual(result.glyphs.count, 2)
        let focused = result.glyphs[0].instance.color
        let dimmed = result.glyphs[1].instance.color
        XCTAssertEqual(focused.w, 1, accuracy: 0.01)
        XCTAssertEqual(dimmed.w, 0.5, accuracy: 0.01)
        XCTAssertEqual(dimmed.x, focused.x * 0.5, accuracy: 0.01)
    }

    func testInstanceBufferGrowsByDoublingAndCompacts() throws {
        let (device, _) = try requireMetalDevice()
        let buffer = try XCTUnwrap(GlyphInstanceBuffer(device: device), "Shared instance buffer must allocate")
        XCTAssertEqual(buffer.capacity, GlyphInstanceBuffer.minimumCapacity)
        XCTAssertEqual(GlyphInstanceBuffer.minimumCapacity, 16_384)
        XCTAssertEqual(GlyphInstanceBuffer.maximumCapacity, 131_072)

        let dummy = GlyphInstance(
            origin: SIMD2(1, 2),
            size: SIMD2(3, 4),
            uvOrigin: .zero,
            uvSize: SIMD2(1, 1),
            color: SIMD4(1, 1, 1, 1),
            atlasPage: 1
        )
        buffer.write(Array(repeating: dummy, count: 20_000))
        XCTAssertEqual(buffer.capacity, 32_768)
        XCTAssertEqual(buffer.count, 20_000)
        XCTAssertEqual(buffer.primaryCount, 20_000)
        XCTAssertEqual(buffer.instances.count, 20_000)

        buffer.write(Array(repeating: dummy, count: 40_000))
        XCTAssertEqual(buffer.capacity, 65_536)
        XCTAssertEqual(buffer.count, 40_000)
        XCTAssertEqual(buffer.primaryCount, 40_000)

        buffer.write(Array(repeating: dummy, count: 70_000))
        XCTAssertEqual(buffer.capacity, 131_072)
        XCTAssertEqual(buffer.primaryCount, 70_000)

        buffer.write(Array(repeating: dummy, count: GlyphInstanceBuffer.maximumCapacity + 1))
        XCTAssertEqual(buffer.capacity, GlyphInstanceBuffer.maximumCapacity)
        XCTAssertEqual(buffer.instances.count, GlyphInstanceBuffer.maximumCapacity + 1)
        XCTAssertEqual(buffer.count, GlyphInstanceBuffer.maximumCapacity + 1)
        XCTAssertEqual(buffer.primaryCount, GlyphInstanceBuffer.maximumCapacity)
        XCTAssertLessThan(buffer.primaryCount, buffer.count)
        XCTAssertEqual(buffer.overflowBuffers.count, 1)
        let overflowCount = buffer.overflowBuffers[0].length / MemoryLayout<GlyphInstance>.stride
        XCTAssertEqual(overflowCount, 1)
        XCTAssertEqual(buffer.primaryCount + overflowCount, buffer.count)

        buffer.compact()
        XCTAssertEqual(buffer.capacity, GlyphInstanceBuffer.minimumCapacity)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.primaryCount, 0)
        XCTAssertTrue(buffer.instances.isEmpty)
        XCTAssertTrue(buffer.overflowBuffers.isEmpty)
    }

    func testWarmBandDoesNotEmitAndEmitMissesTakeRasterBudgetFirst() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let string = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let line = makeLine(string, font: font)
        let metrics = lineMetrics(line)
        let frame = CGRect(x: 0, y: 0, width: metrics.base.width, height: metrics.scaled.height)
        let cut = CTLineGetOffsetForStringIndex(line, 3, nil)
        let emitRect = CGRect(x: -4, y: -20, width: cut, height: metrics.scaled.height + 40)
        let warmRect = CGRect(x: -4, y: -20, width: metrics.base.width + 8, height: metrics.scaled.height + 40)
        var budget = GlyphRasterBudget(limit: 8)
        let request = GlyphExtractRequest(
            line: line,
            fragmentFrame: frame,
            descent: metrics.descent,
            baseSize: metrics.base,
            scaledSize: metrics.scaled,
            unfocusedAlpha: 1,
            focusedRanges: [],
            scale: 2,
            emitRect: emitRect,
            atlasWarmRect: warmRect,
            fallbackFont: font,
            fallbackColor: .white,
            appearance: nil
        )
        let result = GlyphRunExtractor.extract(request, atlas: atlas, budget: &budget)
        XCTAssertFalse(result.glyphs.isEmpty)
        XCTAssertGreaterThan(result.warmedGlyphCount, 0)
        XCTAssertEqual(budget.remaining, 0)
        for glyph in result.glyphs {
            let quad = CGRect(
                x: CGFloat(glyph.instance.origin.x),
                y: CGFloat(glyph.instance.origin.y),
                width: CGFloat(glyph.instance.size.x),
                height: CGFloat(glyph.instance.size.y)
            )
            XCTAssertTrue(quad.intersects(emitRect), "emitted quad must intersect emitRect")
        }
        XCTAssertLessThan(result.glyphs.count, ctGlyphCount(line))
    }
}

private extension GlyphRunExtractorTests {
    struct LineMetrics {
        var descent: CGFloat
        var base: CGSize
        var scaled: CGSize
    }

    func makeMenlo(pointSize: CGFloat) -> CTFont {
        CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
    }

    func makeAppleColorEmojiFont(pointSize: CGFloat) throws -> CTFont {
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, pointSize, nil)
        let postScriptName = CTFontCopyPostScriptName(font) as String
        if postScriptName != "AppleColorEmoji" {
            XCTFail("Apple Color Emoji is missing (got \(postScriptName))")
            struct AppleColorEmojiMissing: Error {}
            throw AppleColorEmojiMissing()
        }
        return font
    }

    func requireMetalDevice() throws -> (MTLDevice, MTLCommandQueue) {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        guard let device = MetalContext.shared.device, let queue = MetalContext.shared.commandQueue else {
            XCTFail("MetalContext.isAvailable is true but device or command queue is nil")
            throw XCTSkip("Metal is not available")
        }
        return (device, queue)
    }

    func makeAtlas() throws -> GlyphAtlas {
        let (device, queue) = try requireMetalDevice()
        return GlyphAtlas(
            device: device,
            commandQueue: queue,
            hasUnifiedMemory: device.hasUnifiedMemory
        )
    }

    func makeLine(_ string: String, font: CTFont, extra: [NSAttributedString.Key: Any] = [:]) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        for (key, value) in extra {
            attributes[key] = value
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    func lineMetrics(_ line: CTLine, multiplier: CGFloat = 1) -> LineMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent + leading
        let base = CGSize(width: width, height: height)
        return LineMetrics(descent: descent, base: base, scaled: CGSize(width: width, height: height * multiplier))
    }

    func affineEqual(_ lhs: CGAffineTransform, _ rhs: CGAffineTransform) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.tx == rhs.tx && lhs.ty == rhs.ty
    }

    func ctGlyphCount(_ line: CTLine) -> Int {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
            return 0
        }
        return runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }
    }

    func extract(
        line: CTLine,
        font: CTFont,
        atlas: GlyphAtlas,
        fragmentFrame: CGRect? = nil,
        metrics: LineMetrics,
        scale: CGFloat = 2,
        emitRect: CGRect? = nil,
        atlasWarmRect: CGRect = .infinite,
        unfocusedAlpha: CGFloat = 1,
        focusedRanges: [NSRange] = []
    ) -> GlyphExtractResult {
        let frame = fragmentFrame ?? CGRect(origin: .zero, size: metrics.scaled)
        let request = GlyphExtractRequest(
            line: line,
            fragmentFrame: frame,
            descent: metrics.descent,
            baseSize: metrics.base,
            scaledSize: metrics.scaled,
            unfocusedAlpha: unfocusedAlpha,
            focusedRanges: focusedRanges,
            scale: scale,
            emitRect: emitRect ?? CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000),
            atlasWarmRect: atlasWarmRect,
            fallbackFont: font,
            fallbackColor: .white,
            appearance: nil
        )
        return GlyphRunExtractor.extract(request, atlas: atlas)
    }
}

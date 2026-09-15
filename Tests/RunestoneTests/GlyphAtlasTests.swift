import CoreText
import Metal
import XCTest
@testable import Runestone

final class GlyphAtlasTests: XCTestCase {
    func testDefaultBudgetAndCaps() {
        XCTAssertEqual(GlyphAtlas.lruBudgetBytes, 32 * 1024 * 1024)
        XCTAssertEqual(GlyphAtlas.maxGlyphExtentPixels, 256)
        XCTAssertEqual(GlyphAtlas.coveragePageSize, 2048)
        XCTAssertEqual(GlyphAtlas.colorPageSize, 1024)
        XCTAssertEqual(GlyphRasterizer.padPixels, 2)
        XCTAssertEqual(GlyphRasterizer.maxGlyphExtentPixels, 256)
    }

    func testPixelSizeFormula() throws {
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        let key = GlyphKey.make(font: font, glyph: glyph, scale: 2, isColor: false)
        XCTAssertEqual(key.pixelSize, UInt16((16.0 * 2.0 * 64.0).rounded()))
        XCTAssertEqual(key.scale, 2)
        XCTAssertEqual(key.subpixel, 0)
        XCTAssertFalse(key.isColor)
    }

    func testSubpixelBucketsAreUsedOnlyAtOneX() {
        XCTAssertEqual(GlyphKey.subpixelBucket(forX: 10.05, scale: 1), 0)
        XCTAssertEqual(GlyphKey.subpixelBucket(forX: 10.40, scale: 1), 1)
        XCTAssertEqual(GlyphKey.subpixelBucket(forX: 10.80, scale: 1), 2)
        XCTAssertEqual(GlyphKey.subpixelBucket(forX: 10.80, scale: 2), 0)
        XCTAssertEqual(GlyphKey.subpixelOffset(for: 2, scale: 1), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(GlyphKey.subpixelOffset(for: 2, scale: 2), 0)
    }

    func testMatrixHashDiffersForSyntheticItalic() throws {
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        let upright = GlyphKey.make(font: font, glyph: glyph, scale: 2, isColor: false)
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        let italicFont = CTFontCreateCopyWithAttributes(font, 0, &shear, nil)
        let italic = GlyphKey.make(font: italicFont, glyph: glyph, scale: 2, isColor: false)
        XCTAssertEqual(upright.fontID, italic.fontID)
        XCTAssertNotEqual(upright.matrixHash, italic.matrixHash)
        XCTAssertNotEqual(upright, italic)
    }

    func testColorFontDetection() throws {
        let menlo = makeMenlo(pointSize: 16)
        XCTAssertFalse(GlyphRasterizer.isColorFont(menlo))
        let emoji = try makeAppleColorEmojiFont(pointSize: 32)
        XCTAssertTrue(GlyphRasterizer.isColorFont(emoji))
    }

    func testRasterizeAProducesCoverage() throws {
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        guard case .bitmap(let bitmap) = GlyphRasterizer.rasterize(
            font: font,
            glyph: glyph,
            scale: 2,
            isColor: false
        ) else {
            XCTFail("Expected coverage bitmap for 'A'")
            return
        }
        XCTAssertFalse(bitmap.isColor)
        XCTAssertGreaterThan(bitmap.width, 0)
        XCTAssertGreaterThan(bitmap.height, 0)
        XCTAssertTrue(bitmap.data.contains { $0 > 0 }, "Coverage raster of 'A' should have non-zero samples")
    }

    func testRasterizeEmojiCPUBitmapIsPremultipliedBGRA() throws {
        let font = try makeAppleColorEmojiFont(pointSize: 32)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "😀", font: font), "Apple Color Emoji must provide 😀")
        guard case .bitmap(let bitmap) = GlyphRasterizer.rasterize(
            font: font,
            glyph: glyph,
            scale: 2,
            isColor: true
        ) else {
            XCTFail("Expected BGRA bitmap for emoji")
            return
        }
        XCTAssertTrue(bitmap.isColor)
        assertPremultipliedBGRA(bitmap.data, width: bitmap.width, height: bitmap.height, bytesPerRow: bitmap.bytesPerRow)
    }

    func testOversizeCapWithoutGPU() throws {
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        let result = GlyphRasterizer.rasterize(
            font: font,
            glyph: glyph,
            scale: 2,
            isColor: false,
            maxExtent: 8
        )
        guard case .oversize = result else {
            XCTFail("Expected oversize for a tiny cap")
            return
        }
    }

    @MainActor
    func testInvalidateForFontDropsOnlyThatFontsTiles() throws {
        let atlas = try makeAtlas()
        let menlo = makeMenlo(pointSize: 16)
        let courier = CTFontCreateWithName("Courier" as CFString, 16, nil)
        let menloGlyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: menlo))
        let courierGlyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: courier))
        _ = atlas.lookup(font: menlo, glyph: menloGlyph, scale: 2, isColor: false)
        _ = atlas.lookup(font: courier, glyph: courierGlyph, scale: 2, isColor: false)
        let menloKey = GlyphKey.make(font: menlo, glyph: menloGlyph, scale: 2, isColor: false)
        let courierKey = GlyphKey.make(font: courier, glyph: courierGlyph, scale: 2, isColor: false)
        XCTAssertTrue(atlas.contains(menloKey))
        XCTAssertTrue(atlas.contains(courierKey))

        atlas.invalidate(for: menlo)

        XCTAssertFalse(atlas.contains(menloKey), "Menlo tile should be gone")
        XCTAssertTrue(atlas.contains(courierKey), "Courier tile should survive")
    }

    @MainActor
    func testMissRasterHit() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        let key = GlyphKey.make(font: font, glyph: glyph, scale: 2, isColor: false)
        XCTAssertFalse(atlas.contains(key))
        guard case .hit(let slot) = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("First lookup should rasterize and hit")
            return
        }
        XCTAssertEqual(atlas.missCount, 1)
        XCTAssertEqual(atlas.hitCount, 0)
        XCTAssertFalse(slot.isEmpty)
        XCTAssertEqual(slot.texture?.pixelFormat, .r8Unorm)
        XCTAssertTrue(atlas.contains(key))
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Second lookup should be a cache hit")
            return
        }
        XCTAssertEqual(atlas.missCount, 1)
        XCTAssertEqual(atlas.hitCount, 1)
    }

    @MainActor
    func testEvictionAt32MB() throws {
        let atlas = try makeAtlas()
        XCTAssertEqual(GlyphAtlas.lruBudgetBytes, 32 * 1024 * 1024)
        let extent = GlyphAtlas.maxGlyphExtentPixels
        let bytesPerRow = extent
        let data = Data(count: bytesPerRow * extent)
        let fontID = GlyphKey.make(
            font: makeMenlo(pointSize: 16),
            glyph: 1,
            scale: 1,
            isColor: false
        ).fontID
        let gutter = GlyphAtlas.packerGutterPixels
        let stride = extent + gutter
        let tilesPerAxis = (GlyphAtlas.coveragePageSize + gutter) / stride
        let glyphsPerPage = tilesPerAxis * tilesPerAxis
        XCTAssertGreaterThan(glyphsPerPage, 0)
        let pageCountToExceedBudget = 9
        var keys: [GlyphKey] = []
        keys.reserveCapacity(glyphsPerPage * pageCountToExceedBudget)
        for index in 0..<(glyphsPerPage * pageCountToExceedBudget) {
            let key = GlyphKey(
                fontID: fontID,
                glyph: UInt16(truncatingIfNeeded: index),
                pixelSize: UInt16(truncatingIfNeeded: index),
                matrixHash: UInt64(index),
                scale: 1,
                subpixel: 0,
                isColor: false
            )
            let bitmap = GlyphBitmap(
                key: key,
                width: extent,
                height: extent,
                bytesPerRow: bytesPerRow,
                data: data,
                originX: 0,
                originY: 0,
                isColor: false
            )
            guard case .hit = atlas.upload(bitmap) else {
                XCTFail("Dummy coverage upload \(index) failed")
                return
            }
            keys.append(key)
        }
        XCTAssertLessThanOrEqual(atlas.usedBytes, GlyphAtlas.lruBudgetBytes)
        XCTAssertEqual(atlas.coveragePageCount, 8)
        XCTAssertEqual(atlas.usedBytes, 8 * 2048 * 2048)
        XCTAssertFalse(atlas.contains(keys[0]), "LRU page should be evicted once the 32 MB cap is exceeded")
        XCTAssertTrue(atlas.contains(keys[glyphsPerPage]))
        XCTAssertTrue(atlas.contains(keys[keys.count - 1]))
    }

    @MainActor
    func testScaleKeyIsolation() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        let key1 = GlyphKey.make(font: font, glyph: glyph, scale: 1, isColor: false)
        let key2 = GlyphKey.make(font: font, glyph: glyph, scale: 2, isColor: false)
        XCTAssertNotEqual(key1, key2)
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 1, isColor: false) else {
            XCTFail("Scale 1 lookup failed")
            return
        }
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Scale 2 lookup failed")
            return
        }
        XCTAssertTrue(atlas.contains(key1))
        XCTAssertTrue(atlas.contains(key2))
        XCTAssertEqual(atlas.missCount, 2)
    }

    @MainActor
    func testColorVsCoverageRouting() throws {
        let atlas = try makeAtlas()
        let menlo = makeMenlo(pointSize: 16)
        let coverageGlyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: menlo), "Menlo must provide glyph A")
        guard case .hit(let coverage) = atlas.lookup(font: menlo, glyph: coverageGlyph, scale: 2, isColor: false) else {
            XCTFail("Coverage lookup failed")
            return
        }
        XCTAssertEqual(coverage.texture?.pixelFormat, .r8Unorm)
        XCTAssertEqual(atlas.coveragePageCount, 1)
        XCTAssertEqual(atlas.colorPageCount, 0)

        let emojiFont = try makeAppleColorEmojiFont(pointSize: 32)
        let emojiGlyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "😀", font: emojiFont), "Apple Color Emoji must provide 😀")
        guard case .hit(let color) = atlas.lookup(font: emojiFont, glyph: emojiGlyph, scale: 2, isColor: true) else {
            XCTFail("Color lookup failed")
            return
        }
        XCTAssertEqual(color.texture?.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(atlas.coveragePageCount, 1)
        XCTAssertEqual(atlas.colorPageCount, 1)
        XCTAssertFalse(coverage.texture === color.texture)
    }

    @MainActor
    func testHasUnifiedMemoryStorageModeBranch() throws {
        let (device, queue) = try requireMetalDevice()
        let sharedAtlas = GlyphAtlas(device: device, commandQueue: queue, hasUnifiedMemory: true)
        XCTAssertEqual(sharedAtlas.storageMode, .shared)
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        guard case .hit(let sharedSlot) = sharedAtlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Shared-storage lookup failed")
            return
        }
        XCTAssertEqual(sharedSlot.texture?.storageMode, .shared)
        let sharedPixels = try XCTUnwrap(sharedAtlas.copyPixels(from: sharedSlot), "Shared readback failed")
        XCTAssertTrue(sharedPixels.contains { $0 > 0 })

        let privateAtlas = GlyphAtlas(device: device, commandQueue: queue, hasUnifiedMemory: false)
        XCTAssertEqual(privateAtlas.storageMode, .private)
        guard case .hit(let privateSlot) = privateAtlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Private-storage lookup failed")
            return
        }
        XCTAssertEqual(privateSlot.texture?.storageMode, .private)
        let privatePixels = try XCTUnwrap(privateAtlas.copyPixels(from: privateSlot), "Private blit readback failed")
        XCTAssertTrue(privatePixels.contains { $0 > 0 })
    }

    @MainActor
    func testRasterizeAAndReadTextureBack() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        guard case .hit(let slot) = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Lookup of 'A' failed")
            return
        }
        let pixels = try XCTUnwrap(atlas.copyPixels(from: slot), "Texture readback of 'A' failed")
        XCTAssertEqual(slot.texture?.pixelFormat, .r8Unorm)
        XCTAssertTrue(pixels.contains { $0 > 0 }, "Texture for 'A' should contain coverage")
    }

    @MainActor
    func testRasterizeEmojiTextureIsPremultipliedBGRA() throws {
        let atlas = try makeAtlas()
        let font = try makeAppleColorEmojiFont(pointSize: 32)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "😀", font: font), "Apple Color Emoji must provide 😀")
        guard case .hit(let slot) = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: true) else {
            XCTFail("Lookup of emoji failed")
            return
        }
        XCTAssertEqual(slot.texture?.pixelFormat, .bgra8Unorm)
        let pixels = try XCTUnwrap(atlas.copyPixels(from: slot), "Texture readback of emoji failed")
        assertPremultipliedBGRA(pixels, width: slot.width, height: slot.height, bytesPerRow: slot.width * 4)
    }

    @MainActor
    func testOversizeResultIsExposed() throws {
        let (device, queue) = try requireMetalDevice()
        let atlas = GlyphAtlas(device: device, commandQueue: queue, hasUnifiedMemory: device.hasUnifiedMemory, maxGlyphExtent: 8)
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        guard case .oversize = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Expected oversize result so callers can fall back")
            return
        }
        guard case .oversize = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Oversize should be cached")
            return
        }
        XCTAssertEqual(atlas.missCount, 1)
        XCTAssertEqual(atlas.cachedGlyphCount, 0)
    }

    @MainActor
    func testPrewarmLatin1HitsOnMainQueue() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 14)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        atlas.prewarm(font: font, scale: 2, rasterizeOnBackground: false)
        XCTAssertGreaterThan(atlas.cachedGlyphCount, 0)
        let missesBefore = atlas.missCount
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Pre-warmed 'A' should hit")
            return
        }
        XCTAssertEqual(atlas.missCount, missesBefore)
        XCTAssertEqual(atlas.hitCount, 1)
        let digit = try XCTUnwrap(GlyphRasterizer.glyph(for: "7", font: font), "Menlo must provide glyph 7")
        guard case .hit = atlas.lookup(font: font, glyph: digit, scale: 2, isColor: false) else {
            XCTFail("Pre-warmed digit should hit")
            return
        }
        XCTAssertEqual(atlas.missCount, missesBefore)
    }

    @MainActor
    func testPrewarmBackgroundUploadsOnMain() async throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 14)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "Z", font: font), "Menlo must provide glyph Z")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            atlas.prewarm(font: font, scale: 2, rasterizeOnBackground: true) {
                continuation.resume()
            }
        }
        let missesBefore = atlas.missCount
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Background pre-warm should upload Latin-1 on the main actor")
            return
        }
        XCTAssertEqual(atlas.missCount, missesBefore)
    }

    @MainActor
    func testMemoryPressureDropsNonHotPages() throws {
        let (device, queue) = try requireMetalDevice()
        let atlas = GlyphAtlas(
            device: device,
            commandQueue: queue,
            hasUnifiedMemory: true,
            coveragePageSize: 64,
            maxGlyphExtent: 64
        )
        let data = Data(count: 64 * 64)
        let fontID = GlyphKey.make(font: makeMenlo(pointSize: 16), glyph: 1, scale: 1, isColor: false).fontID
        var keys: [GlyphKey] = []
        for index in 0..<3 {
            let key = GlyphKey(
                fontID: fontID,
                glyph: UInt16(index),
                pixelSize: UInt16(index + 1),
                matrixHash: UInt64(index),
                scale: 1,
                subpixel: 0,
                isColor: false
            )
            let bitmap = GlyphBitmap(
                key: key,
                width: 64,
                height: 64,
                bytesPerRow: 64,
                data: data,
                originX: 0,
                originY: 0,
                isColor: false
            )
            guard case .hit = atlas.upload(bitmap) else {
                XCTFail("Upload \(index) failed")
                return
            }
            keys.append(key)
        }
        XCTAssertEqual(atlas.coveragePageCount, 3)
        XCTAssertTrue(atlas.contains(keys[2]))
        atlas.handleMemoryPressure()
        XCTAssertEqual(atlas.coveragePageCount, 1)
        XCTAssertFalse(atlas.contains(keys[0]))
        XCTAssertFalse(atlas.contains(keys[1]))
        XCTAssertTrue(atlas.contains(keys[2]))
    }

    @MainActor
    func testSyntheticItalicMissesUprightTile() throws {
        let atlas = try makeAtlas()
        let font = makeMenlo(pointSize: 16)
        let glyph = try XCTUnwrap(GlyphRasterizer.glyph(for: "A", font: font), "Menlo must provide glyph A")
        guard case .hit = atlas.lookup(font: font, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Upright lookup failed")
            return
        }
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
        let italicFont = CTFontCreateCopyWithAttributes(font, 0, &shear, nil)
        let italicKey = GlyphKey.make(font: italicFont, glyph: glyph, scale: 2, isColor: false)
        XCTAssertFalse(atlas.contains(italicKey))
        guard case .hit = atlas.lookup(font: italicFont, glyph: glyph, scale: 2, isColor: false) else {
            XCTFail("Italic lookup should miss the upright tile and rasterize")
            return
        }
        XCTAssertEqual(atlas.missCount, 2)
        XCTAssertTrue(atlas.contains(italicKey))
    }
}

private extension GlyphAtlasTests {
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

    @MainActor
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

    @MainActor
    func makeAtlas(hasUnifiedMemory: Bool? = nil) throws -> GlyphAtlas {
        let (device, queue) = try requireMetalDevice()
        return GlyphAtlas(
            device: device,
            commandQueue: queue,
            hasUnifiedMemory: hasUnifiedMemory ?? device.hasUnifiedMemory
        )
    }

    func assertPremultipliedBGRA(
        _ data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(width, 0, "Emoji width", file: file, line: line)
        XCTAssertGreaterThan(height, 0, "Emoji height", file: file, line: line)
        var opaqueOrCovered = 0
        var violated = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for x in 0..<width {
                    let pixel = row + x * 4
                    let blue = pixel[0]
                    let green = pixel[1]
                    let red = pixel[2]
                    let alpha = pixel[3]
                    if alpha > 0 {
                        opaqueOrCovered += 1
                    }
                    if red > alpha || green > alpha || blue > alpha {
                        violated += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(opaqueOrCovered, 0, "Emoji raster was empty", file: file, line: line)
        XCTAssertEqual(violated, 0, "Emoji BGRA should be premultiplied (RGB <= A)", file: file, line: line)
    }
}

@preconcurrency import AppKit
import CoreText
import Darwin
import Foundation

/// CPU bitmap produced by `GlyphRasterizer`. Pixel rows are top-down (Metal-ready).
struct GlyphBitmap: Sendable {
    var key: GlyphKey
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var data: Data
    /// Pixel offset from the glyph origin to the left of the padded tile.
    var originX: Float
    /// Pixel offset from the glyph origin to the bottom of the padded tile (y-up).
    var originY: Float
    var isColor: Bool
}

enum GlyphRasterResult: Sendable {
    case bitmap(GlyphBitmap)
    case oversize
    case empty
    case failed
}

enum GlyphRasterizer {
    static let padPixels = 2
    static let maxGlyphExtentPixels = 256

    static func isColorFont(_ font: CTFont) -> Bool {
        // Core Text: kCTFontColorGlyphsAttribute == "NSCTFontColorGlyphsAttribute"
        if let flag = CTFontCopyAttribute(font, "NSCTFontColorGlyphsAttribute" as CFString) as? Bool, flag {
            return true
        }
        return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
    }

    static func glyph(for string: String, font: CTFont) -> CGGlyph? {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else {
            return nil
        }
        guard CTRunGetGlyphCount(run) > 0 else {
            return nil
        }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph == 0 ? nil : glyph
    }

    static func rasterize(
        font: CTFont,
        glyph: CGGlyph,
        scale: CGFloat,
        runMatrix: CGAffineTransform = .identity,
        subpixel: UInt8 = 0,
        isColor: Bool,
        maxExtent: Int = maxGlyphExtentPixels
    ) -> GlyphRasterResult {
        let key = GlyphKey.make(
            font: font,
            glyph: glyph,
            scale: scale,
            runMatrix: runMatrix,
            subpixel: subpixel,
            isColor: isColor
        )
        var glyphRef = glyph
        var fontBounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyphRef, &fontBounds, 1)
        let aabb = fontBounds.applying(runMatrix)
        let scale = max(scale, 0.001)
        let pixelMinX = floor(aabb.minX * scale)
        let pixelMinY = floor(aabb.minY * scale)
        let pixelMaxX = ceil(aabb.maxX * scale)
        let pixelMaxY = ceil(aabb.maxY * scale)
        let contentWidth = pixelMaxX - pixelMinX
        let contentHeight = pixelMaxY - pixelMinY
        if contentWidth <= 0 || contentHeight <= 0 {
            return .empty
        }
        let width = Int(contentWidth) + 2 * padPixels
        let height = Int(contentHeight) + 2 * padPixels
        if width > maxExtent || height > maxExtent {
            return .oversize
        }
        let bytesPerPixel = isColor ? 4 : 1
        let bytesPerRow = alignedBytesPerRow(width: width, bytesPerPixel: bytesPerPixel)
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            return drawGlyph(
                font: font,
                glyph: glyph,
                scale: scale,
                runMatrix: runMatrix,
                isColor: isColor,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixels: base,
                pixelMinX: pixelMinX,
                pixelMinY: pixelMinY,
                subpixelOffset: GlyphKey.subpixelOffset(for: subpixel, scale: scale)
            )
        }
        guard drawn else {
            return .failed
        }
        flipVertically(data: &data, height: height, bytesPerRow: bytesPerRow)
        return .bitmap(GlyphBitmap(
            key: key,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            data: data,
            originX: Float(
                pixelMinX - CGFloat(padPixels)
                    - GlyphKey.subpixelOffset(for: subpixel, scale: scale) * scale
            ),
            originY: Float(pixelMinY - CGFloat(padPixels)),
            isColor: isColor
        ))
    }

    /// Whole-`CTRun` fallback: rasterize every glyph of a run into one premultiplied BGRA tile,
    /// including its shadow. Used when the per-glyph coverage atlas cannot represent the run
    /// (`NSShadow`, a glyph over the size cap, an unreproducible run matrix, …). `positions` are the
    /// raw `CTRunGetPositions` output (line-relative, Y-up baseline space); `runMatrix` is applied to
    /// positions and bounds but *not* composed onto the glyph shapes (`CTFontDrawGlyphs` applies the
    /// font matrix itself).
    struct RunRasterInput {
        var font: CTFont
        var glyphs: [CGGlyph]
        var positions: [CGPoint]
        var runMatrix: CGAffineTransform
        var foregroundColor: CGColor
        var shadow: NSShadow?
        var scale: CGFloat
        var key: GlyphKey
    }

    /// The whole-run tile can be larger than a single glyph but must still fit a color page.
    static let maxRunExtentPixels = GlyphAtlas.colorPageSize

    static func rasterizeRun(_ input: RunRasterInput, maxExtent: Int = maxRunExtentPixels) -> GlyphRasterResult {
        let count = min(input.glyphs.count, input.positions.count)
        guard count > 0 else {
            return .empty
        }
        let scale = max(input.scale, 0.001)
        let positions = input.positions.prefix(count).map { $0.applying(input.runMatrix) }
        var bbox = CGRect.null
        for index in 0..<count {
            var glyph = input.glyphs[index]
            var glyphBounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(input.font, .default, &glyph, &glyphBounds, 1)
            let transformed = glyphBounds.applying(input.runMatrix)
                .offsetBy(dx: positions[index].x, dy: positions[index].y)
            bbox = bbox.union(transformed)
        }
        guard !bbox.isNull, bbox.width > 0, bbox.height > 0 else {
            return .empty
        }
        if let shadow = input.shadow {
            let dx = abs(shadow.shadowOffset.width) + 3 * shadow.shadowBlurRadius
            let dy = abs(shadow.shadowOffset.height) + 3 * shadow.shadowBlurRadius
            bbox = bbox.insetBy(dx: -dx, dy: -dy)
        }
        let pad = CGFloat(padPixels)
        let width = Int((bbox.width * scale).rounded(.up)) + 2 * padPixels
        let height = Int((bbox.height * scale).rounded(.up)) + 2 * padPixels
        if width > maxExtent || height > maxExtent {
            return .oversize
        }
        let bytesPerPixel = 4
        let bytesPerRow = alignedBytesPerRow(width: width, bytesPerPixel: bytesPerPixel)
        var data = Data(count: bytesPerRow * height)
        let glyphs = Array(input.glyphs.prefix(count))
        let drewSomething = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.textMatrix = .identity
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: pad / scale - bbox.minX, y: pad / scale - bbox.minY)
            if let shadow = input.shadow {
                context.setShadow(
                    offset: shadow.shadowOffset,
                    blur: shadow.shadowBlurRadius,
                    color: shadow.shadowColor?.cgColor
                )
            }
            context.setFillColor(input.foregroundColor)
            var mutablePositions = positions
            var mutableGlyphs = glyphs
            CTFontDrawGlyphs(input.font, &mutableGlyphs, &mutablePositions, count, context)
            return true
        }
        guard drewSomething else {
            return .failed
        }
        flipVertically(data: &data, height: height, bytesPerRow: bytesPerRow)
        return .bitmap(GlyphBitmap(
            key: input.key,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            data: data,
            originX: Float(bbox.minX * scale - pad),
            originY: Float(bbox.minY * scale - pad),
            isColor: true
        ))
    }

    static func prewarmBitmaps(
        font: CTFont,
        scale: CGFloat,
        runMatrix: CGAffineTransform = .identity,
        maxExtent: Int = maxGlyphExtentPixels
    ) -> [GlyphBitmap] {
        let isColor = isColorFont(font)
        var bitmaps: [GlyphBitmap] = []
        bitmaps.reserveCapacity(prewarmScalars.count)
        var seen = Set<CGGlyph>()
        for scalar in prewarmScalars {
            guard let glyph = glyph(for: String(scalar), font: font), seen.insert(glyph).inserted else {
                continue
            }
            if case .bitmap(let bitmap) = rasterize(
                font: font,
                glyph: glyph,
                scale: scale,
                runMatrix: runMatrix,
                isColor: isColor,
                maxExtent: maxExtent
            ) {
                bitmaps.append(bitmap)
            }
        }
        return bitmaps
    }
}

extension GlyphRasterizer {
    /// Printable Latin-1.
    static let prewarmScalars: [UnicodeScalar] = {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(96 + 96)
        for value in 0x20...0x7E {
            if let scalar = UnicodeScalar(value) {
                scalars.append(scalar)
            }
        }
        for value in 0xA0...0xFF {
            if let scalar = UnicodeScalar(value) {
                scalars.append(scalar)
            }
        }
        return scalars
    }()
}

private func alignedBytesPerRow(width: Int, bytesPerPixel: Int) -> Int {
    let raw = max(width, 1) * bytesPerPixel
    return (raw + 15) & ~15
}

private func drawGlyph(
    font: CTFont,
    glyph: CGGlyph,
    scale: CGFloat,
    runMatrix: CGAffineTransform,
    isColor: Bool,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    pixels: UnsafeMutableRawPointer,
    pixelMinX: CGFloat,
    pixelMinY: CGFloat,
    subpixelOffset: CGFloat
) -> Bool {
    let context: CGContext?
    if isColor {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return false
        }
        // BGRA, premultiplied: little-endian + alpha in the high byte.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    } else {
        // Swift's CGContext initializer requires a color space; DeviceGray 8-bit is R8 coverage.
        context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }
    guard let context else {
        return false
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    if !isColor {
        context.setFillColor(gray: 1, alpha: 1)
    }
    // Positions are in scaled user space; the font matrix comes only from CTFontDrawGlyphs.
    context.scaleBy(x: scale, y: scale)
    context.concatenate(runMatrix)
    context.textMatrix = .identity
    let pad = CGFloat(GlyphRasterizer.padPixels)
    var glyphRef = glyph
    // Padded origin is in post-transform AABB space; the CTM already concatenates runMatrix.
    var position = CGPoint(
        x: (pad - pixelMinX) / scale + subpixelOffset,
        y: (pad - pixelMinY) / scale
    )
    if !runMatrix.isIdentity {
        position = position.applying(runMatrix.inverted())
    }
    CTFontDrawGlyphs(font, &glyphRef, &position, 1, context)
    return true
}

private func flipVertically(data: inout Data, height: Int, bytesPerRow: Int) {
    guard height > 1, bytesPerRow > 0 else {
        return
    }
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            return
        }
        var scratch = [UInt8](repeating: 0, count: bytesPerRow)
        for y in 0..<(height / 2) {
            let top = base + y * bytesPerRow
            let bottom = base + (height - 1 - y) * bytesPerRow
            scratch.withUnsafeMutableBytes { scratchRaw in
                guard let scratchBase = scratchRaw.baseAddress else {
                    return
                }
                memcpy(scratchBase, top, bytesPerRow)
                memcpy(top, bottom, bytesPerRow)
                memcpy(bottom, scratchBase, bytesPerRow)
            }
        }
    }
}

import CoreText
import Foundation

/// Cache key for a rasterized glyph tile.
///
/// `matrixHash` is part of the key so a synthetic italic (same `CGFont`, sheared
/// `CTFont` matrix) does not share an upright tile.
struct GlyphKey: Hashable, Sendable {
    var fontID: ObjectIdentifier
    var glyph: UInt16
    var pixelSize: UInt16
    var matrixHash: UInt64
    var scale: UInt8
    var subpixel: UInt8
    var isColor: Bool

    static func make(
        font: CTFont,
        glyph: CGGlyph,
        scale: CGFloat,
        runMatrix: CGAffineTransform = .identity,
        subpixel: UInt8 = 0,
        isColor: Bool
    ) -> GlyphKey {
        let pointSize = CTFontGetSize(font)
        let pixelSize = UInt16(clamping: Int((pointSize * scale * 64).rounded()))
        let scaleBucket = UInt8(clamping: max(1, Int(scale.rounded())))
        return GlyphKey(
            fontID: CGFontIntern.shared.id(for: font),
            glyph: UInt16(glyph),
            pixelSize: pixelSize,
            matrixHash: matrixHash(fontMatrix: CTFontGetMatrix(font), runMatrix: runMatrix),
            scale: scaleBucket,
            subpixel: subpixel,
            isColor: isColor
        )
    }

    /// Three horizontal coverage phases on 1× displays; Retina keeps a single atlas entry.
    static func subpixelBucket(forX x: CGFloat, scale: CGFloat) -> UInt8 {
        guard scale < 1.5 else {
            return 0
        }
        let fraction = x - floor(x)
        return UInt8(min(max(Int(fraction * 3), 0), 2))
    }

    static func subpixelOffset(for bucket: UInt8, scale: CGFloat) -> CGFloat {
        guard scale < 1.5, bucket < 3 else {
            return 0
        }
        return CGFloat(bucket) / 3
    }

    /// Stable identity for `font`'s underlying `CGFont`, matching the `fontID` `make(...)` stores.
    static func fontID(for font: CTFont) -> ObjectIdentifier {
        CGFontIntern.shared.id(for: font)
    }

    static func matrixHash(fontMatrix: CGAffineTransform, runMatrix: CGAffineTransform) -> UInt64 {
        var hasher = Hasher()
        combine(fontMatrix, into: &hasher)
        combine(runMatrix, into: &hasher)
        return UInt64(truncatingIfNeeded: hasher.finalize())
    }
}

private final class CGFontIntern: @unchecked Sendable {
    static let shared = CGFontIntern()
    private let lock = NSLock()
    private var fonts: [ObjectIdentifier: CGFont] = [:]

    func id(for font: CTFont) -> ObjectIdentifier {
        let cgFont = CTFontCopyGraphicsFont(font, nil)
        let identifier = ObjectIdentifier(cgFont)
        lock.lock()
        fonts[identifier] = cgFont
        lock.unlock()
        return identifier
    }
}

private func combine(_ transform: CGAffineTransform, into hasher: inout Hasher) {
    hasher.combine(quantizeAffineComponent(transform.a))
    hasher.combine(quantizeAffineComponent(transform.b))
    hasher.combine(quantizeAffineComponent(transform.c))
    hasher.combine(quantizeAffineComponent(transform.d))
    hasher.combine(quantizeAffineComponent(transform.tx))
    hasher.combine(quantizeAffineComponent(transform.ty))
}

private func quantizeAffineComponent(_ value: CGFloat) -> Int32 {
    Int32((Double(value) * 1024.0).rounded())
}

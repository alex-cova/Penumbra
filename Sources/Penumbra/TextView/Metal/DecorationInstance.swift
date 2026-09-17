import Foundation
import simd

/// One axis-aligned, optionally rounded, optionally stroked rectangle in content coordinates.
///
/// Covers every filled/stroked decoration `LineFragmentRenderer` draws with Core Graphics:
/// standard highlight fills, the marked-text background, outline highlights (fill + stroke), the
/// fold-placeholder chip, the diagnostic warning border, and straight underlines. Wavy squiggles
/// are the exception — they are emitted as `DecorationVertex` triangles.
struct SolidInstance: Equatable {
    /// Content-space top-left, in points.
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    /// Premultiplied sRGB. `w == 0` means "no fill".
    var fillColor: SIMD4<Float>
    /// Premultiplied sRGB. `w == 0` (or `strokeWidth == 0`) means "no stroke".
    var strokeColor: SIMD4<Float>
    var cornerRadius: Float
    var strokeWidth: Float
    /// Bit 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left. Matches `RectCorner`'s order via
    /// `SolidInstance.cornerMask(from:)`.
    var roundedCornersMask: UInt32

    static let noColor = SIMD4<Float>(0, 0, 0, 0)
}

/// One vertex of a per-vertex-colored triangle list. Used for squiggle ribbons, which cannot be
/// expressed as a single rounded rect.
struct DecorationVertex: Equatable {
    /// Content-space position, in points.
    var position: SIMD2<Float>
    /// Premultiplied sRGB.
    var color: SIMD4<Float>
}

extension SolidInstance {
    /// `RectCorner` → shader corner mask (bit 0 TL, 1 TR, 2 BR, 3 BL).
    static func cornerMask(from corners: RectCorner) -> UInt32 {
        var mask: UInt32 = 0
        if corners.contains(.topLeft) { mask |= 1 << 0 }
        if corners.contains(.topRight) { mask |= 1 << 1 }
        if corners.contains(.bottomRight) { mask |= 1 << 2 }
        if corners.contains(.bottomLeft) { mask |= 1 << 3 }
        return mask
    }

    static let allCornersMask: UInt32 = 0b1111
}

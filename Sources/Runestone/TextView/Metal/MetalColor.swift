@preconcurrency import AppKit
import Foundation
import simd

/// Colour conversion shared by the glyph and decoration paint paths: an `NSColor` resolved against
/// a specific `NSAppearance` and returned as premultiplied sRGB, which is what every Metal pipeline
/// in this package blends with (`sourceRGBBlendFactor = .one`).
enum MetalColor {
    static func premultipliedSRGB(_ color: UIColor, appearance: NSAppearance?) -> SIMD4<Float> {
        premultiplied(color, appearance: appearance, colorSpace: .sRGB)
    }

    static func premultiplied(
        _ color: UIColor,
        appearance: NSAppearance?,
        colorSpace: NSColorSpace
    ) -> SIMD4<Float> {
        func convert(_ color: UIColor) -> SIMD4<Float> {
            guard let rgb = color.usingColorSpace(colorSpace) else {
                return SIMD4(0, 0, 0, 1)
            }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return SIMD4(Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha))
        }
        guard let appearance else {
            return convert(color)
        }
        var result = SIMD4<Float>(0, 0, 0, 1)
        appearance.performAsCurrentDrawingAppearance {
            result = convert(color)
        }
        return result
    }
}

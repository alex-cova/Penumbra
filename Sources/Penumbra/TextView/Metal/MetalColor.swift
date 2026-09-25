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

    private struct CacheKey: Hashable {
        let color: UIColor
        let appearanceName: NSAppearance.Name?
        let colorSpace: NSColorSpace
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: SIMD4<Float>] = [:]

    /// Memoized: glyph extraction converts each Core Text run's colour, and the conversion (colour
    /// space plus `performAsCurrentDrawingAppearance`) was ~30% of `GlyphRunExtractor.prepare`.
    /// A theme has a few dozen colours; the cache is dropped if it ever grows past that.
    static func premultiplied(
        _ color: UIColor,
        appearance: NSAppearance?,
        colorSpace: NSColorSpace
    ) -> SIMD4<Float> {
        // Without an explicit appearance a dynamic colour resolves against the current one, which
        // can change under the cache (light/dark switch).
        guard appearance != nil || color.type == .componentBased else {
            return convertPremultiplied(color, appearance: appearance, colorSpace: colorSpace)
        }
        let key = CacheKey(color: color, appearanceName: appearance?.name, colorSpace: colorSpace)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let value = convertPremultiplied(color, appearance: appearance, colorSpace: colorSpace)
        cacheLock.lock()
        if cache.count >= 512 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = value
        cacheLock.unlock()
        return value
    }

    private static func convertPremultiplied(
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

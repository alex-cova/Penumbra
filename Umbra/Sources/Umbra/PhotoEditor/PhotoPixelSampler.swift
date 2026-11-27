import CoreGraphics
import Foundation

/// A single sampled pixel, with formatted readouts for the loupe.
nonisolated struct PhotoSampledPixel: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
    /// Image-pixel coordinate the sample was taken from (top-left origin).
    var location: CGPoint

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgbText: String { "\(red), \(green), \(blue)" }

    var hslText: String {
        let (h, s, l) = Self.hsl(r: Double(red) / 255, g: Double(green) / 255, b: Double(blue) / 255)
        return "\(Int(h.rounded()))°, \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
    }

    private static func hsl(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2
        guard delta > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        var h: Double
        switch maxC {
        case r: h = (g - b) / delta + (g < b ? 6 : 0)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        h *= 60
        return (h, s, l)
    }
}

/// Reads one pixel out of a `CGImage` by rasterising a 1×1 window over the target coordinate.
nonisolated enum PhotoPixelSampler {
    static func pixel(in image: CGImage, at point: CGPoint) -> PhotoSampledPixel? {
        let width = image.width
        let height = image.height
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = bytes.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }

        // Crop to the single target pixel first (a cheap ref) so the draw is 1×1 → 1×1, not a
        // full-image downscale on every hover tick.
        let target = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? image
        context.draw(target, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return PhotoSampledPixel(
            red: bytes[0],
            green: bytes[1],
            blue: bytes[2],
            alpha: bytes[3],
            location: CGPoint(x: x, y: y)
        )
    }
}

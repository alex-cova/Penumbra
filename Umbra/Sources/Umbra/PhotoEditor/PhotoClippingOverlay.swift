import CoreGraphics
import Foundation

/// Builds a transparent overlay that paints blown highlights red and crushed shadows blue over a
/// rendered preview. A CPU pass over the preview `CGImage` — the same approach as
/// `PhotoHistogramEngine` — so it is cheap (the preview is small) and unit-testable, unlike a
/// `CIFilter` chain.
nonisolated enum PhotoClippingOverlay {
    /// A pixel counts as clipped when any channel is at or past the threshold.
    static func mask(
        for image: CGImage,
        shadowThreshold: UInt8 = 2,
        highlightThreshold: UInt8 = 253,
        maxEdge: Int = 2400
    ) -> CGImage? {
        let scale = min(1.0, Double(maxEdge) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let readContext = source.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        var clippedAny = false
        source.withUnsafeBytes { rawIn in
            output.withUnsafeMutableBytes { rawOut in
                let src = rawIn.bindMemory(to: UInt8.self)
                let dst = rawOut.bindMemory(to: UInt8.self)
                var i = 0
                while i < src.count {
                    let r = src[i], g = src[i + 1], b = src[i + 2]
                    if r >= highlightThreshold || g >= highlightThreshold || b >= highlightThreshold {
                        dst[i] = 255; dst[i + 1] = 45; dst[i + 2] = 45; dst[i + 3] = 220
                        clippedAny = true
                    } else if r <= shadowThreshold, g <= shadowThreshold, b <= shadowThreshold {
                        dst[i] = 60; dst[i + 1] = 110; dst[i + 2] = 255; dst[i + 3] = 210
                        clippedAny = true
                    }
                    i += 4
                }
            }
        }
        guard clippedAny else { return nil }

        return output.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}

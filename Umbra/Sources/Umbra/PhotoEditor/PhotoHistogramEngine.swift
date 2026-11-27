import CoreGraphics
import Foundation

/// Per-channel tonal distribution of a rendered preview, plus the fraction of pixels pinned at the
/// black or white ends. Bin arrays are normalised `0...1` against the tallest bin across all four
/// channels so the view can draw them directly.
nonisolated struct PhotoHistogram: Equatable, Sendable {
    static let binCount = 256

    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var luma: [Double]
    var shadowClipped: Double
    var highlightClipped: Double

    static let empty = PhotoHistogram(
        red: Array(repeating: 0, count: binCount),
        green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount),
        luma: Array(repeating: 0, count: binCount),
        shadowClipped: 0,
        highlightClipped: 0
    )

    var isEmpty: Bool { self == .empty }
}

nonisolated enum PhotoHistogramEngine {
    /// Draws `image` once into a small fixed-size RGBA8 context (cost independent of preview
    /// resolution), then bins every pixel of that downscale. Returns `.empty` if the image cannot
    /// be rasterised.
    static func compute(_ image: CGImage, sampleEdge: Int = 256) -> PhotoHistogram {
        let edge = max(1, sampleEdge)
        let aspect = image.height > 0 ? Double(image.width) / Double(image.height) : 1
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = edge
            height = max(1, Int((Double(edge) / aspect).rounded()))
        } else {
            height = edge
            width = max(1, Int((Double(edge) * aspect).rounded()))
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else {
            return .empty
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = [Double](repeating: 0, count: PhotoHistogram.binCount)
        var green = [Double](repeating: 0, count: PhotoHistogram.binCount)
        var blue = [Double](repeating: 0, count: PhotoHistogram.binCount)
        var luma = [Double](repeating: 0, count: PhotoHistogram.binCount)

        let pixelCount = width * height
        var shadowHits = 0
        var highlightHits = 0

        pixels.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < buffer.count {
                let r = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])
                red[r] += 1
                green[g] += 1
                blue[b] += 1
                let y = Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())
                luma[min(255, max(0, y))] += 1

                if r == 0 || g == 0 || b == 0 { shadowHits += 1 }
                if r == 255 || g == 255 || b == 255 { highlightHits += 1 }
                i += 4
            }
        }

        let peak = max(
            red.max() ?? 0,
            green.max() ?? 0,
            blue.max() ?? 0,
            luma.max() ?? 0,
            1
        )
        let denom = Double(max(pixelCount, 1))

        return PhotoHistogram(
            red: red.map { $0 / peak },
            green: green.map { $0 / peak },
            blue: blue.map { $0 / peak },
            luma: luma.map { $0 / peak },
            shadowClipped: Double(shadowHits) / denom,
            highlightClipped: Double(highlightHits) / denom
        )
    }
}

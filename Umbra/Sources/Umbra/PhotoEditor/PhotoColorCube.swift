import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Shared 3D LUT helpers for tone curves and selective HSL. Cube layout matches Core Image:
/// blue varies fastest, then green, then red; each sample is four `Float32` RGBA values.
nonisolated enum PhotoColorCube {
    static let dimension = 32

    static func data(mapping: (Double, Double, Double) -> (Double, Double, Double)) -> Data {
        let n = dimension
        var samples = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        let denom = Double(n - 1)
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let mapped = mapping(Double(r) / denom, Double(g) / denom, Double(b) / denom)
                    samples[index] = Float(mapped.0)
                    samples[index + 1] = Float(mapped.1)
                    samples[index + 2] = Float(mapped.2)
                    samples[index + 3] = 1
                    index += 4
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static func apply(_ image: CIImage, cube: Data) -> CIImage {
        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = cube
        return filter.outputImage ?? image
    }

    // MARK: - HSL

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let delta = maxC - minC
        guard delta > 0.00001 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        let h: Double
        if maxC == r {
            h = (g - b) / delta + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        return (h * 60, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s <= 0.00001 {
            return (l, l, l)
        }
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (
            hueToRGB(p, q, hue + 1 / 3),
            hueToRGB(p, q, hue),
            hueToRGB(p, q, hue - 1 / 3)
        )
    }

    private static func hueToRGB(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }

    static func interpolate(xs: [Double], ys: [Double], x: Double) -> Double {
        let x = min(1, max(0, x))
        guard xs.count == ys.count, xs.count >= 2 else { return x }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        for i in 1..<xs.count {
            if x <= xs[i] {
                let span = max(xs[i] - xs[i - 1], 0.00001)
                let t = (x - xs[i - 1]) / span
                return ys[i - 1] + (ys[i] - ys[i - 1]) * t
            }
        }
        return ys.last ?? x
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

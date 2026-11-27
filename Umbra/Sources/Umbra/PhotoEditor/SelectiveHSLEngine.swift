import CoreImage
import Foundation

nonisolated enum SelectiveHSLEngine {
    static func apply(_ image: CIImage, hsl: SelectiveHSL) -> CIImage {
        guard !hsl.isIdentity else { return image }
        return PhotoColorCube.apply(image, cube: cubeData(hsl))
    }

    static func cubeData(_ hsl: SelectiveHSL) -> Data {
        PhotoColorCube.data { r, g, b in
            map(r, g, b, hsl: hsl)
        }
    }

    static func map(_ r: Double, _ g: Double, _ b: Double, hsl: SelectiveHSL) -> (Double, Double, Double) {
        var sample = PhotoColorCube.rgbToHSL(r, g, b)
        var hueShift = 0.0
        var satShift = 0.0
        var lumShift = 0.0
        var weightSum = 0.0

        for band in ColorBand.allCases {
            let weight = bandWeight(hue: sample.h, band: band)
            guard weight > 0 else { continue }
            let shift = hsl[band]
            hueShift += shift.hueDegrees * weight
            satShift += shift.saturationDelta * weight
            lumShift += shift.luminanceDelta * weight
            weightSum += weight
        }

        if weightSum > 0.00001 {
            sample.h += hueShift
            sample.s = min(1, max(0, sample.s + satShift))
            sample.l = min(1, max(0, sample.l + lumShift))
        }

        let rgb = PhotoColorCube.hslToRGB(sample.h, sample.s, sample.l)
        return (
            min(1, max(0, rgb.0)),
            min(1, max(0, rgb.1)),
            min(1, max(0, rgb.2))
        )
    }

    static func bandWeight(hue: Double, band: ColorBand) -> Double {
        let distance = PhotoColorCube.hueDistance(hue, band.hueCenter)
        let t = 1 - distance / band.halfWidth
        return max(0, t)
    }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

nonisolated enum ToneCurveEngine {
    static func apply(_ image: CIImage, curve: ToneCurve) -> CIImage {
        guard !curve.isIdentity else { return image }
        let channelsIdentity = curve.red == ToneCurve.identityYs
            && curve.green == ToneCurve.identityYs
            && curve.blue == ToneCurve.identityYs
        if channelsIdentity {
            return applyRGB(image, ys: curve.rgb)
        }
        let cube = PhotoColorCube.data { r, g, b in
            let mappedR = PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.red, x: r)
            let mappedG = PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.green, x: g)
            let mappedB = PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.blue, x: b)
            let afterRGB = (
                PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.rgb, x: mappedR),
                PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.rgb, x: mappedG),
                PhotoColorCube.interpolate(xs: ToneCurve.sampleXs, ys: curve.rgb, x: mappedB)
            )
            return (
                min(1, max(0, afterRGB.0)),
                min(1, max(0, afterRGB.1)),
                min(1, max(0, afterRGB.2))
            )
        }
        return PhotoColorCube.apply(image, cube: cube)
    }

    static func applyRGB(_ image: CIImage, ys: [Double]) -> CIImage {
        let points = ToneCurve.clamped(ys)
        guard points != ToneCurve.identityYs else { return image }
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: points[0])
        filter.point1 = CGPoint(x: 0.25, y: points[1])
        filter.point2 = CGPoint(x: 0.5, y: points[2])
        filter.point3 = CGPoint(x: 0.75, y: points[3])
        filter.point4 = CGPoint(x: 1, y: points[4])
        return filter.outputImage ?? image
    }
}

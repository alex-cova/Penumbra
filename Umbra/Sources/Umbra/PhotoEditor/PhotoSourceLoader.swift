import CoreImage
import Foundation

/// Loads a `CIImage` for the render pipeline. RAW files go through `CIRAWFilter` so decode
/// settings actually affect pixels; everything else uses ImageIO via `CIImage(contentsOf:)`.
nonisolated enum PhotoSourceLoader {
    static func image(
        at url: URL,
        raw: RAWDecodeSettings = .identity,
        draft: Bool
    ) -> CIImage? {
        if PhotoRAWSupport.isRAW(url: url), let decoded = decodeRAW(url: url, settings: raw, draft: draft) {
            return decoded
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    static func decodeRAW(url: URL, settings: RAWDecodeSettings, draft: Bool) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        apply(settings, to: filter, draft: draft)
        return filter.outputImage
    }

    static func apply(_ settings: RAWDecodeSettings, to filter: CIRAWFilter, draft: Bool) {
        filter.isDraftModeEnabled = draft
        filter.boostAmount = Float(settings.boostAmount)
        filter.boostShadowAmount = Float(settings.shadowBoostAmount)
        filter.localToneMapAmount = Float(settings.localToneMapAmount)
        filter.baselineExposure = Float(settings.exposureEV)
        filter.sharpnessAmount = Float(settings.sharpnessAmount)
        filter.luminanceNoiseReductionAmount = Float(settings.luminanceNRAmount)
        filter.colorNoiseReductionAmount = Float(settings.colorNRAmount)
        filter.shadowBias = Float(settings.shadowBiasAmount)
        filter.contrastAmount = Float(settings.contrastAmount)
        filter.isLensCorrectionEnabled = settings.lensCorrection
        if settings.temperature != 0 {
            filter.neutralTemperature = Float(settings.neutralTemperatureKelvin)
        }
        if settings.tint != 0 {
            filter.neutralTint = Float(settings.neutralTintAmount)
        }
    }
}

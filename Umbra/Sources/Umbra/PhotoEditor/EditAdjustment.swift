import CoreGraphics
import Foundation

/// Non-destructive edit recipe. UI ranges are `-100...100`; `PhotoRenderEngine` maps them to
/// filter-native values. Geometry is applied in the order documented on the engine.
nonisolated struct EditAdjustment: Equatable, Sendable, Codable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var brightness: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var vignette: Double = 0
    var sharpness: Double = 0

    var preset: PhotoPreset = .original

    var toneCurve: ToneCurve = ToneCurve()
    var selectiveHSL: SelectiveHSL = SelectiveHSL()
    var raw: RAWDecodeSettings = .identity

    /// Normalized `0...1` crop in the straightened, rotated image space.
    var crop: CGRect? = nil
    var rotationQuarterTurns: Int = 0
    var straightenDegrees: Double = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    /// Pixelate / blur / block-out regions, applied before the crop in the same normalized space.
    var redactions: [RedactionRegion] = []

    static let identity = EditAdjustment()

    var isIdentity: Bool { self == .identity }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, brightness, temperature, tint
        case highlights, shadows, vignette, sharpness, preset
        case toneCurve, selectiveHSL, raw
        case crop, rotationQuarterTurns, straightenDegrees, flipHorizontal, flipVertical
        case redactions
    }

    /// `CGRect` is not always `Codable` under Swift 6; persist crop as four doubles.
    private struct CodableRect: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        preset = try container.decodeIfPresent(PhotoPreset.self, forKey: .preset) ?? .original
        toneCurve = try container.decodeIfPresent(ToneCurve.self, forKey: .toneCurve) ?? ToneCurve()
        selectiveHSL = try container.decodeIfPresent(SelectiveHSL.self, forKey: .selectiveHSL) ?? SelectiveHSL()
        raw = try container.decodeIfPresent(RAWDecodeSettings.self, forKey: .raw) ?? .identity
        crop = try container.decodeIfPresent(CodableRect.self, forKey: .crop)?.cgRect
        rotationQuarterTurns = try container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        straightenDegrees = try container.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        redactions = try container.decodeIfPresent([RedactionRegion].self, forKey: .redactions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(preset, forKey: .preset)
        try container.encode(toneCurve, forKey: .toneCurve)
        try container.encode(selectiveHSL, forKey: .selectiveHSL)
        try container.encode(raw, forKey: .raw)
        try container.encodeIfPresent(crop.map(CodableRect.init), forKey: .crop)
        try container.encode(rotationQuarterTurns, forKey: .rotationQuarterTurns)
        try container.encode(straightenDegrees, forKey: .straightenDegrees)
        try container.encode(flipHorizontal, forKey: .flipHorizontal)
        try container.encode(flipVertical, forKey: .flipVertical)
        try container.encode(redactions, forKey: .redactions)
    }

    // MARK: - UI range → filter-native mapping

    /// `CIExposureAdjust.inputEV`, `-2...+2`.
    var exposureEV: Double { clampedUnit * 2 }

    /// `CIColorControls.inputContrast`, `0.5...1.5` (identity `1`).
    var contrastAmount: Double { 1 + clamped(contrast) / 200 }

    /// `CIColorControls.inputSaturation`, `0...2` (identity `1`).
    var saturationAmount: Double { 1 + clamped(saturation) / 100 }

    /// `CIColorControls.inputBrightness`, `-0.5...+0.5` (identity `0`).
    var brightnessAmount: Double { clamped(brightness) / 200 }

    /// Target color temperature in Kelvin for `CITemperatureAndTint` (neutral `6500`).
    /// Positive warmth lowers Kelvin (warmer / more orange).
    var targetTemperatureKelvin: Double { 6500 - clamped(temperature) / 100 * 1500 }

    /// Tint axis for `CITemperatureAndTint`, `-50...+50` (identity `0`).
    var targetTintAmount: Double { clamped(tint) / 2 }

    /// `CIHighlightShadowAdjust.inputHighlightAmount`, `0...1` (identity `1`).
    var highlightAmount: Double { 1 - max(0, clamped(highlights)) / 100 }

    /// `CIHighlightShadowAdjust.inputShadowAmount`, `-1...+1` (identity `0`).
    var shadowAmount: Double { clamped(shadows) / 100 }

    /// `CIVignette.inputIntensity`, `0...2` (identity `0`). Negative UI values are ignored.
    var vignetteIntensity: Double { max(0, clamped(vignette)) / 50 }

    /// `CISharpenLuminance.inputSharpness`, `0...1`. Negative UI values are ignored.
    var sharpenAmount: Double { max(0, clamped(sharpness)) / 100 }

    private var clampedUnit: Double { clamped(exposure) / 100 }

    private func clamped(_ value: Double) -> Double {
        min(100, max(-100, value))
    }

    /// Color/tone recipe without crop, orientation, or redactions, used for saved looks.
    var lookRecipe: EditAdjustment {
        var look = self
        look.crop = nil
        look.rotationQuarterTurns = 0
        look.straightenDegrees = 0
        look.flipHorizontal = false
        look.flipVertical = false
        look.redactions = []
        return look
    }

    /// Apply another look while keeping this document's geometry and redactions.
    func replacingLook(with other: EditAdjustment) -> EditAdjustment {
        var next = other.lookRecipe
        next.crop = crop
        next.rotationQuarterTurns = rotationQuarterTurns
        next.straightenDegrees = straightenDegrees
        next.flipHorizontal = flipHorizontal
        next.flipVertical = flipVertical
        next.redactions = redactions
        return next
    }
}

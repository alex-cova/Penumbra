import Foundation

/// Optional decorative gradient painted behind a slider track, matching Lightroom's white-balance
/// controls. Named rather than a `LinearGradient` so the model layer stays free of SwiftUI.
nonisolated enum PhotoSliderGradient: Sendable {
    case temperature
    case tint
}

nonisolated enum AdjustmentParameter: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case contrast
    case saturation
    case brightness
    case temperature
    case tint
    case highlights
    case shadows
    case vignette
    case sharpness

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .brightness: "Brightness"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .vignette: "Vignette"
        case .sharpness: "Sharpness"
        }
    }

    var keyPath: WritableKeyPath<EditAdjustment, Double> {
        switch self {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .brightness: \.brightness
        case .temperature: \.temperature
        case .tint: \.tint
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .vignette: \.vignette
        case .sharpness: \.sharpness
        }
    }

    /// UI slider bounds. Every tone/color parameter is a bipolar `-100...100`; the two effects that
    /// ignore negative input in the engine (`vignette`, `sharpness`) present as `0...100`.
    var range: ClosedRange<Double> {
        switch self {
        case .vignette, .sharpness: 0...100
        default: -100...100
        }
    }

    /// Value the slider snaps to and double-click resets to.
    var detent: Double { 0 }

    var gradient: PhotoSliderGradient? {
        switch self {
        case .temperature: .temperature
        case .tint: .tint
        default: nil
        }
    }

    /// Lightroom-style inspector modules. The BASIC module intentionally folds the old
    /// light + color groupings into one panel, in Lightroom's control order (white balance,
    /// then tone, then presence).
    nonisolated enum Module: String, CaseIterable, Identifiable, Sendable {
        case basic
        case detail
        case effects

        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .basic: "Basic"
            case .detail: "Detail"
            case .effects: "Effects"
            }
        }

        var parameters: [AdjustmentParameter] {
            switch self {
            case .basic:
                [.temperature, .tint, .exposure, .contrast, .highlights, .shadows, .brightness, .saturation]
            case .detail:
                [.sharpness]
            case .effects:
                [.vignette]
            }
        }

        func isIdentity(in adjustments: EditAdjustment) -> Bool {
            parameters.allSatisfy { adjustments[keyPath: $0.keyPath] == $0.detent }
        }

        func reset(_ adjustments: inout EditAdjustment) {
            for parameter in parameters {
                adjustments[keyPath: parameter.keyPath] = parameter.detent
            }
        }
    }
}

/// Parallel to `AdjustmentParameter` for the CIRAWFilter decode controls, so `RAWPane` renders a
/// data-driven list instead of eleven hand-unrolled sliders. Bounds and detents mirror the
/// documentation on `RAWDecodeSettings`.
nonisolated enum RAWParameter: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case boost
    case shadowBoost
    case sharpness
    case luminanceNR
    case colorNR
    case localToneMap
    case shadowBias
    case contrast
    case temperature
    case tint

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .exposure: "Exposure"
        case .boost: "Boost"
        case .shadowBoost: "Shadow Boost"
        case .sharpness: "Sharpness"
        case .luminanceNR: "Luminance NR"
        case .colorNR: "Color NR"
        case .localToneMap: "Local Tone Map"
        case .shadowBias: "Shadow Bias"
        case .contrast: "Contrast"
        case .temperature: "Temperature"
        case .tint: "Tint"
        }
    }

    var keyPath: WritableKeyPath<RAWDecodeSettings, Double> {
        switch self {
        case .exposure: \.exposure
        case .boost: \.boost
        case .shadowBoost: \.shadowBoost
        case .sharpness: \.sharpness
        case .luminanceNR: \.luminanceNR
        case .colorNR: \.colorNR
        case .localToneMap: \.localToneMap
        case .shadowBias: \.shadowBias
        case .contrast: \.contrast
        case .temperature: \.temperature
        case .tint: \.tint
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure, .shadowBias, .contrast, .temperature, .tint: -100...100
        default: 0...100
        }
    }

    /// The as-shot baseline for this control — where the slider snaps and resets.
    var detent: Double {
        switch self {
        case .boost: 100
        case .sharpness: 40
        case .luminanceNR, .colorNR: 50
        default: 0
        }
    }

    var gradient: PhotoSliderGradient? {
        switch self {
        case .temperature: .temperature
        case .tint: .tint
        default: nil
        }
    }

    /// Noise-reduction and sharpening controls surfaced in the DETAIL module for RAW files.
    static let detailBand: [RAWParameter] = [.sharpness, .luminanceNR, .colorNR]
}

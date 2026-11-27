import Foundation

/// CIRAWFilter decode controls. Identity matches the filter defaults so JPEG/HEIC files that
/// ignore this struct stay untouched, and a RAW file with an identity recipe uses the camera
/// baseline.
nonisolated struct RAWDecodeSettings: Equatable, Sendable, Codable {
    /// UI `-100...100` → EV `-2...+2` on `CIRAWFilter`.
    var exposure: Double = 0
    /// UI `0...100`, identity `100` → `boostAmount` `0...1`.
    var boost: Double = 100
    /// UI `0...100` → `boostShadowAmount` `0...1`.
    var shadowBoost: Double = 0
    /// UI `0...100` → `sharpnessAmount` `0...1`.
    var sharpness: Double = 40
    /// UI `0...100` → `luminanceNoiseReductionAmount` `0...1`.
    var luminanceNR: Double = 50
    /// UI `0...100` → `colorNoiseReductionAmount` `0...1`.
    var colorNR: Double = 50
    /// UI `0...100` → `localToneMapAmount` `0...1`.
    var localToneMap: Double = 0
    /// UI `-100...100` → `shadowBias` `-2...+2`.
    var shadowBias: Double = 0
    /// UI `-100...100` → `contrastAmount` `0.5...1.5` (identity `0` → `1`).
    var contrast: Double = 0
    /// UI `-100...100`. `0` leaves as-shot white balance.
    var temperature: Double = 0
    /// UI `-100...100`. `0` leaves as-shot white balance.
    var tint: Double = 0
    var lensCorrection: Bool = true

    static let identity = RAWDecodeSettings()

    var isIdentity: Bool { self == .identity }

    private enum CodingKeys: String, CodingKey {
        case exposure, boost, shadowBoost, sharpness, luminanceNR, colorNR, localToneMap
        case shadowBias, contrast, temperature, tint, lensCorrection
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        boost = try container.decodeIfPresent(Double.self, forKey: .boost) ?? 100
        shadowBoost = try container.decodeIfPresent(Double.self, forKey: .shadowBoost) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 40
        luminanceNR = try container.decodeIfPresent(Double.self, forKey: .luminanceNR) ?? 50
        colorNR = try container.decodeIfPresent(Double.self, forKey: .colorNR) ?? 50
        localToneMap = try container.decodeIfPresent(Double.self, forKey: .localToneMap) ?? 0
        shadowBias = try container.decodeIfPresent(Double.self, forKey: .shadowBias) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        lensCorrection = try container.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? true
    }

    var exposureEV: Double { min(100, max(-100, exposure)) / 100 * 2 }
    var boostAmount: Double { min(100, max(0, boost)) / 100 }
    var shadowBoostAmount: Double { min(100, max(0, shadowBoost)) / 100 }
    var sharpnessAmount: Double { min(100, max(0, sharpness)) / 100 }
    var luminanceNRAmount: Double { min(100, max(0, luminanceNR)) / 100 }
    var colorNRAmount: Double { min(100, max(0, colorNR)) / 100 }
    var localToneMapAmount: Double { min(100, max(0, localToneMap)) / 100 }
    var shadowBiasAmount: Double { min(100, max(-100, shadowBias)) / 50 }
    var contrastAmount: Double { 1 + min(100, max(-100, contrast)) / 200 }
    var neutralTemperatureKelvin: Double { 6500 - min(100, max(-100, temperature)) / 100 * 1500 }
    var neutralTintAmount: Double { min(100, max(-100, tint)) / 2 }
}

nonisolated enum PhotoRAWSupport {
    static let fileExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef",
        "srw", "raw", "nrw", "rwl", "erf", "mrw", "x3f",
    ]

    static func isRAW(url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }
}

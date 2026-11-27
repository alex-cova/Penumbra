import Foundation

/// Hue / saturation / luminance shift for one color band. UI range `-100...100`.
nonisolated struct HSLShift: Equatable, Sendable, Codable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    /// Hue rotation in degrees (`-60...+60`).
    var hueDegrees: Double { clamped / 100 * 60 }

    /// Saturation add (`-0.5...+0.5`).
    var saturationDelta: Double { clampedSaturation / 200 }

    /// Lightness add (`-0.5...+0.5`).
    var luminanceDelta: Double { clampedLuminance / 200 }

    private var clamped: Double { min(100, max(-100, hue)) }
    private var clampedSaturation: Double { min(100, max(-100, saturation)) }
    private var clampedLuminance: Double { min(100, max(-100, luminance)) }
}

nonisolated enum ColorBand: String, CaseIterable, Identifiable, Sendable, Codable {
    case reds, oranges, yellows, greens, aquas, blues, purples, magentas

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .reds: "Reds"
        case .oranges: "Oranges"
        case .yellows: "Yellows"
        case .greens: "Greens"
        case .aquas: "Aquas"
        case .blues: "Blues"
        case .purples: "Purples"
        case .magentas: "Magentas"
        }
    }

    var abbreviation: String {
        switch self {
        case .reds: "R"
        case .oranges: "O"
        case .yellows: "Y"
        case .greens: "G"
        case .aquas: "A"
        case .blues: "B"
        case .purples: "P"
        case .magentas: "M"
        }
    }

    /// Center hue in degrees, `0...360`.
    var hueCenter: Double {
        switch self {
        case .reds: 0
        case .oranges: 30
        case .yellows: 60
        case .greens: 120
        case .aquas: 180
        case .blues: 240
        case .purples: 270
        case .magentas: 315
        }
    }

    /// Half-width of the triangular influence window, in degrees.
    var halfWidth: Double {
        switch self {
        case .reds, .oranges, .yellows, .magentas: 30
        case .greens, .blues: 40
        case .aquas, .purples: 30
        }
    }
}

/// Eight-band selective HSL recipe. Identity is a no-op in the render pipeline.
nonisolated struct SelectiveHSL: Equatable, Sendable, Codable {
    var reds = HSLShift()
    var oranges = HSLShift()
    var yellows = HSLShift()
    var greens = HSLShift()
    var aquas = HSLShift()
    var blues = HSLShift()
    var purples = HSLShift()
    var magentas = HSLShift()

    var isIdentity: Bool {
        reds.isIdentity && oranges.isIdentity && yellows.isIdentity && greens.isIdentity
            && aquas.isIdentity && blues.isIdentity && purples.isIdentity && magentas.isIdentity
    }

    subscript(band: ColorBand) -> HSLShift {
        get {
            switch band {
            case .reds: reds
            case .oranges: oranges
            case .yellows: yellows
            case .greens: greens
            case .aquas: aquas
            case .blues: blues
            case .purples: purples
            case .magentas: magentas
            }
        }
        set {
            switch band {
            case .reds: reds = newValue
            case .oranges: oranges = newValue
            case .yellows: yellows = newValue
            case .greens: greens = newValue
            case .aquas: aquas = newValue
            case .blues: blues = newValue
            case .purples: purples = newValue
            case .magentas: magentas = newValue
            }
        }
    }
}

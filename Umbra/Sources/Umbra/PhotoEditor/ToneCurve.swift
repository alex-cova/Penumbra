import CoreGraphics
import Foundation

/// Five-point tone curve. X positions are fixed at `0, 0.25, 0.5, 0.75, 1`; stored values are Y
/// in `0...1`. Identity is a straight diagonal.
nonisolated struct ToneCurve: Equatable, Sendable, Codable {
    static let identityYs: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let sampleXs: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var rgb: [Double] = identityYs
    var red: [Double] = identityYs
    var green: [Double] = identityYs
    var blue: [Double] = identityYs

    var isIdentity: Bool {
        rgb == Self.identityYs
            && red == Self.identityYs
            && green == Self.identityYs
            && blue == Self.identityYs
    }

    subscript(channel: ToneCurveChannel) -> [Double] {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            let clamped = Self.clamped(newValue)
            switch channel {
            case .rgb: rgb = clamped
            case .red: red = clamped
            case .green: green = clamped
            case .blue: blue = clamped
            }
        }
    }

    static func clamped(_ values: [Double]) -> [Double] {
        var next = values
        if next.count != 5 {
            next = identityYs
        }
        return next.map { min(1, max(0, $0)) }
    }
}

nonisolated enum ToneCurveChannel: String, CaseIterable, Identifiable, Sendable, Codable {
    case rgb, red, green, blue

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }

    var shortLabel: LocalizedStringResource {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        }
    }
}

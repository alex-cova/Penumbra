import Foundation

nonisolated enum PhotoPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case original
    case vivid
    case noir
    case chrome
    case fade
    case silvertone
    case warmVintage

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .original: "Original"
        case .vivid: "Vivid"
        case .noir: "Noir"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .silvertone: "Silvertone"
        case .warmVintage: "Warm Vintage"
        }
    }
}

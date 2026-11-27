import CoreGraphics
import Foundation

nonisolated enum RedactionStyle: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case pixelate
    case blur
    case solid

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .solid: "Block out"
        }
    }

    var symbol: String {
        switch self {
        case .pixelate: "squareshape.split.3x3"
        case .blur: "drop"
        case .solid: "rectangle.fill"
        }
    }
}

/// A rectangle to pixelate / blur / block out before export. `rect` is normalized `0...1` in the
/// same post-orientation, pre-crop space as `EditAdjustment.crop`. Persisted as four doubles because
/// `CGRect` is not reliably `Codable` under Swift 6.
nonisolated struct RedactionRegion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var rect: CGRect
    var style: RedactionStyle
    /// `0...100` UI strength: pixel block size / blur radius as a fraction of the box.
    var strength: Double

    init(id: UUID = UUID(), rect: CGRect, style: RedactionStyle = .pixelate, strength: Double = 55) {
        self.id = id
        self.rect = rect
        self.style = style
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, style, strength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rect = CGRect(
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0,
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 0,
            height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        )
        style = try container.decodeIfPresent(RedactionStyle.self, forKey: .style) ?? .pixelate
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 55
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rect.origin.x, forKey: .x)
        try container.encode(rect.origin.y, forKey: .y)
        try container.encode(rect.size.width, forKey: .width)
        try container.encode(rect.size.height, forKey: .height)
        try container.encode(style, forKey: .style)
        try container.encode(strength, forKey: .strength)
    }
}

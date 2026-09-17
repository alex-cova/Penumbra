import Foundation
@preconcurrency import AppKit

/// Range of text to highlight.
public final class HighlightedRange {
    /// Unique identifier of the highlighted range.
    public let id: String
    /// Range in the text to highlight.
    public let range: NSRange
    /// Color to highlight the text with.
    public let color: UIColor
    /// Corner radius of the highlight.
    public let cornerRadius: CGFloat
    /// How the highlight is rendered.
    public let style: HighlightStyle
    /// Whether the highlight should use a dimmed appearance.
    public let isInactive: Bool

    /// Create a new highlighted range.
    /// - Parameters:
    ///   - id: ID of the range. Defaults to a UUID.
    ///   - range: Range in the text to highlight.
    ///   - color: Color to highlight the text with.
    ///   - cornerRadius: Corner radius of the highlight. A value of zero or less means no corner radius. Defaults to 0.
    ///   - style: How the highlight is rendered. Defaults to `.standard`.
    ///   - isInactive: Whether the highlight should use a dimmed appearance. Defaults to `false`.
    public init(id: String = UUID().uuidString,
                range: NSRange,
                color: UIColor,
                cornerRadius: CGFloat = 0,
                style: HighlightStyle = .standard,
                isInactive: Bool = false) {
        self.id = id
        self.range = range
        self.color = color
        self.cornerRadius = cornerRadius
        self.style = style
        self.isInactive = isInactive
    }

    init(emphasis: Emphasis, group: String, color: UIColor) {
        self.id = "emphasis:\(group):\(UUID().uuidString)"
        self.range = emphasis.range
        self.color = color
        self.cornerRadius = emphasis.style.shapeRadius
        self.style = emphasis.style
        self.isInactive = emphasis.inactive
    }
}

extension HighlightedRange: Equatable {
    public static func == (lhs: HighlightedRange, rhs: HighlightedRange) -> Bool {
        lhs.id == rhs.id && lhs.range == rhs.range && lhs.color == rhs.color && lhs.style == rhs.style
    }
}

extension HighlightedRange: CustomDebugStringConvertible {
    public var debugDescription: String {
        "[HighightedRange range=\(range)]"
    }
}

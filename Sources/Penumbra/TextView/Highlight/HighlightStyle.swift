import Foundation
@preconcurrency import AppKit

/// Defines how a highlighted range is drawn in the text view.
public enum HighlightStyle: Equatable {
    /// Filled background highlight.
    case standard
    /// Straight underline drawn beneath the text.
    case underline(color: UIColor)
    /// Wavy squiggle drawn beneath the text (typical for diagnostics).
    case squiggle(color: UIColor)
    /// Rounded outline around the text, optionally filled.
    case outline(color: UIColor, fill: Bool = false)

    var shapeRadius: CGFloat {
        switch self {
        case .standard:
            return 4
        case .underline, .squiggle:
            return 0
        case .outline:
            return 2.5
        }
    }
}

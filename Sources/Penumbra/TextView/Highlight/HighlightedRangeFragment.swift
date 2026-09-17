import Foundation
@preconcurrency import AppKit

final class HighlightedRangeFragment: Equatable {
    let range: NSRange
    let containsStart: Bool
    let containsEnd: Bool
    let color: UIColor
    let cornerRadius: CGFloat
    let style: HighlightStyle
    let isInactive: Bool
    var roundedCorners: UIRectCorner {
        if containsStart && containsEnd {
            return .allCorners
        } else if containsStart {
            return [.topLeft, .bottomLeft]
        } else if containsEnd {
            return [.topRight, .bottomRight]
        } else {
            return []
        }
    }

    init(range: NSRange,
         containsStart: Bool,
         containsEnd: Bool,
         color: UIColor,
         cornerRadius: CGFloat,
         style: HighlightStyle = .standard,
         isInactive: Bool = false) {
        self.range = range
        self.containsStart = containsStart
        self.containsEnd = containsEnd
        self.color = color
        self.cornerRadius = cornerRadius
        self.style = style
        self.isInactive = isInactive
    }
}

extension HighlightedRangeFragment {
    static func == (lhs: HighlightedRangeFragment, rhs: HighlightedRangeFragment) -> Bool {
        lhs.range == rhs.range
        && lhs.containsStart == rhs.containsStart
        && lhs.containsEnd == rhs.containsEnd
        && lhs.color == rhs.color
        && lhs.cornerRadius == rhs.cornerRadius
        && lhs.style == rhs.style
        && lhs.isInactive == rhs.isInactive
    }
}

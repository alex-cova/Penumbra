import Foundation
@preconcurrency import AppKit

final class TreeSitterSyntaxHighlightToken {
    let range: NSRange
    let textColor: UIColor?
    let shadow: NSShadow?
    let font: UIFont?
    let fontTraits: FontTraits
    var isEmpty: Bool {
        range.length == 0 || (textColor == nil && font == nil && shadow == nil && fontTraits.isEmpty)
    }

    init(range: NSRange, textColor: UIColor?, shadow: NSShadow?, font: UIFont?, fontTraits: FontTraits) {
        self.range = range
        self.textColor = textColor
        self.shadow = shadow
        self.font = font
        self.fontTraits = fontTraits
    }
}

extension TreeSitterSyntaxHighlightToken: Equatable {
    static func == (lhs: TreeSitterSyntaxHighlightToken, rhs: TreeSitterSyntaxHighlightToken) -> Bool {
        lhs.range == rhs.range && lhs.textColor == rhs.textColor && lhs.font == rhs.font
    }
}

extension TreeSitterSyntaxHighlightToken {
    var upperBound: Int {
        range.location + range.length
    }

    func hasSameStyle(as other: TreeSitterSyntaxHighlightToken) -> Bool {
        fontTraits == other.fontTraits
            && textColor === other.textColor
            && font === other.font
            && shadow === other.shadow
    }

    func merging(_ other: TreeSitterSyntaxHighlightToken) -> TreeSitterSyntaxHighlightToken {
        let location = min(range.location, other.range.location)
        let end = max(upperBound, other.upperBound)
        return TreeSitterSyntaxHighlightToken(
            range: NSRange(location: location, length: end - location),
            textColor: textColor,
            shadow: shadow,
            font: font,
            fontTraits: fontTraits
        )
    }

    static func locationSort(_ lhs: TreeSitterSyntaxHighlightToken, _ rhs: TreeSitterSyntaxHighlightToken) -> Bool {
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        } else {
            return lhs.range.length < rhs.range.length
        }
    }
}

extension TreeSitterSyntaxHighlightToken: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterSyntaxHighlightToken: \(range.location) - \(range.length)]"
    }
}

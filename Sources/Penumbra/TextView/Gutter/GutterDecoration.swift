import CoreGraphics
import Foundation

/// A clickable icon drawn in the editor gutter beside a line.
public struct GutterDecoration: Equatable, Sendable {
    /// Where the icon is drawn.
    public enum Placement: Equatable, Sendable {
        /// The decoration column, left of the line numbers.
        case decorationColumn
        /// In place of the line's number (a breakpoint). A click on it is a click on the line
        /// number and reaches ``TextView/gutterLineClickHandler``, not
        /// ``TextView/gutterDecorationHandler``. Without line numbers it is drawn in the column.
        case lineNumber
        /// The line-marker column right of the line numbers (a run button), in place of the line's
        /// markers. The column is at least one slot wide while one is shown.
        case lineMarkerColumn
    }

    /// 1-based document line. Decorations follow line insertions and removals until the host
    /// replaces them (see ``TextView/gutterDecorationsDidMove``).
    public private(set) var line: Int
    /// The host's identity for the decoration, so it can tell which one moved.
    public let id: String?
    public let symbolName: String
    public let accessibilityLabel: String
    /// The icon's color. `nil` draws it in the gutter's default decoration color.
    public let tintColor: CGColor?
    /// A small SF Symbol drawn over the icon's bottom-trailing corner (for example a `?` on a
    /// conditional breakpoint).
    public let badgeSymbolName: String?
    public let placement: Placement

    public init(
        line: Int,
        symbolName: String,
        accessibilityLabel: String,
        tintColor: CGColor? = nil,
        badgeSymbolName: String? = nil,
        placement: Placement = .decorationColumn,
        id: String? = nil
    ) {
        self.line = line
        self.id = id
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.tintColor = tintColor
        self.badgeSymbolName = badgeSymbolName
        self.placement = placement
    }

    func moved(toLine line: Int) -> GutterDecoration {
        var copy = self
        copy.line = line
        return copy
    }
}

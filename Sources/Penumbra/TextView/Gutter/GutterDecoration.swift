import CoreGraphics
import Foundation

/// A clickable icon drawn in the editor gutter beside a line.
public struct GutterDecoration: Equatable, Sendable {
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

    public init(
        line: Int,
        symbolName: String,
        accessibilityLabel: String,
        tintColor: CGColor? = nil,
        badgeSymbolName: String? = nil,
        id: String? = nil
    ) {
        self.line = line
        self.id = id
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.tintColor = tintColor
        self.badgeSymbolName = badgeSymbolName
    }

    func moved(toLine line: Int) -> GutterDecoration {
        var copy = self
        copy.line = line
        return copy
    }
}

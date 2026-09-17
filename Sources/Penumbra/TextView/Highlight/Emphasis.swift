import Foundation
@preconcurrency import AppKit

/// A single emphasized range in the document.
public struct Emphasis: Equatable {
    public let range: NSRange
    public let style: HighlightStyle
    /// When `true`, the emphasis is removed automatically after a short animation.
    public let flash: Bool
    /// When `true`, draws a dimmer/inactive appearance.
    public let inactive: Bool
    /// When `true`, the text view selects this range when the emphasis is added.
    public let selectInDocument: Bool

    public init(range: NSRange,
                style: HighlightStyle = .standard,
                flash: Bool = false,
                inactive: Bool = false,
                selectInDocument: Bool = false) {
        self.range = range
        self.style = style
        self.flash = flash
        self.inactive = inactive
        self.selectInDocument = selectInDocument
    }
}

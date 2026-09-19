import CoreGraphics

/// How a theme renders markdown markup that needs more than a colour — today, heading sizes.
///
/// Scales multiply the theme's base font size and are rounded to whole points: fewer distinct
/// sizes means fewer glyph-atlas tiles and crisper stems.
public struct MarkdownMarkupStyle: Sendable, Equatable {
    /// H1…H6 as a multiple of the base font size. Values below 1 are clamped to 1.
    public var headingScales: [CGFloat]

    public init(headingScales: [CGFloat]) {
        self.headingScales = headingScales
    }

    /// No size changes — headings differ by colour and weight only.
    public static let none = MarkdownMarkupStyle(headingScales: [1, 1, 1, 1, 1, 1])

    /// Obsidian/Typora-style progression. At 13 pt: 21 / 18 / 16 / 14 / 13 / 13.
    public static let `default` = MarkdownMarkupStyle(headingScales: [1.60, 1.38, 1.22, 1.10, 1.0, 1.0])
}

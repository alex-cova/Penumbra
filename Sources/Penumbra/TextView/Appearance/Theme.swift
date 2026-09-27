import Foundation
@preconcurrency import AppKit

/// Fonts and colors to be used by a `TextView`.
public protocol Theme: AnyObject {
    /// Default font of text in the text view.
    var font: NSFont { get }
    /// Default color of text in the text view.
    var textColor: NSColor { get }
    /// Background color of the gutter containing line numbers.
    var gutterBackgroundColor: NSColor { get }
    /// Color of the hairline next to the gutter containing line numbers.
    var gutterHairlineColor: NSColor { get }
    /// Width of the hairline next to the gutter containing line numbers.
    var gutterHairlineWidth: CGFloat { get }
    /// Color of the line numbers in the gutter.
    var lineNumberColor: NSColor { get }
    /// Font of the line nubmers in the gutter.
    var lineNumberFont: NSFont { get }
    /// Background color of the selected line.
    var selectedLineBackgroundColor: NSColor { get }
    /// Color of the line number of the selected line.
    var selectedLinesLineNumberColor: NSColor { get }
    /// Background color of the gutter for selected lines.
    var selectedLinesGutterBackgroundColor: NSColor { get }
    /// Color of invisible characters, i.e. dots, spaces and line breaks.
    var invisibleCharactersColor: NSColor { get }
    /// Color of the hairline next to the page guide.
    var pageGuideHairlineColor: NSColor { get }
    /// Width of the hairline next to the page guide.
    var pageGuideHairlineWidth: CGFloat { get }
    /// Background color of the page guide.
    var pageGuideBackgroundColor: NSColor { get }
    /// Background color of marked text. Text will be marked when writing certain languages, for example Chinese and Japanese.
    var markedTextBackgroundColor: NSColor { get }
    /// Corner radius of the background of marked text. Text will be marked when writing certain languages, for example Chinese and Japanese.
    /// A value of zero or less means that the background will not have rounded corners. Defaults to 0.
    var markedTextBackgroundCornerRadius: CGFloat { get }
    /// Background color of the text selection highlight.
    ///
    /// Defaults to opaque `#3b82f6`. Prefer a static sRGB color over appearance-adaptive
    /// colors — selection is drawn via Core Graphics and dynamic colors can resolve
    /// against the wrong appearance.
    var selectionColor: NSColor { get }
    /// Color of the hairline drawn above a method/function declaration when
    /// ``TextView/showMethodSeparators`` is on. The editor draws the right-margin hairline
    /// (``pageGuideHairlineColor`` at 45% opacity, ``pageGuideHairlineWidth``).
    /// Defaults to ``pageGuideHairlineColor``.
    var methodSeparatorColor: NSColor { get }
    /// Thickness, in points, of the method separator hairline. The editor uses
    /// ``pageGuideHairlineWidth``. Defaults to one hairline.
    var methodSeparatorWidth: CGFloat { get }
    /// Background color used to highlight other occurrences of the selection when
    /// ``TextView/highlightsOccurrencesOfSelection`` is on. Defaults to a translucent
    /// ``selectionColor``.
    var occurrenceHighlightColor: NSColor { get }
    /// Background color of the find/replace bar (``TextView/showFindPanel(mode:)``).
    /// Defaults to `NSColor.windowBackgroundColor`.
    var findBarBackgroundColor: NSColor { get }
    /// Color of the hairline separating the find bar from the text underneath it.
    /// Defaults to ``gutterHairlineColor``.
    var findBarHairlineColor: NSColor { get }
    /// Background color of the find bar's search field. Defaults to a shade of
    /// ``findBarBackgroundColor``.
    var findBarFieldBackgroundColor: NSColor { get }
    /// Border color of the find bar's search field when it isn't focused. Defaults to
    /// ``findBarHairlineColor``.
    var findBarFieldBorderColor: NSColor { get }
    /// Color of typed text and button glyphs in the find bar. Defaults to ``textColor``.
    var findBarTextColor: NSColor { get }
    /// Color of placeholder text, the match count, and inactive icon buttons in the find bar.
    /// Defaults to a lower-contrast shade of ``findBarTextColor``.
    var findBarMutedTextColor: NSColor { get }
    /// Color of the focus ring and active toggle pills (Case/Regex/Wrap) in the find bar.
    /// Defaults to ``selectionColor``.
    var findBarAccentColor: NSColor { get }
    /// Color of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func textColor(for highlightName: String) -> NSColor?
    /// Font of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func font(for highlightName: String) -> NSFont?
    /// Traits of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func fontTraits(for highlightName: String) -> FontTraits
    /// Shadow of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func shadow(for highlightName: String) -> NSShadow?
    /// Highlighted range for a text range matching a search query.
    ///
    /// This function is called when highlighting a search result from the built-in find panel.
    ///
    /// Return `nil` to prevent highlighting the range.
    /// - Parameters:
    ///   - foundTextRange: The text range matching a search query.
    ///   - style: Style used to decorate the text.
    /// - Returns: The object used for highlighting the provided text range, or `nil` if the range should not be highlighted.
    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: EditorTextSearchFoundTextStyle) -> HighlightedRange?
}

public extension Theme {
    var gutterHairlineWidth: CGFloat {
        hairlineLength
    }

    var pageGuideHairlineWidth: CGFloat {
        hairlineLength
    }

    var markedTextBackgroundCornerRadius: CGFloat {
        0
    }

    /// Opaque `#3b82f6` — visible on both light and dark editor backgrounds.
    var selectionColor: NSColor {
        NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
    }

    var methodSeparatorColor: NSColor {
        pageGuideHairlineColor
    }

    var methodSeparatorWidth: CGFloat {
        hairlineLength
    }

    var occurrenceHighlightColor: NSColor {
        selectionColor.withAlphaComponent(0.28)
    }

    var findBarBackgroundColor: NSColor {
        .windowBackgroundColor
    }

    var findBarHairlineColor: NSColor {
        gutterHairlineColor
    }

    var findBarFieldBackgroundColor: NSColor {
        .textBackgroundColor
    }

    var findBarFieldBorderColor: NSColor {
        findBarHairlineColor
    }

    var findBarTextColor: NSColor {
        textColor
    }

    var findBarMutedTextColor: NSColor {
        .secondaryLabelColor
    }

    var findBarAccentColor: NSColor {
        selectionColor
    }

    func font(for highlightName: String) -> NSFont? {
        nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        []
    }

    func shadow(for highlightName: String) -> NSShadow? {
        nil
    }

    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: EditorTextSearchFoundTextStyle) -> HighlightedRange? {
        switch style {
        case .found:
            return HighlightedRange(range: foundTextRange, color: .systemYellow.withAlphaComponent(0.2))
        case .highlighted:
            return HighlightedRange(range: foundTextRange, color: .systemYellow)
        case .standard:
            return nil
        @unknown default:
            return nil
        }
    }
}

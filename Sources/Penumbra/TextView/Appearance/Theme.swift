import Foundation
@preconcurrency import AppKit

/// Fonts and colors to be used by a `TextView`.
public protocol Theme: AnyObject {
    /// Default font of text in the text view.
    var font: UIFont { get }
    /// Default color of text in the text view.
    var textColor: UIColor { get }
    /// Background color of the gutter containing line numbers.
    var gutterBackgroundColor: UIColor { get }
    /// Color of the hairline next to the gutter containing line numbers.
    var gutterHairlineColor: UIColor { get }
    /// Width of the hairline next to the gutter containing line numbers.
    var gutterHairlineWidth: CGFloat { get }
    /// Color of the line numbers in the gutter.
    var lineNumberColor: UIColor { get }
    /// Font of the line nubmers in the gutter.
    var lineNumberFont: UIFont { get }
    /// Background color of the selected line.
    var selectedLineBackgroundColor: UIColor { get }
    /// Color of the line number of the selected line.
    var selectedLinesLineNumberColor: UIColor { get }
    /// Background color of the gutter for selected lines.
    var selectedLinesGutterBackgroundColor: UIColor { get }
    /// Color of invisible characters, i.e. dots, spaces and line breaks.
    var invisibleCharactersColor: UIColor { get }
    /// Color of the hairline next to the page guide.
    var pageGuideHairlineColor: UIColor { get }
    /// Width of the hairline next to the page guide.
    var pageGuideHairlineWidth: CGFloat { get }
    /// Background color of the page guide.
    var pageGuideBackgroundColor: UIColor { get }
    /// Background color of marked text. Text will be marked when writing certain languages, for example Chinese and Japanese.
    var markedTextBackgroundColor: UIColor { get }
    /// Corner radius of the background of marked text. Text will be marked when writing certain languages, for example Chinese and Japanese.
    /// A value of zero or less means that the background will not have rounded corners. Defaults to 0.
    var markedTextBackgroundCornerRadius: CGFloat { get }
    /// Background color of the text selection highlight.
    ///
    /// Defaults to opaque `#3b82f6`. Prefer a static sRGB color over appearance-adaptive
    /// colors — selection is drawn via Core Graphics and dynamic colors can resolve
    /// against the wrong appearance.
    var selectionColor: UIColor { get }
    /// Color of the hairline drawn above a method/function declaration when
    /// ``TextView/showMethodSeparators`` is on. Defaults to ``gutterHairlineColor``.
    var methodSeparatorColor: UIColor { get }
    /// Thickness, in points, of the method separator hairline. Defaults to one hairline.
    var methodSeparatorWidth: CGFloat { get }
    /// Background color used to highlight other occurrences of the selection when
    /// ``TextView/highlightsOccurrencesOfSelection`` is on. Defaults to a translucent
    /// ``selectionColor``.
    var occurrenceHighlightColor: UIColor { get }
    /// Background color of the find/replace bar (``TextView/showFindPanel(mode:)``).
    /// Defaults to `NSColor.windowBackgroundColor`.
    var findBarBackgroundColor: UIColor { get }
    /// Color of the hairline separating the find bar from the text underneath it.
    /// Defaults to ``gutterHairlineColor``.
    var findBarHairlineColor: UIColor { get }
    /// Background color of the find bar's search field. Defaults to a shade of
    /// ``findBarBackgroundColor``.
    var findBarFieldBackgroundColor: UIColor { get }
    /// Border color of the find bar's search field when it isn't focused. Defaults to
    /// ``findBarHairlineColor``.
    var findBarFieldBorderColor: UIColor { get }
    /// Color of typed text and button glyphs in the find bar. Defaults to ``textColor``.
    var findBarTextColor: UIColor { get }
    /// Color of placeholder text, the match count, and inactive icon buttons in the find bar.
    /// Defaults to a lower-contrast shade of ``findBarTextColor``.
    var findBarMutedTextColor: UIColor { get }
    /// Color of the focus ring and active toggle pills (Case/Regex/Wrap) in the find bar.
    /// Defaults to ``selectionColor``.
    var findBarAccentColor: UIColor { get }
    /// Color of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func textColor(for highlightName: String) -> UIColor?
    /// Font of text matching the capture sequence.
    ///
    /// See <doc:CreatingATheme> for more information on higlight names.
    func font(for highlightName: String) -> UIFont?
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
    /// This function is called when highlighting a search result that was found using the standard find/replace interaction enabled using <doc:TextView/isFindInteractionEnabled>.
    ///
    /// Return `nil` to prevent highlighting the range.
    /// - Parameters:
    ///   - foundTextRange: The text range matching a search query.
    ///   - style: Style used to decorate the text.
    /// - Returns: The object used for highlighting the provided text range, or `nil` if the range should not be highlighted.
    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange?
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
    var selectionColor: UIColor {
        UIColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
    }

    var methodSeparatorColor: UIColor {
        gutterHairlineColor
    }

    var methodSeparatorWidth: CGFloat {
        hairlineLength
    }

    var occurrenceHighlightColor: UIColor {
        selectionColor.withAlphaComponent(0.28)
    }

    var findBarBackgroundColor: UIColor {
        .windowBackgroundColor
    }

    var findBarHairlineColor: UIColor {
        gutterHairlineColor
    }

    var findBarFieldBackgroundColor: UIColor {
        .textBackgroundColor
    }

    var findBarFieldBorderColor: UIColor {
        findBarHairlineColor
    }

    var findBarTextColor: UIColor {
        textColor
    }

    var findBarMutedTextColor: UIColor {
        .secondaryLabelColor
    }

    var findBarAccentColor: UIColor {
        selectionColor
    }

    func font(for highlightName: String) -> UIFont? {
        nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        []
    }

    func shadow(for highlightName: String) -> NSShadow? {
        nil
    }

    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
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

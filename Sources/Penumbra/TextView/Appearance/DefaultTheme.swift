import Foundation
@preconcurrency import AppKit

/// Default theme used by Penumbra when no other theme has been set.
public final class DefaultTheme: Penumbra.Theme {
    nonisolated(unsafe) private static let defaultFont = NSFont(name: "Menlo", size: 14) ?? NSFont.userFixedPitchFont(ofSize: 14) ?? NSFont.systemFont(ofSize: 14)

    public let font: UIFont = DefaultTheme.defaultFont
    public let textColor = UIColor(themeColorNamed: "foreground")
    public let gutterBackgroundColor = UIColor(themeColorNamed: "gutter_background")
    public let gutterHairlineColor = UIColor(themeColorNamed: "gutter_hairline")
    public let lineNumberColor = UIColor(themeColorNamed: "line_number")
    public let lineNumberFont: UIFont = DefaultTheme.defaultFont
    public let selectedLineBackgroundColor = UIColor(themeColorNamed: "current_line")
    public let selectedLinesLineNumberColor = UIColor(themeColorNamed: "line_number_current_line")
    public let selectedLinesGutterBackgroundColor = UIColor(themeColorNamed: "gutter_background")
    public let invisibleCharactersColor = UIColor(themeColorNamed: "invisible_characters")
    public let pageGuideHairlineColor = UIColor(themeColorNamed: "page_guide_hairline")
    public let pageGuideBackgroundColor = UIColor(themeColorNamed: "page_guide_background")
    public let markedTextBackgroundColor = UIColor(themeColorNamed: "marked_text")
    public let selectionColor = UIColor(themeColorNamed: "selection")
    public let methodSeparatorColor = UIColor(themeColorNamed: "method_separator")
    public let occurrenceHighlightColor = UIColor(themeColorNamed: "occurrence_highlight")

    // One dynamic NSColor per palette slot. `textColor(for:)` used to allocate a new
    // appearance-adaptive color for every token, which dominated highlight apply time.
    private static let commentColor = UIColor(themeColorNamed: "comment")
    private static let stringColor = UIColor(themeColorNamed: "string")
    private static let keywordColor = UIColor(themeColorNamed: "keyword")
    private static let typeColor = UIColor(themeColorNamed: "type")
    private static let numberColor = UIColor(themeColorNamed: "number")
    private static let functionColor = UIColor(themeColorNamed: "function")
    private static let constructorColor = UIColor(themeColorNamed: "constructor")
    private static let propertyColor = UIColor(themeColorNamed: "property")
    private static let punctuationColor = UIColor(themeColorNamed: "punctuation")
    private static let variableBuiltinColor = UIColor(themeColorNamed: "variable_builtin")
    private static let attributeColor = UIColor(themeColorNamed: "attribute")
    private static let searchMatchFoundColor = UIColor(themeColorNamed: "search_match_found")
    private static let searchMatchHighlightedColor = UIColor(themeColorNamed: "search_match_highlighted")
    private static let diffPlusColor = UIColor(themeColorNamed: "diff_plus")
    private static let diffMinusColor = UIColor(themeColorNamed: "diff_minus")
    private static let diffDeltaColor = UIColor(themeColorNamed: "diff_delta")

    private var textColorCache: [String: UIColor?] = [:]
    private var fontTraitsCache: [String: FontTraits] = [:]
    private let cacheLock = NSLock()

    public init() {}

    public func textColor(for highlightName: String) -> UIColor? {
        cacheLock.lock()
        if let cached = textColorCache[highlightName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let resolved = HighlightName(highlightName) else {
            cacheLock.lock()
            textColorCache[highlightName] = nil
            cacheLock.unlock()
            return nil
        }
        let color = Self.internedColor(for: resolved)
        cacheLock.lock()
        textColorCache[highlightName] = color
        cacheLock.unlock()
        return color
    }

    public func fontTraits(for highlightName: String) -> FontTraits {
        cacheLock.lock()
        if let cached = fontTraitsCache[highlightName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let resolved = HighlightName(highlightName) else {
            cacheLock.lock()
            fontTraitsCache[highlightName] = []
            cacheLock.unlock()
            return []
        }
        let traits: FontTraits
        switch resolved {
        case .keyword, .markupHeading, .markupBold:
            traits = .bold
        case .markupItalic:
            traits = .italic
        default:
            traits = []
        }
        cacheLock.lock()
        fontTraitsCache[highlightName] = traits
        cacheLock.unlock()
        return traits
    }

    public func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        switch style {
        case .found:
            return HighlightedRange(range: foundTextRange, color: Self.searchMatchFoundColor, cornerRadius: 2)
        case .highlighted:
            return HighlightedRange(range: foundTextRange, color: Self.searchMatchHighlightedColor, cornerRadius: 2)
        case .standard:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func internedColor(for highlightName: HighlightName) -> UIColor? {
        switch highlightName {
        case .attribute:
            return attributeColor
        case .boolean:
            return propertyColor
        case .comment:
            return commentColor
        case .constant:
            return propertyColor
        case .constantBuiltin:
            return propertyColor
        case .constantCharacter:
            return propertyColor
        case .constantMacro:
            return functionColor
        case .constructor:
            return constructorColor
        case .diffPlus:
            return diffPlusColor
        case .diffMinus:
            return diffMinusColor
        case .diffDelta:
            return diffDeltaColor
        case .embedded:
            return nil
        case .float:
            return numberColor
        case .function:
            return functionColor
        case .keyword:
            return keywordColor
        case .label:
            return punctuationColor
        case .markupHeading:
            return keywordColor
        case .markupBold, .markupItalic:
            return nil
        case .markupQuote:
            return commentColor
        case .markupRaw:
            return stringColor
        case .markupLinkUrl:
            return stringColor
        case .markupLinkLabel:
            return propertyColor
        case .number:
            return numberColor
        case .operator:
            return punctuationColor
        case .parameter:
            return propertyColor
        case .property:
            return propertyColor
        case .punctuation, .punctuationBracket, .punctuationDelimiter, .punctuationSpecial:
            return punctuationColor
        case .string, .stringEscape:
            return stringColor
        case .type, .typeBuiltin:
            return typeColor
        case .variable:
            return nil
        case .variableBuiltin:
            return variableBuiltinColor
        case .variableMember:
            return propertyColor
        case .variableParameter:
            return propertyColor
        }
    }
}

private extension UIColor {
    /// Theme colors are defined directly in code rather than resolved from `Theme.xcassets` at
    /// runtime: named/asset-catalog colors have been observed to fail to resolve (`NSColor(named:in:)`
    /// returns `nil`) when Penumbra is statically linked, which used to collapse chrome to a
    /// near-black fallback and — worse — collapsed every syntax-highlight token color to the same
    /// indistinguishable fallback, silently defeating syntax highlighting. Defining colors here
    /// removes the `Bundle.module` resource-bundle dependency from `DefaultTheme`'s correctness
    /// entirely, so it can't fail this way again. `Theme.xcassets` is kept around for reference
    /// (e.g. previewing colors in Xcode) but is no longer consulted at runtime.
    convenience init(themeColorNamed name: String) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch name {
            case "gutter_background", "page_guide_background":
                return .textBackgroundColor
            case "current_line":
                return .selectedContentBackgroundColor.withAlphaComponent(0.25)
            case "selection":
                // Opaque #3b82f6 — same static color for light and dark.
                return UIColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
            case "marked_text", "search_match_found", "search_match_highlighted":
                return .selectedContentBackgroundColor.withAlphaComponent(0.35)
            case "occurrence_highlight":
                // Translucent #3b82f6 — reads on both light and dark editor backgrounds.
                return UIColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 0.28)
            case "method_separator":
                return .secondaryLabelColor
            case "foreground":
                return .textColor
            case "line_number", "line_number_current_line", "invisible_characters",
                 "gutter_hairline", "page_guide_hairline":
                return .secondaryLabelColor
            case "comment":
                return isDark
                    ? UIColor(srgbRed: 0.424, green: 0.475, blue: 0.525, alpha: 1)
                    : UIColor(srgbRed: 0.365, green: 0.424, blue: 0.475, alpha: 1)
            case "string":
                return isDark
                    ? UIColor(srgbRed: 0.988, green: 0.416, blue: 0.365, alpha: 1)
                    : UIColor(srgbRed: 0.769, green: 0.102, blue: 0.086, alpha: 1)
            case "keyword":
                return isDark
                    ? UIColor(srgbRed: 0.988, green: 0.373, blue: 0.639, alpha: 1)
                    : UIColor(srgbRed: 0.608, green: 0.137, blue: 0.576, alpha: 1)
            case "type":
                return isDark
                    ? UIColor(srgbRed: 0.365, green: 0.847, blue: 1.000, alpha: 1)
                    : UIColor(srgbRed: 0.043, green: 0.310, blue: 0.475, alpha: 1)
            case "number":
                return isDark
                    ? UIColor(srgbRed: 0.816, green: 0.749, blue: 0.412, alpha: 1)
                    : UIColor(srgbRed: 0.110, green: 0.000, blue: 0.812, alpha: 1)
            case "function":
                return isDark
                    ? UIColor(srgbRed: 0.404, green: 0.718, blue: 0.643, alpha: 1)
                    : UIColor(srgbRed: 0.196, green: 0.427, blue: 0.455, alpha: 1)
            case "constructor":
                return isDark
                    ? UIColor(srgbRed: 0.620, green: 0.945, blue: 0.867, alpha: 1)
                    : UIColor(srgbRed: 0.110, green: 0.275, blue: 0.290, alpha: 1)
            case "property", "constant_builtin", "constant_character":
                return isDark
                    ? UIColor(srgbRed: 0.631, green: 0.404, blue: 0.902, alpha: 1)
                    : UIColor(srgbRed: 0.424, green: 0.212, blue: 0.663, alpha: 1)
            case "punctuation", "operator":
                return isDark
                    ? UIColor(srgbRed: 0.573, green: 0.631, blue: 0.694, alpha: 1)
                    : UIColor(srgbRed: 0.290, green: 0.333, blue: 0.376, alpha: 1)
            case "variable_builtin":
                return isDark
                    ? UIColor(srgbRed: 0.816, green: 0.659, blue: 1.000, alpha: 1)
                    : UIColor(srgbRed: 0.224, green: 0.000, blue: 0.627, alpha: 1)
            case "attribute":
                return isDark
                    ? UIColor(srgbRed: 0.988, green: 0.827, blue: 0.302, alpha: 1)
                    : UIColor(srgbRed: 0.769, green: 0.502, blue: 0.000, alpha: 1)
            case "diff_plus":
                return isDark
                    ? UIColor(srgbRed: 0.310, green: 0.839, blue: 0.459, alpha: 1)
                    : UIColor(srgbRed: 0.133, green: 0.490, blue: 0.204, alpha: 1)
            case "diff_minus":
                return isDark
                    ? UIColor(srgbRed: 1.000, green: 0.420, blue: 0.420, alpha: 1)
                    : UIColor(srgbRed: 0.769, green: 0.118, blue: 0.227, alpha: 1)
            case "diff_delta":
                return isDark
                    ? UIColor(srgbRed: 0.910, green: 0.639, blue: 0.239, alpha: 1)
                    : UIColor(srgbRed: 0.702, green: 0.420, blue: 0.000, alpha: 1)
            default:
                return .labelColor
            }
        }
    }
}

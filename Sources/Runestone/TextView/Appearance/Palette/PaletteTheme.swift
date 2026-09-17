import AppKit

/// Runestone theme that does **not** depend on asset-catalog ``DefaultTheme`` colors. Those
/// named colors fail to resolve when Runestone is statically linked into an app, collapsing every
/// token (and the gutter) to the near-black fallback.
///
/// Colors are resolved eagerly from a ``ThemePalette`` rather than being appearance-adaptive
/// `NSColor`s. Runestone bakes theme colors into `CGColor`s outside any AppKit drawing context,
/// so a dynamic color resolves against `NSApp.effectiveAppearance` — i.e. system Dark Mode —
/// and would ignore an app's own per-appearance theme choice.
///
/// Nonisolated so ``TextViewState`` can be built off the main thread without hopping back for
/// theme property reads during parse.
public final class PaletteTheme: Theme, @unchecked Sendable {
    private let mono: UIFont
    private let palette: ThemePalette

    public init(size: CGFloat = 13, palette: ThemePalette, font: UIFont) {
        mono = font
        self.palette = palette
    }

    /// Convenience initializer matching the common PostScript-name lookup pattern.
    public convenience init(size: CGFloat = 13, palette: ThemePalette, postscriptName: String?) {
        let font = postscriptName.flatMap { NSFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        self.init(size: size, palette: palette, font: font)
    }

    public var font: UIFont { mono }
    public var lineNumberFont: UIFont { mono }

    public var textColor: UIColor { NSColor(rgb: palette.text) }
    public var backgroundColor: NSColor { NSColor(rgb: palette.background) }
    /// Match the editor chrome so the gutter never reads as a black slab.
    public var gutterBackgroundColor: UIColor { NSColor(rgb: palette.gutterBackground) }
    public var gutterHairlineColor: UIColor { NSColor(rgb: palette.gutterHairline) }
    public var lineNumberColor: UIColor { NSColor(rgb: palette.lineNumber) }
    public var selectedLineBackgroundColor: UIColor { NSColor(rgb: palette.selectedLineBackground) }
    public var selectedLinesLineNumberColor: UIColor { NSColor(rgb: palette.selectedLinesLineNumber) }
    public var selectedLinesGutterBackgroundColor: UIColor { NSColor(rgb: palette.selectedLinesGutterBackground) }
    public var invisibleCharactersColor: UIColor { NSColor(rgb: palette.invisibleCharacters) }
    public var pageGuideHairlineColor: UIColor { NSColor(rgb: palette.pageGuideHairline) }
    public var pageGuideBackgroundColor: UIColor { NSColor(rgb: palette.pageGuideBackground) }
    public var markedTextBackgroundColor: UIColor { NSColor(rgb: palette.markedTextBackground) }
    /// Runestone reapplies this on every `setState` via `theme.selectionColor`.
    public var selectionColor: UIColor {
        ThemePalette.selectionHighlightColor(isDark: palette.isDark)
    }

    public func textColor(for highlightName: String) -> UIColor? {
        // Mirror Runestone's HighlightName peeling: "string.special.key" → "string".
        var components = highlightName.split(separator: ".")
        while !components.isEmpty {
            let candidate = components.joined(separator: ".")
            if let color = highlightColor(for: candidate) {
                return color
            }
            components.removeLast()
        }
        return nil
    }

    public func fontTraits(for highlightName: String) -> FontTraits {
        var components = highlightName.split(separator: ".")
        while !components.isEmpty {
            let candidate = components.joined(separator: ".")
            if candidate == "keyword" || candidate == "include" {
                return .bold
            }
            components.removeLast()
        }
        return []
    }

    private func highlightColor(for name: String) -> UIColor? {
        switch name {
        case "comment":
            return NSColor(rgb: palette.comment)
        case "constant.builtin", "constant.character", "constant":
            return NSColor(rgb: palette.constant)
        case "constructor", "type":
            return NSColor(rgb: palette.type)
        case "function", "embedded":
            return NSColor(rgb: palette.function)
        case "keyword", "include":
            return NSColor(rgb: palette.keyword)
        case "number":
            return NSColor(rgb: palette.number)
        case "property", "attribute":
            return NSColor(rgb: palette.property)
        case "string", "string.special", "string.special.key":
            return NSColor(rgb: palette.string)
        case "variable.builtin":
            return NSColor(rgb: palette.variableBuiltin)
        case "tag":
            return NSColor(rgb: palette.keyword)
        case "operator", "punctuation":
            return NSColor(rgb: palette.punctuation)
        default:
            return nil
        }
    }
}

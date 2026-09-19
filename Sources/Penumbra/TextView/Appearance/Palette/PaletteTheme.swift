import AppKit

/// Penumbra theme that does **not** depend on asset-catalog ``DefaultTheme`` colors. Those
/// named colors fail to resolve when Penumbra is statically linked into an app, collapsing every
/// token (and the gutter) to the near-black fallback.
///
/// Colors are resolved eagerly from a ``ThemePalette`` rather than being appearance-adaptive
/// `NSColor`s. Penumbra bakes theme colors into `CGColor`s outside any AppKit drawing context,
/// so a dynamic color resolves against `NSApp.effectiveAppearance` — i.e. system Dark Mode —
/// and would ignore an app's own per-appearance theme choice.
///
/// Nonisolated so ``TextViewState`` can be built off the main thread without hopping back for
/// theme property reads during parse.
public final class PaletteTheme: Theme, @unchecked Sendable {
    private let mono: UIFont
    private let palette: ThemePalette
    /// Capture name → heading font. Built once in `init` and never mutated, so `font(for:)` (called
    /// per capture, possibly off the main thread) is a lock-free lookup that returns the *same
    /// instance* every time. That matters: the highlighter coalesces adjacent tokens by comparing
    /// fonts with `===`, so transient instances would defeat coalescing.
    private let headingFonts: [String: UIFont]

    public init(size: CGFloat = 13, palette: ThemePalette, font: UIFont, markupStyle: MarkdownMarkupStyle = .default) {
        mono = font
        self.palette = palette
        var headingFonts: [String: UIFont] = [:]
        let baseSize = font.pointSize
        for (index, scale) in markupStyle.headingScales.prefix(6).enumerated() {
            let pointSize = (baseSize * max(1, scale)).rounded()
            // No font at scale 1 keeps those headings on the highlighter's colour-only fast path.
            guard pointSize > baseSize else { continue }
            // Same descriptor → same family and face, so a theme-font change still sweeps these
            // out of the Metal glyph atlas (which invalidates per face, not per size).
            if let scaled = NSFont(descriptor: font.fontDescriptor, size: pointSize) {
                headingFonts["markup.heading.\(index + 1)"] = scaled
            }
        }
        self.headingFonts = headingFonts
    }

    /// Convenience initializer matching the common PostScript-name lookup pattern.
    public convenience init(
        size: CGFloat = 13,
        palette: ThemePalette,
        postscriptName: String?,
        markupStyle: MarkdownMarkupStyle = .default
    ) {
        let font = postscriptName.flatMap { NSFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        self.init(size: size, palette: palette, font: font, markupStyle: markupStyle)
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
    /// Penumbra reapplies this on every `setState` via `theme.selectionColor`.
    public var selectionColor: UIColor {
        ThemePalette.selectionHighlightColor(isDark: palette.isDark)
    }

    public func textColor(for highlightName: String) -> UIColor? {
        // Mirror Penumbra's HighlightName peeling: "string.special.key" → "string".
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

    /// Heading font for `markup.heading.1`…`.6` when heading scaling is on; `nil` otherwise. The bare
    /// `markup.heading` deliberately gets none, so only levelled headings change size.
    public func font(for highlightName: String) -> UIFont? {
        headingFonts[highlightName]
    }

    public func fontTraits(for highlightName: String) -> FontTraits {
        var components = highlightName.split(separator: ".")
        while !components.isEmpty {
            switch components.joined(separator: ".") {
            case "keyword", "include", "markup.heading", "markup.bold", "markup.table":
                return .bold
            case "markup.italic":
                return .italic
            default:
                components.removeLast()
            }
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
        case "diff.plus":
            return NSColor(rgb: palette.diffPlus)
        case "diff.minus":
            return NSColor(rgb: palette.diffMinus)
        case "diff.delta":
            return NSColor(rgb: palette.diffDelta)
        // Markdown. `markup.bold`/`markup.italic` are deliberately absent: they style by weight only
        // and inherit the body colour. Levelled names (`markup.heading.1`, `markup.list.checked`,
        // `markup.table.header`) peel to the entries below.
        case "markup.heading":
            return NSColor(rgb: palette.markupHeading ?? palette.keyword)
        case "markup.quote", "markup.strikethrough":
            return NSColor(rgb: palette.markupQuote ?? palette.comment)
        case "markup.raw":
            return NSColor(rgb: palette.markupRaw ?? palette.string)
        case "markup.link.url":
            return NSColor(rgb: palette.markupLinkURL ?? palette.string)
        case "markup.link.label":
            return NSColor(rgb: palette.markupLinkLabel ?? palette.property)
        case "markup.list":
            return NSColor(rgb: palette.punctuation)
        case "markup.list.checked":
            return NSColor(rgb: palette.function)
        case "markup.table":
            return NSColor(rgb: palette.property)
        default:
            return nil
        }
    }
}

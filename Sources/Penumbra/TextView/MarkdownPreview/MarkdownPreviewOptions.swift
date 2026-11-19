@preconcurrency import AppKit

/// Reading options for the markdown preview that a host exposes as settings: typeface and size,
/// line spacing and length, headings, paragraphs and tables. ``MarkdownPreviewController``
/// applies them on top of the style it derives from the editor; the defaults leave that style
/// as it is.
public struct MarkdownPreviewOptions: Equatable, Sendable {
    public enum Typeface: Equatable, Sendable {
        /// The editor's font.
        case editor
        /// San Francisco.
        case system
        /// New York.
        case serif
        /// SF Mono.
        case monospaced
        /// An installed font family, by name. Falls back to the editor's font when missing.
        case custom(String)
    }

    public enum LineSpacing: String, CaseIterable, Sendable {
        case compact
        case normal
        case relaxed
    }

    public enum HeadingAlignment: String, CaseIterable, Sendable {
        case leading
        case center
    }

    public enum TableDensity: String, CaseIterable, Sendable {
        case padded
        case compact
    }

    public var typeface: Typeface
    /// Body text size in points; `nil` uses the editor's. Headings scale from it.
    public var fontSize: CGFloat?
    public var lineSpacing: LineSpacing
    /// Longest line of body text in characters; `nil` uses the full width.
    public var maxLineLength: Int?
    public var headingAlignment: HeadingAlignment
    public var numbersHeadings: Bool
    /// Indents the first line of a paragraph that follows another paragraph.
    public var indentsParagraphs: Bool
    public var justifiesParagraphs: Bool
    public var tableDensity: TableDensity
    /// Whether a click on a diagram opens it in the zoomable viewer.
    public var opensDiagramsOnClick: Bool
    /// Whether the preview fades in and settles from a larger scale when it opens (only fades with Reduce Motion).
    public var animatesAppearance: Bool

    public static let fontSizeRange: ClosedRange<CGFloat> = 9...32
    public static let lineLengthRange: ClosedRange<Int> = 40...200

    public init(
        typeface: Typeface = .editor,
        fontSize: CGFloat? = nil,
        lineSpacing: LineSpacing = .normal,
        maxLineLength: Int? = nil,
        headingAlignment: HeadingAlignment = .leading,
        numbersHeadings: Bool = false,
        indentsParagraphs: Bool = false,
        justifiesParagraphs: Bool = false,
        tableDensity: TableDensity = .padded,
        opensDiagramsOnClick: Bool = true,
        animatesAppearance: Bool = true
    ) {
        self.typeface = typeface
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.maxLineLength = maxLineLength
        self.headingAlignment = headingAlignment
        self.numbersHeadings = numbersHeadings
        self.indentsParagraphs = indentsParagraphs
        self.justifiesParagraphs = justifiesParagraphs
        self.tableDensity = tableDensity
        self.opensDiagramsOnClick = opensDiagramsOnClick
        self.animatesAppearance = animatesAppearance
    }

    /// `style` with these options applied. Colors are left alone.
    @MainActor
    public func applied(to style: MarkdownPreviewStyle) -> MarkdownPreviewStyle {
        var style = style
        let size = fontSize.map { min(max($0, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound) }
            ?? style.bodyFont.pointSize
        style.bodyFont = Self.font(for: typeface, size: size, editorFont: style.bodyFont)
        if fontSize != nil || typeface != .editor {
            style.codeFont = .monospacedSystemFont(ofSize: max(size - 1, 9), weight: .regular)
        }
        switch lineSpacing {
        case .compact: style.lineSpacing = 1
        case .normal: break
        case .relaxed: style.lineSpacing = (size * 0.6).rounded()
        }
        style.maxLineLength = maxLineLength.map {
            min(max($0, Self.lineLengthRange.lowerBound), Self.lineLengthRange.upperBound)
        }
        style.headingAlignment = headingAlignment == .center ? .center : .natural
        style.numbersHeadings = numbersHeadings
        style.paragraphIndent = indentsParagraphs ? (size * 2).rounded() : 0
        style.justifiesParagraphs = justifiesParagraphs
        if tableDensity == .compact {
            style.tableCellPadding = 3
        }
        return style
    }

    /// The body font for `typeface` at `size`.
    @MainActor
    static func font(for typeface: Typeface, size: CGFloat, editorFont: NSFont) -> NSFont {
        switch typeface {
        case .editor:
            return NSFontManager.shared.convert(editorFont, toSize: size)
        case .system:
            return .systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
            return NSFont(descriptor: serif, size: size) ?? base
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .custom(let family):
            let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return NSFontManager.shared.convert(editorFont, toSize: size) }
            return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
                ?? NSFont(name: name, size: size)
                ?? NSFontManager.shared.convert(editorFont, toSize: size)
        }
    }
}

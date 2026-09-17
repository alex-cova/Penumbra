@preconcurrency import AppKit

/// Typography and colors for the markdown preview, typically derived from the host editor.
///
/// AppKit font and color references are main-actor resources. For async mermaid rendering,
/// use ``mermaidRenderingContext`` to cross isolation with a `Sendable` color snapshot.
public struct MarkdownPreviewStyle: Equatable {
    public var bodyFont: NSFont
    public var bodyColor: NSColor
    public var backgroundColor: NSColor
    public var codeFont: NSFont
    public var codeBackgroundColor: NSColor
    public var headingScale: [CGFloat]
    public var contentInset: CGFloat
    public var blockSpacing: CGFloat
    public var lineSpacing: CGFloat
    public var listIndent: CGFloat
    public var codePadding: CGFloat
    public var mermaidMaxDimension: CGFloat

    /// Per-level indent applied to blockquote content, in addition to `contentInset`.
    public var quoteIndent: CGFloat
    /// Width of the vertical accent bar drawn at each quote level's leading edge.
    public var quoteBarWidth: CGFloat
    /// Extra breathing room around a quote band beyond the text frame.
    public var quotePadding: CGFloat
    /// Tint colors cycled by quote depth (1-indexed) so `>`, `>>`, `>>>` read apart.
    public var quoteTints: [NSColor]
    /// Padding inside each table cell.
    public var tableCellPadding: CGFloat
    /// Color of table borders and row/column hairlines.
    public var tableBorderColor: NSColor
    /// Floor a table column may be shrunk to before its content clips.
    public var tableMinColumnWidth: CGFloat
    /// Side length of a drawn task-list checkbox glyph.
    public var checkboxSize: CGFloat
    /// Color used for markdown link text.
    public var linkColor: NSColor
    /// Whether a checked task item's text is dimmed to signal completion.
    public var dimsCompletedTasks: Bool

    /// Font size of a footnote entry's body text, as a fraction of `bodyFont`'s point size.
    public var footnoteFontScale: CGFloat
    /// Font size of an inline `[^1]` reference marker, as a fraction of the surrounding text's font.
    public var footnoteReferenceScale: CGFloat
    /// How far an inline reference marker is raised above the baseline, as a fraction of the
    /// surrounding text's font size.
    public var footnoteReferenceBaselineRatio: CGFloat
    /// Width of a footnote entry's number-marker gutter, mirroring `listIndent` for ordered lists.
    public var footnoteMarkerWidth: CGFloat
    /// Vertical gap between consecutive footnote entries.
    public var footnoteSpacing: CGFloat

    public init(
        bodyFont: NSFont = .systemFont(ofSize: 14),
        bodyColor: NSColor = .labelColor,
        backgroundColor: NSColor = .textBackgroundColor,
        codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBackgroundColor: NSColor = .quaternaryLabelColor,
        headingScale: [CGFloat] = [2.0, 1.6, 1.35, 1.2, 1.1, 1.05],
        contentInset: CGFloat = 20,
        blockSpacing: CGFloat = 14,
        lineSpacing: CGFloat = 4,
        listIndent: CGFloat = 24,
        codePadding: CGFloat = 10,
        mermaidMaxDimension: CGFloat = 4096,
        quoteIndent: CGFloat = 20,
        quoteBarWidth: CGFloat = 3,
        quotePadding: CGFloat = 8,
        quoteTints: [NSColor] = [.systemBlue, .systemPurple, .systemOrange],
        tableCellPadding: CGFloat = 8,
        tableBorderColor: NSColor = .separatorColor,
        tableMinColumnWidth: CGFloat = 48,
        checkboxSize: CGFloat = 13,
        linkColor: NSColor = .linkColor,
        dimsCompletedTasks: Bool = true,
        footnoteFontScale: CGFloat = 0.85,
        footnoteReferenceScale: CGFloat = 0.72,
        footnoteReferenceBaselineRatio: CGFloat = 0.32,
        footnoteMarkerWidth: CGFloat = 26,
        footnoteSpacing: CGFloat = 4
    ) {
        self.bodyFont = bodyFont
        self.bodyColor = bodyColor
        self.backgroundColor = backgroundColor
        self.codeFont = codeFont
        self.codeBackgroundColor = codeBackgroundColor
        self.headingScale = headingScale
        self.contentInset = contentInset
        self.blockSpacing = blockSpacing
        self.lineSpacing = lineSpacing
        self.listIndent = listIndent
        self.codePadding = codePadding
        self.mermaidMaxDimension = mermaidMaxDimension
        self.quoteIndent = quoteIndent
        self.quoteBarWidth = quoteBarWidth
        self.quotePadding = quotePadding
        self.quoteTints = quoteTints
        self.tableCellPadding = tableCellPadding
        self.tableBorderColor = tableBorderColor
        self.tableMinColumnWidth = tableMinColumnWidth
        self.checkboxSize = checkboxSize
        self.linkColor = linkColor
        self.dimsCompletedTasks = dimsCompletedTasks
        self.footnoteFontScale = footnoteFontScale
        self.footnoteReferenceScale = footnoteReferenceScale
        self.footnoteReferenceBaselineRatio = footnoteReferenceBaselineRatio
        self.footnoteMarkerWidth = footnoteMarkerWidth
        self.footnoteSpacing = footnoteSpacing
    }

    /// Font used for a footnote entry's body text (`bodyFont` scaled by `footnoteFontScale`).
    public func footnoteFont(for bodyFont: NSFont) -> NSFont {
        NSFontManager.shared.convert(bodyFont, toSize: bodyFont.pointSize * footnoteFontScale)
    }

    /// Sendable color snapshot for off-main mermaid rasterization.
    public struct MermaidRenderingContext: Sendable {
        public let backgroundRGBA: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
        public let foregroundRGBA: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
        public let mermaidMaxDimension: CGFloat
    }

    public var mermaidRenderingContext: MermaidRenderingContext {
        MermaidRenderingContext(
            backgroundRGBA: Self.rgbaComponents(backgroundColor),
            foregroundRGBA: Self.rgbaComponents(bodyColor),
            mermaidMaxDimension: mermaidMaxDimension
        )
    }

    private static func rgbaComponents(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return (0, 0, 0, 1)
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    @MainActor
    public static func from(textView: TextView) -> MarkdownPreviewStyle {
        let font = textView.theme.font
        let textColor = textView.theme.textColor
        let background = textView.backgroundColor ?? .textBackgroundColor
        return MarkdownPreviewStyle(
            bodyFont: font,
            bodyColor: textColor,
            backgroundColor: background,
            codeFont: .monospacedSystemFont(ofSize: max(font.pointSize - 1, 11), weight: .regular),
            codeBackgroundColor: textColor.withAlphaComponent(0.06),
            tableBorderColor: textColor.withAlphaComponent(0.15),
            linkColor: .linkColor
        )
    }
}

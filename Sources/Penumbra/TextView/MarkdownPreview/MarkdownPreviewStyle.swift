@preconcurrency import AppKit

/// Typography and colors for the markdown preview, typically derived from the host editor.
public struct MarkdownPreviewStyle: Sendable, Equatable {
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
        mermaidMaxDimension: CGFloat = 4096
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
            codeBackgroundColor: textColor.withAlphaComponent(0.06)
        )
    }
}

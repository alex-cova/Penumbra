import AppKit
import Penumbra
import SwiftUI

/// Penumbra's rendering for the two chat blocks SwiftUI does worse than the editor: fenced code gets
/// the editor theme's syntax colours, and a ```mermaid fence becomes a diagram. The chat keeps its own
/// prose, file links, selection and code actions; only these blocks come from here.
///
/// Both go through `MarkdownPreviewRasterizer`, the same pipeline as the Markdown preview over the
/// editor, with one shared bounded cache, so scrolling a long chat or re-showing a message renders
/// nothing twice.
@MainActor
enum IDEAgentRichBlocks {
    /// Longest fence that is highlighted; a larger one stays plain text.
    static let maxHighlightedCharacters = 50_000
    /// The width a diagram is laid out at. The picture is scaled down to its column, so a resize never
    /// renders it again.
    private static let diagramWidth: CGFloat = 720

    private static let cache = MarkdownPreviewRasterCache()

    enum Diagram {
        case image(CGImage, size: CGSize)
        case failed(String)
    }

    /// Chat colours as a preview style: a diagram is drawn for the card it sits on.
    private nonisolated static func makeStyle() -> MarkdownPreviewStyle {
        MarkdownPreviewStyle(
            bodyColor: IDEAppearance.NSToken.foreground,
            backgroundColor: IDEAppearance.NSToken.editor)
    }

    /// Changes whenever the colours a rendered block depends on change.
    static var appearanceKey: String {
        "\(IDEAppearance.scheme.isDark)-\(IDEAppearance.scheme.editor)-\(IDEEditorTheme.shared.current.font.pointSize)"
    }

    static func isMermaid(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespaces).lowercased() == "mermaid"
    }

    /// The fence with the editor theme's colours, or `nil` for a language without a grammar. The colours
    /// only: the font is left to the view, so the block keeps the chat's code size.
    static func highlight(_ code: String, language: String?) async -> AttributedString? {
        guard language != nil, code.count <= maxHighlightedCharacters else { return nil }
        let document = MarkdownPreviewDocument(blocks: [
            MarkdownPreviewBlock(kind: .codeBlock(language: language, source: code))
        ])
        let style = makeStyle()
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: style,
            contentWidth: diagramWidth,
            syntaxTheme: IDEEditorTheme.shared.current,
            codeBlockLanguageResolver: { IDELanguageSupport.language(forIdentifier: $0) },
            cache: cache)
        guard let highlighted = result.highlightedCode[0] else { return nil }
        let colored = NSMutableAttributedString(attributedString: highlighted)
        let whole = NSRange(location: 0, length: colored.length)
        colored.removeAttribute(.font, range: whole)
        colored.removeAttribute(.paragraphStyle, range: whole)
        colored.removeAttribute(.backgroundColor, range: whole)
        return try? AttributedString(colored, including: \.appKit)
    }

    /// The diagram for a mermaid source, or why it could not be drawn.
    static func diagram(_ source: String) async -> Diagram {
        let document = MarkdownPreviewDocument(blocks: [MarkdownPreviewBlock(kind: .mermaid(source: source))])
        let style = makeStyle()
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: style,
            contentWidth: diagramWidth,
            cache: cache)
        if let image = result.images[0] {
            let size = result.naturalSizes[0] ?? CGSize(width: image.width, height: image.height)
            return .image(image, size: size)
        }
        return .failed(result.errors[0] ?? "Nothing was drawn.")
    }
}

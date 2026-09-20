import Foundation
@preconcurrency import AppKit

/// Mermaid/image/code-fence rasterization output for a parsed ``MarkdownPreviewDocument``, keyed
/// by block index — feeds straight into the matching ``MarkdownPreviewView`` properties
/// (`rasterImages`, `rasterNaturalSizes`, `highlightedCode`).
public struct MarkdownPreviewRasterResult: @unchecked Sendable {
    public var images: [Int: CGImage]
    public var naturalSizes: [Int: CGSize]
    public var highlightedCode: [Int: NSAttributedString]
    /// Block index → error message, for mermaid diagrams that failed to render.
    public var errors: [Int: String]

    public init(
        images: [Int: CGImage] = [:],
        naturalSizes: [Int: CGSize] = [:],
        highlightedCode: [Int: NSAttributedString] = [:],
        errors: [Int: String] = [:]
    ) {
        self.images = images
        self.naturalSizes = naturalSizes
        self.highlightedCode = highlightedCode
        self.errors = errors
    }
}

/// Standalone rasterization for a parsed ``MarkdownPreviewDocument``, independent of any host
/// `TextView`. ``MarkdownPreviewController`` does the same work internally for the
/// toggle-over-the-editor preview in Umbra; this is that same pipeline (image loading, fenced-code
/// syntax highlighting, mermaid diagram layout/raster) exposed for a host — e.g. a read-only chat
/// bubble — that wants to drive a ``MarkdownPreviewView`` directly, with no editor in the loop.
public enum MarkdownPreviewRasterizer {
    /// - Parameters:
    ///   - contentWidth: the preview's content width (already excluding `style.contentInset`),
    ///     used to size mermaid diagrams and pick a display width for images.
    ///   - codeBlockLanguageResolver: maps a fenced-code language hint (e.g. `"swift"`) to a
    ///     tree-sitter language. Fenced code renders unhighlighted (plain) when `nil` or when the
    ///     resolver returns `nil` for a given hint.
    public static func rasterize(
        document: MarkdownPreviewDocument,
        style: MarkdownPreviewStyle,
        contentWidth: CGFloat,
        baseURL: URL? = nil,
        syntaxTheme: Theme = DefaultTheme(),
        codeBlockLanguageResolver: ((String) -> TreeSitterLanguage?)? = nil,
        codeBlockLanguageProvider: TreeSitterLanguageProvider? = nil
    ) async -> MarkdownPreviewRasterResult {
        var result = MarkdownPreviewRasterResult()

        for (index, block) in document.blocks.enumerated() {
            switch block.kind {
            case .image(_, let reference):
                guard let image = MarkdownPreviewImageLoader.loadImage(at: reference, baseURL: baseURL) else { continue }
                result.images[index] = image
                result.naturalSizes[index] = MarkdownPreviewImageLoader.naturalSize(of: image)

            case .codeBlock(let language, let source):
                guard let resolver = codeBlockLanguageResolver, let highlighted = MarkdownPreviewCodeHighlighter.highlight(
                    source: source,
                    languageHint: language,
                    theme: syntaxTheme,
                    languageResolver: resolver,
                    languageProvider: codeBlockLanguageProvider
                ) else { continue }
                result.highlightedCode[index] = highlighted

            case .mermaid(let source):
                let rendered = await MermaidPaintAdapter.render(
                    source: source,
                    mermaidStyle: style.mermaidRenderingContext,
                    contentWidth: contentWidth
                )
                if let image = rendered.image {
                    result.images[index] = image
                    if let naturalSize = rendered.naturalSize {
                        result.naturalSizes[index] = naturalSize
                    }
                } else if let message = rendered.errorMessage {
                    result.errors[index] = message
                }

            case .heading, .paragraph, .list, .table, .thematicBreak, .mermaidError, .footnotes:
                continue
            }
        }

        return result
    }
}

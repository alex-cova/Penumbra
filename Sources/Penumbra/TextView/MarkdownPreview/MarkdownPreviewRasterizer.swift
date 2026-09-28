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

    /// Adds `other`'s entries, replacing any for the same block index.
    mutating func merge(_ other: MarkdownPreviewRasterResult) {
        images.merge(other.images) { $1 }
        naturalSizes.merge(other.naturalSizes) { $1 }
        highlightedCode.merge(other.highlightedCode) { $1 }
        errors.merge(other.errors) { $1 }
    }
}

/// Standalone rasterization for a parsed ``MarkdownPreviewDocument``, independent of any host
/// `TextView`. ``MarkdownPreviewController`` runs the same pipeline (``MarkdownPreviewRasterWorker``)
/// for the toggle-over-the-editor preview in Umbra; this exposes it for a host — e.g. a read-only
/// chat bubble — that wants to drive a ``MarkdownPreviewView`` directly, with no editor in the loop.
public enum MarkdownPreviewRasterizer {
    /// - Parameters:
    ///   - contentWidth: the preview's content width (already excluding `style.contentInset`),
    ///     used to size mermaid diagrams and pick a display width for images.
    ///   - codeBlockLanguageResolver: maps a fenced-code language hint (e.g. `"swift"`) to a
    ///     tree-sitter language. Fenced code renders unhighlighted (plain) when `nil` or when the
    ///     resolver returns `nil` for a given hint.
    ///   - cache: reuse diagrams, highlighted code and images across calls (e.g. one cache per
    ///     preview, passed on every re-render). Without one, everything is rendered afresh.
    public static func rasterize(
        document: MarkdownPreviewDocument,
        style: MarkdownPreviewStyle,
        contentWidth: CGFloat,
        baseURL: URL? = nil,
        syntaxTheme: Theme = DefaultTheme(),
        codeBlockLanguageResolver: (@Sendable (String) -> TreeSitterLanguage?)? = nil,
        codeBlockLanguageProvider: TreeSitterLanguageProvider? = nil,
        cache: MarkdownPreviewRasterCache? = nil
    ) async -> MarkdownPreviewRasterResult {
        let inputs = MarkdownPreviewRasterInputs(
            baseURL: baseURL,
            mermaidContext: style.mermaidRenderingContext,
            contentWidth: contentWidth,
            syntaxTheme: syntaxTheme,
            languageResolver: codeBlockLanguageResolver,
            languageProvider: codeBlockLanguageProvider
        )
        let cache = cache ?? MarkdownPreviewRasterCache()
        var pass = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs, cache: cache)
        let rendered = await MarkdownPreviewRasterWorker.renderMermaid(pass.pendingMermaid, inputs: inputs, cache: cache)
        pass.result.merge(rendered)
        return pass.result
    }
}

/// Everything raster work needs from the host, snapshotted so it can run off the main actor.
/// `Theme` and the resolver are only read.
struct MarkdownPreviewRasterInputs: @unchecked Sendable {
    var baseURL: URL?
    var mermaidContext: MarkdownPreviewStyle.MermaidRenderingContext
    var contentWidth: CGFloat
    var syntaxTheme: Theme
    var languageResolver: ((String) -> TreeSitterLanguage?)?
    var languageProvider: TreeSitterLanguageProvider?
}

/// The cheap part of raster work (cache hits, code highlighting, image decoding) plus the
/// mermaid diagrams still to render.
struct MarkdownPreviewRasterPass: @unchecked Sendable {
    var result = MarkdownPreviewRasterResult()
    var pendingMermaid: [(index: Int, source: String)] = []
}

/// Renders one mermaid diagram. Tests substitute a counting renderer.
typealias MarkdownPreviewMermaidRender = @Sendable (
    _ source: String,
    _ context: MarkdownPreviewStyle.MermaidRenderingContext,
    _ contentWidth: CGFloat
) async -> MermaidPaintResult

enum MarkdownPreviewRasterWorker {
    /// Resolves every block that doesn't need a mermaid render: cached diagrams, code fences
    /// (highlighting is sub-millisecond per fence) and local images. Synchronous; call it off the
    /// main actor, right after parsing, so the first layout of a new parse already has them.
    static func resolve(
        document: MarkdownPreviewDocument,
        inputs: MarkdownPreviewRasterInputs,
        cache: MarkdownPreviewRasterCache
    ) -> MarkdownPreviewRasterPass {
        var pass = MarkdownPreviewRasterPass()
        for (index, block) in document.blocks.enumerated() {
            switch block.kind {
            case .image(_, let reference):
                guard let url = MarkdownPreviewImageLoader.fileURL(for: reference, baseURL: inputs.baseURL) else { continue }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let image: CGImage
                if let cached = cache.image(path: url.path, modified: modified) {
                    image = cached
                } else if let loaded = MarkdownPreviewImageLoader.loadImage(at: url) {
                    cache.storeImage(loaded, path: url.path, modified: modified)
                    image = loaded
                } else {
                    continue
                }
                pass.result.images[index] = image
                pass.result.naturalSizes[index] = MarkdownPreviewImageLoader.naturalSize(of: image)

            case .codeBlock(let language, let source):
                guard let resolver = inputs.languageResolver else { continue }
                if let cached = cache.highlightedCode(language: language, source: source, theme: inputs.syntaxTheme) {
                    pass.result.highlightedCode[index] = cached
                } else if let highlighted = MarkdownPreviewCodeHighlighter.highlight(
                    source: source,
                    languageHint: language,
                    theme: inputs.syntaxTheme,
                    languageResolver: resolver,
                    languageProvider: inputs.languageProvider
                ) {
                    cache.storeHighlightedCode(highlighted, language: language, source: source, theme: inputs.syntaxTheme)
                    pass.result.highlightedCode[index] = highlighted
                }

            case .mermaid(let source):
                if let cached = cache.mermaid(source: source, context: inputs.mermaidContext) {
                    apply(cached, at: index, to: &pass.result)
                } else {
                    pass.pendingMermaid.append((index, source))
                }

            case .heading, .paragraph, .list, .table, .thematicBreak, .mermaidError, .footnotes:
                continue
            }
        }
        return pass
    }

    /// Renders `pending` diagrams one at a time in document order, storing each in `cache` as it
    /// finishes. Diagrams are not rendered concurrently: BeautifulMermaid shares one ELK layout
    /// engine across calls. Stops early when the task is cancelled; finished diagrams stay cached.
    static func renderMermaid(
        _ pending: [(index: Int, source: String)],
        inputs: MarkdownPreviewRasterInputs,
        cache: MarkdownPreviewRasterCache,
        render: MarkdownPreviewMermaidRender = { source, context, width in
            await MermaidPaintAdapter.render(source: source, mermaidStyle: context, contentWidth: width)
        }
    ) async -> MarkdownPreviewRasterResult {
        var result = MarkdownPreviewRasterResult()
        for (index, source) in pending {
            guard !Task.isCancelled else { break }
            // The same diagram may appear twice, or have been rendered by an overlapping pass.
            if let cached = cache.mermaid(source: source, context: inputs.mermaidContext) {
                apply(cached, at: index, to: &result)
                continue
            }
            let rendered = await render(source, inputs.mermaidContext, inputs.contentWidth)
            let entry = MarkdownPreviewRasterCache.MermaidEntry(
                image: rendered.image,
                naturalSize: rendered.naturalSize,
                errorMessage: rendered.image == nil ? rendered.errorMessage : nil
            )
            cache.storeMermaid(entry, source: source, context: inputs.mermaidContext)
            apply(entry, at: index, to: &result)
        }
        return result
    }

    private static func apply(
        _ entry: MarkdownPreviewRasterCache.MermaidEntry,
        at index: Int,
        to result: inout MarkdownPreviewRasterResult
    ) {
        if let image = entry.image {
            result.images[index] = image
            if let naturalSize = entry.naturalSize {
                result.naturalSizes[index] = naturalSize
            }
        } else if let message = entry.errorMessage {
            result.errors[index] = message
        }
    }
}

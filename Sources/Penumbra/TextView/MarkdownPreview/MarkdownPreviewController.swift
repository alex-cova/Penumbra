@preconcurrency import AppKit

/// Toggles and maintains a rendered markdown preview beside a host ``TextView``.
///
/// Owned by the pane host (Umbra: ``IDEEditorPaneHost``). The preview is offered only when
/// `textView.languageIdentifier == "markdown"`.
@MainActor
public final class MarkdownPreviewController: NSObject {
    public let previewView = MarkdownPreviewView()
    private weak var textView: TextView?
    private let splitView = NSSplitView()
    private var editorContainer: NSView?
    private var isPreviewVisible = false
    private var parseGeneration = 0
    private var parseTask: Task<Void, Never>?
    private var mermaidGeneration = 0
    private var mermaidTask: Task<Void, Never>?
    private var rasterImages: [Int: CGImage] = [:]
    private var highlightedCode: [Int: NSAttributedString] = [:]
    private var previewDelegate: PreviewTextViewDelegate?
    private var chainedTextViewDelegate: ChainedTextViewDelegate?

    /// Base URL for resolving relative markdown image paths (typically the open document's file URL).
    public var documentBaseURL: URL?

    /// Maps a fenced-code language hint (e.g. `"swift"`) to a tree-sitter language for syntax highlighting.
    public var codeBlockLanguageResolver: ((String) -> TreeSitterLanguage?)?

    /// Optional provider for embedded languages inside highlighted code fences.
    public var codeBlockLanguageProvider: TreeSitterLanguageProvider?

    /// Debounce interval before re-parsing after a buffer edit. Tests may shorten this.
    var parseDebounceNanoseconds: UInt64 = 200_000_000

    public var isVisible: Bool { isPreviewVisible }

    public init(textView: TextView) {
        self.textView = textView
        super.init()
        previewView.style = MarkdownPreviewStyle.from(textView: textView)
        previewView.usesMetalRendering = textView.isMetalRenderingActive

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        previewDelegate = PreviewTextViewDelegate(controller: self)
    }

    /// Chains preview text/Metal observation ahead of an existing delegate (e.g. EIP forwarding).
    public func installTextObservation(chaining delegate: TextViewDelegate?) {
        let chained = ChainedTextViewDelegate(primary: previewDelegate, secondary: delegate)
        chainedTextViewDelegate = chained
        textView?.editorDelegate = chained
    }

    /// Chains preview Metal fallback ahead of an existing host handler.
    public func installMetalFailureHandler(chaining handler: ((String) -> Void)?) {
        textView?.onMetalRenderingFailure = { [weak self] reason in
            self?.previewView.usesMetalRendering = false
            handler?(reason)
        }
    }

    /// Embeds `editorView` (typically the pane host's outer container) into a horizontal split.
    public func embed(editorView: NSView) {
        guard editorContainer == nil else { return }
        editorContainer = editorView
        editorView.removeFromSuperview()
        splitView.addArrangedSubview(editorView)
        splitView.addArrangedSubview(previewView)
        previewView.isHidden = true
        splitView.setPosition(1, ofDividerAt: 0)
    }

    public var containerView: NSView { splitView }

    /// Toggles the preview. Returns `false` when the buffer is not markdown.
    @discardableResult
    public func toggle() -> Bool {
        guard textView?.languageIdentifier == "markdown" else { return false }
        if isPreviewVisible {
            hidePreview()
        } else {
            showPreview()
        }
        return true
    }

    public func closeIfNotMarkdown() {
        guard textView?.languageIdentifier != "markdown" else { return }
        hidePreview()
    }

    public func refreshStyle() {
        guard let textView else { return }
        previewView.style = MarkdownPreviewStyle.from(textView: textView)
        previewView.usesMetalRendering = textView.isMetalRenderingActive
        scheduleParse()
    }

    private func showPreview() {
        isPreviewVisible = true
        previewView.isHidden = false
        if let divider = splitView.subviews.firstIndex(of: previewView), divider > 0 {
            let total = splitView.bounds.width
            splitView.setPosition(total * 0.55, ofDividerAt: divider - 1)
        }
        refreshStyle()
        scheduleParse()
    }

    private func hidePreview() {
        isPreviewVisible = false
        previewView.isHidden = true
        parseTask?.cancel()
        mermaidTask?.cancel()
    }

    func noteTextDidChange() {
        guard isPreviewVisible else { return }
        scheduleParse()
    }

    fileprivate func languageDidChange() {
        closeIfNotMarkdown()
        if isPreviewVisible {
            scheduleParse()
        }
    }

    private static func sleepForDebounce(_ nanoseconds: UInt64) async throws {
        if #available(macOS 13.0, *) {
            try await Task.sleep(for: .nanoseconds(Int64(nanoseconds)))
        } else {
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private func scheduleParse() {
        guard isPreviewVisible, let textView else { return }
        parseGeneration += 1
        let generation = parseGeneration
        let source = textView.text
        let style = MarkdownPreviewStyle.from(textView: textView)
        previewView.style = style
        previewView.usesMetalRendering = textView.isMetalRenderingActive

        parseTask?.cancel()
        let debounce = parseDebounceNanoseconds
        parseTask = Task { [weak self] in
            try? await Self.sleepForDebounce(debounce)
            guard !Task.isCancelled else { return }
            let document = await Task.detached(priority: .userInitiated) {
                MarkdownPreviewDocument.parse(source)
            }.value
            guard let self, parseGeneration == generation else { return }
            previewView.document = document
            scheduleRasterLayout(document: document, style: style, generation: generation)
        }
    }

    private func scheduleRasterLayout(
        document: MarkdownPreviewDocument,
        style: MarkdownPreviewStyle,
        generation: Int
    ) {
        mermaidGeneration += 1
        let rasterGen = mermaidGeneration
        mermaidTask?.cancel()

        let mermaidBlocks: [(Int, String)] = document.blocks.enumerated().compactMap { index, block in
            if case .mermaid(let source) = block { return (index, source) }
            return nil
        }
        let imageBlocks: [(Int, String)] = document.blocks.enumerated().compactMap { index, block in
            if case .image(_, let reference) = block { return (index, reference) }
            return nil
        }
        let codeBlocks: [(Int, String?, String)] = document.blocks.enumerated().compactMap { index, block in
            if case .codeBlock(let language, let source) = block { return (index, language, source) }
            return nil
        }

        if mermaidBlocks.isEmpty, imageBlocks.isEmpty, codeBlocks.isEmpty {
            rasterImages = [:]
            highlightedCode = [:]
            previewView.rasterImages = [:]
            previewView.highlightedCode = [:]
            previewView.needsLayout = true
            return
        }

        let contentWidth = max(previewView.bounds.width - style.contentInset * 2, 200)
        let baseURL = documentBaseURL
        let mermaidStyle = style.mermaidRenderingContext
        let work = MarkdownPreviewRasterWork(
            imageBlocks: imageBlocks,
            codeBlocks: codeBlocks,
            mermaidBlocks: mermaidBlocks,
            baseURL: baseURL,
            mermaidStyle: mermaidStyle,
            contentWidth: contentWidth,
            syntaxTheme: UncheckedSendableTheme(value: textView?.theme ?? DefaultTheme()),
            languageResolver: codeBlockLanguageResolver.map(UncheckedLanguageResolver.init),
            languageProvider: UncheckedLanguageProvider(value: codeBlockLanguageProvider)
        )
        mermaidTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await MarkdownPreviewRasterWorker.perform(work)
            await MainActor.run {
                guard let self, self.mermaidGeneration == rasterGen, self.parseGeneration == generation else { return }
                self.rasterImages = result.images
                self.highlightedCode = result.highlightedCode
                self.previewView.rasterImages = result.images
                self.previewView.highlightedCode = result.highlightedCode
                if !result.errors.isEmpty {
                    var blocks = document.blocks
                    for (index, message) in result.errors {
                        if case .mermaid(let source) = blocks[index] {
                            blocks[index] = .mermaidError(source: source, message: message)
                        }
                    }
                    self.previewView.document = MarkdownPreviewDocument(blocks: blocks)
                }
                self.previewView.needsLayout = true
            }
        }
    }
}

private struct RasterWorkResult: @unchecked Sendable {
    let images: [Int: CGImage]
    let highlightedCode: [Int: NSAttributedString]
    let errors: [Int: String]
}

private struct MarkdownPreviewRasterWork: Sendable {
    let imageBlocks: [(Int, String)]
    let codeBlocks: [(Int, String?, String)]
    let mermaidBlocks: [(Int, String)]
    let baseURL: URL?
    let mermaidStyle: MarkdownPreviewStyle.MermaidRenderingContext
    let contentWidth: CGFloat
    let syntaxTheme: UncheckedSendableTheme
    let languageResolver: UncheckedLanguageResolver?
    let languageProvider: UncheckedLanguageProvider
}

/// Read-only `Theme` handle for off-main syntax highlighting.
private struct UncheckedSendableTheme: @unchecked Sendable {
    let value: Theme
}

private struct UncheckedLanguageResolver: @unchecked Sendable {
    let value: (String) -> TreeSitterLanguage?

    init(_ value: @escaping (String) -> TreeSitterLanguage?) {
        self.value = value
    }
}

private struct UncheckedLanguageProvider: @unchecked Sendable {
    let value: TreeSitterLanguageProvider?
}

private enum MarkdownPreviewRasterWorker {
    nonisolated static func perform(_ work: MarkdownPreviewRasterWork) async -> RasterWorkResult {
        var images: [Int: CGImage] = [:]
        var highlightedCode: [Int: NSAttributedString] = [:]
        var errors: [Int: String] = [:]

        for (index, reference) in work.imageBlocks {
            if let image = MarkdownPreviewImageLoader.loadImage(at: reference, baseURL: work.baseURL) {
                images[index] = image
            }
        }
        if let languageResolver = work.languageResolver {
            for (index, language, source) in work.codeBlocks {
                if let highlighted = MarkdownPreviewCodeHighlighter.highlight(
                    source: source,
                    languageHint: language,
                    theme: work.syntaxTheme.value,
                    languageResolver: languageResolver.value,
                    languageProvider: work.languageProvider.value
                ) {
                    highlightedCode[index] = highlighted
                }
            }
        }
        for (index, source) in work.mermaidBlocks {
            let result = await MermaidPaintAdapter.render(
                source: source,
                mermaidStyle: work.mermaidStyle,
                contentWidth: work.contentWidth
            )
            if let image = result.image {
                images[index] = image
            } else if let message = result.errorMessage {
                errors[index] = message
            }
        }

        return RasterWorkResult(images: images, highlightedCode: highlightedCode, errors: errors)
    }
}

@MainActor
private final class PreviewTextViewDelegate: TextViewDelegate {
    weak var controller: MarkdownPreviewController?

    init(controller: MarkdownPreviewController) {
        self.controller = controller
    }

    func textViewDidChange(_ textView: TextView) {
        controller?.noteTextDidChange()
    }
}

@MainActor
private final class ChainedTextViewDelegate: TextViewDelegate {
    weak var primary: TextViewDelegate?
    weak var secondary: TextViewDelegate?

    init(primary: TextViewDelegate?, secondary: TextViewDelegate?) {
        self.primary = primary
        self.secondary = secondary
    }

    func textViewDidChange(_ textView: TextView) {
        primary?.textViewDidChange(textView)
        secondary?.textViewDidChange(textView)
    }

    func textViewDidChangeSelection(_ textView: TextView) {
        primary?.textViewDidChangeSelection(textView)
        secondary?.textViewDidChangeSelection(textView)
    }

    func textViewDidFinishSyntaxParse(_ textView: TextView) {
        primary?.textViewDidFinishSyntaxParse(textView)
        secondary?.textViewDidFinishSyntaxParse(textView)
    }
}

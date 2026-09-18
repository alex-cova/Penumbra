@preconcurrency import AppKit

/// Toggles and maintains a rendered markdown preview that covers a host ``TextView``.
///
/// Owned by the pane host (Umbra: ``IDEEditorPaneHost``). The preview is offered only when
/// `textView.languageIdentifier == "markdown"`. When shown, the preview is layered directly on
/// top of the editor (same frame, via constraints) rather than in a side-by-side split, so
/// toggling it replaces the editor in place instead of splitting the pane.
@MainActor
public final class MarkdownPreviewController: NSObject {
    public let previewView = MarkdownPreviewView()
    private weak var textView: TextView?
    private let containerStack = NSView()
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
    private var editorWasSelectableBeforePreview = true

    /// Base URL for resolving relative markdown image paths (typically the open document's file URL).
    public var documentBaseURL: URL?

    /// Maps a fenced-code language hint (e.g. `"swift"`) to a tree-sitter language for syntax highlighting.
    public var codeBlockLanguageResolver: ((String) -> TreeSitterLanguage?)?

    /// Optional provider for embedded languages inside highlighted code fences.
    public var codeBlockLanguageProvider: TreeSitterLanguageProvider?

    /// Debounce interval before re-parsing after a buffer edit. Tests may shorten this.
    var parseDebounceNanoseconds: UInt64 = 200_000_000

    /// Awaits the debounced parse and the raster/highlight pass currently in flight.
    /// Tests use this instead of sleeping for a fixed interval.
    func waitForPendingWork() async {
        await parseTask?.value
        await mermaidTask?.value
    }

    public var isVisible: Bool { isPreviewVisible }

    public init(textView: TextView) {
        self.textView = textView
        super.init()
        previewView.style = MarkdownPreviewStyle.from(textView: textView)
        previewView.usesMetalRendering = textView.isMetalRenderingActive

        containerStack.translatesAutoresizingMaskIntoConstraints = false

        previewDelegate = PreviewTextViewDelegate(controller: self)
    }

    /// Chains preview text/Metal observation ahead of an existing delegate (e.g. EIP forwarding).
    public func installTextObservation(chaining delegate: TextViewDelegate?) {
        let chained = ChainedTextViewDelegate(primary: previewDelegate, secondary: delegate)
        chainedTextViewDelegate = chained
        textView?.editorDelegate = chained
    }

    /// Chains editor Metal fallback ahead of an existing host handler.
    ///
    /// Oversized preview layouts fall back to Core Graphics locally without invoking the host
    /// handler — only the editor's Metal path should disable rendering workspace-wide.
    public func installMetalFailureHandler(chaining handler: ((String) -> Void)?) {
        textView?.onMetalRenderingFailure = { [weak self] reason in
            self?.previewView.usesMetalRendering = false
            handler?(reason)
        }
    }

    /// Layers `editorView` (typically the pane host's outer container) and the preview into the
    /// same frame, with the preview on top so toggling it covers the editor in place.
    public func embed(editorView: NSView) {
        guard editorContainer == nil else { return }
        editorContainer = editorView
        editorView.removeFromSuperview()
        editorView.translatesAutoresizingMaskIntoConstraints = false
        previewView.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addSubview(editorView)
        containerStack.addSubview(previewView)
        NSLayoutConstraint.activate([
            editorView.topAnchor.constraint(equalTo: containerStack.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor),
            previewView.topAnchor.constraint(equalTo: containerStack.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor)
        ])
        previewView.isHidden = true
    }

    public var containerView: NSView { containerStack }

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

    /// Renders the currently visible preview into PDF data. Returns `nil` when the preview isn't
    /// shown (nothing rendered to export) or the buffer hasn't parsed yet.
    public func exportPDFData() -> Data? {
        guard isPreviewVisible else { return nil }
        return previewView.renderedDocumentPDFData()
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

    /// Re-parses the current buffer when the preview is visible. Document text installed via
    /// `TextView.setState` (e.g. switching tabs) does not route through `textViewDidChange`, so
    /// the host must call this explicitly after loading a different document into `textView` —
    /// otherwise the preview keeps showing the previous file's content until the next keystroke.
    public func refresh() {
        guard isPreviewVisible else { return }
        scheduleParse()
    }

    private func showPreview() {
        isPreviewVisible = true
        // The preview is layered directly on top of the editor in the same frame, but the
        // editor underneath stays live unless we explicitly disable it here — otherwise its
        // (invisible) text remains selectable/focusable while the rendered preview covers it.
        if let textView {
            editorWasSelectableBeforePreview = textView.isSelectable
            textView.isSelectable = false
        }
        previewView.isHidden = false
        refreshStyle()
        scheduleParse()
    }

    private func hidePreview() {
        isPreviewVisible = false
        previewView.isHidden = true
        textView?.isSelectable = editorWasSelectableBeforePreview
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
        try await Task.sleep(for: .nanoseconds(Int64(nanoseconds)))
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
            if case .mermaid(let source) = block.kind { return (index, source) }
            return nil
        }
        let imageBlocks: [(Int, String)] = document.blocks.enumerated().compactMap { index, block in
            if case .image(_, let reference) = block.kind { return (index, reference) }
            return nil
        }
        let codeBlocks: [(Int, String?, String)] = document.blocks.enumerated().compactMap { index, block in
            if case .codeBlock(let language, let source) = block.kind { return (index, language, source) }
            return nil
        }

        if mermaidBlocks.isEmpty, imageBlocks.isEmpty, codeBlocks.isEmpty {
            mermaidTask = nil
            rasterImages = [:]
            highlightedCode = [:]
            previewView.rasterImages = [:]
            previewView.rasterNaturalSizes = [:]
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
                self.previewView.rasterNaturalSizes = result.naturalSizes
                self.previewView.highlightedCode = result.highlightedCode
                if !result.errors.isEmpty {
                    var blocks = document.blocks
                    for (index, message) in result.errors {
                        if case .mermaid(let source) = blocks[index].kind {
                            blocks[index].kind = .mermaidError(source: source, message: message)
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
    let naturalSizes: [Int: CGSize]
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
        var naturalSizes: [Int: CGSize] = [:]
        var highlightedCode: [Int: NSAttributedString] = [:]
        var errors: [Int: String] = [:]

        for (index, reference) in work.imageBlocks {
            if let image = MarkdownPreviewImageLoader.loadImage(at: reference, baseURL: work.baseURL) {
                images[index] = image
                naturalSizes[index] = MarkdownPreviewImageLoader.naturalSize(of: image)
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
                naturalSizes[index] = result.naturalSize
            } else if let message = result.errorMessage {
                errors[index] = message
            }
        }

        return RasterWorkResult(images: images, naturalSizes: naturalSizes, highlightedCode: highlightedCode, errors: errors)
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

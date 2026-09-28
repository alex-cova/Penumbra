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
    private var mermaidTask: Task<Void, Never>?
    private var mermaidWorkTask: Task<MarkdownPreviewRasterResult, Never>?
    /// Rendered diagrams, highlighted fences and decoded images, reused across edits and
    /// document switches.
    private let rasterCache = MarkdownPreviewRasterCache()
    /// Parsed prose chunks of the last parse, so an edit re-parses only what changed.
    private let parseCache = MarkdownPreviewParseCache()
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

    /// Benchmarks only (`@_spi(Benchmarks) import Penumbra`).
    @_spi(Benchmarks)
    public func benchmarkWaitForPendingWork() async {
        await waitForPendingWork()
    }

    @_spi(Benchmarks)
    public var benchmarkParseDebounceNanoseconds: UInt64 {
        get { parseDebounceNanoseconds }
        set { parseDebounceNanoseconds = newValue }
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
        scheduleParse(immediate: true)
    }

    /// Re-parses the current buffer when the preview is visible. Document text installed via
    /// `TextView.setState` (e.g. switching tabs) does not route through `textViewDidChange`, so
    /// the host must call this explicitly after loading a different document into `textView` —
    /// otherwise the preview keeps showing the previous file's content until the next keystroke.
    public func refresh() {
        guard isPreviewVisible else { return }
        scheduleParse(immediate: true)
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
    }

    private func hidePreview() {
        isPreviewVisible = false
        previewView.isHidden = true
        textView?.isSelectable = editorWasSelectableBeforePreview
        parseTask?.cancel()
        cancelMermaidWork()
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

    /// Parses the buffer and shows it. Edits are debounced; showing the preview or switching
    /// documents (`immediate`) is not. The buffer is read once the debounce has elapsed, never per
    /// keystroke. Parsing and every cheap raster (cached diagrams, code fences, images) happen in
    /// one detached step and land in one layout; only uncached mermaid diagrams follow later.
    private func scheduleParse(immediate: Bool = false) {
        guard isPreviewVisible, textView != nil else { return }
        parseGeneration += 1
        let generation = parseGeneration
        parseTask?.cancel()
        cancelMermaidWork()

        let debounce = immediate ? 0 : parseDebounceNanoseconds
        parseTask = Task { [weak self] in
            if debounce > 0 {
                try? await Self.sleepForDebounce(debounce)
            }
            guard !Task.isCancelled, let self, self.parseGeneration == generation, let textView = self.textView else { return }
            let source = textView.text
            let style = MarkdownPreviewStyle.from(textView: textView)
            let inputs = self.rasterInputs(style: style)
            let cache = self.rasterCache
            let parseCache = self.parseCache
            let parsed = await Task.detached(priority: .userInitiated) {
                let document = MarkdownPreviewDocument.parse(source, cache: parseCache)
                let pass = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs, cache: cache)
                return ParsedPreview(document: document, pass: pass)
            }.value
            guard self.parseGeneration == generation else { return }
            self.show(parsed, style: style)
            if !parsed.pass.pendingMermaid.isEmpty {
                self.scheduleMermaid(parsed.pass.pendingMermaid, document: parsed.document, inputs: inputs, generation: generation)
            }
        }
    }

    private func rasterInputs(style: MarkdownPreviewStyle) -> MarkdownPreviewRasterInputs {
        MarkdownPreviewRasterInputs(
            baseURL: documentBaseURL,
            mermaidContext: style.mermaidRenderingContext,
            contentWidth: max(previewView.bounds.width - style.contentInset * 2, 200),
            syntaxTheme: textView?.theme ?? DefaultTheme(),
            languageResolver: codeBlockLanguageResolver,
            languageProvider: codeBlockLanguageProvider
        )
    }

    /// Installs a parse and its resolved rasters in one go (a single relayout). A diagram still
    /// being rendered keeps the previous parse's image for the same block, so editing inside a
    /// fence doesn't collapse it to a placeholder and back.
    private func show(_ parsed: ParsedPreview, style: MarkdownPreviewStyle) {
        var result = parsed.pass.result
        if let previous = previewView.document {
            for (index, _) in parsed.pass.pendingMermaid where index < previous.blocks.count {
                guard case .mermaid = previous.blocks[index].kind, let image = previewView.rasterImages[index] else { continue }
                result.images[index] = image
                result.naturalSizes[index] = previewView.rasterNaturalSizes[index]
            }
        }
        previewView.style = style
        previewView.usesMetalRendering = textView?.isMetalRenderingActive ?? false
        previewView.document = Self.markingErrors(result.errors, in: parsed.document)
        previewView.rasterImages = result.images
        previewView.rasterNaturalSizes = result.naturalSizes
        previewView.highlightedCode = result.highlightedCode
    }

    private func scheduleMermaid(
        _ pending: [(index: Int, source: String)],
        document: MarkdownPreviewDocument,
        inputs: MarkdownPreviewRasterInputs,
        generation: Int
    ) {
        let cache = rasterCache
        let work = Task.detached(priority: .userInitiated) {
            await MarkdownPreviewRasterWorker.renderMermaid(pending, inputs: inputs, cache: cache)
        }
        mermaidWorkTask = work
        // This main-actor task only awaits the detached work, so `self` never crosses into
        // nonisolated code (Swift 6 `SendingRisksDataRace`).
        mermaidTask = Task { [weak self] in
            let rendered = await work.value
            guard let self, self.parseGeneration == generation else { return }
            var images = self.previewView.rasterImages
            var sizes = self.previewView.rasterNaturalSizes
            for (index, _) in pending {
                images[index] = nil
                sizes[index] = nil
            }
            images.merge(rendered.images) { $1 }
            sizes.merge(rendered.naturalSizes) { $1 }
            if !rendered.errors.isEmpty {
                self.previewView.document = Self.markingErrors(rendered.errors, in: self.previewView.document ?? document)
            }
            self.previewView.rasterImages = images
            self.previewView.rasterNaturalSizes = sizes
        }
    }

    private func cancelMermaidWork() {
        mermaidWorkTask?.cancel()
        mermaidWorkTask = nil
        mermaidTask?.cancel()
    }

    private static func markingErrors(_ errors: [Int: String], in document: MarkdownPreviewDocument) -> MarkdownPreviewDocument {
        guard !errors.isEmpty else { return document }
        var blocks = document.blocks
        for (index, message) in errors where index < blocks.count {
            if case .mermaid(let source) = blocks[index].kind {
                blocks[index].kind = .mermaidError(source: source, message: message)
            }
        }
        return MarkdownPreviewDocument(blocks: blocks)
    }
}

private struct ParsedPreview: @unchecked Sendable {
    let document: MarkdownPreviewDocument
    let pass: MarkdownPreviewRasterPass
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

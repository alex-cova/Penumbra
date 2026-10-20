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
    /// The light copies PDF export renders. Separate from `rasterCache`, which holds one code
    /// theme and the on-screen diagrams: sharing it would evict those on every export.
    private let exportRasterCache = MarkdownPreviewRasterCache()
    /// Parsed prose chunks of the last parse, so an edit re-parses only what changed.
    private let parseCache = MarkdownPreviewParseCache()
    private var previewDelegate: PreviewTextViewDelegate?
    private var chainedTextViewDelegate: ChainedTextViewDelegate?
    private var editorWasSelectableBeforePreview = true
    /// The editor's carets when the preview covered it. Making the editor unselectable clears its
    /// selection, so they are put back when the preview closes.
    private var editorSelectionBeforePreview: [NSRange] = []

    /// Base URL for resolving relative markdown image paths (typically the open document's file URL).
    public var documentBaseURL: URL?

    /// Maps a fenced-code language hint (e.g. `"swift"`) to a tree-sitter language for syntax highlighting.
    public var codeBlockLanguageResolver: ((String) -> TreeSitterLanguage?)?

    /// Optional provider for embedded languages inside highlighted code fences.
    public var codeBlockLanguageProvider: TreeSitterLanguageProvider?

    /// A fixed light or dark look for the on-screen preview, whatever the editor theme is; `nil`
    /// follows the editor. Only the preview is affected: PDF export is always light.
    public var appearanceOverride: MarkdownPreviewAppearance? {
        didSet {
            guard appearanceOverride != oldValue else { return }
            applyAppearanceOverride()
        }
    }

    /// Shows a sun/moon button at the preview's top-right corner that flips between the light and
    /// dark look (``appearanceOverride``). Off by default: a host that embeds the preview inline
    /// has no use for it.
    public var showsAppearanceToggle = false {
        didSet { updateAppearanceToggle() }
    }

    /// Called when the user flips the look with the toggle (not when ``appearanceOverride`` is set
    /// in code), so the host can remember the choice.
    public var onAppearanceOverrideChange: ((MarkdownPreviewAppearance?) -> Void)?

    private let appearanceToggle = NSButton()
    /// Test-only hook (`@testable import` visibility).
    var debugAppearanceToggle: NSButton { appearanceToggle }

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
        configureAppearanceToggle()
    }

    private func configureAppearanceToggle() {
        appearanceToggle.translatesAutoresizingMaskIntoConstraints = false
        appearanceToggle.isBordered = false
        appearanceToggle.bezelStyle = .regularSquare
        appearanceToggle.imagePosition = .imageOnly
        appearanceToggle.imageScaling = .scaleProportionallyDown
        appearanceToggle.focusRingType = .none
        appearanceToggle.target = self
        appearanceToggle.action = #selector(toggleAppearance)
        appearanceToggle.wantsLayer = true
        appearanceToggle.layer?.cornerRadius = 6
        appearanceToggle.isHidden = true
    }

    /// The style the preview shows: the editor's, or the fixed look the host asked for.
    private func makeStyle(for textView: TextView) -> MarkdownPreviewStyle {
        let style = MarkdownPreviewStyle.from(textView: textView)
        guard let appearanceOverride else { return style }
        return style.withAppearance(appearanceOverride)
    }

    private func applyAppearanceOverride() {
        previewView.appearance = appearanceOverride.flatMap {
            NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
        }
        refreshStyle()
    }

    @objc private func toggleAppearance() {
        let switchTo: MarkdownPreviewAppearance = isDisplayingDark ? .light : .dark
        appearanceOverride = switchTo
        onAppearanceOverrideChange?(switchTo)
    }

    private var isDisplayingDark: Bool {
        previewView.style.isDark(under: previewView.effectiveAppearance)
    }

    /// Shows the button only while the preview is up, with the icon of the look a click switches to.
    private func updateAppearanceToggle() {
        appearanceToggle.isHidden = !(showsAppearanceToggle && isPreviewVisible)
        let dark = isDisplayingDark
        let symbol = dark ? "sun.max.fill" : "moon.fill"
        let label = dark ? "Switch Preview to Light Mode" : "Switch Preview to Dark Mode"
        appearanceToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        appearanceToggle.toolTip = label
        appearanceToggle.setAccessibilityLabel(label)
        // The button sits on the page, so it takes the page's look rather than the window's.
        appearanceToggle.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearanceToggle.contentTintColor = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1)
        appearanceToggle.layer?.backgroundColor = (dark
            ? NSColor.white.withAlphaComponent(0.1)
            : NSColor.black.withAlphaComponent(0.06)).cgColor
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
        containerStack.addSubview(appearanceToggle)
        NSLayoutConstraint.activate([
            // Clear of the overlay scroller on the right edge.
            appearanceToggle.topAnchor.constraint(equalTo: containerStack.topAnchor, constant: 8),
            appearanceToggle.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor, constant: -18),
            appearanceToggle.widthAnchor.constraint(equalToConstant: 28),
            appearanceToggle.heightAnchor.constraint(equalToConstant: 28),
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

    /// Renders the currently visible preview into PDF data, always in light mode: a white page with
    /// dark text, whatever the editor theme or system appearance. Returns `nil` when the preview
    /// isn't shown (nothing rendered to export) or the buffer hasn't parsed yet.
    ///
    /// The on-screen preview is left alone: diagrams and highlighted code are rendered again with
    /// light colors into `exportRasterCache`, and laid out by a throwaway layout, so nothing the
    /// live preview caches changes. Cached diagrams make a repeat export immediate.
    public func exportPDFData() async -> Data? {
        guard isPreviewVisible, let document = previewView.document else { return nil }
        let style = previewView.style.lightForExport()
        var inputs = rasterInputs(style: style)
        // The shared placeholder's colors are dynamic and have light variants; being one instance,
        // it also lets the export cache hit on the next export.
        inputs.syntaxTheme = DefaultTheme.placeholder
        let work = ExportRasterWork(document: document, inputs: inputs)
        let cache = exportRasterCache
        let raster = await Task.detached(priority: .userInitiated) {
            var pass = MarkdownPreviewRasterWorker.resolve(document: work.document, inputs: work.inputs, cache: cache)
            let rendered = await MarkdownPreviewRasterWorker.renderMermaid(pass.pendingMermaid, inputs: work.inputs, cache: cache)
            pass.result.merge(rendered)
            return pass.result
        }.value
        let exported = Self.markingErrors(raster.errors, in: document)
        return previewView.renderedPDFData(document: exported, style: style, raster: raster)
    }

    public func closeIfNotMarkdown() {
        guard textView?.languageIdentifier != "markdown" else { return }
        hidePreview()
    }

    public func refreshStyle() {
        guard let textView else { return }
        previewView.style = makeStyle(for: textView)
        previewView.usesMetalRendering = textView.isMetalRenderingActive
        updateAppearanceToggle()
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
            editorSelectionBeforePreview = textView.selectedRanges
            textView.isSelectable = false
        }
        previewView.isHidden = false
        refreshStyle()
    }

    private func hidePreview() {
        let wasVisible = isPreviewVisible
        isPreviewVisible = false
        previewView.isHidden = true
        updateAppearanceToggle()
        parseTask?.cancel()
        cancelMermaidWork()
        // Called for every document load too; only a preview that was up changed the editor.
        guard wasVisible, let textView else { return }
        textView.isSelectable = editorWasSelectableBeforePreview
        // Hiding the editor dropped its focus and caret session: bring both back where they were.
        textView.restoreSelectedRanges(editorSelectionBeforePreview)
        editorSelectionBeforePreview = []
        textView.focusTextInput()
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
            let style = self.makeStyle(for: textView)
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
            // A fixed look brings its own code colors: the editor theme's tokens were chosen for
            // the editor's background, which the preview no longer has.
            syntaxTheme: appearanceOverride != nil ? DefaultTheme.placeholder : (textView?.theme ?? DefaultTheme()),
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

private struct ExportRasterWork: @unchecked Sendable {
    let document: MarkdownPreviewDocument
    let inputs: MarkdownPreviewRasterInputs
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

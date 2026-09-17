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
        textView?.editorDelegate = ChainedTextViewDelegate(primary: previewDelegate, secondary: delegate)
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
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled else { return }
            let document = await Task.detached {
                MarkdownPreviewDocument.parse(source)
            }.value
            await MainActor.run {
                guard let self, self.parseGeneration == generation else { return }
                self.previewView.document = document
                self.scheduleRasterLayout(document: document, style: style, generation: generation)
            }
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
        let syntaxTheme = textView?.theme ?? DefaultTheme()
        let languageResolver = codeBlockLanguageResolver
        let languageProvider = codeBlockLanguageProvider
        mermaidTask = Task { [weak self] in
            var images: [Int: CGImage] = [:]
            var code: [Int: NSAttributedString] = [:]
            var errors: [Int: String] = [:]
            for (index, reference) in imageBlocks {
                if let image = MarkdownPreviewImageLoader.loadImage(at: reference, baseURL: baseURL) {
                    images[index] = image
                }
            }
            if let languageResolver {
                for (index, language, source) in codeBlocks {
                    if let highlighted = MarkdownPreviewCodeHighlighter.highlight(
                        source: source,
                        languageHint: language,
                        theme: syntaxTheme,
                        languageResolver: languageResolver,
                        languageProvider: languageProvider
                    ) {
                        code[index] = highlighted
                    }
                }
            }
            for (index, source) in mermaidBlocks {
                let result = await MermaidPaintAdapter.render(source: source, style: style, contentWidth: contentWidth)
                if let image = result.image {
                    images[index] = image
                } else if let message = result.errorMessage {
                    errors[index] = message
                }
            }
            await MainActor.run {
                guard let self, self.mermaidGeneration == rasterGen, self.parseGeneration == generation else { return }
                self.rasterImages = images
                self.highlightedCode = code
                self.previewView.rasterImages = images
                self.previewView.highlightedCode = code
                if !errors.isEmpty {
                    var blocks = document.blocks
                    for (index, message) in errors {
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

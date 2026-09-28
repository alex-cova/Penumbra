@preconcurrency import AppKit

/// Read-only scrollable surface that paints a ``MarkdownPreviewDocument``.
@MainActor
public final class MarkdownPreviewView: NSView {
    private let scrollView = NSScrollView()
    private let contentView = MarkdownPreviewContentView()
    private let metalRenderer = MarkdownPreviewMetalRenderer()
    private var prefersMetal = false
    private var useMetal = false
    /// Measured blocks of the last layout, so a relayout only measures blocks that changed.
    private let measureCache = MarkdownPreviewMeasureCache()
    /// Bumped by every input that affects layout; `layout()` does nothing while it and the
    /// width are unchanged since the last applied layout.
    private var inputGeneration = 0
    private var appliedLayoutKey: (generation: Int, width: CGFloat)?

    public var document: MarkdownPreviewDocument? {
        didSet {
            if let document {
                setAccessibilityValue(document.accessibilityDescriptions.joined(separator: "\n\n"))
            }
            scheduleRelayout()
        }
    }

    public var style: MarkdownPreviewStyle = .init() {
        didSet {
            guard style != oldValue else { return }
            scheduleRelayout()
        }
    }

    public var rasterImages: [Int: CGImage] = [:] {
        didSet { scheduleRelayout() }
    }

    /// Natural (unscaled) point size of each raster image, when known — lets `rasterHeights(for:)`
    /// size a mermaid/image block to its own natural extent instead of always stretching it to
    /// the full content width.
    public var rasterNaturalSizes: [Int: CGSize] = [:] {
        didSet { scheduleRelayout() }
    }

    public var highlightedCode: [Int: NSAttributedString] = [:] {
        didSet { scheduleRelayout() }
    }

    public var usesMetalRendering: Bool {
        get { useMetal }
        set {
            guard prefersMetal != newValue else { return }
            prefersMetal = newValue
            scheduleRelayout()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = style.backgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        metalRenderer.isActive = false

        // Both this container and `contentView` size themselves via explicit `frame`/
        // `setFrameSize` assignments in `applyLayout`, not Auto Layout — leave them
        // frame-driven (the default `translatesAutoresizingMaskIntoConstraints = true`)
        // rather than declaring them as constraint participants with no width/height
        // constraint to actually give them a size.
        //
        // Flipped to match `MarkdownPreviewContentView.isFlipped == true`: the tile grid
        // (`MarkdownPreviewTileGrid.contentRect(for:)`) and `scrollView.documentVisibleRect`
        // both need to agree on "top of document" meaning the same thing, and an unflipped
        // `NSView` document view would otherwise open the scroll view at the bottom of the
        // document and measure scroll position from the bottom.
        let documentView = MarkdownPreviewDocumentContainerView()
        documentView.addSubview(contentView)
        scrollView.documentView = documentView

        addSubview(scrollView)
        // The Metal canvas is a fixed viewport-sized overlay (not part of the scrolling document
        // view) — its drawable stays viewport-sized no matter how tall the document is; scrolling
        // is handled by re-rasterizing/re-blitting tiles for the new visible rect instead of
        // moving the canvas itself.
        addSubview(metalRenderer.view)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown Preview")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollViewDidScroll() {
        metalRenderer.setVisibleRect(scrollView.documentVisibleRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { false }

    /// Test-only hooks (`@testable import` visibility): expose otherwise-private scroll/render
    /// internals so tests can assert on actual presentation and layout geometry rather than only
    /// on `isHidden`/`usesMetalRendering` flags.
    var debugMetalPresentedTileCount: Int { metalRenderer.presentedTileCount }
    var debugMetalRequestedTileCount: Int { metalRenderer.lastRequestedTileCount }
    var debugDocumentView: NSView? { scrollView.documentView }

    /// Benchmarks only (`@_spi(Benchmarks) import Penumbra`): scrolls the preview so its visible
    /// rect starts at `y` and presents synchronously, as a scroll-wheel event would.
    @_spi(Benchmarks)
    public func benchmarkScroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        metalRenderer.presentIfNeeded()
    }

    /// Benchmarks only: forces a layout pass with unchanged inputs.
    @_spi(Benchmarks)
    public func benchmarkForceLayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @_spi(Benchmarks)
    public var benchmarkIsMetalActive: Bool { useMetal }

    /// Benchmarks only: blocks the last layout had to measure (not found in the measure cache).
    @_spi(Benchmarks)
    public var benchmarkMeasureMisses: Int { measureCache.lastMissCount }

    func applyLayout(_ layout: MarkdownPreviewLayout) {
        guard let documentView = scrollView.documentView else { return }
        let size = layout.contentSize
        documentView.setFrameSize(size)
        contentView.frame = CGRect(origin: .zero, size: size)
        contentView.layout = layout
        contentView.style = style
        contentView.rasterImages = rasterImages
        contentView.highlightedCode = highlightedCode
        contentView.needsDisplay = true
        layoutMetalCanvasFrame()

        let shouldUseMetal = prefersMetal && MetalContext.isAvailable
        useMetal = shouldUseMetal
        contentView.isHidden = shouldUseMetal
        metalRenderer.isActive = shouldUseMetal

        if shouldUseMetal {
            // Prime the renderer's visible rect *before* `update()` rebuilds the tile grid: it
            // guards a same-rect no-op and otherwise seeds the very first raster pass with a
            // leftover (or zero) rect that may not intersect the new document at all, presenting
            // zero tiles — a "successful" frame that is nonetheless blank.
            metalRenderer.setVisibleRect(scrollView.documentVisibleRect)
            let succeeded = metalRenderer.update(
                layout: layout,
                style: style,
                rasterImages: rasterImages,
                highlightedCode: highlightedCode
            )
            if !succeeded {
                useMetal = false
                contentView.isHidden = false
                metalRenderer.isActive = false
            }
        }
    }

    /// Sizes the Metal overlay to the scroll view's clip view (the visible viewport), never the
    /// full document — tall documents stay on Metal via tile re-rasterization instead of a
    /// full-content-height drawable.
    private func layoutMetalCanvasFrame() {
        let clipView = scrollView.contentView
        metalRenderer.view.frame = convert(clipView.bounds, from: clipView)
    }

    private func scheduleRelayout() {
        inputGeneration += 1
        needsLayout = true
    }

    /// Layout passes that measured and applied a new layout (not skipped as unchanged).
    private(set) var debugAppliedLayoutCount = 0
    var debugMeasureMisses: Int { measureCache.lastMissCount }

    public override func layout() {
        super.layout()
        layer?.backgroundColor = style.backgroundColor.cgColor
        layoutMetalCanvasFrame()
        guard let document = document else {
            appliedLayoutKey = nil
            contentView.layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
            contentView.isHidden = false
            useMetal = false
            metalRenderer.isActive = false
            metalRenderer.clear()
            return
        }
        let width = max(bounds.width, 1)
        if let applied = appliedLayoutKey, applied.generation == inputGeneration, applied.width == width {
            metalRenderer.presentIfNeeded()
            return
        }
        let layout = computeLayout(document: document, width: width)
        applyLayout(layout)
        appliedLayoutKey = (inputGeneration, width)
        debugAppliedLayoutCount += 1
        // `layerContentsRedrawPolicy = .never` on the Metal canvas means `setNeedsDisplay` alone
        // (from `applyLayout`/`metalRenderer.update`) never reaches `updateLayer()`. This layout
        // pass is the reliable synchronous trigger; scroll/async-raster updates outside of layout
        // fall back to the canvas's own deferred present.
        metalRenderer.presentIfNeeded()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalRenderer.invalidateAllTiles()
        metalRenderer.setVisibleRect(scrollView.documentVisibleRect)
        metalRenderer.presentIfNeeded()
    }

    /// Semantic colors (label, link, separator) resolve differently in light and dark mode, and
    /// the cached typeset text and tiles carry resolved colors.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        measureCache.removeAll()
        metalRenderer.invalidateAllTiles()
        scheduleRelayout()
    }

    /// Renders the full (unclipped) document into a single-page PDF via the same CG drawing path
    /// used on screen, so this reflects what's currently shown regardless of whether the Metal
    /// path is active for live display. `nil` when nothing has been parsed yet.
    func renderedDocumentPDFData() -> Data? {
        guard document != nil else { return nil }
        layoutSubtreeIfNeeded()
        return contentView.dataWithPDF(inside: contentView.bounds)
    }

    /// Natural content size for `document` at `width`, without requiring the view to be laid out
    /// or on-screen. Lets a host that embeds the preview inline (not in its own scrolling pane —
    /// e.g. an auto-sizing chat bubble) size itself to fit before ever displaying the view.
    ///
    /// Uses the view's current `rasterImages`/`rasterNaturalSizes`/`highlightedCode`, so call this
    /// after those are set (or after `waitForPendingWork()`-equivalent host-side rasterization) for
    /// an accurate mermaid/image/code-block height; before that it undercounts unrasterized blocks.
    public func preferredContentSize(forWidth width: CGFloat) -> CGSize {
        guard let document else { return .zero }
        return computeLayout(document: document, width: max(width, 1)).contentSize
    }

    private func computeLayout(document: MarkdownPreviewDocument, width: CGFloat) -> MarkdownPreviewLayout {
        let heights = rasterHeights(for: document, width: width)
        return MarkdownPreviewLayout.layout(
            document: document,
            style: style,
            width: width,
            mermaidHeights: heights.mermaid,
            imageHeights: heights.images,
            highlightedCode: highlightedCode,
            cache: measureCache
        )
    }

    private func rasterHeights(
        for document: MarkdownPreviewDocument,
        width: CGFloat
    ) -> (mermaid: [Int: CGFloat], images: [Int: CGFloat]) {
        var mermaid: [Int: CGFloat] = [:]
        var images: [Int: CGFloat] = [:]
        let contentWidth = max(width - style.contentInset * 2, 1)
        for (index, block) in document.blocks.enumerated() {
            guard let image = rasterImages[index] else { continue }
            let height: CGFloat
            if let natural = rasterNaturalSizes[index], natural.width > 0 {
                // Never upscale past the natural size: display width only shrinks to fit.
                let displayWidth = min(contentWidth, natural.width)
                height = max(displayWidth * (natural.height / natural.width), 80)
            } else {
                let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
                height = max(contentWidth * aspect, 80)
            }
            switch block.kind {
            case .mermaid, .mermaidError:
                mermaid[index] = height
            case .image:
                images[index] = height
            default:
                break
            }
        }
        return (mermaid, images)
    }
}

/// `NSScrollView.documentView` container. Flipped to agree with `MarkdownPreviewContentView`
/// (also flipped) and with `MarkdownPreviewTileGrid`'s top-down tile indexing — an unflipped
/// document view would otherwise open the scroll view at the bottom of the document and measure
/// `documentVisibleRect` from the bottom, handing the Metal renderer the wrong tiles.
@MainActor
private final class MarkdownPreviewDocumentContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class MarkdownPreviewContentView: NSView {
    var layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
    var style = MarkdownPreviewStyle()
    var rasterImages: [Int: CGImage] = [:]
    var highlightedCode: [Int: NSAttributedString] = [:]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MarkdownPreviewCGRenderer.draw(
            layout: layout,
            style: style,
            rasterImages: rasterImages,
            highlightedCode: highlightedCode,
            in: context,
            bounds: bounds,
            clip: dirtyRect
        )
    }
}

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

    /// Whether clicking a rendered mermaid diagram opens it at full size. The preview fits each
    /// diagram to the column, which leaves a large one unreadable.
    public var opensDiagramsOnClick = true {
        didSet { updateDiagramHitAreas() }
    }

    /// Called with the diagram's mermaid source when one is clicked. `nil` opens Penumbra's
    /// zoomable viewer window in the preview's colors.
    public var diagramOpenHandler: ((_ source: String) -> Void)?

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
        documentContainer = documentView
        documentView.onClick = { [weak self] point in self?.diagramClicked(at: point) }

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

    private weak var documentContainer: MarkdownPreviewDocumentContainerView?

    /// The source of the rendered mermaid diagram at `point` (document coordinates), if any.
    /// A diagram still rendering, or one that failed, is not a target.
    func diagramSource(at point: CGPoint) -> String? {
        for blockLayout in contentView.layout.blockLayouts where blockLayout.frame.contains(point) {
            if case .mermaid(let source) = blockLayout.block.kind,
               rasterImage(forMermaidSource: source) != nil {
                return source
            }
            return nil
        }
        return nil
    }

    private func rasterImage(forMermaidSource source: String) -> CGImage? {
        guard let blocks = document?.blocks else { return nil }
        for (index, block) in blocks.enumerated() {
            if case .mermaid(let candidate) = block.kind, candidate == source, let image = rasterImages[index] {
                return image
            }
        }
        return nil
    }

    /// `point` is in document coordinates (the container and content view share them).
    private func diagramClicked(at point: CGPoint) {
        guard opensDiagramsOnClick, let source = diagramSource(at: point) else { return }
        openDiagram(source: source)
    }

    // MARK: - Reveal animation

    static let revealAnimationKey = "penumbra.markdownPreview.reveal"
    /// The scale the page starts at when it appears: larger than the page, which settles down
    /// to full size (Keynote's "Scale Big").
    static let revealStartScale: CGFloat = 1.15

    /// Plays the preview's entrance: the page fades in while it shrinks from
    /// ``revealStartScale`` down to full size around its center, with a slight spring. With
    /// `reduceMotion` it only fades. The model values stay at full opacity and no transform, so
    /// the page is correct the moment the animation ends or is removed.
    public func playRevealAnimation(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard let layer else { return }
        alphaValue = 1
        layer.removeAnimation(forKey: Self.revealAnimationKey)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        if reduceMotion {
            fade.duration = 0.18
            group.animations = [fade]
            group.duration = fade.duration
        } else {
            fade.duration = 0.22
            // AppKit layers anchor at their corner, so the scale is built around the center.
            let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            var start = CATransform3DMakeTranslation(center.x, center.y, 0)
            start = CATransform3DScale(start, Self.revealStartScale, Self.revealStartScale, 1)
            start = CATransform3DTranslate(start, -center.x, -center.y, 0)
            let grow = CASpringAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: start)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.mass = 1
            grow.stiffness = 220
            grow.damping = 20
            grow.initialVelocity = 0
            grow.duration = grow.settlingDuration
            group.animations = [fade, grow]
            group.duration = max(fade.duration, grow.duration)
        }
        layer.add(group, forKey: Self.revealAnimationKey)
    }

    /// Hides the page until ``playRevealAnimation(reduceMotion:)``, so the previous document is
    /// not shown before the entrance.
    func prepareForReveal() {
        layer?.removeAnimation(forKey: Self.revealAnimationKey)
        alphaValue = 0
    }

    /// Plays the entrance at the end of the next layout pass, the one that lays out the
    /// document just installed.
    func revealAfterNextLayout() {
        revealsAfterLayout = true
        needsLayout = true
    }

    private var revealsAfterLayout = false
    /// Test-only hook (`@testable import` visibility).
    var debugRevealsAfterLayout: Bool { revealsAfterLayout }

    private func revealIfLaidOut() {
        guard revealsAfterLayout, document != nil else { return }
        revealsAfterLayout = false
        playRevealAnimation()
    }

    /// Drops a pending or running entrance and shows the page as it is.
    func cancelReveal() {
        revealsAfterLayout = false
        layer?.removeAnimation(forKey: Self.revealAnimationKey)
        alphaValue = 1
    }

    /// Opens `source` the way a click on its diagram does.
    public func openDiagram(source: String) {
        if let diagramOpenHandler {
            diagramOpenHandler(source)
        } else {
            MermaidDiagramViewer.show(source: source, context: style.mermaidRenderingContext)
        }
    }

    /// Pointing-hand cursor and a tooltip over each rendered diagram.
    private func updateDiagramHitAreas() {
        guard let documentContainer else { return }
        var rects: [CGRect] = []
        if opensDiagramsOnClick {
            for blockLayout in contentView.layout.blockLayouts {
                if case .mermaid(let source) = blockLayout.block.kind, rasterImage(forMermaidSource: source) != nil {
                    rects.append(blockLayout.frame)
                }
            }
        }
        documentContainer.setDiagramRects(rects)
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
    var debugContentView: NSView { contentView }

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
        updateDiagramHitAreas()

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
            revealIfLaidOut()
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
        revealIfLaidOut()
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

    /// Renders the full (unclipped) `document` into a single-page PDF with `style` and the given
    /// rasters, always under the light (aqua) appearance, whatever the on-screen preview shows.
    /// Lays the document out afresh at the view's current width with a throwaway measure cache,
    /// so the live layout and its cached typesetting (which hold the on-screen colors) are
    /// untouched. `nil` for an empty layout.
    ///
    /// Draws straight from the layout into a PDF context, via the same CG path used on screen:
    /// while Metal is active `contentView` is hidden, and a hidden view contributes nothing to
    /// `dataWithPDF`, which produced a blank page.
    func renderedPDFData(
        document: MarkdownPreviewDocument,
        style: MarkdownPreviewStyle,
        raster: MarkdownPreviewRasterResult
    ) -> Data? {
        guard let aqua = NSAppearance(named: .aqua) else { return nil }
        let width = max(bounds.width, 1)
        var layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
        aqua.performAsCurrentDrawingAppearance {
            let heights = Self.rasterHeights(
                for: document,
                width: width,
                contentInset: style.horizontalInset(forWidth: width),
                rasterImages: raster.images,
                rasterNaturalSizes: raster.naturalSizes
            )
            layout = MarkdownPreviewLayout.layout(
                document: document,
                style: style,
                width: width,
                mermaidHeights: heights.mermaid,
                imageHeights: heights.images,
                highlightedCode: raster.highlightedCode,
                cache: MarkdownPreviewMeasureCache()
            )
        }
        return pdfData(
            layout: layout,
            style: style,
            rasterImages: raster.images,
            highlightedCode: raster.highlightedCode,
            appearance: aqua
        )
    }

    private func pdfData(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString],
        appearance: NSAppearance
    ) -> Data? {
        let size = layout.contentSize
        guard size.width > 0, size.height > 0 else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        // The layout is top-down (the on-screen content view is flipped).
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        appearance.performAsCurrentDrawingAppearance {
            MarkdownPreviewCGRenderer.draw(
                layout: layout,
                style: style,
                rasterImages: rasterImages,
                highlightedCode: highlightedCode,
                in: context,
                bounds: mediaBox
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
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
        Self.rasterHeights(
            for: document,
            width: width,
            contentInset: style.horizontalInset(forWidth: width),
            rasterImages: rasterImages,
            rasterNaturalSizes: rasterNaturalSizes
        )
    }

    private static func rasterHeights(
        for document: MarkdownPreviewDocument,
        width: CGFloat,
        contentInset: CGFloat,
        rasterImages: [Int: CGImage],
        rasterNaturalSizes: [Int: CGSize]
    ) -> (mermaid: [Int: CGFloat], images: [Int: CGFloat]) {
        var mermaid: [Int: CGFloat] = [:]
        var images: [Int: CGFloat] = [:]
        let contentWidth = max(width - contentInset * 2, 1)
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
private final class MarkdownPreviewDocumentContainerView: NSView, NSViewToolTipOwner {
    override var isFlipped: Bool { true }

    static let diagramToolTip = "Click to open the diagram at full size"

    /// Diagrams that open on click. Kept here, not on the content view, because the content
    /// view is hidden while Metal draws and a hidden view gets no cursor rects or tooltips.
    private var diagramRects: [CGRect] = []

    func setDiagramRects(_ rects: [CGRect]) {
        guard rects != diagramRects else { return }
        diagramRects = rects
        removeAllToolTips()
        for rect in rects {
            // `addToolTip` does not retain its owner. A bridged string owner was freed at once,
            // and AppKit messaged the dead object when the tooltip timer fired (a crash on
            // hover). This view outlives its own tooltips.
            addToolTip(rect, owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        Self.diagramToolTip
    }

    override func resetCursorRects() {
        for rect in diagramRects {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// A single click that ends where it started (in document coordinates). Clicks reach this
    /// view whether the content view is showing (it passes them up) or hidden behind the Metal
    /// canvas (which ignores hits).
    var onClick: ((CGPoint) -> Void)?
    private var mouseDownPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.clickCount == 1 ? convert(event.locationInWindow, from: nil) : nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard let start = mouseDownPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        guard hypot(end.x - start.x, end.y - start.y) <= 4 else { return }
        onClick?(end)
    }
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

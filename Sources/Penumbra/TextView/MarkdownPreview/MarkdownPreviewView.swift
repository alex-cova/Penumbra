@preconcurrency import AppKit

/// Read-only scrollable surface that paints a ``MarkdownPreviewDocument``.
@MainActor
public final class MarkdownPreviewView: NSView {
    private let scrollView = NSScrollView()
    private let contentView = MarkdownPreviewContentView()
    private let metalRenderer = MarkdownPreviewMetalRenderer()
    private var prefersMetal = false
    private var useMetal = false

    public var document: MarkdownPreviewDocument? {
        didSet { scheduleRelayout() }
    }

    public var style: MarkdownPreviewStyle = .init() {
        didSet { scheduleRelayout() }
    }

    public var rasterImages: [Int: CGImage] = [:] {
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

        if let document = document {
            setAccessibilityValue(document.accessibilityDescriptions.joined(separator: "\n\n"))
        }

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
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        layer?.backgroundColor = style.backgroundColor.cgColor
        layoutMetalCanvasFrame()
        guard let document = document else {
            contentView.layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
            contentView.isHidden = false
            useMetal = false
            metalRenderer.isActive = false
            metalRenderer.clear()
            return
        }
        let width = max(bounds.width, 1)
        let heights = rasterHeights(for: document)
        let layout = MarkdownPreviewLayout.layout(
            document: document,
            style: style,
            width: width,
            mermaidHeights: heights.mermaid,
            imageHeights: heights.images,
            highlightedCode: highlightedCode
        )
        applyLayout(layout)
        // `layerContentsRedrawPolicy = .never` on the Metal canvas means `setNeedsDisplay` alone
        // (from `applyLayout`/`metalRenderer.update`) never reaches `updateLayer()`. This layout
        // pass is the reliable synchronous trigger; scroll/async-raster updates outside of layout
        // fall back to the canvas's own deferred present.
        metalRenderer.presentIfNeeded()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalRenderer.invalidateForScaleChange()
        metalRenderer.setVisibleRect(scrollView.documentVisibleRect)
        metalRenderer.presentIfNeeded()
    }

    private func rasterHeights(for document: MarkdownPreviewDocument) -> (mermaid: [Int: CGFloat], images: [Int: CGFloat]) {
        var mermaid: [Int: CGFloat] = [:]
        var images: [Int: CGFloat] = [:]
        let contentWidth = max(bounds.width - style.contentInset * 2, 1)
        for (index, block) in document.blocks.enumerated() {
            guard let image = rasterImages[index] else { continue }
            let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
            let height = max(contentWidth * aspect, 80)
            switch block {
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

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

        contentView.translatesAutoresizingMaskIntoConstraints = false
        metalRenderer.view.translatesAutoresizingMaskIntoConstraints = false
        metalRenderer.isActive = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentView)
        documentView.addSubview(metalRenderer.view)
        scrollView.documentView = documentView

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            metalRenderer.view.topAnchor.constraint(equalTo: documentView.topAnchor),
            metalRenderer.view.leadingAnchor.constraint(equalTo: documentView.leadingAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown Preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { false }

    func applyLayout(_ layout: MarkdownPreviewLayout) {
        guard let documentView = scrollView.documentView else { return }
        let size = layout.contentSize
        documentView.setFrameSize(size)
        contentView.frame = CGRect(origin: .zero, size: size)
        metalRenderer.view.frame = CGRect(origin: .zero, size: size)
        contentView.layout = layout
        contentView.style = style
        contentView.rasterImages = rasterImages
        contentView.highlightedCode = highlightedCode
        contentView.needsDisplay = true

        if let document = document {
            setAccessibilityValue(document.accessibilityDescriptions.joined(separator: "\n\n"))
        }

        let scale = metalRenderer.backingScaleFactor
        let shouldUseMetal = prefersMetal && MarkdownPreviewMetalRenderer.canRasterize(
            contentSize: size,
            scale: scale
        )
        useMetal = shouldUseMetal
        contentView.isHidden = shouldUseMetal
        metalRenderer.isActive = shouldUseMetal

        if shouldUseMetal {
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

    private func scheduleRelayout() {
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        layer?.backgroundColor = style.backgroundColor.cgColor
        guard let document = document else {
            contentView.layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
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
            bounds: bounds
        )
    }
}

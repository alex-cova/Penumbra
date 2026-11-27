@preconcurrency import AppKit

/// Renders a local image file with pinch, scroll-wheel, and keyboard zoom.
///
/// The viewer is an overlay: it sits on top of the pane's editor and must fully occlude it while
/// visible. Two rules keep the covered editor from leaking through:
///
/// 1. The scroll view is opaque (`drawsBackground` + `viewerBackgroundColor`). A transparent
///    scroll view shows the editor behind the image whenever the zoomed image is smaller than
///    the viewport, which is exactly the reported "editor behind the image" bug.
/// 2. The covered editor is made unselectable (and leaves the key-view loop) while the image
///    shows, mirroring the markdown cover preview, JSON diagram, and CSV table overlays. This
///    stops keyboard focus — and with it caret/selection/typing — from landing in the invisible
///    buffer behind the image. Saved values are restored on `hide()`.
///
/// The host assigns `coveredEditor` (the pane's `TextView`) and `viewerBackgroundColor` (the
/// editor color). View transforms (rotate/flip/crop/adjust) live in the Umbra photo editor, not
/// here: this controller is a viewer only.
@MainActor
public final class ImageViewerController: NSObject {
    private let containerStack = NSView()
    private let scrollView = ImageScrollView()
    private let imageView = NSImageView()
    private let errorLabel = NSTextField(labelWithString: "")
    private weak var contentContainer: NSView?
    private var isVisible = false
    private(set) var currentURL: URL?

    /// The editor this viewer covers. Made unselectable while the image shows, restored on hide.
    public weak var coveredEditor: TextView?
    private var editorWasSelectable = true
    private var editorWasInKeyLoop = true

    /// Opaque backdrop painted behind (and around) the image. The host sets this to the editor
    /// color so letterboxing blends with the surrounding UI instead of leaking the covered editor.
    public var viewerBackgroundColor: NSColor = .textBackgroundColor {
        didSet { applyBackgroundColor() }
    }

    /// Fired after every zoom, show, and hide so a toolbar can refresh its readout.
    public var onStateChange: (() -> Void)?

    public var isShowing: Bool { isVisible }

    /// Current zoom as a whole-number percentage (`100` == actual size).
    public var zoomPercent: Int { Int((scrollView.magnification * 100).rounded()) }

    /// The displayed image's point size, for toolbar readouts.
    public var imagePixelSize: CGSize { imageView.image?.size ?? .zero }

    /// The image currently on screen, if any.
    public var currentImage: NSImage? { imageView.image }

    /// One step of the zoom ladder (matches the photo editor's `PhotoViewport.zoomStep`).
    private static let zoomStep: CGFloat = 1.25

    public override init() {
        super.init()
        configureViews()
    }

    /// Layers `contentView` (typically the editor stack) under the image viewer so toggling
    /// visibility swaps between text and image in place.
    public func embed(contentView: NSView) {
        guard contentContainer == nil else { return }
        contentContainer = contentView
        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addSubview(contentView)
        containerStack.addSubview(scrollView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: containerStack.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: containerStack.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor)
        ])
        scrollView.isHidden = true
    }

    public var containerView: NSView { containerStack }

    public func show(url: URL) {
        currentURL = url
        isVisible = true
        scrollView.isHidden = false
        setCoveredEditorEnabled(false)

        if let image = NSImage(contentsOf: url) {
            errorLabel.isHidden = true
            imageView.isHidden = false
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            scrollView.documentView = imageView
            zoomToFit()
        } else {
            imageView.image = nil
            imageView.isHidden = true
            errorLabel.stringValue = "Unable to load image"
            errorLabel.isHidden = false
            scrollView.documentView = errorLabel
            scrollView.magnification = 1
            onStateChange?()
        }
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        currentURL = nil
        scrollView.isHidden = true
        imageView.image = nil
        scrollView.documentView = nil
        setCoveredEditorEnabled(true)
        onStateChange?()
    }

    public func focusForInteraction() {
        scrollView.window?.makeFirstResponder(scrollView)
    }

    public func isShowing(url: URL) -> Bool {
        isVisible && currentURL == url
    }

    // MARK: - Zoom (toolbar + keyboard)

    public func zoomIn() {
        adjustZoom(by: Self.zoomStep)
    }

    public func zoomOut() {
        adjustZoom(by: 1 / Self.zoomStep)
    }

    /// Fits the whole image into the viewport, centered.
    public func zoomToFit() {
        guard let image = imageView.image else { return }
        let imageSize = image.size
        let visibleSize = scrollView.contentView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else {
            scrollView.magnification = 1
            onStateChange?()
            return
        }
        let scale = min(visibleSize.width / imageSize.width, visibleSize.height / imageSize.height)
        scrollView.magnification = min(max(scale, scrollView.minMagnification), scrollView.maxMagnification)
        centerImage()
        onStateChange?()
    }

    /// Actual pixels (100%), centered.
    public func zoomToActualSize() {
        scrollView.magnification = 1
        centerImage()
        onStateChange?()
    }

    /// Fills the viewport (the shorter edge touches), centered.
    public func zoomToFill() {
        guard let image = imageView.image else { return }
        let imageSize = image.size
        let visibleSize = scrollView.contentView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else {
            return
        }
        let scale = max(visibleSize.width / imageSize.width, visibleSize.height / imageSize.height)
        scrollView.magnification = min(max(scale, scrollView.minMagnification), scrollView.maxMagnification)
        centerImage()
        onStateChange?()
    }

    /// Recenters the image at the current zoom.
    public func recenter() {
        centerImage()
        onStateChange?()
    }

    // MARK: - Private

    private func configureViews() {
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.wantsLayer = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        applyBackgroundColor()
        scrollView.onZoomIn = { [weak self] in self?.zoomIn() }
        scrollView.onZoomOut = { [weak self] in self?.zoomOut() }
        scrollView.onResetZoom = { [weak self] in self?.zoomToActualSize() }
        scrollView.onMagnificationChanged = { [weak self] in self?.onStateChange?() }

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter

        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
    }

    private func applyBackgroundColor() {
        containerStack.layer?.backgroundColor = viewerBackgroundColor.cgColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = viewerBackgroundColor
    }

    /// Locks (`enabled == false`) or restores the editor underneath, so keyboard focus, caret,
    /// selection, and typing can never land in the invisible buffer behind the image.
    private func setCoveredEditorEnabled(_ enabled: Bool) {
        guard let editor = coveredEditor else { return }
        if enabled {
            editor.isSelectable = editorWasSelectable
            editor.participatesInKeyViewLoop = editorWasInKeyLoop
        } else {
            editorWasSelectable = editor.isSelectable
            editorWasInKeyLoop = editor.participatesInKeyViewLoop
            editor.isSelectable = false
            editor.participatesInKeyViewLoop = false
        }
    }

    /// Centers the (possibly zoomed) document in the viewport.
    private func centerImage() {
        let documentSize = scrollView.documentView?.frame.size ?? .zero
        let visibleSize = scrollView.contentView.bounds.size
        let scaled = CGSize(width: documentSize.width * scrollView.magnification,
                            height: documentSize.height * scrollView.magnification)
        let origin = NSPoint(
            x: max(0, (scaled.width - visibleSize.width) / 2),
            y: max(0, (scaled.height - visibleSize.height) / 2)
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func adjustZoom(by factor: CGFloat) {
        let next = scrollView.magnification * factor
        scrollView.magnification = min(max(next, scrollView.minMagnification), scrollView.maxMagnification)
        onStateChange?()
    }
}

private final class ImageScrollView: NSScrollView {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onMagnificationChanged: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                onZoomIn?()
                return
            case "-":
                onZoomOut?()
                return
            case "0":
                onResetZoom?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.deltaY > 0 {
                onZoomIn?()
            } else if event.deltaY < 0 {
                onZoomOut?()
            }
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard allowsMagnification else {
            super.magnify(with: event)
            return
        }
        let next = magnification * (1 + event.magnification)
        magnification = min(max(next, minMagnification), maxMagnification)
        onMagnificationChanged?()
    }
}

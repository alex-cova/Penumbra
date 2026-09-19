@preconcurrency import AppKit

/// Renders a local image file with pinch, scroll-wheel, and keyboard zoom.
@MainActor
public final class ImageViewerController: NSObject {
    private let containerStack = NSView()
    private let scrollView = ImageScrollView()
    private let imageView = NSImageView()
    private let errorLabel = NSTextField(labelWithString: "")
    private weak var contentContainer: NSView?
    private var isVisible = false
    private(set) var currentURL: URL?

    public var isShowing: Bool { isVisible }

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

        if let image = NSImage(contentsOf: url) {
            errorLabel.isHidden = true
            imageView.isHidden = false
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            scrollView.documentView = imageView
            fitToVisibleArea()
        } else {
            imageView.image = nil
            imageView.isHidden = true
            errorLabel.stringValue = "Unable to load image"
            errorLabel.isHidden = false
            scrollView.documentView = errorLabel
            scrollView.magnification = 1
        }
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        currentURL = nil
        scrollView.isHidden = true
        imageView.image = nil
        scrollView.documentView = nil
    }

    public func focusForInteraction() {
        scrollView.window?.makeFirstResponder(scrollView)
    }

    public func isShowing(url: URL) -> Bool {
        isVisible && currentURL == url
    }

    private func configureViews() {
        containerStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.onZoomIn = { [weak self] in self?.zoomIn() }
        scrollView.onZoomOut = { [weak self] in self?.zoomOut() }
        scrollView.onResetZoom = { [weak self] in self?.resetZoom() }

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter

        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
    }

    private func fitToVisibleArea() {
        guard let image = imageView.image else { return }
        let imageSize = image.size
        let visibleSize = scrollView.contentView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else {
            scrollView.magnification = 1
            return
        }
        let scale = min(visibleSize.width / imageSize.width, visibleSize.height / imageSize.height, 1)
        scrollView.magnification = max(scale, scrollView.minMagnification)
        scrollView.contentView.scroll(to: .zero)
    }

    private func zoomIn() {
        adjustZoom(by: 1.15)
    }

    private func zoomOut() {
        adjustZoom(by: 1 / 1.15)
    }

    private func resetZoom() {
        scrollView.magnification = 1
        scrollView.contentView.scroll(to: .zero)
    }

    private func adjustZoom(by factor: CGFloat) {
        let next = scrollView.magnification * factor
        scrollView.magnification = min(max(next, scrollView.minMagnification), scrollView.maxMagnification)
    }
}

private final class ImageScrollView: NSScrollView {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?

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
    }
}

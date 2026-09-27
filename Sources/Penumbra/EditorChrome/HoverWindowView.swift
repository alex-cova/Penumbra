@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit hover window that renders a `HoverWindowModel`: Markdown (signatures, Javadoc,
/// code blocks) in a scrollable, selectable text view sized to its content.
@MainActor
public final class HoverWindowView: NSView {
    /// The widest and tallest a hover window gets; longer text scrolls.
    static let maxSize = NSSize(width: 520, height: 320)
    private static let padding: CGFloat = 8
    private static let minWidth: CGFloat = 120

    private var model: HoverWindowModel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    public init(model: HoverWindowModel) {
        self.model = model
        super.init(frame: .zero)
        configure()
        update(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: HoverWindowModel) {
        self.model = model
        textView.textStorage?.setAttributedString(HoverMarkdownRenderer.render(model.contents, isMarkdown: model.isMarkdown))
        textView.scroll(.zero)
    }

    /// The window size that fits `model`'s text, capped at ``maxSize`` (past which it scrolls).
    public static func preferredSize(for model: HoverWindowModel) -> NSSize {
        let text = HoverMarkdownRenderer.render(model.contents, isMarkdown: model.isMarkdown)
        let content = HoverMarkdownRenderer.size(of: text, maxWidth: maxSize.width - padding * 2)
        return NSSize(
            width: min(max(content.width + padding * 2, minWidth), maxSize.width),
            height: min(content.height + padding * 2, maxSize.height)
        )
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    /// The layer's colors are baked to `CGColor` once, so re-resolve them when the appearance changes.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        applyLayerColors()

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Self.padding, height: Self.padding)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

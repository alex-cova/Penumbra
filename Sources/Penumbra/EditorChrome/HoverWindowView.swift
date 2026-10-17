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
    /// Room for the action buttons under the text.
    private static let actionRowHeight: CGFloat = 34

    private var model: HoverWindowModel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let actionStack = NSStackView()
    /// Called with the pressed button's action.
    public var onAction: ((HoverAction) -> Void)?

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
        rebuildActions(model.actions)
        needsLayout = true
    }

    /// The window size that fits `model`'s text, capped at ``maxSize`` (past which it scrolls).
    public static func preferredSize(for model: HoverWindowModel) -> NSSize {
        let text = HoverMarkdownRenderer.render(model.contents, isMarkdown: model.isMarkdown)
        let content = HoverMarkdownRenderer.size(of: text, maxWidth: maxSize.width - padding * 2)
        var height = min(content.height + padding * 2, maxSize.height)
        if !model.actions.isEmpty {
            height = min(height + actionRowHeight, maxSize.height + actionRowHeight)
        }
        return NSSize(
            width: min(max(content.width + padding * 2, minWidth), maxSize.width),
            height: height
        )
    }

    public override func layout() {
        super.layout()
        if model.actions.isEmpty {
            actionStack.isHidden = true
            scrollView.frame = bounds
        } else {
            actionStack.isHidden = false
            let rowHeight = Self.actionRowHeight
            actionStack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
            scrollView.frame = NSRect(x: 0, y: rowHeight, width: bounds.width, height: bounds.height - rowHeight)
        }
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

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.edgeInsets = NSEdgeInsets(top: 0, left: Self.padding, bottom: 0, right: Self.padding)
        actionStack.isHidden = true
        addSubview(actionStack)
    }

    private func rebuildActions(_ actions: [HoverAction]) {
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(actionPressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            actionStack.addArrangedSubview(button)
        }
        actionStack.isHidden = actions.isEmpty
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard model.actions.indices.contains(sender.tag) else { return }
        onAction?(model.actions[sender.tag])
    }

    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

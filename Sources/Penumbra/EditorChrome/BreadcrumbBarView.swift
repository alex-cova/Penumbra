@preconcurrency import AppKit
import EditorIntelligence

/// Horizontal breadcrumb bar showing enclosing symbols at the cursor.
@MainActor
public final class BreadcrumbBarView: NSView {
    public var onSelectSegment: ((BreadcrumbSegment) -> Void)?

    private var model = BreadcrumbBarModel(segments: [])
    private let stackView = NSStackView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: BreadcrumbBarModel) {
        self.model = model
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, segment) in model.segments.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: " › ")
                separator.font = NSFont.systemFont(ofSize: 11)
                separator.textColor = .secondaryLabelColor
                stackView.addArrangedSubview(separator)
            }
            let button = NSButton(title: segment.title, target: self, action: #selector(segmentTapped(_:)))
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 11)
            button.tag = index
            stackView.addArrangedSubview(button)
        }
        invalidateIntrinsicContentSize()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    /// `layer?.backgroundColor` in `configure()` is baked to `CGColor` once, so a dynamic system
    /// color goes stale if the effective appearance changes afterward.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 0
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard model.segments.indices.contains(sender.tag) else {
            return
        }
        onSelectSegment?(model.segments[sender.tag])
    }
}

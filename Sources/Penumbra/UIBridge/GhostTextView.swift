@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit ghost text view that renders a `GhostTextModel`.
@MainActor
public final class GhostTextView: NSView {
    private var model: GhostTextModel

    public init(model: GhostTextModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: GhostTextModel) {
        self.model = model
        setNeedsDisplay(bounds)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        model.text.draw(at: NSPoint(x: 0, y: 0), withAttributes: attributes)
    }
}

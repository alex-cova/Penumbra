@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit completion panel view that renders a `CompletionPanelModel`.
@MainActor
public final class CompletionPanelView: NSView {
    private var model: CompletionPanelModel

    public init(model: CompletionPanelModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: CompletionPanelModel) {
        self.model = model
        setNeedsDisplay(bounds)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let border = NSBezierPath(rect: bounds)
        NSColor.separatorColor.setStroke()
        border.stroke()
        if let first = model.items.first {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
            first.label.draw(at: NSPoint(x: 8, y: bounds.height - 20), withAttributes: attributes)
        }
    }
}

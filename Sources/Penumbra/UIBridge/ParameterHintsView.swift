@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit parameter hints view that renders a `ParameterHintsModel`.
@MainActor
public final class ParameterHintsView: NSView {
    private var model: ParameterHintsModel

    public init(model: ParameterHintsModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: ParameterHintsModel) {
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
        guard model.signatures.indices.contains(model.activeSignature) else {
            return
        }
        let signature = model.signatures[model.activeSignature]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        signature.draw(at: NSPoint(x: 8, y: bounds.height - 18), withAttributes: attributes)
    }
}

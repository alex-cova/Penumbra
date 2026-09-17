@preconcurrency import AppKit
import EditorIntelligence

/// Native AppKit hover window view that renders a `HoverWindowModel`.
@MainActor
public final class HoverWindowView: NSView {
    private var model: HoverWindowModel

    public init(model: HoverWindowModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(model: HoverWindowModel) {
        self.model = model
        setNeedsDisplay(bounds)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        model.contents.draw(in: dirtyRect.insetBy(dx: 8, dy: 8), withAttributes: attributes)
    }
}

@preconcurrency import AppKit

/// Draws an inline completion's extra lines under the caret line, inside the room the
/// layout reserved for them (`LineController.bottomInset`). Click-through: the ghost is
/// display-only, and any caret move dismisses it.
@MainActor
public final class InlineCompletionLinesView: NSView {
    private var lines: [String] = []
    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var textColor: NSColor = .secondaryLabelColor

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The size needed for `lines` in `font`.
    public static func size(of lines: [String], font: NSFont) -> CGSize {
        let width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return CGSize(width: ceil(width), height: ceil(font.lineHeight) * CGFloat(lines.count))
    }

    public func update(lines: [String], font: NSFont, textColor: NSColor) {
        self.lines = lines
        self.font = font
        self.textColor = textColor
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        var y: CGFloat = 0
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attributes)
            y += font.lineHeight
        }
    }
}

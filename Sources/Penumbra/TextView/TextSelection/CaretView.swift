@preconcurrency import AppKit
import CoreText
import Foundation

final class CaretView: EditorView {
    var caretColor: NSColor = .label {
        didSet { setNeedsDisplay() }
    }
    var shape: CaretShape = .bar {
        didSet { setNeedsDisplay() }
    }
    /// The character a block caret covers. Drawn in ``coveredTextColor`` over the fill.
    var coveredText = "" {
        didSet { setNeedsDisplay() }
    }
    var coveredFont: NSFont? {
        didSet { setNeedsDisplay() }
    }
    /// Editor background, so a block caret knocks the glyph out of the fill.
    var coveredTextColor: NSColor = .textBackgroundColor {
        didSet { setNeedsDisplay() }
    }
    /// Baseline measured up from the bottom of the caret rect. Matches the line fragment,
    /// whose typographic box puts the baseline `descent` above its bottom edge.
    var baselineFromBottom: CGFloat = 0 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setNeedsDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {
        caretColor.setFill()
        bounds.fill()
        guard shape == .block, !coveredText.isEmpty, let coveredFont else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: coveredText,
            attributes: [
                .font: coveredFont,
                .foregroundColor: coveredTextColor
            ]
        ))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: baselineFromBottom)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

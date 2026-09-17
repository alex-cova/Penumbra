@preconcurrency import AppKit
import Foundation

/// Draws a thin horizontal rule above each method/function declaration, IntelliJ-style.
///
/// Like `FoldRibbonView`, this view spans the full document content height and scrolls with it, so
/// drawing is scoped to `dirtyRect` — cost is bounded by the separators overlapping the exposed
/// band, not the total count. It carries no glyphs, so it does not need a Metal counterpart; it
/// sits behind the glyph canvas.
final class MethodSeparatorView: UIView {
    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0 {
        didSet { if textContainerInsetTop != oldValue { needsDisplay = true } }
    }
    /// 0-based document rows that get a separator drawn along their top edge.
    var separatorRows: Set<Int> = [] {
        didSet { if separatorRows != oldValue { needsDisplay = true } }
    }
    var separatorColor: UIColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var separatorWidth: CGFloat = 1 {
        didSet { if separatorWidth != oldValue { needsDisplay = true } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let lineManager,
              !separatorRows.isEmpty,
              separatorWidth > 0 else {
            return
        }
        let lineCount = lineManager.lineCount
        context.setFillColor(separatorColor.cgColor)
        for row in separatorRows where row > 0 && row < lineCount {
            let line = lineManager.line(atRow: row)
            guard line.data.lineHeight > 0 else {
                continue
            }
            let y = (textContainerInsetTop + line.yPosition - separatorWidth / 2).rounded()
            let ruleRect = CGRect(x: 0, y: y, width: bounds.width, height: separatorWidth)
            guard ruleRect.maxY >= dirtyRect.minY, ruleRect.minY <= dirtyRect.maxY else {
                continue
            }
            context.fill(ruleRect)
        }
    }
}

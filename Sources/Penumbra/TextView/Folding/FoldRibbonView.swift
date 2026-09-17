@preconcurrency import AppKit
import Foundation

/// The code-folding ribbon shown in the gutter, alongside line numbers. Draws a capsule per
/// foldable region overlapping the currently-drawn rect and toggles the deepest fold under the
/// mouse on click.
///
/// Like `LineNumberView`, this view lives inside `LayoutManager`'s `gutterContainerView` and scrolls
/// with the document (its frame spans the full content height, not just the viewport). Drawing is
/// scoped to `dirtyRect` — AppKit only asks for the currently-exposed band — so cost stays bounded
/// by the number of folds overlapping the visible region rather than the total fold count.
final class FoldRibbonView: UIView {
    weak var lineManager: LineManager?
    weak var foldingController: FoldingController?
    var textContainerInsetTop: CGFloat = 0
    var markerColor: UIColor = .lightGray {
        didSet { needsDisplay = true }
    }
    var collapsedMarkerColor: UIColor = .darkGray {
        didSet { needsDisplay = true }
    }
    var chevronColor: UIColor = .white {
        didSet { needsDisplay = true }
    }

    private var hoveredRow: Int?
    private var trackingArea: NSTrackingArea?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let newHoveredRow = row(atLocalY: point.y)
        if newHoveredRow != hoveredRow {
            hoveredRow = newHoveredRow
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredRow != nil {
            hoveredRow = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(atLocalY: point.y), let fold = foldingController?.deepestFold(atRow: row) else {
            super.mouseDown(with: event)
            return
        }
        foldingController?.toggleCollapse(fold)
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let lineManager, let foldingController else {
            return
        }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1)
        guard minRow <= maxRow else {
            return
        }
        let visibleRows = minRow ... maxRow
        for fold in foldingController.folds where fold.lineRange.overlaps(visibleRows) {
            draw(fold, in: context, lineManager: lineManager)
        }
    }
}

private extension FoldRibbonView {
    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else {
            return nil
        }
        let contentY = max(localY - textContainerInsetTop, 0)
        return lineManager.line(containingYOffset: contentY)?.index
    }

    private func draw(_ fold: FoldRange, in context: CGContext, lineManager: LineManager) {
        guard fold.lineRange.lowerBound < lineManager.lineCount else {
            return
        }
        let startLine = lineManager.line(atRow: fold.lineRange.lowerBound)
        let endRow = min(fold.lineRange.upperBound, lineManager.lineCount - 1)
        let endLine = lineManager.line(atRow: endRow)
        let minY = textContainerInsetTop + startLine.yPosition
        let maxY = textContainerInsetTop + endLine.yPosition + endLine.data.lineHeight
        guard maxY > minY else {
            return
        }
        let isHovered = hoveredRow.map { fold.lineRange.contains($0) } ?? false
        let inset: CGFloat = 1.5
        let rect = CGRect(x: inset, y: minY + inset, width: bounds.width - inset * 2, height: maxY - minY - inset * 2)
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil)
        if fold.isCollapsed {
            context.setFillColor(collapsedMarkerColor.cgColor)
            context.addPath(path)
            context.fillPath()
            drawChevron(in: context, rect: rect)
        } else {
            context.setFillColor(markerColor.withAlphaComponent(isHovered ? 0.9 : 0.55).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawChevron(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setStrokeColor(chevronColor.cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let midX = rect.midX
        let midY = rect.midY
        let halfWidth = min(rect.width, rect.height) * 0.22
        let path = CGMutablePath()
        path.move(to: CGPoint(x: midX - halfWidth, y: midY - halfWidth))
        path.addLine(to: CGPoint(x: midX + halfWidth, y: midY))
        path.addLine(to: CGPoint(x: midX - halfWidth, y: midY + halfWidth))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

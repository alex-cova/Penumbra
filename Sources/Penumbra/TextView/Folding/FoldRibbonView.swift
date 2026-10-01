@preconcurrency import AppKit
import Foundation

/// The code-folding column shown in the gutter, alongside line numbers. Draws a chevron on the
/// header row of each foldable region overlapping the currently-drawn rect and toggles that
/// region on click.
///
/// An expanded region shows `chevron.down` only while the mouse is over the column (the hovered
/// row's chevron is drawn stronger); a collapsed region always shows `chevron.right`, so folded
/// code stays visible without hovering.
///
/// Like `LineNumberView`, this view lives inside `LayoutManager`'s `gutterContainerView` and scrolls
/// with the document (its frame spans the full content height, not just the viewport). Drawing is
/// scoped to `dirtyRect` — AppKit only asks for the currently-exposed band — so cost stays bounded
/// by the number of folds rather than the size of the document.
final class FoldRibbonView: EditorView {
    weak var lineManager: LineManager?
    weak var foldingModel: FoldingModel?
    var textContainerInsetTop: CGFloat = 0
    /// Height of one line fragment; chevrons are centred in a line's first fragment.
    var rowHeight: CGFloat = 17 {
        didSet { needsDisplay = true }
    }
    var chevronColor: NSColor = .lightGray {
        didSet {
            chevronImages = [:]
            needsDisplay = true
        }
    }

    /// The rows of the block the caret is in, marked by a bar along the ribbon's trailing edge.
    var scopeRows: ClosedRange<Int>? {
        didSet {
            if scopeRows != oldValue {
                needsDisplay = true
            }
        }
    }
    var scopeColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    private static let symbolPointSize: CGFloat = 11
    private static let scopeBarWidth: CGFloat = 2
    private static let restingAlpha: CGFloat = 0.55
    private static let collapsedAlpha: CGFloat = 0.85

    private var hoveredRow: Int?
    private var trackingArea: NSTrackingArea?
    private var chevronImages: [String: NSImage] = [:]

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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoveredRow(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredRow(with: event)
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
        guard let row = row(atLocalY: point.y), let fold = fold(withHeaderRow: row) else {
            super.mouseDown(with: event)
            return
        }
        foldingModel?.toggleCollapse(fold)
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let lineManager, lineManager.lineCount > 0, let foldingModel else {
            return
        }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1)
        guard minRow <= maxRow else {
            return
        }
        drawScopeBar(in: dirtyRect, lineManager: lineManager)
        let isRevealed = hoveredRow != nil
        // Regions can share a header row (`{` opening two nested folds): draw one chevron there,
        // collapsed if any of them is.
        var headerRows: [Int: Bool] = [:]
        for fold in foldingModel.regions where (minRow ... maxRow).contains(fold.lineRange.lowerBound) {
            headerRows[fold.lineRange.lowerBound, default: false] = headerRows[fold.lineRange.lowerBound] == true || fold.isCollapsed
        }
        for (row, isCollapsed) in headerRows where isCollapsed || isRevealed {
            drawChevron(atRow: row, isCollapsed: isCollapsed, lineManager: lineManager)
        }
    }
}

private extension FoldRibbonView {
    private func updateHoveredRow(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHoveredRow = row(atLocalY: point.y)
        if newHoveredRow != hoveredRow {
            hoveredRow = newHoveredRow
            needsDisplay = true
        }
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        lineManager?.row(containingYOffset: max(localY - textContainerInsetTop, 0))
    }

    /// The region whose header line is `row`; a collapsed one wins, then the deepest.
    private func fold(withHeaderRow row: Int) -> FoldRegion? {
        var best: FoldRegion?
        for region in foldingModel?.regions ?? [] where region.lineRange.lowerBound == row {
            guard let current = best else {
                best = region
                continue
            }
            if region.isCollapsed != current.isCollapsed {
                if region.isCollapsed {
                    best = region
                }
            } else if region.depth > current.depth {
                best = region
            }
        }
        return best
    }

    private func drawScopeBar(in dirtyRect: CGRect, lineManager: LineManager) {
        guard let scopeRows, scopeRows.lowerBound < lineManager.lineCount else {
            return
        }
        let last = min(scopeRows.upperBound, lineManager.lineCount - 1)
        let top = textContainerInsetTop + lineManager.yPosition(ofRow: scopeRows.lowerBound)
        let bottom = textContainerInsetTop + lineManager.yPosition(ofRow: last) + lineManager.lineInfo(atRow: last).lineHeight
        let bar = CGRect(x: bounds.maxX - Self.scopeBarWidth - 1, y: top, width: Self.scopeBarWidth, height: max(bottom - top, 0))
        guard bar.height > 0, bar.intersects(dirtyRect) else {
            return
        }
        scopeColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: Self.scopeBarWidth / 2, yRadius: Self.scopeBarWidth / 2).fill()
    }

    private func drawChevron(atRow row: Int, isCollapsed: Bool, lineManager: LineManager) {
        guard row < lineManager.lineCount else {
            return
        }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0, let image = chevronImage(isCollapsed: isCollapsed) else {
            return
        }
        let fragmentHeight = min(rowHeight, lineHeight)
        let size = image.size
        let rect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: textContainerInsetTop + lineManager.yPosition(ofRow: row) + (fragmentHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        let alpha: CGFloat
        if isCollapsed {
            alpha = row == hoveredRow ? 1 : Self.collapsedAlpha
        } else {
            alpha = row == hoveredRow ? 1 : Self.restingAlpha
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func chevronImage(isCollapsed: Bool) -> NSImage? {
        let name = isCollapsed ? "chevron.right" : "chevron.down"
        if let cached = chevronImages[name] {
            return cached
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [chevronColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        chevronImages[name] = image
        return image
    }
}

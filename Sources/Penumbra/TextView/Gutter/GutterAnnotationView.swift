@preconcurrency import AppKit
import Foundation

/// The annotation column: one line of small text per block of annotated rows, an optional tint
/// behind each annotation's rows, a tooltip on hover, and clicks and hover reported to the host.
///
/// Like ``GutterLineMarkerView`` it only covers the viewport: its frame is the visible part of the
/// column in document coordinates (`frame.minY` is the document y of its top), so every redraw is
/// bounded by the visible rows.
final class GutterAnnotationView: EditorView, NSViewToolTipOwner {
    static let horizontalPadding: CGFloat = 6
    static let maximumTextWidth: CGFloat = 280

    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    /// Height of one line fragment; text is centred in a line's first fragment.
    var rowHeight: CGFloat = 17
    var store = GutterAnnotationStore()
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }
    var textColor = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    /// Rows of this annotation id are drawn with the selection colour over their tint (the host
    /// sets it while the pointer is over a commit's popover, say). Only repaints.
    var highlightedID: Int? {
        didSet {
            if highlightedID != oldValue { needsDisplay = true }
        }
    }
    var highlightColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) {
        didSet { needsDisplay = true }
    }
    /// A click on an annotated row. Returns whether it was handled; an unhandled click goes on to
    /// the next responder.
    var onClick: ((GutterAnnotationClick) -> Bool)?
    /// The pointer moved onto another annotation (or left the column: `nil`). Fires once per
    /// annotation, not per mouse move.
    var onHover: ((GutterAnnotationClick?) -> Void)?

    private var toolTipTag: NSView.ToolTipTag?
    private var trackingArea: NSTrackingArea?
    private var hoveredID: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var frame: NSRect {
        didSet {
            if frame.size != oldValue.size {
                if let toolTipTag { removeToolTip(toolTipTag) }
                toolTipTag = addToolTip(bounds, owner: self, userData: nil)
            }
            // Scrolling moves the rows under a still pointer: what was hovered is no longer there.
            if frame.minY != oldValue.minY { endHover() }
        }
    }

    /// The width the column needs: the widest of the longest distinct texts, capped.
    static func columnWidth(for annotations: [GutterAnnotation], font: NSFont) -> CGFloat {
        guard !annotations.isEmpty else { return 0 }
        // Measuring every commit of a long history would be wasted work: the widest text is
        // among the longest strings.
        let candidates = annotations.count <= 24
            ? annotations
            : Array(annotations.sorted { $0.displayText.utf16.count > $1.displayText.utf16.count }.prefix(24))
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let widest = candidates.map {
            ($0.displayText as NSString).size(withAttributes: [.font: $0.isEmphasized ? bold : font]).width
        }.max() ?? 0
        return ceil(min(widest, maximumTextWidth)) + horizontalPadding * 2
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let lineManager, lineManager.lineCount > 0, !store.isEmpty else { return }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = min(row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1), store.rowCount - 1)
        guard minRow <= maxRow else { return }
        // Tint and highlight are per row; the text only on a block's first row.
        for row in minRow...maxRow {
            guard let annotation = store.annotation(atRow: row), let rect = rowRect(row: row, lineManager: lineManager) else { continue }
            if let tint = annotation.tint {
                NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha).setFill()
                rect.fill()
            }
            if annotation.id == highlightedID {
                highlightColor.setFill()
                rect.fill()
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let regular: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph
        ]
        var emphasized = regular
        emphasized[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for row in minRow...maxRow where store.startsBlock(atRow: row) {
            guard let annotation = store.annotation(atRow: row), !annotation.text.isEmpty,
                  let rect = textRect(row: row, lineManager: lineManager) else { continue }
            (annotation.displayText as NSString).draw(in: rect, withAttributes: annotation.isEmphasized ? emphasized : regular)
        }
    }

    // MARK: - Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        // A host that follows the pointer shows its own popover instead.
        guard onHover == nil else { return "" }
        guard let row = row(atLocalY: point.y), let annotation = store.annotation(atRow: row) else { return "" }
        return annotation.tooltip
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickable = onClick != nil && annotation(atLocalPoint: point) != nil
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard onHover != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hit(atLocalPoint: point, isSecondary: false, event: nil) else {
            endHover()
            return
        }
        guard hit.annotation.id != hoveredID else { return }
        hoveredID = hit.annotation.id
        onHover?(hit)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        endHover()
    }

    override func mouseDown(with event: NSEvent) {
        click(event, isSecondary: event.modifierFlags.contains(.control)) { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        click(event, isSecondary: true) { super.rightMouseDown(with: event) }
    }

    private func click(_ event: NSEvent, isSecondary: Bool, otherwise: () -> Void) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onClick, let hit = hit(atLocalPoint: point, isSecondary: isSecondary, event: event),
              onClick(hit) else {
            otherwise()
            return
        }
    }

    /// The pointer left the annotations, or the rows moved from under it (a scroll, new annotations).
    func endHover() {
        guard hoveredID != nil else { return }
        hoveredID = nil
        onHover?(nil)
    }

    private func annotation(atLocalPoint point: CGPoint) -> GutterAnnotation? {
        hit(atLocalPoint: point, isSecondary: false, event: nil)?.annotation
    }

    /// The annotation under `point`. Empty space below the last line (the view covers the whole
    /// viewport) is not a row, even though the line lookup clamps to the last one.
    private func hit(atLocalPoint point: CGPoint, isSecondary: Bool, event: NSEvent?) -> GutterAnnotationClick? {
        guard let lineManager, let row = row(atLocalY: point.y), let annotation = store.annotation(atRow: row),
              let rect = rowRect(row: row, lineManager: lineManager),
              point.y >= rect.minY, point.y < rect.maxY else { return nil }
        return GutterAnnotationClick(line: row + 1, annotation: annotation, isSecondary: isSecondary,
                                     event: event, rect: rect, anchorView: self)
    }

    // MARK: - Geometry

    /// The whole line (its first fragment's top to the line's bottom), full column width.
    private func rowRect(row: Int, lineManager: LineManager) -> CGRect? {
        guard row >= 0, row < lineManager.lineCount else { return nil }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0 else { return nil }
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) - frame.minY
        return CGRect(x: 0, y: y, width: bounds.width, height: lineHeight)
    }

    private func textRect(row: Int, lineManager: LineManager) -> CGRect? {
        guard row >= 0, row < lineManager.lineCount else { return nil }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0 else { return nil }
        let fragmentHeight = min(rowHeight, lineHeight)
        let textHeight = font.lineHeight
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) + lineManager.textTopInset(ofRow: row)
            + (fragmentHeight - textHeight) / 2 - frame.minY
        return CGRect(x: Self.horizontalPadding, y: y, width: max(bounds.width - Self.horizontalPadding * 2, 0), height: textHeight)
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        return lineManager.row(containingYOffset: max(localY + frame.minY - textContainerInsetTop, 0))
    }
}

@preconcurrency import AppKit
import Foundation

/// The annotation column: one line of small text per block of annotated rows, with a tooltip on
/// hover.
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
    private var toolTipTag: NSView.ToolTipTag?

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
            guard frame.size != oldValue.size else { return }
            if let toolTipTag { removeToolTip(toolTipTag) }
            toolTipTag = addToolTip(bounds, owner: self, userData: nil)
        }
    }

    /// The width the column needs: the widest of the longest distinct texts, capped.
    static func columnWidth(for annotations: [GutterAnnotation], font: NSFont) -> CGFloat {
        guard !annotations.isEmpty else { return 0 }
        // Measuring every commit of a long history would be wasted work: the widest text is
        // among the longest strings.
        let candidates = annotations.count <= 24
            ? annotations
            : Array(annotations.sorted { $0.text.utf16.count > $1.text.utf16.count }.prefix(24))
        let widest = candidates.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(min(widest, maximumTextWidth)) + horizontalPadding * 2
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let lineManager, lineManager.lineCount > 0, !store.isEmpty else { return }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = min(row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1), store.rowCount - 1)
        guard minRow <= maxRow else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph
        ]
        for row in minRow...maxRow where store.startsBlock(atRow: row) {
            guard let annotation = store.annotation(atRow: row), !annotation.text.isEmpty,
                  let rect = textRect(row: row, lineManager: lineManager) else { continue }
            (annotation.text as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    // MARK: - Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let row = row(atLocalY: point.y), let annotation = store.annotation(atRow: row) else { return "" }
        return annotation.tooltip
    }

    // MARK: - Geometry

    private func textRect(row: Int, lineManager: LineManager) -> CGRect? {
        guard row >= 0, row < lineManager.lineCount else { return nil }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0 else { return nil }
        let fragmentHeight = min(rowHeight, lineHeight)
        let textHeight = font.lineHeight
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) + (fragmentHeight - textHeight) / 2 - frame.minY
        return CGRect(x: Self.horizontalPadding, y: y, width: max(bounds.width - Self.horizontalPadding * 2, 0), height: textHeight)
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        return lineManager.row(containingYOffset: max(localY + frame.minY - textContainerInsetTop, 0))
    }
}

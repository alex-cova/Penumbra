@preconcurrency import AppKit
import Foundation

/// The line-marker column: up to ``maximumSlots`` ``GutterLineMarker`` icons per line, a tooltip
/// on hover and a callback on click.
///
/// Like `FoldRibbonView` it spans the content height and scrolls with the document. `draw(_:)`
/// only visits the markers inside the dirty rect's rows (a binary search into markers sorted by
/// line) and reads positions without line handles, so its cost is bounded by the visible rows.
final class GutterLineMarkerView: UIView {
    nonisolated static let maximumSlots = 2
    static let slotWidth: CGFloat = 14
    static let iconSize: CGFloat = 12

    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    /// Height of one line fragment; icons are centred in a line's first fragment.
    var rowHeight: CGFloat = 17
    var markers: [GutterLineMarker] = [] {
        didSet {
            guard markers != oldValue else { return }
            sortedMarkers = markers.sorted { $0.line == $1.line ? $0.id < $1.id : $0.line < $1.line }
            hoveredMarkerID = nil
            toolTip = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The clicked marker and its icon's rect in this view's coordinates.
    var onMarkerClicked: ((GutterLineMarker, CGRect) -> Void)?

    private var sortedMarkers: [GutterLineMarker] = []
    private var hoveredMarkerID: Int?
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
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (marker(at: point) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hit = marker(at: point)
        (hit != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        guard hit?.marker.id != hoveredMarkerID else { return }
        hoveredMarkerID = hit?.marker.id
        toolTip = hit?.marker.tooltip
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredMarkerID = nil
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = marker(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onMarkerClicked?(hit.marker, hit.rect)
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let lineManager, lineManager.lineCount > 0,
              !sortedMarkers.isEmpty else { return }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1)
        guard minRow <= maxRow else { return }
        var index = Self.firstIndex(in: sortedMarkers, atOrAfterLine: minRow + 1)
        while index < sortedMarkers.count, sortedMarkers[index].line <= maxRow + 1 {
            let line = sortedMarkers[index].line
            var slot = 0
            while index < sortedMarkers.count, sortedMarkers[index].line == line {
                if slot < Self.maximumSlots, let rect = iconRect(line: line, slot: slot, lineManager: lineManager) {
                    GutterLineMarkerGlyphs.draw(sortedMarkers[index].icon, in: rect, context: context)
                }
                slot += 1
                index += 1
            }
        }
    }

    // MARK: - Geometry

    /// The marker under `point` and its icon rect.
    func marker(at point: CGPoint) -> (marker: GutterLineMarker, rect: CGRect)? {
        guard let lineManager, let row = row(atLocalY: point.y) else { return nil }
        let line = row + 1
        var index = Self.firstIndex(in: sortedMarkers, atOrAfterLine: line)
        var slot = 0
        while index < sortedMarkers.count, sortedMarkers[index].line == line, slot < Self.maximumSlots {
            if let rect = iconRect(line: line, slot: slot, lineManager: lineManager),
               rect.insetBy(dx: -1, dy: -2).contains(point) {
                return (sortedMarkers[index], rect)
            }
            slot += 1
            index += 1
        }
        return nil
    }

    private func iconRect(line: Int, slot: Int, lineManager: LineManager) -> CGRect? {
        let row = line - 1
        guard row >= 0, row < lineManager.lineCount else { return nil }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0 else { return nil }
        let fragmentHeight = min(rowHeight, lineHeight)
        let size = Self.iconSize
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) + (fragmentHeight - size) / 2
        let x = CGFloat(slot) * Self.slotWidth + (Self.slotWidth - size) / 2
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        return lineManager.row(containingYOffset: max(localY - textContainerInsetTop, 0))
    }

    /// Index of the first marker whose line is at least `line`.
    static func firstIndex(in markers: [GutterLineMarker], atOrAfterLine line: Int) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].line < line { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

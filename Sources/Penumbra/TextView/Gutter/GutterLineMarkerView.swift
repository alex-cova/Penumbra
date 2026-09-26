@preconcurrency import AppKit
import Foundation

/// The line-marker column: up to ``maximumSlots`` ``GutterLineMarker`` icons per line, a tooltip
/// on hover and a callback on click.
///
/// Like IntelliJ's gutter it only ever covers the viewport: its frame is the visible part of the
/// gutter column (in document coordinates, so `frame.minY` is the document y of its top), and a
/// redraw — after scrolling, an edit or new markers — paints the visible rows' markers, found by a
/// binary search into the ``GutterLineMarkerStore``, without line handles.
final class GutterLineMarkerView: UIView {
    nonisolated static let maximumSlots = 2
    static let slotWidth: CGFloat = 14
    static let iconSize: CGFloat = 12

    weak var lineManager: LineManager?
    var textContainerInsetTop: CGFloat = 0
    /// Height of one line fragment; icons are centred in a line's first fragment.
    var rowHeight: CGFloat = 17
    /// Shared with the layout manager, which moves the markers through edits.
    var store = GutterLineMarkerStore()
    /// Replaces the store's markers (tests and hosts without a layout manager).
    var markers: [GutterLineMarker] {
        get { store.markers }
        set {
            store.replace(with: newValue)
            markersDidChange()
        }
    }
    /// The clicked marker and its icon's rect in this view's coordinates.
    var onMarkerClicked: ((GutterLineMarker, CGRect) -> Void)?

    private var sortedMarkers: [GutterLineMarker] {
        store.markers
    }
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

    /// The markers were replaced or moved: repaint the visible rows and drop the hover state.
    func markersDidChange() {
        hoveredMarkerID = nil
        toolTip = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) + (fragmentHeight - size) / 2 - frame.minY
        let x = CGFloat(slot) * Self.slotWidth + (Self.slotWidth - size) / 2
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func row(atLocalY localY: CGFloat) -> Int? {
        guard let lineManager else { return nil }
        return lineManager.row(containingYOffset: max(localY + frame.minY - textContainerInsetTop, 0))
    }

    private static func firstIndex(in markers: [GutterLineMarker], atOrAfterLine line: Int) -> Int {
        GutterLineMarkerStore.firstIndex(in: markers, atOrAfterLine: line)
    }
}

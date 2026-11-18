@preconcurrency import AppKit
import Foundation

/// The line-marker column: up to ``maximumSlots`` ``GutterLineMarker`` icons per line, a tooltip
/// on hover and a callback on click. ``GutterDecoration``s placed here (run buttons) take a line's
/// place from its markers.
///
/// Like IntelliJ's gutter it only ever covers the viewport: its frame is the visible part of the
/// gutter column (in document coordinates, so `frame.minY` is the document y of its top), and a
/// redraw — after scrolling, an edit or new markers — paints the visible rows' markers, found by a
/// binary search into the ``GutterLineMarkerStore``, without line handles.
final class GutterLineMarkerView: EditorView {
    nonisolated static let maximumSlots = 1
    static let slotWidth: CGFloat = 16
    static let iconSize: CGFloat = 14

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
    /// Sorted by line; only the first one on a line is shown, in place of the line's markers.
    var decorations: [GutterDecoration] = [] {
        didSet {
            if decorations != oldValue { markersDidChange() }
        }
    }
    /// A click on a decoration, with its 1-based line.
    var onDecorationClicked: ((Int) -> Void)?
    /// A secondary click on a decoration. Returns whether it was handled.
    var onGutterLineClicked: ((GutterLineClick) -> Bool)?
    var decorationColor: NSColor = .systemGreen

    private enum HoverTarget: Equatable {
        case marker(id: Int)
        case decoration(line: Int)
    }

    private var sortedMarkers: [GutterLineMarker] {
        store.markers
    }
    private var hoveredTarget: HoverTarget?
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
        hoveredTarget = nil
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
        (hoverTarget(at: point) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hit = hoverTarget(at: point)
        (hit != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        guard hit?.target != hoveredTarget else { return }
        hoveredTarget = hit?.target
        toolTip = hit?.toolTip
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredTarget = nil
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let decoration = decoration(at: point) {
            if event.modifierFlags.contains(.control) {
                if onGutterLineClicked?(GutterLineClick(line: decoration.line, isSecondary: true, event: event, decoration: decoration)) != true {
                    super.mouseDown(with: event)
                }
            } else if let onDecorationClicked {
                onDecorationClicked(decoration.line)
            } else {
                super.mouseDown(with: event)
            }
            return
        }
        guard let hit = marker(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onMarkerClicked?(hit.marker, hit.rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let decoration = decoration(at: point),
              onGutterLineClicked?(GutterLineClick(line: decoration.line, isSecondary: true, event: event, decoration: decoration)) == true else {
            super.rightMouseDown(with: event)
            return
        }
    }

    private func hoverTarget(at point: CGPoint) -> (target: HoverTarget, toolTip: String)? {
        if let decoration = decoration(at: point) {
            return (.decoration(line: decoration.line), decoration.accessibilityLabel)
        }
        if let hit = marker(at: point) {
            return (.marker(id: hit.marker.id), hit.marker.tooltip)
        }
        return nil
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let lineManager, lineManager.lineCount > 0,
              !(sortedMarkers.isEmpty && decorations.isEmpty) else { return }
        let minRow = row(atLocalY: dirtyRect.minY) ?? 0
        let maxRow = row(atLocalY: dirtyRect.maxY) ?? (lineManager.lineCount - 1)
        guard minRow <= maxRow else { return }
        var decorationIndex = Self.firstDecorationIndex(in: decorations, atOrAfterLine: minRow + 1)
        while decorationIndex < decorations.count, decorations[decorationIndex].line <= maxRow + 1 {
            let decoration = decorations[decorationIndex]
            if let rect = iconRect(line: decoration.line, slot: 0, lineManager: lineManager) {
                decoration.drawIcon(in: rect, defaultColor: decorationColor)
            }
            while decorationIndex < decorations.count, decorations[decorationIndex].line == decoration.line {
                decorationIndex += 1
            }
        }
        var index = Self.firstIndex(in: sortedMarkers, atOrAfterLine: minRow + 1)
        while index < sortedMarkers.count, sortedMarkers[index].line <= maxRow + 1 {
            let line = sortedMarkers[index].line
            let isDecorated = decoration(onLine: line) != nil
            var slot = 0
            let runLengthOnLine = runLength(from: index, line: line)
            while index < sortedMarkers.count, sortedMarkers[index].line == line {
                if !isDecorated, slot < Self.maximumSlots, let rect = iconRect(line: line, slot: slot, lineManager: lineManager) {
                    // Markers beyond the slot are not dropped silently: the count says how many share the line.
                    let marker = sortedMarkers[index]
                    GutterLineMarkerGlyphs.draw(marker, count: max(marker.stackCount, runLengthOnLine), in: rect, context: context)
                }
                slot += 1
                index += 1
            }
        }
    }

    /// How many markers the store holds on `line`, starting at `start`.
    private func runLength(from start: Int, line: Int) -> Int {
        var end = start
        while end < sortedMarkers.count, sortedMarkers[end].line == line { end += 1 }
        return end - start
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { false }

    /// One button per marker in the visible rows, so VoiceOver can reach and press what the gutter draws.
    override func accessibilityChildren() -> [Any]? {
        guard let lineManager, let window else { return nil }
        let first = row(atLocalY: visibleRect.minY) ?? 0
        let last = row(atLocalY: visibleRect.maxY) ?? max(lineManager.lineCount - 1, 0)
        var elements: [NSAccessibilityElement] = []
        var index = Self.firstIndex(in: sortedMarkers, atOrAfterLine: first + 1)
        while index < sortedMarkers.count, sortedMarkers[index].line <= last + 1 {
            let marker = sortedMarkers[index]
            let line = marker.line
            let count = max(marker.stackCount, runLength(from: index, line: line))
            if decoration(onLine: line) == nil, let rect = iconRect(line: line, slot: 0, lineManager: lineManager) {
                let element = GutterMarkerAccessibilityElement()
                let label = marker.symbol?.accessibilityLabel ?? GutterLineMarkerGlyphs.accessibilityLabel(for: marker.icon)
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(count > 1 ? "\(label), \(count) markers on line \(line)" : "\(label), line \(line)")
                element.setAccessibilityHelp(marker.tooltip)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rect)
                let screen = window.convertToScreen(convert(rect, to: nil))
                element.setAccessibilityFrame(screen)
                element.setAccessibilityActivationPoint(CGPoint(x: screen.midX, y: screen.midY))
                let captured = marker
                element.onPress = { [weak self] in self?.onMarkerClicked?(captured, rect) }
                elements.append(element)
            }
            while index < sortedMarkers.count, sortedMarkers[index].line == line { index += 1 }
        }
        return elements
    }

    // MARK: - Geometry

    /// The marker under `point` and its icon rect. A decorated line's markers are not shown.
    func marker(at point: CGPoint) -> (marker: GutterLineMarker, rect: CGRect)? {
        guard let lineManager, let row = row(atLocalY: point.y) else { return nil }
        let line = row + 1
        guard decoration(onLine: line) == nil else { return nil }
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

    /// The decoration under `point`.
    func decoration(at point: CGPoint) -> GutterDecoration? {
        guard let lineManager, let row = row(atLocalY: point.y),
              let decoration = decoration(onLine: row + 1),
              let rect = iconRect(line: row + 1, slot: 0, lineManager: lineManager),
              rect.insetBy(dx: -1, dy: -2).contains(point) else { return nil }
        return decoration
    }

    private func decoration(onLine line: Int) -> GutterDecoration? {
        let index = Self.firstDecorationIndex(in: decorations, atOrAfterLine: line)
        return index < decorations.count && decorations[index].line == line ? decorations[index] : nil
    }

    private func iconRect(line: Int, slot: Int, lineManager: LineManager) -> CGRect? {
        let row = line - 1
        guard row >= 0, row < lineManager.lineCount else { return nil }
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        // A line inside a collapsed fold has no height.
        guard lineHeight > 0 else { return nil }
        let fragmentHeight = min(rowHeight, lineHeight)
        let size = Self.iconSize
        let y = textContainerInsetTop + lineManager.yPosition(ofRow: row) + lineManager.textTopInset(ofRow: row)
            + (fragmentHeight - size) / 2 - frame.minY
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

    private static func firstDecorationIndex(in decorations: [GutterDecoration], atOrAfterLine line: Int) -> Int {
        var low = 0
        var high = decorations.count
        while low < high {
            let middle = (low + high) / 2
            if decorations[middle].line < line {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// A marker as an accessibility button; pressing it does what clicking the icon does.
private final class GutterMarkerAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

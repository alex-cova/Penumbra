@preconcurrency import AppKit
import Foundation

/// A full-width band behind whole lines, for example a diff viewer's added and removed lines.
///
/// Set through ``TextView/lineBackgrounds``. A band with a `lineCount` of zero is drawn as a thin
/// rule along the top edge of `line`: the place where the other side of a diff has lines this
/// side does not.
public struct LineBackground: Equatable, Sendable {
    /// 1-based first line.
    public var line: Int
    /// Lines the band covers. Zero draws a rule at the top of `line`.
    public var lineCount: Int
    public let color: CGColor

    public init(line: Int, lineCount: Int, color: CGColor) {
        self.line = line
        self.lineCount = max(0, lineCount)
        self.color = color
    }

    /// 0-based rows `[firstRow, endRow)`; empty for a rule.
    var firstRow: Int { line - 1 }
    var endRow: Int { line - 1 + lineCount }
}

/// The bands of ``TextView/lineBackgrounds``, sorted by line, kept on their lines while the text is
/// edited until the host sends fresh ones. Like ``GutterLineMarkerStore``, an edit costs the
/// caller's constant number of line lookups plus shifting the bands below it.
final class LineBackgroundStore {
    private(set) var bands: [LineBackground] = []

    var isEmpty: Bool {
        bands.isEmpty
    }

    func replace(with newBands: [LineBackground]) {
        let isSorted = zip(newBands, newBands.dropFirst()).allSatisfy { $0.line <= $1.line }
        bands = isSorted ? newBands : newBands.sorted { $0.line < $1.line }
    }

    /// Moves the bands through `edit`. Returns whether any band moved, shrank or grew.
    @discardableResult
    func applyEdit(_ edit: GutterLineMarkerEdit) -> Bool {
        let first = firstIndex(endingAfterRow: edit.startRow)
        guard first < bands.count else {
            return false
        }
        let endRow = edit.startRow + edit.removedRows
        var didChange = false
        for index in first ..< bands.count {
            let band = bands[index]
            let start = Self.newRow(forStart: band.firstRow, edit: edit, endRow: endRow)
            let end = max(start, Self.newRow(forEnd: band.endRow, edit: edit, endRow: endRow))
            let moved = LineBackground(line: start + 1, lineCount: end - start, color: band.color)
            if moved != band {
                bands[index] = moved
                didChange = true
            }
        }
        return didChange
    }

    /// Bands that can touch rows `firstRow ... lastRow`, in order.
    func bands(intersectingRows firstRow: Int, _ lastRow: Int) -> ArraySlice<LineBackground> {
        let start = firstIndex(endingAfterRow: firstRow)
        var end = start
        while end < bands.count, bands[end].firstRow <= lastRow {
            end += 1
        }
        return bands[start ..< end]
    }

    /// The first band whose rows (or rule) reach past `row`. Bands do not overlap, so their ends
    /// are sorted like their starts.
    private func firstIndex(endingAfterRow row: Int) -> Int {
        var low = 0
        var high = bands.count
        while low < high {
            let mid = (low + high) / 2
            if max(bands[mid].endRow, bands[mid].firstRow + 1) <= row {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func newRow(forStart row: Int, edit: GutterLineMarkerEdit, endRow: Int) -> Int {
        if row <= edit.startRow { return row }
        if row > endRow { return row + edit.lineDelta }
        return edit.startRow + edit.insertedRows
    }

    private static func newRow(forEnd row: Int, edit: GutterLineMarkerEdit, endRow: Int) -> Int {
        if row <= edit.startRow { return row }
        if row > endRow { return row + edit.lineDelta }
        return edit.startRow + edit.insertedRows + 1
    }
}

/// One band, ready to paint: a content-space rect and its color.
struct LineBackgroundFill: Equatable {
    var frame: CGRect
    var color: CGColor
}

/// Paints ``LineBackgroundStore`` bands behind the text when Core Graphics is the paint backend.
/// When Metal paints, the opaque canvas covers this view and `LayoutManager` replays
/// ``fills(clip:)`` into the canvas underlay, like the method separators.
final class LineBackgroundView: EditorView {
    weak var lineManager: LineManager?
    let store = LineBackgroundStore()
    var textContainerInsetTop: CGFloat = 0 {
        didSet { if textContainerInsetTop != oldValue { needsDisplay = true } }
    }
    /// Height of the rule drawn for a band with no lines.
    static let ruleThickness: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Content-space fills for the bands that reach into `clip`. Only rows inside `clip` are
    /// looked up, so a pass costs the visible rows, not the band count.
    func fills(clip: CGRect) -> [LineBackgroundFill] {
        guard let lineManager, !store.isEmpty, bounds.width > 0 else {
            return []
        }
        let lineCount = lineManager.lineCount
        guard lineCount > 0 else {
            return []
        }
        let firstRow = lineManager.row(containingYOffset: clip.minY - textContainerInsetTop - Self.ruleThickness) ?? 0
        let lastRow = (lineManager.row(containingYOffset: clip.maxY - textContainerInsetTop + Self.ruleThickness) ?? lineCount - 1) + 1
        var fills: [LineBackgroundFill] = []
        for band in store.bands(intersectingRows: firstRow, lastRow) {
            let startRow = min(max(band.firstRow, 0), lineCount)
            let minY = y(atRowStart: startRow, lineManager: lineManager, lineCount: lineCount)
            let rect: CGRect
            if band.lineCount == 0 {
                rect = CGRect(x: 0, y: (minY - Self.ruleThickness / 2).rounded(), width: bounds.width, height: Self.ruleThickness)
            } else {
                let endRow = min(max(band.endRow, startRow), lineCount)
                let maxY = y(atRowStart: endRow, lineManager: lineManager, lineCount: lineCount)
                guard maxY > minY else { continue }
                rect = CGRect(x: 0, y: minY, width: bounds.width, height: maxY - minY)
            }
            guard rect.maxY >= clip.minY, rect.minY <= clip.maxY else { continue }
            fills.append(LineBackgroundFill(frame: rect, color: band.color))
        }
        return fills
    }

    /// Top of `row` in content space; `lineCount` is the bottom of the last line.
    private func y(atRowStart row: Int, lineManager: LineManager, lineCount: Int) -> CGFloat {
        if row >= lineCount {
            let last = lineCount - 1
            return textContainerInsetTop + lineManager.yPosition(ofRow: last) + lineManager.lineInfo(atRow: last).lineHeight
        }
        return textContainerInsetTop + lineManager.yPosition(ofRow: row)
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        for fill in fills(clip: dirtyRect) {
            context.setFillColor(fill.color)
            context.fill(fill.frame)
        }
    }
}

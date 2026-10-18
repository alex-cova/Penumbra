import CoreGraphics
import Foundation

/// Where a scrollbar or minimap hover maps, and which lines the preview shows.
///
/// Pure values so the mapping can be tested without a window. The hovered line is the anchor.
/// The popup shows up to five visible lines on either side of it. A click jumps to the first of
/// those lines, the one at the top of the popup.
/// A pointer position on the scrollbar or the minimap, in the text view's coordinates.
struct EditorFragmentHit {
    /// Document row under the pointer.
    var anchorRow: Int
    /// The pointer is on the knob, the minimap indicator, or a line already in the viewport.
    var isOnScreen: Bool
    /// The strip the pointer is over, used to place the popup against its leading edge.
    var stripFrame: CGRect
}

struct EditorFragmentPreview {
    /// Visible lines kept on either side of the anchor.
    static let linesAround = 5
    /// How far a search may walk through collapsed (zero-height) rows in one direction.
    static let collapsedScanLimit = 64
    /// Characters kept from one line. A minified line must not become an attributed string.
    static let maximumLineLength = 500
    /// Rows a scroll-wheel notch may walk, collapsed lines included.
    static let wheelScanLimit = 256

    struct RowWindow: Equatable {
        /// Document rows in display order. The first is the line a click jumps to.
        var rows: [Int]
        /// The hovered row, or the nearest visible row when the hover landed in a collapsed run.
        var anchorRow: Int
    }

    /// Lines around `anchorRow`, skipping rows whose height is 0. Empty when nothing visible is
    /// within ``collapsedScanLimit`` rows of the anchor.
    static func rowWindow(anchorRow: Int, lineCount: Int, lineHeight: (Int) -> CGFloat) -> RowWindow {
        guard lineCount > 0 else {
            return RowWindow(rows: [], anchorRow: 0)
        }
        let anchor = min(max(anchorRow, 0), lineCount - 1)
        guard let center = visibleRow(near: anchor, lineCount: lineCount, lineHeight: lineHeight) else {
            return RowWindow(rows: [], anchorRow: anchor)
        }
        let before = collect(from: center, direction: -1, lineCount: lineCount, lineHeight: lineHeight)
        let after = collect(from: center, direction: 1, lineCount: lineCount, lineHeight: lineHeight)
        return RowWindow(rows: before.reversed() + [center] + after, anchorRow: center)
    }

    /// Moves `steps` visible rows from `anchor` (negative steps move toward the start). The walk
    /// stops at the document ends and after ``wheelScanLimit`` rows.
    static func row(from anchor: Int, movingBy steps: Int, lineCount: Int, lineHeight: (Int) -> CGFloat) -> Int {
        guard lineCount > 0 else {
            return 0
        }
        var row = min(max(anchor, 0), lineCount - 1)
        guard steps != 0 else {
            return row
        }
        var remaining = min(abs(steps), wheelScanLimit)
        let direction = steps > 0 ? 1 : -1
        var scanned = 0
        while remaining > 0, scanned < wheelScanLimit {
            let next = row + direction
            if next < 0 || next >= lineCount {
                break
            }
            row = next
            scanned += 1
            if lineHeight(row) > 0 {
                remaining -= 1
            }
        }
        return row
    }

    /// A line is on screen when its top lies in the visible content rect.
    static func isOnScreen(lineTop: CGFloat, visibleTop: CGFloat, visibleHeight: CGFloat) -> Bool {
        lineTop >= visibleTop && lineTop < visibleTop + visibleHeight
    }

    /// `contentOffset.y` that puts `lineTop` at `popupTop` in the text view, clamped to the legal range.
    static func contentOffset(
        aligningLineTop lineTop: CGFloat,
        withPopupTop popupTop: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let target = lineTop - popupTop
        return min(max(target, minimum), max(maximum, minimum))
    }

    private static func visibleRow(near anchor: Int, lineCount: Int, lineHeight: (Int) -> CGFloat) -> Int? {
        if lineHeight(anchor) > 0 {
            return anchor
        }
        for distance in 1 ... collapsedScanLimit {
            let next = anchor + distance
            if next < lineCount, lineHeight(next) > 0 {
                return next
            }
            let previous = anchor - distance
            if previous >= 0, lineHeight(previous) > 0 {
                return previous
            }
        }
        return nil
    }

    /// Visible rows walking away from `center`. Nearer rows come first.
    private static func collect(
        from center: Int,
        direction: Int,
        lineCount: Int,
        lineHeight: (Int) -> CGFloat
    ) -> [Int] {
        var found: [Int] = []
        var row = center + direction
        var scanned = 0
        while found.count < linesAround, row >= 0, row < lineCount, scanned < collapsedScanLimit {
            scanned += 1
            if lineHeight(row) > 0 {
                found.append(row)
            }
            row += direction
        }
        return found
    }
}

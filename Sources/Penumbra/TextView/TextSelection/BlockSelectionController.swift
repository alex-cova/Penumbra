import Foundation

/// One corner of an active block/column selection: a document line row plus a *view-space* x
/// position — not a character column. With proportional fonts and tabs, "column 12" is a
/// different pixel offset on every line, so every real editor's column selection is geometric.
/// Storing an x position also makes ragged lines and short lines fall out for free when
/// materializing: a short line simply clamps to its own end.
struct BlockSelectionAnchor {
    var lineIndex: Int
    var xPosition: CGFloat
}

/// Tracks an active column/block selection as a rectangle between two `BlockSelectionAnchor`
/// corners, and materializes it into the flat `[NSRange]` the rest of the selection pipeline
/// understands.
///
/// The rectangle — not just its materialized ranges — is retained for the lifetime of the mode,
/// since growing the block with the keyboard (⌃⇧↑/↓/←/→) needs the original anchor corner and x
/// position, which a flattened range array can't reconstruct.
final class BlockSelectionController {
    private(set) var anchor: BlockSelectionAnchor?
    private(set) var active: BlockSelectionAnchor?

    /// Sticky column-selection mode (⌘⇧8). While enabled, an ordinary selection assignment does
    /// *not* tear down the rectangle — see `TextInputView._selectedRange`'s `didSet` — so
    /// arrows and drags keep growing a column selection until the mode is turned off.
    var isStickyModeEnabled = false

    var isActive: Bool {
        anchor != nil
    }

    func begin(at anchor: BlockSelectionAnchor) {
        self.anchor = anchor
        active = anchor
    }

    func extend(to active: BlockSelectionAnchor) {
        guard anchor != nil else {
            return
        }
        self.active = active
    }

    /// Clears block-selection mode. Any previously materialized ranges are left untouched by the
    /// caller — this only ends the persistent rectangle tracking.
    func end() {
        anchor = nil
        active = nil
        isStickyModeEnabled = false
    }

    /// Materializes the rectangle into one `NSRange` per covered document row.
    ///
    /// Only the first visual line fragment of each document line participates — a block
    /// selection follows document lines, not wrapped visual lines, matching Xcode's behavior for
    /// soft-wrapped text.
    ///
    /// - Parameter lineCount: Total number of document lines, used to clamp the rectangle.
    /// - Parameter indexForXPosition: Resolves a document character index for a given row and
    ///   view-space x position. Callers are expected to typeset off-screen rows on demand (e.g.
    ///   via `LayoutManager.prepareLineForDisplay(atLocation:)`) and to clamp the result to the
    ///   row's own bounds, since a short row must not reach past its own end.
    func materializedRanges(lineCount: Int, indexForXPosition: (_ row: Int, _ xPosition: CGFloat) -> Int) -> [NSRange] {
        guard let anchor, let active, lineCount > 0 else {
            return []
        }
        let startRow = max(min(anchor.lineIndex, active.lineIndex), 0)
        let endRow = min(max(anchor.lineIndex, active.lineIndex), lineCount - 1)
        guard startRow <= endRow else {
            return []
        }
        let leftX = min(anchor.xPosition, active.xPosition)
        let rightX = max(anchor.xPosition, active.xPosition)
        var ranges: [NSRange] = []
        ranges.reserveCapacity(endRow - startRow + 1)
        for row in startRow...endRow {
            let startIndex = indexForXPosition(row, leftX)
            let endIndex = indexForXPosition(row, rightX)
            let location = min(startIndex, endIndex)
            let length = max(startIndex, endIndex) - location
            ranges.append(NSRange(location: location, length: length))
        }
        return ranges
    }
}

@preconcurrency import AppKit
import Foundation

/// One selection's fixed end (`anchor`) and the end keyboard navigation moves (`active`).
struct SelectionEnds: Equatable {
    var anchor: Int
    var active: Int

    var range: NSRange {
        NSRange(location: min(anchor, active), length: abs(active - anchor))
    }
}

extension TextInputView {
    /// The anchor and active end of every selection, in document order. The ends the last
    /// extension produced are reused while the selection set is untouched, so ⇧← after ⇧→ shrinks
    /// each selection from its own anchor. Any other selection change falls back to reading a
    /// non-empty range as anchored at its start.
    private var currentSelectionEnds: [SelectionEnds] {
        let ranges = selectedRanges
        if multiSelectionEnds.map(\.range) == ranges {
            return multiSelectionEnds
        }
        return ranges.map { range in
            range.length == 0
                ? SelectionEnds(anchor: range.location, active: range.location)
                : SelectionEnds(anchor: range.location, active: range.upperBound)
        }
    }

    /// Extends every selection (⇧/⌥⇧/⌘⇧ + arrows, ⇧Home/End): each active end moves with `move`
    /// while its anchor stays put. Selections that grow into each other merge into one.
    func extendAllSelections(_ move: (Int) -> Int?) {
        endBlockSelectionUnlessSticky()
        let primaryIndex = multiSelectionController.primaryIndex
        let ends = currentSelectionEnds
        var entries = ends.enumerated().map { index, ends -> (ends: SelectionEnds, isPrimary: Bool) in
            var ends = ends
            if let active = move(ends.active) {
                ends.active = active
            }
            return (ends, index == primaryIndex)
        }
        entries.sort {
            let (lhs, rhs) = ($0.ends.range, $1.ends.range)
            return lhs.location != rhs.location ? lhs.location < rhs.location : lhs.length < rhs.length
        }
        var merged: [(ends: SelectionEnds, isPrimary: Bool)] = []
        for entry in entries {
            guard let last = merged.last else {
                merged.append(entry)
                continue
            }
            let (previous, current) = (last.ends.range, entry.ends.range)
            let overlaps = current.location < previous.upperBound
                || (current.location == previous.upperBound && (current.length > 0 && previous.length > 0 || current.length == 0 && previous.length == 0))
            guard overlaps else {
                merged.append(entry)
                continue
            }
            let union = NSRange(location: previous.location, length: max(previous.upperBound, current.upperBound) - previous.location)
            let forward = last.ends.anchor <= last.ends.active
            let ends = forward
                ? SelectionEnds(anchor: union.location, active: union.upperBound)
                : SelectionEnds(anchor: union.upperBound, active: union.location)
            merged[merged.count - 1] = (ends, last.isPrimary || entry.isPrimary)
        }
        let newPrimary = merged.firstIndex { $0.isPrimary } ?? 0
        applySelectedRanges(merged.map(\.ends.range), primaryIndex: newPrimary)
        multiSelectionEnds = merged.map(\.ends)
        selectionAnchor = merged[newPrimary].ends.anchor
    }

    /// ⇧/⌥⇧/⌘⇧ + arrow with several selections: by character, word or line, per `flags`.
    func extendAllSelections(in direction: EditorTextLayoutDirection, stop: CaretStop?) {
        let textDirection: EditorTextDirection = direction == .left || direction == .up ? .backward : .forward
        if let stop {
            extendAllSelections { caretStopLocation(stop, from: $0, direction: textDirection) }
        } else {
            extendAllSelections { [self] in
                (position(from: IndexedPosition(index: $0), in: direction, offset: 1) as? IndexedPosition)?.index
            }
        }
    }
}

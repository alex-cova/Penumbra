import Foundation

/// Manages multiple carets and/or ranges for multi-cursor and block editing.
final class MultiSelectionController {
    private(set) var selections: [NSRange] = []
    private(set) var primaryIndex: Int = 0

    /// Caret-set history (add-cursor / clone-caret / occurrence operations), independent of the
    /// document's undo stack. Used to implement "undo last caret" (⌘U) without touching text.
    private var history: [(selections: [NSRange], primaryIndex: Int)] = []
    private let historyLimit = 32

    var hasMultipleSelections: Bool {
        selections.count > 1
    }

    var primarySelection: NSRange? {
        guard selections.indices.contains(primaryIndex) else {
            return selections.first
        }
        return selections[primaryIndex]
    }

    func setSelections(_ ranges: [NSRange], primaryIndex: Int = 0) {
        let normalized = Self.normalize(ranges)
        selections = normalized
        self.primaryIndex = normalized.isEmpty ? 0 : min(primaryIndex, normalized.count - 1)
    }

    /// Adds `range` to the current selection set. Unlike the old caret-only behavior, this now
    /// accepts non-empty ranges too (needed for block selection and select-all-occurrences), and
    /// simply re-normalizes the combined set rather than replacing it outright.
    @discardableResult
    func addSelection(_ range: NSRange) -> Bool {
        let candidate = NSRange(location: max(range.location, 0), length: max(range.length, 0))
        let before = selections
        let normalized = Self.normalize(selections + [candidate])
        guard normalized != before else {
            return false
        }
        let previousPrimary = primarySelection
        selections = normalized
        if let previousPrimary,
           let index = selections.firstIndex(where: { $0.location == previousPrimary.location && $0.length == previousPrimary.length }) {
            primaryIndex = index
        } else {
            primaryIndex = min(primaryIndex, max(selections.count - 1, 0))
        }
        return true
    }

    func collapseToPrimary() {
        guard let primary = primarySelection else {
            selections = []
            primaryIndex = 0
            return
        }
        setSelections([primary])
    }

    /// Normalizes a set of ranges: clamps negative locations, removes exact duplicates, merges
    /// overlapping/adjacent non-empty ranges, and drops zero-length carets that fall inside a
    /// (possibly merged) non-empty range. Ranges of differing lengths, and a mix of empty and
    /// non-empty ranges, are both legal — this supports ragged block selections and multi-caret
    /// selections coexisting, unlike the old "everything must be the same length" invariant.
    static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else {
            return []
        }
        let clamped = ranges.map { NSRange(location: max($0.location, 0), length: max($0.length, 0)) }
        let sorted = clamped.sorted {
            $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length
        }
        var merged: [NSRange] = []
        for range in sorted {
            if range.length == 0 {
                if let last = merged.last, last.length > 0, range.location > last.location, range.location < last.upperBound {
                    // Caret falls inside an already-merged non-empty range — redundant.
                    continue
                }
                if merged.contains(where: { $0.location == range.location && $0.length == 0 }) {
                    continue
                }
                merged.append(range)
            } else if let last = merged.last, last.length > 0, range.location <= last.upperBound {
                let newUpperBound = max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = NSRange(location: last.location, length: newUpperBound - last.location)
            } else {
                // Drop any carets already collected that this new range now subsumes.
                merged.removeAll { $0.length == 0 && $0.location >= range.location && $0.location < range.upperBound }
                merged.append(range)
            }
        }
        return merged.sorted { $0.location < $1.location }
    }

    var isMultiCaretMode: Bool {
        selections.count > 1 && selections.allSatisfy { $0.length == 0 }
    }

    var isMultiRangeSelectionMode: Bool {
        selections.count > 1 && selections.allSatisfy { $0.length > 0 }
    }

    // MARK: - Caret-set history

    func pushHistory() {
        history.append((selections: selections, primaryIndex: primaryIndex))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    @discardableResult
    func undoLastCaretChange() -> Bool {
        guard let previous = history.popLast() else {
            return false
        }
        selections = previous.selections
        primaryIndex = previous.primaryIndex
        return true
    }

    func clearHistory() {
        history.removeAll()
    }
}

import Foundation

/// Computes the document rows that get an IntelliJ-style method separator, by scanning the live
/// tree-sitter tree with ``DeclarationScanner`` and keeping the rows of declarations whose rule is
/// a ``DeclarationRule/isMethodSeparatorAnchor``.
///
/// Runs synchronously on the main actor. The scan does no name extraction (`text: nil`), but a
/// whole-tree walk still costs ~8 ms at 20k lines of Java, so edits that add or remove lines are
/// tracked (``noteLinesReplaced(afterRow:removed:inserted:changedRows:)``) and the scan after the
/// next parse only covers the rows they touched (``recomputeAfterParse(changedRows:)``).
@MainActor
final class MethodSeparatorController {
    weak var languageMode: TreeSitterInternalLanguageMode?
    var configuration: LanguageConfiguration?
    var isEnabled = false {
        didSet {
            if isEnabled != oldValue {
                isEnabled ? recompute() : clear()
            }
        }
    }
    /// Called with the new rows (sorted, unique) whenever they change.
    var onRowsChanged: (([Int]) -> Void)?

    /// Separator rows in current document coordinates, sorted and unique. Between an edit and the
    /// next parse these are shifted but not yet published. An array, not a set: a large file has
    /// tens of thousands, and every Return shifts them (rehashing a set cost ~0.7 ms at 120k lines).
    private(set) var separatorRows: [Int] = []
    /// What `onRowsChanged` last reported.
    private var publishedRows: [Int] = []
    /// Rows edits touched since the last scan, in current coordinates.
    private var pendingRows: ClosedRange<Int>?

    /// Rescan and publish if the row set changed.
    ///
    /// `rowWindow` limits the walk to declarations that overlap those rows and keeps separators
    /// outside it. A character typed inside one method must not walk the rest of the file.
    /// `nil` scans the whole tree (open, theme change, or a parse with no row diff).
    func recompute(rowWindow: ClosedRange<Int>? = nil) {
        if rowWindow == nil {
            pendingRows = nil
        }
        separatorRows = computeRows(rowWindow: rowWindow)
        publishIfChanged()
    }

    /// Keeps ``separatorRows`` in step with an edit that replaced lines after `row`: `removed` old
    /// lines went and `inserted` new ones came (from the edit's `LineChangeSet`). Rows below the
    /// edit move; `changedRows` (post-edit) and the replaced rows are rescanned by
    /// ``recomputeAfterParse(changedRows:)``.
    ///
    /// A multi-caret edit arrives as one change set: shifting everything past its first row by the
    /// total delta misplaces rows between the carets, but those lie inside `changedRows`, which
    /// spans every caret, and are rescanned.
    func noteLinesReplaced(afterRow row: Int, removed: Int, inserted: Int, changedRows: ClosedRange<Int>?) {
        guard isEnabled else {
            return
        }
        if removed != 0 || inserted != 0 {
            let delta = inserted - removed
            // Old rows in (row, row + removed] were replaced; the rest below the edit move.
            func shifted(_ oldRow: Int) -> Int? {
                if oldRow <= row {
                    return oldRow
                }
                return oldRow <= row + removed ? nil : oldRow + delta
            }
            let replacedStart = Self.firstIndex(in: separatorRows, greaterThan: row)
            let movedStart = Self.firstIndex(in: separatorRows, greaterThan: row + removed)
            if delta != 0 {
                for index in movedStart ..< separatorRows.count {
                    separatorRows[index] += delta
                }
            }
            separatorRows.removeSubrange(replacedStart ..< movedStart)
            pendingRows = pendingRows.map { pending in
                let lower = shifted(pending.lowerBound) ?? row
                let upper = shifted(pending.upperBound) ?? row + inserted
                return min(lower, upper) ... max(lower, upper)
            }
            pendingRows = Self.union(pendingRows, row ... row + inserted)
        }
        pendingRows = Self.union(pendingRows, changedRows)
    }

    /// Rescan the rows edits touched since the last scan plus `changedRows` (what the parse
    /// changed), and publish.
    func recomputeAfterParse(changedRows: ClosedRange<Int>?) {
        let window = Self.union(pendingRows, changedRows)
        pendingRows = nil
        if let window {
            recompute(rowWindow: max(window.lowerBound, 0) ... max(window.upperBound, 0))
        } else {
            publishIfChanged()
        }
    }

    func clear() {
        pendingRows = nil
        separatorRows = []
        publishIfChanged()
    }

    private func publishIfChanged() {
        guard separatorRows != publishedRows else {
            return
        }
        publishedRows = separatorRows
        onRowsChanged?(separatorRows)
    }

    /// Index of the first element of sorted `rows` greater than `value`.
    private static func firstIndex(in rows: [Int], greaterThan value: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func union(_ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return min(lhs.lowerBound, rhs.lowerBound) ... max(lhs.upperBound, rhs.upperBound)
    }

    private func computeRows(rowWindow: ClosedRange<Int>?) -> [Int] {
        guard isEnabled,
              let configuration,
              configuration.showsMethodSeparators,
              let root = languageMode?.rootSyntaxNode else {
            return []
        }
        let declarations = DeclarationScanner.scan(
            root: root,
            configuration: configuration,
            text: nil,
            rowWindow: rowWindow
        )
        var scanned = Set<Int>()
        for declaration in declarations where declaration.isMethodSeparatorAnchor {
            let row = declaration.container.startRow
            if row > 0 {
                scanned.insert(row)
            }
        }
        guard let rowWindow else {
            return scanned.sorted()
        }
        // Keep the rows outside the window and splice the scanned ones in between, without
        // hashing or sorting all of them. A declaration enclosing the window (its class) starts
        // outside it and is found again; it's normally known already.
        let windowStart = Self.firstIndex(in: separatorRows, greaterThan: rowWindow.lowerBound - 1)
        let windowEnd = Self.firstIndex(in: separatorRows, greaterThan: rowWindow.upperBound)
        var inside: [Int] = []
        var unknownOutside: [Int] = []
        for row in scanned {
            if rowWindow.contains(row) {
                inside.append(row)
            } else {
                let index = Self.firstIndex(in: separatorRows, greaterThan: row - 1)
                if index == separatorRows.count || separatorRows[index] != row {
                    unknownOutside.append(row)
                }
            }
        }
        var rows = Array(separatorRows[..<windowStart])
        rows.append(contentsOf: inside.sorted())
        rows.append(contentsOf: separatorRows[windowEnd...])
        if !unknownOutside.isEmpty {
            rows = Array(Set(rows).union(unknownOutside)).sorted()
        }
        return rows
    }
}

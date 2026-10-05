import Foundation

/// What a line in the change stripe stands for, compared with the last commit.
public enum GutterChangeKind: Hashable, Sendable {
    /// Lines the buffer has and the last commit does not.
    case added
    /// Lines that differ from the last commit.
    case modified
    /// Lines the last commit has and the buffer does not. Drawn on the boundary before ``GutterChange/line``.
    case deleted
}

/// A run of lines in the gutter's change stripe.
///
/// A deletion has a ``lineCount`` of zero and sits on the boundary before ``line`` (a ``line`` past
/// the last line sits on the bottom edge of the file). ``deletedLineCount`` is how many lines were
/// removed there, for the tooltip.
public struct GutterChange: Hashable, Sendable {
    public var line: Int
    public var lineCount: Int
    public var kind: GutterChangeKind
    public var deletedLineCount: Int

    public init(line: Int, lineCount: Int, kind: GutterChangeKind, deletedLineCount: Int = 0) {
        self.line = max(1, line)
        if kind == .deleted {
            self.lineCount = 0
            self.kind = .deleted
            self.deletedLineCount = max(1, deletedLineCount)
        } else {
            self.lineCount = max(0, lineCount)
            self.kind = kind
            self.deletedLineCount = 0
        }
    }

    /// 0-based first row. A deletion occupies none.
    var firstRow: Int { line - 1 }

    /// Exclusive end row.
    var endRow: Int { line - 1 + lineCount }

    /// Last 1-based line this mark draws on.
    var lastLine: Int { line + max(lineCount, 1) - 1 }

    var tooltip: String {
        switch kind {
        case .added:
            return "Added"
        case .modified:
            return "Modified"
        case .deleted:
            return deletedLineCount == 1 ? "1 line deleted" : "\(deletedLineCount) lines deleted"
        }
    }
}

/// The change stripe's spans, sorted by line, kept on their lines while the text is edited until
/// the host sends fresh ones.
///
/// An edit costs a walk of the spans (a handful of hunks, not the document) plus the constant
/// lookups the caller already made for ``GutterLineMarkerEdit``. Lines the edit produced are marked
/// at once: a line inserted above an existing one is added, a line whose text changed is modified
/// (a line that was already added stays added), and removed lines leave a deletion mark. The host's
/// next ``replace(with:)`` is the accurate diff.
final class GutterChangeStore {
    private(set) var changes: [GutterChange] = []

    var isEmpty: Bool { changes.isEmpty }

    func replace(with newChanges: [GutterChange]) {
        changes = Self.coalesce(newChanges)
    }

    func clear() {
        changes = []
    }

    /// Spans that draw on 1-based lines `first ... last`, in order.
    func changes(touchingLines first: Int, _ last: Int) -> ArraySlice<GutterChange> {
        guard first <= last, !changes.isEmpty else { return [] }
        let start = firstIndex(touchingLine: first)
        var end = start
        while end < changes.count, changes[end].line <= last + 1, changes[end].firstRow <= last {
            // A span that starts just after `last` cannot reach it, except a deletion on the
            // boundary after the last visible line, which `line <= last + 1` already allows
            // through; the loop below stops at the first span that starts later.
            if changes[end].line > last && changes[end].kind != .deleted { break }
            end += 1
        }
        return changes[start ..< end]
    }

    /// Moves the spans through `edit` and marks the rows it produced. Returns whether anything changed.
    @discardableResult
    func applyEdit(_ edit: GutterLineMarkerEdit) -> Bool {
        let shifted = changes.compactMap { shift($0, edit: edit) }
        let marked = overlay(optimisticMarks(edit), onto: shifted)
        let coalesced = Self.coalesce(marked)
        guard coalesced != changes else { return false }
        changes = coalesced
        return true
    }

    // MARK: - Edit

    private func shift(_ change: GutterChange, edit: GutterLineMarkerEdit) -> GutterChange? {
        if change.kind == .deleted {
            guard let row = edit.newRow(forRow: change.firstRow) else { return nil }
            return GutterChange(line: row + 1, lineCount: 0, kind: .deleted, deletedLineCount: change.deletedLineCount)
        }
        guard let rows = survivingRows(first: change.firstRow, end: change.endRow, edit: edit) else { return nil }
        return GutterChange(line: rows.lowerBound + 1, lineCount: rows.count, kind: change.kind)
    }

    /// The rows of `[first, end)` that survive `edit`, as a half-open range in the new document.
    /// The touched region is one interval, so this is a constant number of ``GutterLineMarkerEdit/newRow(forRow:)``
    /// calls however long the span is.
    private func survivingRows(first: Int, end: Int, edit: GutterLineMarkerEdit) -> Range<Int>? {
        guard first < end else { return nil }
        let touchedLast = edit.startRow + edit.removedRows
        var lower: Int?
        var upper: Int?

        func include(row: Int) {
            lower = min(lower ?? row, row)
            upper = max(upper ?? (row + 1), row + 1)
        }

        let beforeEnd = min(end, edit.startRow)
        if first < beforeEnd {
            include(row: first)
            include(row: beforeEnd - 1)
        }

        let touchFirst = max(first, edit.startRow)
        let touchEnd = min(end, touchedLast + 1)
        if touchFirst < touchEnd {
            if touchFirst <= edit.startRow, let row = edit.newRow(forRow: edit.startRow) {
                include(row: row)
            }
            if touchedLast != edit.startRow, touchFirst <= touchedLast, touchedLast < touchEnd,
               let row = edit.newRow(forRow: touchedLast) {
                include(row: row)
            }
        }

        let afterStart = max(first, touchedLast + 1)
        if afterStart < end {
            include(row: afterStart + edit.lineDelta)
            include(row: end - 1 + edit.lineDelta)
        }
        guard let lower, let upper, lower < upper else { return nil }
        return lower ..< upper
    }

    private func optimisticMarks(_ edit: GutterLineMarkerEdit) -> [GutterChange] {
        if edit.isInsertion, edit.startsAtLineStart, edit.insertedTextEndsWithLineBreak, edit.lineDelta > 0 {
            return [GutterChange(line: edit.startRow + 1, lineCount: edit.lineDelta, kind: .added)]
        }
        let wholeLinesRemoved = !edit.isInsertion && edit.startsAtLineStart && edit.endsAtLineStart
            && edit.lineDelta < 0 && edit.lineDelta == -edit.removedRows
        if wholeLinesRemoved {
            return [GutterChange(line: edit.startRow + 1, lineCount: 0, kind: .deleted, deletedLineCount: -edit.lineDelta)]
        }
        let produced = max(edit.removedRows + 1 + edit.lineDelta, 1)
        var marks = [GutterChange(line: edit.startRow + 1, lineCount: produced, kind: .modified)]
        if edit.lineDelta < 0 {
            marks.append(GutterChange(line: edit.startRow + 1, lineCount: 0, kind: .deleted, deletedLineCount: -edit.lineDelta))
        }
        return marks
    }

    /// Lays `marks` over `spans`. A modified mark that lands entirely on added lines stays added.
    private func overlay(_ marks: [GutterChange], onto spans: [GutterChange]) -> [GutterChange] {
        var result = spans
        for mark in marks {
            if mark.kind == .deleted {
                result.append(mark)
                continue
            }
            result = punch(mark, into: result)
        }
        return result
    }

    private func punch(_ mark: GutterChange, into spans: [GutterChange]) -> [GutterChange] {
        let markEnd = mark.line + mark.lineCount
        var cursor = mark.line
        var coveredByAdded = true
        var saw = false
        for span in spans where span.kind != .deleted {
            let spanEnd = span.line + span.lineCount
            let overlapStart = max(span.line, mark.line)
            let overlapEnd = min(spanEnd, markEnd)
            guard overlapStart < overlapEnd else { continue }
            if cursor < overlapStart { coveredByAdded = false }
            if span.kind != .added { coveredByAdded = false }
            saw = true
            cursor = max(cursor, overlapEnd)
        }
        if !saw || cursor < markEnd { coveredByAdded = false }
        let kind: GutterChangeKind = (mark.kind == .modified && coveredByAdded) ? .added : mark.kind
        let painted = GutterChange(line: mark.line, lineCount: mark.lineCount, kind: kind)

        var output: [GutterChange] = []
        for span in spans {
            if span.kind == .deleted {
                output.append(span)
                continue
            }
            let spanEnd = span.line + span.lineCount
            if spanEnd <= painted.line || span.line >= markEnd {
                output.append(span)
                continue
            }
            if span.line < painted.line {
                output.append(GutterChange(line: span.line, lineCount: painted.line - span.line, kind: span.kind))
            }
            if spanEnd > markEnd {
                output.append(GutterChange(line: markEnd, lineCount: spanEnd - markEnd, kind: span.kind))
            }
        }
        output.append(painted)
        return output
    }

    private static func coalesce(_ spans: [GutterChange]) -> [GutterChange] {
        let sorted = spans.sorted { lhs, rhs in
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.kind == .deleted && rhs.kind != .deleted
        }
        var result: [GutterChange] = []
        for span in sorted {
            guard span.kind == .deleted || span.lineCount > 0 else { continue }
            guard let last = result.last else {
                result.append(span)
                continue
            }
            if span.kind == .deleted, last.kind == .deleted, span.line == last.line {
                result[result.count - 1] = GutterChange(
                    line: last.line, lineCount: 0, kind: .deleted,
                    deletedLineCount: last.deletedLineCount + span.deletedLineCount)
                continue
            }
            if span.kind != .deleted, last.kind == span.kind, span.line <= last.line + last.lineCount {
                let end = max(last.line + last.lineCount, span.line + span.lineCount)
                result[result.count - 1] = GutterChange(line: last.line, lineCount: end - last.line, kind: last.kind)
                continue
            }
            result.append(span)
        }
        return result
    }

    private func firstIndex(touchingLine line: Int) -> Int {
        var low = 0
        var high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].lastLine < line {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

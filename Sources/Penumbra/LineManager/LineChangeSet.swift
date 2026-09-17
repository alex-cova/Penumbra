import Foundation

final class LineChangeSet {
    private(set) var insertedLines: Set<DocumentLineNode> = []
    private(set) var removedLines: Set<DocumentLineNode> = []
    private(set) var editedLines: Set<DocumentLineNode> = []

    func markLineInserted(_ line: DocumentLineNode) {
        removedLines.remove(line)
        editedLines.remove(line)
        insertedLines.insert(line)
    }

    func markLineRemoved(_ line: DocumentLineNode) {
        insertedLines.remove(line)
        editedLines.remove(line)
        removedLines.insert(line)
    }

    func markLineEdited(_ line: DocumentLineNode) {
        if !insertedLines.contains(line) && !removedLines.contains(line) {
            editedLines.insert(line)
        }
    }

    func union(with otherChangeSet: LineChangeSet) {
        insertedLines.formUnion(otherChangeSet.insertedLines)
        removedLines.formUnion(otherChangeSet.removedLines)
        editedLines.formUnion(otherChangeSet.editedLines)
    }

    /// Rows touched by this edit in post-edit coordinates, padded by one line so indent/fold
    /// providers see the neighboring line. `nil` when the change set is empty.
    func affectedRowRange(lineCount: Int) -> ClosedRange<Int>? {
        guard lineCount > 0 else {
            return nil
        }
        var minimum = Int.max
        var maximum = Int.min
        func consider(_ row: Int) {
            let clamped = min(max(row, 0), lineCount - 1)
            minimum = min(minimum, clamped)
            maximum = max(maximum, clamped)
        }
        for line in editedLines {
            consider(line.row)
        }
        for line in insertedLines {
            consider(line.row)
        }
        for line in removedLines {
            consider(line.row)
        }
        guard minimum != Int.max else {
            return nil
        }
        minimum = max(0, minimum - 1)
        maximum = min(lineCount - 1, maximum + 1)
        return minimum ... maximum
    }

    /// First inserted or edited row, used to shift fold ranges after a line insertion/deletion.
    var spliceRow: Int? {
        let rows = insertedLines.map(\.row) + editedLines.map(\.row)
        return rows.min()
    }
}

extension LineChangeSet: CustomDebugStringConvertible {
    var debugDescription: String {
        "[LineChangeSet insertedLines=\(insertedLines) removedLines=\(removedLines) editedLines=\(editedLines)]"
    }
}

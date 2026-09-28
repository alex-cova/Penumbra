import Foundation

/// A line of text in the annotation column, which sits between the gutter decorations and the
/// line numbers (a host uses it for version-control blame, for example).
///
/// The column is display-only. Consecutive lines that carry the same ``id`` form one block, and
/// only the block's first line shows the text.
public struct GutterAnnotation: Hashable, Sendable {
    /// Identifies what the text stands for (a commit, say). Lines with equal ids share one block.
    public let id: Int
    public let text: String
    public let tooltip: String

    public init(id: Int, text: String, tooltip: String = "") {
        self.id = id
        self.text = text
        self.tooltip = tooltip
    }
}

/// The annotation of every row, kept in step with the text until the host sends fresh ones.
///
/// Rows hold a small index into a table of distinct annotations, so a file of 120,000 lines that
/// has a few hundred commits costs 480 KB, and an edit that adds or removes lines is one array
/// splice of that width, never a per-row lookup. A row touched by an edit shows the ``edited``
/// annotation, like IntelliJ's "Not Committed Yet".
final class GutterAnnotationStore {
    private static let noAnnotation: Int32 = -1
    private static let editedRow: Int32 = -2

    private var table: [GutterAnnotation] = []
    private var rows: [Int32] = []
    private(set) var edited: GutterAnnotation?

    var isEmpty: Bool {
        rows.isEmpty
    }

    var rowCount: Int {
        rows.count
    }

    /// Every distinct annotation, and the ``edited`` one: what the column has to be wide enough for.
    var distinctAnnotations: [GutterAnnotation] {
        edited.map { table + [$0] } ?? table
    }

    /// Replaces every row. `annotations[0]` belongs to line 1; `nil` leaves a row blank.
    func replace(with annotations: [GutterAnnotation?], edited: GutterAnnotation?) {
        var indexByID: [Int: Int32] = [:]
        var newTable: [GutterAnnotation] = []
        var newRows: [Int32] = []
        newRows.reserveCapacity(annotations.count)
        for annotation in annotations {
            guard let annotation else {
                newRows.append(Self.noAnnotation)
                continue
            }
            if let index = indexByID[annotation.id] {
                newRows.append(index)
            } else {
                let index = Int32(newTable.count)
                indexByID[annotation.id] = index
                newTable.append(annotation)
                newRows.append(index)
            }
        }
        table = newTable
        rows = newRows
        self.edited = edited
    }

    func clear() {
        table = []
        rows = []
        edited = nil
    }

    /// The annotation of a 0-based row.
    func annotation(atRow row: Int) -> GutterAnnotation? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        if value == Self.editedRow { return edited }
        return value >= 0 ? table[Int(value)] : nil
    }

    /// Whether the text of `row` starts a block: it differs from the row above.
    func startsBlock(atRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return row == 0 || rows[row - 1] != rows[row]
    }

    /// Follows an edit: the rows it touched, and the lines it added, show the edited annotation.
    /// Returns whether any row changed.
    @discardableResult
    func applyEdit(_ edit: GutterLineMarkerEdit) -> Bool {
        guard !rows.isEmpty else { return false }
        let start = min(max(edit.startRow, 0), rows.count)
        // Lines pushed down by a break typed at a line's start are untouched; only the new
        // rows above them are edited.
        if edit.isInsertion, edit.startsAtLineStart, edit.insertedTextEndsWithLineBreak, edit.lineDelta > 0 {
            rows.insert(contentsOf: repeatElement(Self.editedRow, count: edit.lineDelta), at: start)
            return true
        }
        let end = min(start + edit.removedRows + 1, rows.count)
        // Counted from the rows actually replaced, so an edit the store has no rows for cannot grow it.
        let newCount = max(end - start + edit.lineDelta, 1)
        if end - start == newCount, rows[start..<end].allSatisfy({ $0 == Self.editedRow }) {
            return false
        }
        rows.replaceSubrange(start..<end, with: repeatElement(Self.editedRow, count: newCount))
        return true
    }
}

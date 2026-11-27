import DatabaseKit
import Foundation

struct IDEDatabaseGridPaste: Sendable {
    let text: String
    let delimiter: Character
    let sourceRows: [Int]
    let columns: [Int]

    func edits(
        from store: ResultStore, target: IDEDatabaseSQLiteEditTarget
    ) async throws -> [IDEDatabasePendingEdits.ProposedEdit] {
        guard text.utf8.prefix(1_048_577).count <= 1_048_576,
              let cells = IDECSVTable.clipboardRecords(text, delimiter: delimiter, cellLimit: IDEDatabasePendingEdits.limit),
              let first = cells.first else {
            throw DatabaseError.executionFailed("Paste a rectangular selection of up to 500 cells and 1 MB.")
        }
        guard cells.count <= sourceRows.count, first.count <= columns.count else {
            throw DatabaseError.executionFailed("The clipboard rectangle does not fit from the selected cell.")
        }
        let selectedColumns = columns.prefix(first.count)
        guard selectedColumns.allSatisfy({ target.writable[$0] != nil }) else {
            throw DatabaseError.executionFailed("The clipboard rectangle includes an identity or generated column.")
        }
        let selectedRows = Array(sourceRows.prefix(cells.count))
        let drafts = try await store.mapRows(at: selectedRows) { row in
            selectedColumns.map { target.draft(row: 0, column: $0, values: row) }
        }
        var proposed: [IDEDatabasePendingEdits.ProposedEdit] = []
        for (index, row) in drafts.enumerated() {
            for (column, draft) in row.enumerated() {
                guard let draft else {
                    throw DatabaseError.executionFailed("A destination cell has an incomplete value or row key.")
                }
                let replacement = try Self.replacement(cells[index][column], original: draft.original, field: draft.column.name)
                let actual = IDEDatabaseCellEditDraft(row: selectedRows[index], column: draft.column,
                                                      original: draft.original, keys: draft.keys)
                proposed.append(.init(draft: actual, replacement: replacement))
            }
        }
        return proposed
    }

    private static func replacement(_ text: String, original: DatabaseValue, field: String) throws -> DatabaseValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch original {
        case .int:
            if let number = Int64(trimmed) { return .int(number) }
            throw DatabaseError.executionFailed("\(field) contains an integer. Paste whole numbers into that column.")
        case .double:
            if let number = Double(trimmed), number.isFinite { return .double(number) }
            throw DatabaseError.executionFailed("\(field) contains a real number. Paste finite numbers into that column.")
        case .bool:
            switch trimmed.lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default: throw DatabaseError.executionFailed("\(field) is true or false. Paste true or false into that column.")
            }
        default:
            return .text(text)
        }
    }
}

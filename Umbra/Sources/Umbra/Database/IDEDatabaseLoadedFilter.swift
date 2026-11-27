import DatabaseKit
import Foundation

struct IDEDatabaseLoadedFilter: Sendable {
    struct Matches: Identifiable, Sendable {
        let id = UUID()
        let indices: [Int]
        let loadedRows: Int
        let reachedMatchLimit: Bool
    }

    let text: String
    let column: Int?
    static let matchLimit = 20_000

    func apply(to store: ResultStore) async throws -> Matches {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = await store.snapshot
        guard !query.isEmpty, column.map(snapshot.columns.indices.contains) != false else {
            throw DatabaseError.executionFailed("Enter text and select an available column.")
        }
        var indices: [Int] = []
        for start in stride(from: 0, to: snapshot.rowCount, by: 256) {
            try Task.checkCancellation()
            let matching = try await store.mapRows(in: start..<min(start + 256, snapshot.rowCount)) { row in
                if let column {
                    return row.indices.contains(column) && Self.matches(row[column], query: query)
                }
                return row.contains { Self.matches($0, query: query) }
            }
            for (offset, match) in matching.enumerated() where match {
                if indices.count == Self.matchLimit {
                    return Matches(indices: indices, loadedRows: snapshot.rowCount, reachedMatchLimit: true)
                }
                indices.append(start + offset)
            }
        }
        return Matches(indices: indices, loadedRows: snapshot.rowCount, reachedMatchLimit: false)
    }

    private static func matches(_ value: DatabaseValue, query: String) -> Bool {
        let text: String
        switch value.presence {
        case .null: text = "NULL"
        case .missing: text = "Missing"
        case .empty: text = "Empty"
        case .unloaded: return false
        default: text = String((value.displayText() ?? "").prefix(DatabaseValue.displayLimit))
        }
        return text.localizedStandardContains(query)
    }
}

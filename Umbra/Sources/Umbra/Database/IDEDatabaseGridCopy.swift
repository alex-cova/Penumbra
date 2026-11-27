import DatabaseKit
import Foundation

enum IDEDatabaseGridCopy: String, CaseIterable, Sendable {
    case tsv = "TSV", csv = "CSV", markdown = "Markdown", sql = "SQL"

    private static let byteLimit = 4 * 1024 * 1024
    private static let cellLimit = 50_000
    static let rowLimit = 5_000

    func text(
        from store: ResultStore, rows: IndexSet, columns: [Int], engine: DatabaseEngine
    ) async throws -> String {
        let snapshot = await store.snapshot
        guard !columns.isEmpty, !rows.isEmpty,
              columns.allSatisfy(snapshot.columns.indices.contains),
              let last = rows.last, last < snapshot.rowCount else {
            throw DatabaseError.executionFailed("Select available result cells or rows.")
        }
        guard rows.count <= Self.rowLimit, columns.count <= Self.cellLimit / rows.count else { throw Self.selectionTooLarge }
        if self == .sql, rows.count > 500 { throw Self.selectionTooLarge }
        let titles = columns.map { snapshot.columns[$0].name }
        var parts: [String] = []
        switch self {
        case .tsv: break
        case .csv: parts.append(titles.map { Self.field($0, separator: ",", protectsFormula: true) }.joined(separator: ","))
        case .markdown:
            parts.append(Self.markdownRow(titles))
            parts.append(Self.markdownRow(titles.map { _ in "---" }))
        case .sql: break
        }
        var bytes = parts.reduce(0) { $0 + $1.utf8.count + 2 }
        var rowIndex = 0
        for range in rows.rangeView {
            for start in stride(from: range.lowerBound, to: range.upperBound, by: 12) {
                try Task.checkCancellation()
                let block = try await store.mapRows(in: start..<min(start + 12, range.upperBound)) { row in
                    columns.map { row.indices.contains($0) ? row[$0] : .missing }
                }
                for row in block {
                    let line = try encode(row, titles: titles, first: rowIndex == 0, engine: engine)
                    bytes += line.utf8.count + 2
                    guard bytes <= Self.byteLimit else { throw Self.selectionTooLarge }
                    parts.append(line)
                    rowIndex += 1
                }
            }
        }
        return parts.joined(separator: self == .csv || self == .tsv ? "\r\n" : "\n")
    }

    private static var selectionTooLarge: DatabaseError {
        .executionFailed("The selection is too large to copy. Select fewer rows or columns.")
    }

    private func encode(_ row: [DatabaseValue], titles: [String], first: Bool, engine: DatabaseEngine) throws -> String {
        switch self {
        case .tsv, .csv:
            let separator: Character = self == .tsv ? "\t" : ","
            return row.map { value in
                if value.isNull { return self == .tsv ? "NULL" : "" }
                let numeric: Bool = switch value {
                case .int, .uint, .decimal, .double: true
                default: false
                }
                return Self.field(Self.display(value), separator: separator, protectsFormula: !numeric)
            }.joined(separator: String(separator))
        case .markdown:
            return Self.markdownRow(row.map(Self.display))
        case .sql:
            guard engine != .mongo else { throw DatabaseError.executionFailed("SQL copy is available for SQL results.") }
            let values = try zip(row, titles).map { value, title in
                let literal = try Self.literal(value, engine: engine)
                return first ? try "\(literal) AS \(SQLIdentifiers.quote(title, engine: engine))" : literal
            }
            return (first ? "SELECT " : "UNION ALL SELECT ") + values.joined(separator: ", ")
        }
    }

    private static func display(_ value: DatabaseValue) -> String {
        switch value {
        case .null: "NULL"
        case .missing: "Missing"
        case .unloaded: "Unloaded"
        case .truncated, .bytes: value.displayText() ?? ""
        default: value.rawText ?? ""
        }
    }

    private static func field(_ value: String, separator: Character, protectsFormula: Bool) -> String {
        let safe = protectsFormula && value.first.map({ "=+-@".contains($0) }) == true ? "'" + value : value
        guard safe.contains(separator) || safe.contains(where: { $0 == "\"" || $0.isNewline }) else { return safe }
        return "\"" + safe.replacing("\"", with: "\"\"") + "\""
    }

    private static func markdownRow(_ fields: [String]) -> String {
        "| " + fields.map {
            $0.replacing("\\", with: "\\\\").replacing("|", with: "\\|")
                .replacing("\r\n", with: "<br>").replacing("\r", with: "<br>").replacing("\n", with: "<br>")
        }.joined(separator: " | ") + " |"
    }

    private static func literal(_ value: DatabaseValue, engine: DatabaseEngine) throws -> String {
        switch value {
        case .null: return "NULL"
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .int(let number): return String(number)
        case .uint(let number): return String(number)
        case .double(let number) where number.isFinite: return String(number)
        case .decimal(let number) where number.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#,
                                                     options: .regularExpression) != nil:
            return number
        case .text(let text), .uuid(let text), .temporal(let text, _), .json(let text):
            guard !text.utf8.contains(0) else { break }
            if engine == .mysql, !text.isEmpty { return "CONVERT(X'\(hex(text.utf8))' USING utf8mb4)" }
            let escaped = text.replacing("'", with: "''")
            return engine == .postgres ? "E'\(escaped.replacing("\\", with: "\\\\"))'" : "'\(escaped)'"
        case .bytes(let count, let prefix) where count == prefix.count:
            let data = hex(prefix)
            return engine == .postgres ? "decode('\(data)', 'hex')" : "X'\(data)'"
        default:
            break
        }
        throw DatabaseError.executionFailed("The selection contains a value that cannot be represented as SQL.")
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
}

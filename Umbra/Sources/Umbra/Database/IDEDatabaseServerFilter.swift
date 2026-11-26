import DatabaseKit
import Foundation

struct IDEDatabaseServerFilter: Sendable {
    enum Comparison: String, CaseIterable, Identifiable, Sendable {
        case equals = "Equals", differs = "Does Not Equal"
        var id: Self { self }
    }

    let statement: IDEDatabaseStatement
    let columns: [String]
    let engine: DatabaseEngine
    let connectionID: UUID
    let scopeRevision: UUID?

    func query(column: Int, comparison: Comparison, value: DatabaseValue) throws -> IDEDatabaseResultQuery {
        guard let dialect = SQLDialect(engine: engine), columns.indices.contains(column),
              DatabaseQuery.canPage(statement.sql) else {
            throw DatabaseError.executionFailed("Server filters require a single readable SQL result.")
        }
        let name = columns[column]
        guard columns.filter({ $0.caseInsensitiveCompare(name) == .orderedSame }).count == 1 else {
            throw DatabaseError.executionFailed("Give the filtered column a unique alias and run the source query again.")
        }
        let parts = SQLStatementSplitter.split(statement.sql, dialect: dialect)
        guard parts.count == 1, let base = parts.first?.text else {
            throw DatabaseError.executionFailed("Server filters require a single readable SQL result.")
        }
        let field = try SQLIdentifiers.quote(name, engine: engine)
        let condition: String
        var parameters = statement.parameters
        if value.isNull {
            condition = comparison == .equals ? "IS NULL" : "IS NOT NULL"
        } else {
            let placeholder = engine == .postgres ? "$\(parameters.count + 1)" : "?"
            condition = (comparison == .equals ? "= " : "<> ") + placeholder
            parameters.append(value)
        }
        let sql = "SELECT *\nFROM (\n\(base)\n) AS filtered_result\nWHERE filtered_result.\(field) \(condition)"
        return IDEDatabaseResultQuery(title: "Filter \(name)", sql: sql, parameters: parameters, engine: engine,
                                      binding: .init(connectionID: connectionID), scopeRevision: scopeRevision)
    }
}

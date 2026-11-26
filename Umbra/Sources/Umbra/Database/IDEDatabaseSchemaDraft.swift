import DatabaseKit
import Foundation

struct IDEDatabaseSchemaDraft: Identifiable {
    enum Operation: String, CaseIterable, Identifiable {
        case createTable = "Create Table", addColumn = "Add Column", createIndex = "Create Index"
        case addUnique = "Add Unique Constraint", addForeignKey = "Add Foreign Key"
        var id: Self { self }

        static func tableActions(for engine: DatabaseEngine) -> [Self] {
            engine == .mongo ? [] : [.addColumn, .createIndex, .addUnique, .addForeignKey]
        }
    }

    enum ColumnType: String, CaseIterable, Identifiable {
        case integer = "INTEGER", bigInteger = "BIGINT", text = "TEXT", real = "DOUBLE PRECISION"
        case boolean = "BOOLEAN", date = "DATE", timestamp = "TIMESTAMP"
        var id: Self { self }
    }

    struct Column: Identifiable {
        let id = UUID()
        var name = ""
        var type = ColumnType.text
        var required = false

        func sql(engine: DatabaseEngine) throws -> String {
            let name = try SQLIdentifiers.quote(name.trimmingCharacters(in: .whitespacesAndNewlines), engine: engine)
            return "\(name) \(type.rawValue)\(required ? " NOT NULL" : "")"
        }
    }

    let id = UUID()
    let connection: DatabaseConnection
    let operation: Operation
    var table: String
    var name = ""
    var columns = [Column()]
    var keys = [Column()]
    var referencesTable = ""
    var referencesColumn = ""
    var uniqueIndex = false
    var sqliteRebuild: IDEDatabaseSQLiteRebuild?

    var needsSQLiteRebuild: Bool {
        connection.engine == .sqlite && (operation == .addForeignKey || operation == .addUnique)
    }

    init(connection: DatabaseConnection, operation: Operation, table: String = "") {
        self.connection = connection
        self.operation = operation
        self.table = table
    }

    func statement() throws -> String {
        let engine = connection.engine
        func quote(_ name: String) throws -> String {
            try SQLIdentifiers.quote(name.trimmingCharacters(in: .whitespacesAndNewlines), engine: engine)
        }
        func list(_ columns: [Column]) throws -> String {
            let names = columns.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !names.isEmpty, Set(names.map { $0.lowercased() }).count == names.count else {
                throw DatabaseError.executionFailed("Use a different name for each column.")
            }
            return try names.map(quote).joined(separator: ", ")
        }
        let relation = operation == .createTable ? try quote(table) : try SQLIdentifiers.quote(table, engine: engine)
        let scope = switch engine {
        case .postgres: "public"
        case .sqlite: "main"
        case .mysql: connection.database.isEmpty ? "information_schema" : connection.database
        case .mongo: throw DatabaseError.executionFailed("The schema editor requires a SQL source.")
        }
        let schema = try quote(scope)
        let qualified = "\(schema).\(relation)"
        switch operation {
        case .createTable:
            _ = try list(columns)
            let definitions = try columns.map { try $0.sql(engine: engine) }
            return "CREATE TABLE \(qualified) (\n    \(definitions.joined(separator: ",\n    "))\n);"
        case .addColumn:
            guard let column = columns.first else { throw DatabaseError.executionFailed("Enter the new column.") }
            return "ALTER TABLE \(qualified) ADD COLUMN \(try column.sql(engine: engine));"
        case .createIndex:
            let unique = uniqueIndex ? "UNIQUE " : ""
            let index = try quote(name)
            let destination = engine == .sqlite ? "\(schema).\(index) ON \(relation)" : "\(index) ON \(qualified)"
            return "CREATE \(unique)INDEX \(destination) (\(try list(keys)));"
        case .addUnique:
            let constraint = "CONSTRAINT \(try quote(name)) UNIQUE (\(try list(keys)))"
            return try addConstraint(constraint, relation: qualified)
        case .addForeignKey:
            guard let column = keys.first else { throw DatabaseError.executionFailed("Choose the referencing column.") }
            if needsSQLiteRebuild, table.caseInsensitiveCompare(referencesTable.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
                throw DatabaseError.executionFailed("A rebuild cannot add a self-referencing foreign key.")
            }
            let parent = try quote(referencesTable)
            let reference = engine == .sqlite ? parent : "\(schema).\(parent)"
            let constraint = "CONSTRAINT \(try quote(name)) FOREIGN KEY (\(try quote(column.name)))\n"
                + "    REFERENCES \(reference) (\(try quote(referencesColumn)))"
            return try addConstraint(constraint, relation: qualified)
        }
    }

    private func addConstraint(_ constraint: String, relation: String) throws -> String {
        if needsSQLiteRebuild {
            guard let sqliteRebuild else { throw DatabaseError.executionFailed("Read the SQLite table definition first.") }
            return try sqliteRebuild.statement(adding: constraint, nonce: id)
        }
        return "ALTER TABLE \(relation) ADD \(constraint);"
    }
}

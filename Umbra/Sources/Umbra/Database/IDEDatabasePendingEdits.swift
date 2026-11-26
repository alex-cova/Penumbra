import DatabaseKit
import Foundation
import Observation

/// What the grid may change in one table or collection: the key that identifies a row, the columns
/// a cell edit may write, and (SQLite only) the columns an insert may fill and the loaded values
/// a delete compares. The engine decides what a cell may hold and what a submit runs.
struct IDEDatabaseEditTarget: Sendable, Equatable {
    struct Column: Sendable, Equatable {
        let index: Int
        let name: String
        let required: Bool
        /// The column's `DEFAULT` expression text, when it has one.
        var defaultExpression: String? = nil
    }

    struct InsertColumn: Sendable, Identifiable, Equatable {
        var id: String { name }
        let name: String
        let typeName: String
        /// NOT NULL with no default (and not a rowid alias): an insert must give it a value.
        let required: Bool
        let defaultExpression: String?
        let isRowIDAlias: Bool
        /// Part of a primary key or a unique index: a duplicate needs a different value here.
        let isUnique: Bool

        var canUseDefault: Bool { defaultExpression != nil || isRowIDAlias || !required }
    }

    enum Identity: Sendable, Equatable {
        case primaryKey, uniqueKey
        /// A key the server confirmed (PostgreSQL, MySQL), or MongoDB's `_id`.
        case verifiedKey
        /// The hidden `rowid`, selected beside the table's own columns. SQLite may renumber rowids
        /// on `VACUUM`, so a rowid is only trusted while the result's schema version is current.
        case rowID
    }

    let table: String
    let schemaVersion: Int
    let identity: Identity
    let keys: [Column]
    let writable: [Int: Column]
    let comparable: [Column]
    let insertColumns: [InsertColumn]
    private(set) var engine: DatabaseEngine = .sqlite
    private(set) var schema: String?
    /// The server's confirmation for PostgreSQL and MySQL, used to build and run the UPDATEs.
    private(set) var sql: SQLEditTarget?
    private(set) var mongoDatabase: String?
    /// Why a result column cannot be edited, by result index.
    private(set) var lockedReasons: [Int: String] = [:]
    /// The source name of each result column that comes from the table, by result index.
    private(set) var sourceNames: [Int: String] = [:]

    /// Insert, duplicate and delete are SQLite-only for now.
    var allowsRowChanges: Bool { engine == .sqlite }
    /// Clock functions and column defaults are SQLite-only for now.
    var allowsExpressions: Bool { engine == .sqlite }

    /// A PostgreSQL or MySQL result the server verified.
    init?(sql target: SQLEditTarget, columns: [ResultColumn]) {
        guard !target.keys.isEmpty, target.keys.allSatisfy({ !$0.name.isEmpty }) else { return nil }
        func column(_ source: SQLEditTarget.Column) -> Column {
            Column(index: source.resultIndex, name: source.name, required: source.isRequired)
        }
        table = target.table
        schemaVersion = 0
        identity = .verifiedKey
        keys = target.keys.map(column)
        writable = Dictionary(uniqueKeysWithValues: target.columns.filter { $0.readOnlyReason == nil && !$0.isKey }
            .map { ($0.resultIndex, column($0)) })
        comparable = []
        insertColumns = []
        engine = target.engine
        schema = target.schema
        sql = target
        sourceNames = Dictionary(uniqueKeysWithValues: target.columns.map { ($0.resultIndex, $0.name) })
        lockedReasons = Dictionary(uniqueKeysWithValues: target.columns.compactMap { item in
            item.readOnlyReason.map { (item.resultIndex, $0) }
        })
        for (index, result) in columns.enumerated() where lockedReasons[index] == nil && !target.columns.contains(where: { $0.resultIndex == index }) {
            lockedReasons[index] = "\(result.name) is computed, so its source is not verified."
        }
    }

    /// A MongoDB collection result: `_id` names the document, every other top-level field can be set.
    init?(mongoDatabase database: String, collection: String, columns: [ResultColumn]) {
        guard let idIndex = columns.firstIndex(where: { $0.name == "_id" }) else { return nil }
        table = collection
        schemaVersion = 0
        identity = .verifiedKey
        keys = [Column(index: idIndex, name: "_id", required: true)]
        writable = Dictionary(uniqueKeysWithValues: columns.enumerated().filter { $0.offset != idIndex }
            .map { ($0.offset, Column(index: $0.offset, name: $0.element.name, required: false)) })
        comparable = []
        insertColumns = []
        engine = .mongo
        mongoDatabase = database
        sourceNames = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.offset, $0.element.name) })
        lockedReasons = [idIndex: "_id identifies the document."]
    }

    /// Whether a value may be a cell's original or replacement on this engine.
    func accepts(_ value: DatabaseValue, isKey: Bool = false) -> Bool {
        switch engine {
        case .sqlite:
            return Self.canStage(value)
        case .postgres, .mysql:
            switch value {
            case .null: return !isKey
            case .bool, .int, .uint, .decimal, .uuid: return true
            case .text(let text): return text.utf8.prefix(8_193).count <= 8_192
            case .double: return !isKey
            case .temporal(_, let kind): return kind != .interval
            default: return false
            }
        case .mongo:
            switch value {
            case .text(let text): return text.utf8.prefix(8_193).count <= 8_192
            case .int: return true
            case .bson(let type, _): return isKey && type == "objectId"
            case .null, .missing, .bool, .double: return !isKey
            default: return false
            }
        }
    }

    func accepts(_ cell: SQLiteCellValue) -> Bool {
        switch cell {
        case .value(let value): accepts(value)
        case .expression(let expression): allowsExpressions && expression.isSupported
        }
    }

    /// The statement a mutation will run, for the preview and Copy. MongoDB shows its shell form.
    func statement(for mutation: SQLiteRowMutation) -> (sql: String, parameters: [DatabaseValue])? {
        switch engine {
        case .sqlite:
            return try? mutation.statement(table: table)
        case .postgres, .mysql:
            guard case .update(let update) = mutation, let sql else { return nil }
            return try? sql.statement(for: update)
        case .mongo:
            guard case .update(let update) = mutation, let update = mongoUpdate(update) else { return nil }
            return (update.preview(collection: table), [])
        }
    }

    func mongoUpdate(_ update: SQLiteOptimisticUpdate) -> MongoFieldUpdate? {
        guard let id = update.keys.first?.value else { return nil }
        let changes = update.changes.compactMap { change -> MongoFieldUpdate.Change? in
            change.replacement.literal.map { .init(field: change.column, original: change.original, replacement: $0) }
        }
        return changes.count == update.changes.count ? MongoFieldUpdate(id: id, changes: changes) : nil
    }

    func lockedReason(forColumn index: Int) -> String? { lockedReasons[index] }

    /// The name `rowid` can be selected under, when this table has no key the grid would see:
    /// an ordinary rowid table whose columns do not already use `rowid`, `_rowid_` or `oid`.
    static func rowIDAlias(for info: SQLiteTableInfo) -> String? {
        guard info.hasRowID, info.schema == "main" else { return nil }
        let hasKey = !info.primaryKey.isEmpty || info.indexes.contains { index in
            let names = index.columns.compactMap { $0 }
            return index.isUnique && !index.isPartial && names.count == index.columns.count
                && names.allSatisfy { name in info.columns.first { $0.name == name }?.isNotNull == true }
        }
        guard !hasKey else { return nil }
        let used = Set(info.columns.map { $0.name.lowercased() })
        return ["rowid", "_rowid_", "oid"].first { !used.contains($0) }
    }

    /// Why a result cannot be edited, or nil when `init` would succeed. Shown instead of a bare lock.
    static func readOnlyReason(table info: SQLiteTableInfo, columns: [ResultColumn], rowIDColumn: Int?) -> String? {
        guard info.kind == .table else { return "\(info.name) is a \(info.kind.rawValue), not a table." }
        guard info.schema == "main" else { return "Only tables in the main database can be edited." }
        guard !columns.isEmpty else { return "The result has no columns." }
        for column in columns.enumerated() where column.offset != rowIDColumn {
            guard let origin = column.element.origin else {
                return "\(column.element.name) is computed, so its source column is not verified."
            }
            guard origin.schema == "main", origin.table == info.name else {
                return "\(column.element.name) comes from \(origin.table), not \(info.name)."
            }
        }
        let origins = columns.enumerated().compactMap { $0.offset == rowIDColumn ? nil : $0.element.origin?.column }
        guard Set(origins).count == origins.count else { return "A column appears twice in the result." }
        if Self(table: info, columns: columns, schemaVersion: 0, rowIDColumn: rowIDColumn) == nil {
            return info.withoutRowID
                ? "The result does not include a primary or non-null unique key of \(info.name)."
                : "The result does not include a key of \(info.name), and its rowid is not selected."
        }
        return nil
    }

    init?(table info: SQLiteTableInfo, columns: [ResultColumn], schemaVersion: Int, rowIDColumn: Int? = nil) {
        guard info.kind == .table, info.schema == "main", !columns.isEmpty else { return nil }
        var positions: [String: Int] = [:]
        for (index, column) in columns.enumerated() where index != rowIDColumn {
            guard let origin = column.origin, origin.schema == "main", origin.table == info.name,
                  positions.updateValue(index, forKey: origin.column) == nil else { return nil }
        }
        let byName = Dictionary(uniqueKeysWithValues: info.columns.map { ($0.name, $0) })
        let candidates = [info.primaryKey] + info.indexes.filter { $0.isUnique && !$0.isPartial }.compactMap { index in
            let names = index.columns.compactMap { $0 }
            guard names.count == index.columns.count, names.allSatisfy({ byName[$0]?.isNotNull == true }) else { return nil }
            return names
        }
        func projected(_ name: String) -> Column? {
            guard let index = positions[name], let column = byName[name], column.hidden == 0 else { return nil }
            return Column(index: index, name: name, required: column.isNotNull, defaultExpression: column.defaultValue)
        }
        var identity: Identity = .primaryKey
        var keys: [Column] = []
        var locked = Set(info.primaryKey)
        if let chosen = candidates.first(where: { !$0.isEmpty && $0.allSatisfy { positions[$0] != nil } }) {
            keys = chosen.compactMap(projected)
            guard keys.count == chosen.count else { return nil }
            identity = chosen == info.primaryKey ? .primaryKey : .uniqueKey
            locked.formUnion(chosen)
        } else if let rowIDColumn, info.hasRowID, columns.indices.contains(rowIDColumn) {
            let name = columns[rowIDColumn].name
            keys = [Column(index: rowIDColumn, name: name, required: true)]
            identity = .rowID
        } else {
            return nil
        }
        self.table = info.name
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.keys = keys
        sourceNames = Dictionary(uniqueKeysWithValues: positions.map { ($0.value, $0.key) })
        if identity == .rowID, let rowIDColumn { sourceNames[rowIDColumn] = columns[rowIDColumn].name }
        let keyNames = Set(keys.map(\.name))
        writable = Dictionary(uniqueKeysWithValues: positions.keys.filter { !locked.contains($0) }
            .compactMap(projected).map { ($0.index, $0) })
        comparable = positions.keys.filter { !keyNames.contains($0) }.compactMap(projected).sorted { $0.index < $1.index }
        let aliasesRowID = !info.withoutRowID && info.primaryKey.count == 1
            && byName[info.primaryKey[0]]?.declaredType.uppercased() == "INTEGER"
        let unique = Set(info.indexes.filter { $0.isUnique && !$0.isPartial }.flatMap { $0.columns.compactMap { $0 } })
        insertColumns = info.columns.filter { !$0.isGenerated && !$0.isHidden }.map { column in
            let alias = aliasesRowID && column.name == info.primaryKey[0]
            return InsertColumn(name: column.name, typeName: column.declaredType,
                                required: column.isNotNull && column.defaultValue == nil && !alias,
                                defaultExpression: column.defaultValue, isRowIDAlias: alias,
                                isUnique: unique.contains(column.name) || (!alias && info.primaryKey.contains(column.name)))
        }
    }

    /// The key of the row these values form, nil when any key part is missing or not comparable.
    func keyValues(values: [DatabaseValue]) -> [SQLiteOptimisticUpdate.Key]? {
        let keys: [SQLiteOptimisticUpdate.Key] = keys.compactMap { key in
            guard values.indices.contains(key.index), !values[key.index].isNull,
                  accepts(values[key.index], isKey: true) else { return nil }
            return .init(column: key.name, value: values[key.index])
        }
        return keys.count == self.keys.count ? keys : nil
    }

    func draft(row: Int, column: Int, values: [DatabaseValue]) -> IDEDatabaseCellEditDraft? {
        guard let field = writable[column], values.indices.contains(column),
              accepts(values[column]), let keys = keyValues(values: values) else { return nil }
        return IDEDatabaseCellEditDraft(row: row, column: field, original: values[column], keys: keys)
    }

    /// The row's identity and every loaded value that can be compared when the delete is submitted.
    func deletion(row: Int, values: [DatabaseValue]) -> IDEDatabasePendingEdits.Deletion? {
        guard let keys = keyValues(values: values) else { return nil }
        var originals: [SQLiteOptimisticUpdate.Key] = []
        var skipped = 0
        for column in comparable {
            if values.indices.contains(column.index), Self.canStage(values[column.index]) {
                originals.append(.init(column: column.name, value: values[column.index]))
            } else {
                skipped += 1
            }
        }
        return .init(row: row, keys: keys, originals: originals, uncompared: skipped)
    }

    /// A new row filled from an existing one. A rowid alias is left to SQLite; every other
    /// column keeps the loaded value when it can be written back.
    func duplicate(values: [DatabaseValue], columns: [ResultColumn]) -> [SQLiteInsert.Field] {
        var byName: [String: DatabaseValue] = [:]
        for (index, column) in columns.enumerated() where values.indices.contains(index) {
            if let origin = column.origin { byName[origin.column] = values[index] }
        }
        return insertColumns.compactMap { column in
            guard !column.isRowIDAlias, let value = byName[column.name], Self.canStage(value) else { return nil }
            return .init(column: column.name, value: .value(value))
        }
    }

    static func canStage(_ value: DatabaseValue) -> Bool {
        if case .text(let text) = value, text.utf8.prefix(8_193).count > 8_192 { return false }
        return SQLiteOptimisticUpdate.isEditableValue(value)
    }

    static func canStage(_ cell: SQLiteCellValue) -> Bool {
        switch cell {
        case .value(let value): canStage(value)
        case .expression(let expression): expression.isSupported
        }
    }
}

struct IDEDatabaseCellEditDraft: Identifiable, Sendable {
    let id = UUID()
    let row: Int
    let column: IDEDatabaseSQLiteEditTarget.Column
    var original: DatabaseValue
    let keys: [SQLiteOptimisticUpdate.Key]
}

/// Changes staged for one SQLite result: cell edits, new rows and deleted rows. Nothing touches
/// the database until the user reviews and submits. A batch then goes through states the grid
/// shows: staged locally, submitted into an open transaction, committed, or rolled back.
@MainActor
@Observable
final class IDEDatabasePendingEdits: Equatable {
    struct Position: Hashable {
        let row: Int
        let column: Int
    }

    struct Edit {
        var draft: IDEDatabaseCellEditDraft
        let replacement: SQLiteCellValue
    }

    struct ProposedEdit: Sendable {
        let draft: IDEDatabaseCellEditDraft
        let replacement: SQLiteCellValue

        init(draft: IDEDatabaseCellEditDraft, replacement: SQLiteCellValue) {
            self.draft = draft
            self.replacement = replacement
        }

        init(draft: IDEDatabaseCellEditDraft, replacement: DatabaseValue) {
            self.init(draft: draft, replacement: .value(replacement))
        }
    }

    struct Insertion: Identifiable {
        let id: UUID
        var fields: [SQLiteInsert.Field]
    }

    struct Deletion {
        let row: Int
        let keys: [SQLiteOptimisticUpdate.Key]
        var originals: [SQLiteOptimisticUpdate.Key]
        /// Columns whose loaded value is binary or truncated and so is not compared.
        let uncompared: Int
    }

    /// Where a batch is. Only `local` can be changed.
    enum Phase: Equatable {
        /// Staged in the grid and nowhere else.
        case local
        /// Applied inside the user's open transaction. The file does not have it yet.
        case submitted
        case committed
        case rolledBack
        /// The transaction ended in a way Umbra did not see (a dropped connection, a script).
        case indeterminate
    }

    enum Boundary: Equatable {
        case committed, rolledBack, rolledBackTo(String), ended
    }

    nonisolated static let limit = 500

    struct PreviewRow: Identifiable {
        enum Kind { case update, insert, delete }

        let id: Int
        let kind: Kind
        /// The grid row for an update or delete, nil for a new row.
        let row: Int?
        let mutation: SQLiteRowMutation
        let uncompared: Int

        var title: String {
            switch kind {
            case .update: "Update row \(((row ?? 0) + 1).formatted())"
            case .delete: "Delete row \(((row ?? 0) + 1).formatted())"
            case .insert: "New row"
            }
        }
    }

    struct Conflict {
        let row: PreviewRow
        let current: [DatabaseValue]?
    }

    /// The database refused one mutation (a constraint, a trigger). The batch stayed staged.
    struct Rejection {
        let row: PreviewRow
        let message: String
    }

    struct Counts: Equatable {
        var updatedRows = 0
        var insertedRows = 0
        var deletedRows = 0

        var total: Int { updatedRows + insertedRows + deletedRows }
        var summary: String {
            [(updatedRows, "updated"), (insertedRows, "inserted"), (deletedRows, "deleted")]
                .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }.joined(separator: ", ")
        }
    }

    private enum Action {
        case cell(Position, before: Edit?, after: Edit?)
        case insertion(UUID, before: Insertion?, after: Insertion?)
        case deletion(Int, before: Deletion?, after: Deletion?)
    }

    private struct Snapshot {
        var edits: [Position: Edit]
        var insertions: [Insertion]
        var deletions: [Int: Deletion]
    }

    let target: IDEDatabaseEditTarget
    private(set) var edits: [Position: Edit] = [:]
    private(set) var insertions: [Insertion] = []
    private(set) var deletions: [Int: Deletion] = [:]
    private(set) var conflict: Conflict?
    private(set) var rejection: Rejection?
    private(set) var phase: Phase = .local
    /// What the last submitted batch changed, kept for the badge after its edits are cleared.
    private(set) var submittedCounts = Counts()
    private var submittedSnapshot: Snapshot?
    private var submittedSavepoints: [String] = []
    private var undoStack: [[Action]] = []
    private var redoStack: [[Action]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var committed: Bool { phase == .committed }
    var isLocal: Bool { phase == .local }
    var changeCount: Int { edits.count + insertions.count + deletions.count }
    var hasChanges: Bool { changeCount > 0 }
    var stagedRows: Int {
        Set(edits.keys.map(\.row)).union(deletions.keys).count + insertions.count
    }
    var deletedRows: Set<Int> { Set(deletions.keys) }

    init(target: IDEDatabaseEditTarget) { self.target = target }

    nonisolated static func == (lhs: IDEDatabasePendingEdits, rhs: IDEDatabasePendingEdits) -> Bool { lhs === rhs }

    // MARK: Staging cells

    func stage(_ draft: IDEDatabaseCellEditDraft, replacement: DatabaseValue) throws {
        try stage([ProposedEdit(draft: draft, replacement: replacement)])
    }

    func stage(_ draft: IDEDatabaseCellEditDraft, replacement: SQLiteCellValue) throws {
        try stage([ProposedEdit(draft: draft, replacement: replacement)])
    }

    /// Stage a whole clipboard rectangle as one undoable action.
    @discardableResult
    func stage(_ proposed: [ProposedEdit]) throws -> Int {
        guard proposed.count <= Self.limit else {
            throw DatabaseError.executionFailed("Stage up to 500 cells at a time.")
        }
        try requireLocal()
        var modified = edits
        var actions: [Action] = []
        for edit in proposed {
            var draft = edit.draft
            let replacement = edit.replacement
            guard target.accepts(replacement), !draft.column.required || !replacement.isNull else {
                throw DatabaseError.executionFailed("Use a complete value of up to 8 KB. Required columns cannot be NULL.")
            }
            if case .expression(.columnDefault(let text)) = replacement, draft.column.defaultExpression != text {
                throw DatabaseError.executionFailed("\(draft.column.name) has no such default.")
            }
            guard deletions[draft.row] == nil else {
                throw DatabaseError.executionFailed("Row \((draft.row + 1).formatted()) is staged for deletion. Revert the row first.")
            }
            let position = Position(row: draft.row, column: draft.column.index)
            let before = modified[position]
            if let before { draft.original = before.draft.original }
            if before?.replacement == replacement || (before == nil && replacement.literal == draft.original) { continue }
            let after = replacement.literal == draft.original ? nil : Edit(draft: draft, replacement: replacement)
            modified[position] = after
            actions.append(.cell(position, before: before, after: after))
        }
        guard modified.count + insertions.count + deletions.count <= Self.limit else {
            throw DatabaseError.executionFailed("Submit the current changes before staging more than 500 changes.")
        }
        guard !actions.isEmpty else { return 0 }
        edits = modified
        record(actions)
        return actions.count
    }

    // MARK: Staging rows

    /// Adds a new row. Fields for columns that take their default are simply absent.
    func stageInsertion(_ fields: [SQLiteInsert.Field], replacing id: UUID? = nil) throws {
        try requireLocal()
        let cleaned = try validate(fields)
        let existing = id.flatMap { id in insertions.first { $0.id == id } }
        if id != nil, existing == nil { throw DatabaseError.executionFailed("That new row is no longer staged.") }
        guard existing != nil || changeCount < Self.limit else {
            throw DatabaseError.executionFailed("Submit the current changes before staging more than 500 changes.")
        }
        let after = Insertion(id: existing?.id ?? UUID(), fields: cleaned)
        if let existing {
            guard let index = insertions.firstIndex(where: { $0.id == existing.id }) else { return }
            insertions[index] = after
        } else {
            insertions.append(after)
        }
        record([.insertion(after.id, before: existing, after: after)])
    }

    func removeInsertion(_ id: UUID) {
        guard phase == .local, let index = insertions.firstIndex(where: { $0.id == id }) else { return }
        let before = insertions.remove(at: index)
        record([.insertion(id, before: before, after: nil)])
    }

    /// Marks rows for deletion. Cell edits staged for those rows are dropped in the same undo step.
    func stageDeletions(_ proposed: [Deletion]) throws {
        try requireLocal()
        var actions: [Action] = []
        var newCount = changeCount
        for deletion in proposed where deletions[deletion.row] == nil {
            newCount += 1 - edits.keys.filter { $0.row == deletion.row }.count
            guard newCount <= Self.limit else {
                throw DatabaseError.executionFailed("Submit the current changes before staging more than 500 changes.")
            }
            for position in edits.keys.filter({ $0.row == deletion.row }).sorted(by: { $0.column < $1.column }) {
                actions.append(.cell(position, before: edits.removeValue(forKey: position), after: nil))
            }
            deletions[deletion.row] = deletion
            actions.append(.deletion(deletion.row, before: nil, after: deletion))
        }
        record(actions)
    }

    private func validate(_ fields: [SQLiteInsert.Field]) throws -> [SQLiteInsert.Field] {
        let columns = Dictionary(uniqueKeysWithValues: target.insertColumns.map { ($0.name, $0) })
        var seen = Set<String>()
        for field in fields {
            guard let column = columns[field.column], seen.insert(field.column).inserted,
                  target.accepts(field.value) else {
                throw DatabaseError.executionFailed("Use each column once, with a complete value of up to 8 KB.")
            }
            if case .expression(.columnDefault(let text)) = field.value, column.defaultExpression != text {
                throw DatabaseError.executionFailed("\(column.name) has no such default.")
            }
        }
        for column in target.insertColumns where column.required {
            guard let field = fields.first(where: { $0.column == column.name }), !field.value.isNull else {
                throw DatabaseError.executionFailed("\(column.name) is required and has no default.")
            }
        }
        return fields
    }

    // MARK: Undo, redo, revert

    func undo() {
        guard phase == .local, let actions = undoStack.popLast() else { return }
        for action in actions.reversed() { apply(action, forward: false) }
        redoStack.append(actions)
        clearFailures()
    }

    func redo() {
        guard phase == .local, let actions = redoStack.popLast() else { return }
        for action in actions { apply(action, forward: true) }
        pushUndo(actions)
        clearFailures()
    }

    /// Reverts every staged change of a row (or one cell, for an edit).
    func revert(row: Int, column: Int? = nil) {
        guard phase == .local else { return }
        var actions: [Action] = []
        for position in edits.keys.filter({ $0.row == row && (column == nil || $0.column == column) })
            .sorted(by: { $0.column < $1.column }) {
            actions.append(.cell(position, before: edits.removeValue(forKey: position), after: nil))
        }
        if column == nil, let removed = deletions.removeValue(forKey: row) {
            actions.append(.deletion(row, before: removed, after: nil))
        }
        record(actions)
    }

    func revertAll() {
        edits.removeAll()
        insertions.removeAll()
        deletions.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        clearFailures()
    }

    private func apply(_ action: Action, forward: Bool) {
        switch action {
        case .cell(let position, let before, let after): edits[position] = forward ? after : before
        case .deletion(let row, let before, let after): deletions[row] = forward ? after : before
        case .insertion(let id, let before, let after):
            let value = forward ? after : before
            if let index = insertions.firstIndex(where: { $0.id == id }) {
                if let value { insertions[index] = value } else { insertions.remove(at: index) }
            } else if let value {
                insertions.append(value)
            }
        }
    }

    private func record(_ actions: [Action]) {
        guard !actions.isEmpty else { return }
        pushUndo(actions)
        redoStack.removeAll()
        clearFailures()
    }

    private func requireLocal() throws {
        guard phase == .local else {
            throw DatabaseError.executionFailed("These changes were already submitted. Rerun the query to edit again.")
        }
    }

    private func clearFailures() {
        conflict = nil
        rejection = nil
    }

    // MARK: Preview and outcomes

    /// Deletions first, then updates, then inserts: a row can be deleted and its unique value
    /// reused in the same batch, and an update can free a value an insert takes.
    func preview() -> [PreviewRow] {
        var rows: [PreviewRow] = []
        func add(_ kind: PreviewRow.Kind, _ row: Int?, _ mutation: SQLiteRowMutation, uncompared: Int = 0) {
            rows.append(PreviewRow(id: rows.count, kind: kind, row: row, mutation: mutation, uncompared: uncompared))
        }
        for deletion in deletions.values.sorted(by: { $0.row < $1.row }) {
            add(.delete, deletion.row, .delete(SQLiteDelete(keys: deletion.keys, originals: deletion.originals)),
                uncompared: deletion.uncompared)
        }
        for (row, values) in Dictionary(grouping: edits.values, by: { $0.draft.row }).sorted(by: { $0.key < $1.key }) {
            let rowEdits = values.sorted { $0.draft.column.index < $1.draft.column.index }
            guard let first = rowEdits.first else { continue }
            let changes = rowEdits.map {
                SQLiteOptimisticUpdate.Change(column: $0.draft.column.name, original: $0.draft.original, replacement: $0.replacement)
            }
            add(.update, row, .update(SQLiteOptimisticUpdate(keys: first.draft.keys, changes: changes)))
        }
        for insertion in insertions { add(.insert, nil, .insert(SQLiteInsert(fields: insertion.fields))) }
        return rows
    }

    func markRejected(_ failure: SQLiteMutationFailure, in preview: [PreviewRow]) {
        guard preview.indices.contains(failure.index) else { return }
        rejection = Rejection(row: preview[failure.index], message: failure.message)
    }

    func markConflict(_ conflict: SQLiteOptimisticConflict, in preview: [PreviewRow]) {
        guard preview.indices.contains(conflict.updateIndex) else { return }
        self.conflict = Conflict(row: preview[conflict.updateIndex], current: conflict.current)
    }

    /// The batch ran on the console's connection and is waiting in the user's transaction.
    func markSubmitted(savepoints: [String]) {
        guard phase == .local else { return }
        submittedCounts = counts()
        submittedSnapshot = Snapshot(edits: edits, insertions: insertions, deletions: deletions)
        submittedSavepoints = savepoints.map { $0.lowercased() }
        clearStaged()
        phase = .submitted
    }

    /// The batch is in the file: either its own transaction committed, or the user committed theirs.
    func markCommitted() {
        if phase == .local { submittedCounts = counts() }
        clearStaged()
        submittedSnapshot = nil
        phase = .committed
    }

    func markRolledBack() {
        guard phase == .submitted else { return }
        phase = .rolledBack
    }

    /// After a rollback the file holds the original rows again, so the same batch is valid.
    func restageRolledBack() {
        guard phase == .rolledBack, let snapshot = submittedSnapshot else { return }
        edits = snapshot.edits
        insertions = snapshot.insertions
        deletions = snapshot.deletions
        submittedSnapshot = nil
        phase = .local
    }

    func noteBoundary(_ boundary: Boundary) {
        guard phase == .submitted else { return }
        switch boundary {
        case .committed: markCommitted()
        case .rolledBack: markRolledBack()
        case .rolledBackTo(let name): if submittedSavepoints.contains(name) { markRolledBack() }
        case .ended:
            clearStaged()
            submittedSnapshot = nil
            phase = .indeterminate
        }
    }

    /// Gives up on a conflicting row: its staged changes are dropped and the rest stays staged.
    func discardConflictedRow() {
        guard let conflict else { return }
        switch conflict.row.kind {
        case .update, .delete: if let row = conflict.row.row { revert(row: row) }
        case .insert: break
        }
        self.conflict = nil
    }

    func rebaseConflict() {
        guard let conflict, let current = conflict.current, current.allSatisfy({ target.accepts($0) }),
              let row = conflict.row.row else { return }
        switch conflict.row.mutation {
        case .update(let update):
            for (change, latest) in zip(update.changes, current) {
                guard let pair = edits.first(where: { $0.key.row == row && $0.value.draft.column.name == change.column }) else { continue }
                var edit = pair.value
                edit.draft.original = latest
                edits[pair.key] = latest == edit.replacement.literal ? nil : edit
            }
        case .delete(let delete):
            guard var deletion = deletions[row] else { return }
            deletion.originals = zip(delete.originals, current).map { .init(column: $0.column, value: $1) }
            deletions[row] = deletion
        case .insert: return
        }
        undoStack.removeAll()
        redoStack.removeAll()
        self.conflict = nil
    }

    private func counts() -> Counts {
        Counts(updatedRows: Set(edits.keys.map(\.row)).count, insertedRows: insertions.count, deletedRows: deletions.count)
    }

    private func clearStaged() {
        edits.removeAll()
        insertions.removeAll()
        deletions.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        clearFailures()
    }

    private func pushUndo(_ actions: [Action]) {
        undoStack.append(actions)
        var retained = undoStack.reduce(0) { $0 + $1.count }
        while undoStack.count > 200 || retained > 1_000 {
            retained -= undoStack.removeFirst().count
        }
    }
}

typealias IDEDatabaseSQLiteEditTarget = IDEDatabaseEditTarget

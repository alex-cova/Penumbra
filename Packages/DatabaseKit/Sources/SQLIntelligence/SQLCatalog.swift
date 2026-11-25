import Foundation

/// What the language service knows about the database: a snapshot, handed in. Nothing in this
/// module queries a server, so a keystroke reads memory.
///
/// `isComplete` is the honesty switch. A name that is not in an incomplete catalog is *not yet
/// known*, not *unknown*: diagnostics stay silent and completion still offers what it has.
public struct SQLCatalog: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var name: String
        public var typeName: String
        public var isNotNull: Bool
        public var isPrimaryKey: Bool
        public var hasDefault: Bool
        /// A generated column (`GENERATED ALWAYS AS …`): it cannot be written.
        public var isGenerated: Bool
        /// `GENERATED ALWAYS AS IDENTITY`: the server assigns it and refuses a value.
        public var isIdentityAlways: Bool

        public init(
            name: String, typeName: String = "", isNotNull: Bool = false, isPrimaryKey: Bool = false,
            hasDefault: Bool = false, isGenerated: Bool = false, isIdentityAlways: Bool = false
        ) {
            self.name = name
            self.typeName = typeName
            self.isNotNull = isNotNull
            self.isPrimaryKey = isPrimaryKey
            self.hasDefault = hasDefault
            self.isGenerated = isGenerated
            self.isIdentityAlways = isIdentityAlways
        }

        /// Can an `INSERT` or `UPDATE` name this column?
        public var isWritable: Bool { !isGenerated && !isIdentityAlways }
    }

    public struct Relation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case table, view }
        public var schema: String?
        public var name: String
        public var kind: Kind
        /// Nil until the relation's columns have been read.
        public var columns: [Column]?

        public init(schema: String? = nil, name: String, kind: Kind = .table, columns: [Column]? = nil) {
            self.schema = schema
            self.name = name
            self.kind = kind
            self.columns = columns
        }
    }

    /// A declared foreign key, composite or not. Only these are ever offered as join conditions;
    /// the engine never infers a relationship from column names.
    public struct ForeignKey: Equatable, Sendable {
        public var name: String?
        public var fromRelation: String
        public var fromColumns: [String]
        public var toRelation: String
        public var toColumns: [String]

        public init(name: String? = nil, fromRelation: String, fromColumns: [String], toRelation: String, toColumns: [String]) {
            self.name = name
            self.fromRelation = fromRelation
            self.fromColumns = fromColumns
            self.toRelation = toRelation
            self.toColumns = toColumns
        }
    }

    public var relations: [Relation]
    public var foreignKeys: [ForeignKey]
    public var defaultSchema: String?
    public var isComplete: Bool

    public init(
        relations: [Relation] = [], foreignKeys: [ForeignKey] = [], defaultSchema: String? = nil, isComplete: Bool = false
    ) {
        self.relations = relations
        self.foreignKeys = foreignKeys
        self.defaultSchema = defaultSchema
        self.isComplete = isComplete
    }

    /// Case-insensitive, exact-case first (names differ by case in PostgreSQL when quoted).
    public func relation(named name: String) -> Relation? {
        relations.first { $0.name == name } ?? relations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func relation(qualifiedBy parts: [String]) -> Relation? {
        guard let name = parts.last else { return nil }
        if parts.count == 1 { return relation(named: name) }
        guard parts.count == 2 else { return nil }
        let matching = relations.lazy.filter {
            ($0.schema ?? defaultSchema)?.caseInsensitiveCompare(parts[0]) == .orderedSame
        }
        return matching.first { $0.name == name } ?? matching.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func foreignKeys(between first: String, and second: String) -> [ForeignKey] {
        foreignKeys.filter {
            ($0.fromRelation.caseInsensitiveCompare(first) == .orderedSame && $0.toRelation.caseInsensitiveCompare(second) == .orderedSame)
                || ($0.fromRelation.caseInsensitiveCompare(second) == .orderedSame && $0.toRelation.caseInsensitiveCompare(first) == .orderedSame)
        }
    }

    public var hasUnloadedColumns: Bool { relations.contains { $0.columns == nil } }
}

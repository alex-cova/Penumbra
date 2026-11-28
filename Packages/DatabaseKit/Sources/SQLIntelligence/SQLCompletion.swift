import Foundation

public struct SQLCompletionItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, table, view, column, function, alias, cte, schema, type, joinCondition
    }

    public var label: String
    /// What replaces the typed prefix. Quoted when the name needs it.
    public var insertText: String
    public var kind: Kind
    public var detail: String?
    /// Where the caret goes, counted back from the end of `insertText` (inside `()` for a function).
    public var caretOffsetFromEnd: Int?

    public init(label: String, insertText: String? = nil, kind: Kind, detail: String? = nil, caretOffsetFromEnd: Int? = nil) {
        self.label = label
        self.insertText = insertText ?? label
        self.kind = kind
        self.detail = detail
        self.caretOffsetFromEnd = caretOffsetFromEnd
    }
}

public struct SQLCompletionResult: Equatable, Sendable {
    /// The text the chosen item replaces: the part of the word before the caret.
    public var replacement: NSRange
    public var items: [SQLCompletionItem]
    /// What the engine decided the caret is in, for tests and for the UI to explain an empty list.
    public var context: String

    public init(replacement: NSRange, items: [SQLCompletionItem], context: String) {
        self.replacement = replacement
        self.items = items
        self.context = context
    }
}

/// Semantic completion. It understands the statement around the caret (aliases, CTEs, derived
/// tables, subqueries, INSERT targets) and offers only what is valid there. It reads a catalog
/// snapshot and never waits for anything.
public enum SQLCompletionEngine {
    public static func complete(text: String, caret: Int, dialect: SQLDialect, catalog: SQLCatalog) -> SQLCompletionResult {
        let lexer = SQLLexer(text, dialect: dialect)
        let allTokens = lexer.tokenize()
        let units = lexer.units
        let caret = min(max(caret, 0), units.count)
        let empty = NSRange(location: caret, length: 0)

        // Inside a string or a comment nothing is offered (word completion is the editor's job).
        for token in allTokens where token.kind == .string || token.kind == .comment {
            if (token.start < caret && caret < token.end) || (caret == token.end && !token.isTerminated && token.length > 0) {
                return SQLCompletionResult(replacement: empty, items: [], context: "string-or-comment")
            }
        }

        let statements = SQLStatementSplitter.split(tokens: allTokens, units: units, dialect: dialect)
        var statementTokens: [SQLToken] = []
        if let statement = statements.first(where: { caret >= $0.start && caret <= $0.extendedEnd }) ?? statements.last(where: { $0.extendedEnd < caret && !$0.isTerminated }) {
            statementTokens = allTokens.filter { $0.start >= statement.start && $0.end <= statement.end && $0.kind != .directive }
        }
        let model = SQLModel(tokens: statementTokens.map { $0.kind == .delimiter ? SQLToken(.symbol, $0.start, $0.end) : $0 }, units: units, dialect: dialect)

        // The word being typed, if the caret touches one.
        var typing: Int?
        var prefix = ""
        var replacement = empty
        for (index, token) in model.tokens.enumerated() where token.start < caret && caret <= token.end {
            switch token.kind {
            case .word:
                typing = index
                prefix = String(decoding: units[token.start..<caret], as: UTF16.self)
                replacement = NSRange(location: token.start, length: caret - token.start)
            case .quotedIdentifier:
                typing = index
                prefix = String(decoding: units[(token.start + 1)..<max(token.start + 1, caret)], as: UTF16.self)
                replacement = NSRange(location: token.start + 1, length: max(0, caret - token.start - 1))
            case .number, .parameter:
                return SQLCompletionResult(replacement: empty, items: [], context: "number")
            default:
                break
            }
        }
        let insidePlainQuote = typing.map { model.tokens[$0].kind == .quotedIdentifier } ?? false
        let before = typing ?? model.tokens.firstIndex { $0.start >= caret } ?? model.tokens.count  // position: tokens[..<before] precede
        let position = before

        func finish(_ context: String, _ candidates: [Candidate]) -> SQLCompletionResult {
            let ranked = rank(candidates, prefix: prefix)
            return SQLCompletionResult(replacement: replacement, items: ranked.map { insidePlainQuote ? unquoted($0) : $0 }, context: context)
        }

        // Member access: `alias.`, `table.`, `schema.table.`
        if model.isSymbol(position - 1, ".") {
            var parts: [String] = []
            var cursor = position - 2
            while cursor >= 0, model.isIdentifier(cursor), let part = model.name(cursor) {
                parts.insert(part, at: 0)
                if cursor - 1 >= 0, model.isSymbol(cursor - 1, ".") { cursor -= 2 } else { break }
            }
            let blockID = model.innermostBlock(at: position)
            let segmentIndex = model.segmentIndex(in: blockID, at: position)
            let sources = segmentIndex.map { model.visibleSources(block: blockID, segment: $0, catalog: catalog) } ?? []
            if parts.count == 1, let source = sources.first(where: { $0.qualifier.caseInsensitiveCompare(parts[0]) == .orderedSame }) {
                let candidates = (source.columns ?? []).map { column(column: $0, source: source, dialect: dialect, qualified: false) }
                return finish("member-of-\(source.qualifier)", candidates)
            }
            // `schema.` lists that schema's tables; the catalog is one schema today.
            if parts.count == 1, catalog.defaultSchema?.caseInsensitiveCompare(parts[0]) == .orderedSame
                || catalog.relations.contains(where: { $0.schema?.caseInsensitiveCompare(parts[0]) == .orderedSame })
            {
                return finish("schema", catalog.relations.filter { $0.schema == nil || $0.schema?.caseInsensitiveCompare(parts[0]) == .orderedSame }.map { relationCandidate($0, dialect: dialect) })
            }
            if parts.count == 2, let relation = catalog.relation(qualifiedBy: parts) {
                return finish("member-of-\(relation.name)", (relation.columns ?? []).map { column(column: SQLResolvedColumn(name: $0.name, typeName: $0.typeName, column: $0), source: nil, dialect: dialect, qualified: false) })
            }
            return finish("unknown-qualifier", [])
        }

        // `::type` and `CAST(x AS type)`
        if model.tokens.indices.contains(position - 1), model.tokens[position - 1].kind == .symbol,
           model.tokens[position - 1].length == 2, units[model.tokens[position - 1].start] == 58, dialect == .postgres
        {
            return finish("type", SQLKeywords.types(dialect).map { Candidate(item: SQLCompletionItem(label: $0, kind: .type), group: 0) })
        }
        if model.word(position - 1) == "AS", let open = enclosingParenthesis(model, position), open > 0, model.word(open - 1) == "CAST" {
            return finish("type", SQLKeywords.types(dialect).map { Candidate(item: SQLCompletionItem(label: $0, kind: .type), group: 0) })
        }

        // Nothing before the caret in this statement, or in a fresh subquery.
        if position == 0 || model.tokens.isEmpty {
            return finish("statement-start", SQLKeywords.statementStarters(dialect).map { keyword($0) })
        }
        let blockID = model.innermostBlock(at: position)
        guard let segmentIndex = model.segmentIndex(in: blockID, at: position) else {
            return finish("subquery-start", ["SELECT", "WITH", "VALUES"].map { keyword($0) })
        }
        let block = model.blocks[blockID]
        let segment = block.segments[segmentIndex]
        // Right after `(` of a subquery, or right after a WITH list: a query starts.
        if position == block.start, blockID != 0 {
            return finish("subquery-start", ["SELECT", "WITH", "VALUES"].map { keyword($0) })
        }
        let clauseIndex = model.clauseIndex(in: segment, at: position)
        let clause = clauseIndex.map { segment.clauses[$0] }
        let previous = position - 1
        // `FROM (|` and `EXISTS (|`: what follows the parenthesis is a query.
        if model.isSymbol(previous, "("), model.matching[previous].map({ _ in true }) ?? false,
           let opener = clause?.name, ["FROM", "JOIN"].contains(opener) || model.word(previous - 1) == "EXISTS",
           ["FROM", "JOIN", "EXISTS", ","].contains(model.word(previous - 1) ?? (model.isSymbol(previous - 1, ",") ? "," : ""))
        {
            return finish("subquery-start", ["SELECT", "WITH", "VALUES"].map { keyword($0) })
        }
        let sources = model.visibleSources(block: blockID, segment: segmentIndex, catalog: catalog)
        let parenthesis = enclosingParenthesis(model, position, within: segment)

        guard let clause else {
            // Before any clause: after `WITH x AS (…)`, a bare keyword, or the start of INSERT/UPDATE/DELETE.
            if model.word(previous) == "WITH" || model.word(previous) == "RECURSIVE" {
                return finish("with-name", [])
            }
            if blockID == 0, segment.kind == .other, segmentIndex == 0, block.ctes.isEmpty {
                return finish("statement-start", SQLKeywords.statementStarters(dialect).map { keyword($0) })
            }
            return finish("statement-start", ["SELECT", "INSERT", "UPDATE", "DELETE", "VALUES"].map { keyword($0) })
        }

        switch clause.name {
        case "SELECT":
            return finish("select-list", expressionCandidates(model, position, sources, dialect, catalog, selectList: true))
        case "FROM", "JOIN":
            fallthrough
        case "USING" where segment.kind == .select:
            let expectingSource = previous == clause.keyword || model.isSymbol(previous, ",") || ["LATERAL", "ONLY"].contains(model.word(previous) ?? "")
            if clause.name == "FROM", segment.kind == .delete, previous == clause.keyword || expectingSource {
                return finish("table", tableCandidates(model, blockID, catalog, dialect))
            }
            if expectingSource, parenthesis == nil || clause.name != "USING" {
                return finish("table", tableCandidates(model, blockID, catalog, dialect))
            }
            var words = SQLKeywords.afterSource(dialect)
            if clause.name == "JOIN" { words = ["ON", "USING"] + words }
            return finish("after-source", words.map { keyword($0) })
        case "ON":
            if previous == clause.keyword {
                return finish("join-condition", joinConditionCandidates(model, blockID, segment, segmentIndex, clause, sources, catalog, dialect)
                    + expressionCandidates(model, position, sources, dialect, catalog, selectList: false))
            }
            return finish("condition", expressionCandidates(model, position, sources, dialect, catalog, selectList: false))
        case "UPDATE":
            if previous == clause.keyword || model.isSymbol(previous, ",") {
                return finish("table", tableCandidates(model, blockID, catalog, dialect))
            }
            return finish("after-update-target", [keyword("SET")])
        case "SET":
            // `SET a = 1, |` names a column to assign; `SET a = |` is a value.
            if previous == clause.keyword || (model.isSymbol(previous, ",") && parenthesis == nil) {
                let target = sources.first
                return finish("set-target", writableColumns(of: target, dialect))
            }
            return finish("set-value", expressionCandidates(model, position, sources, dialect, catalog, selectList: false))
        case "INTO", "INSERT":
            if clause.name == "INSERT" { return finish("insert-keyword", [keyword("INTO")]) }
            if previous == clause.keyword || ["TABLE"].contains(model.word(previous) ?? "") {
                return finish("table", tableCandidates(model, blockID, catalog, dialect))
            }
            if let open = parenthesis, model.isSymbol(open, "("), open > clause.keyword {
                // The target's writable columns, minus those already listed.
                let listed = Set(model.identifiersInside(parenthesis: open).map { $0.lowercased() })
                let typingName = typing.flatMap { model.name($0) }?.lowercased()
                let target = sources.first
                let candidates = writableColumns(of: target, dialect).filter {
                    let name = $0.item.label.lowercased()
                    return !listed.contains(name) || name == typingName && listed.filter({ $0 == name }).count <= 1
                }
                return finish("insert-columns", candidates)
            }
            return finish("after-insert-target", ["VALUES", "SELECT", "DEFAULT VALUES", "WITH"].map { keyword($0) })
        case "VALUES":
            return finish("values", ["DEFAULT", "NULL", "TRUE", "FALSE"].map { keyword($0) } + functionCandidates(dialect))
        case "DELETE":
            return finish("delete", [keyword("FROM")])
        case "LIMIT", "OFFSET", "FETCH":
            return finish("limit", [])
        default:
            return finish("condition", expressionCandidates(model, position, sources, dialect, catalog, selectList: false))
        }
    }

    // MARK: Candidates

    struct Candidate {
        var item: SQLCompletionItem
        /// Lower comes first among equal matches.
        var group: Int
    }

    private static func keyword(_ word: String) -> Candidate {
        Candidate(item: SQLCompletionItem(label: word, kind: .keyword), group: 50)
    }

    private static func functionCandidates(_ dialect: SQLDialect) -> [Candidate] {
        SQLKeywords.functions(dialect).map {
            Candidate(item: SQLCompletionItem(
                label: $0.name, insertText: "\($0.name)()", kind: .function, detail: $0.signature, caretOffsetFromEnd: 1
            ), group: 30)
        }
    }

    private static func relationCandidate(_ relation: SQLCatalog.Relation, dialect: SQLDialect) -> Candidate {
        Candidate(item: SQLCompletionItem(
            label: relation.name, insertText: SQLQuoting.insertName(relation.name, dialect: dialect),
            kind: relation.kind == .view ? .view : .table, detail: relation.kind == .view ? "view" : "table"
        ), group: 10)
    }

    private static func tableCandidates(_ model: SQLModel, _ blockID: Int, _ catalog: SQLCatalog, _ dialect: SQLDialect) -> [Candidate] {
        var candidates: [Candidate] = []
        // CTEs of this and every enclosing block come first: they shadow tables of the same name.
        var seen = Set<String>()
        var current: Int? = blockID
        while let id = current {
            for cte in model.blocks[id].ctes.reversed() where seen.insert(cte.name.lowercased()).inserted {
                candidates.append(Candidate(item: SQLCompletionItem(
                    label: cte.name, insertText: SQLQuoting.insertName(cte.name, dialect: dialect), kind: .cte, detail: "common table expression"
                ), group: 5))
            }
            current = model.blocks[id].parent
        }
        candidates += catalog.relations.filter { !seen.contains($0.name.lowercased()) }.map { relationCandidate($0, dialect: dialect) }
        return candidates
    }

    private static func column(column: SQLResolvedColumn, source: SQLResolvedSource?, dialect: SQLDialect, qualified: Bool) -> Candidate {
        let quotedName = SQLQuoting.insertName(column.name, dialect: dialect)
        let qualifier = source.map { SQLQuoting.insertName($0.qualifier, dialect: dialect) }
        var detailParts: [String] = []
        if !column.typeName.isEmpty { detailParts.append(column.typeName) }
        if column.column?.isPrimaryKey == true { detailParts.append("primary key") }
        if column.column?.isNotNull == true, column.column?.isPrimaryKey != true { detailParts.append("not null") }
        if qualified, let source { detailParts.append("from \(source.qualifier)") }
        return Candidate(item: SQLCompletionItem(
            label: qualified && source != nil ? "\(source!.qualifier).\(column.name)" : column.name,
            insertText: qualified && qualifier != nil ? "\(qualifier!).\(quotedName)" : quotedName,
            kind: .column, detail: detailParts.isEmpty ? nil : detailParts.joined(separator: ", ")
        ), group: 10)
    }

    private static func writableColumns(of source: SQLResolvedSource?, _ dialect: SQLDialect) -> [Candidate] {
        guard let columns = source?.columns else { return [] }
        return columns.filter { $0.column?.isWritable ?? true }.map { column(column: $0, source: source, dialect: dialect, qualified: false) }
    }

    /// Columns of every visible source, a column that two sources share offered qualified (so the
    /// result is not ambiguous), then qualifiers, functions and keywords.
    private static func expressionCandidates(
        _ model: SQLModel, _ position: Int, _ sources: [SQLResolvedSource], _ dialect: SQLDialect, _ catalog: SQLCatalog,
        selectList: Bool
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var counts: [String: Int] = [:]
        for source in sources { for column in source.columns ?? [] { counts[column.name.lowercased(), default: 0] += 1 } }
        let previous = position - 1
        let afterOperand = isOperand(model, previous)
        if !afterOperand {
            if selectList, model.word(previous) == "SELECT" || model.isSymbol(previous, ",") || model.word(previous) == "DISTINCT" {
                candidates.append(Candidate(item: SQLCompletionItem(label: "*", kind: .keyword, detail: "all columns"), group: 5))
            }
            for source in sources {
                for column in source.columns ?? [] {
                    let ambiguous = (counts[column.name.lowercased()] ?? 0) > 1
                    candidates.append(self.column(column: column, source: source, dialect: dialect, qualified: ambiguous))
                }
            }
            for source in sources where !source.qualifier.isEmpty {
                candidates.append(Candidate(item: SQLCompletionItem(
                    label: source.qualifier, insertText: SQLQuoting.insertName(source.qualifier, dialect: dialect), kind: .alias,
                    detail: source.relation.map { $0 == source.qualifier ? "table" : "alias of \($0)" } ?? (source.kind == .cte ? "common table expression" : "derived table")
                ), group: 20))
            }
            candidates += functionCandidates(dialect)
            candidates += SQLKeywords.expressionKeywords.map { keyword($0) }
        } else {
            var words = SQLKeywords.afterOperand
            if selectList { words = ["FROM", "AS", "AND", "OR", "IN", "LIKE", "BETWEEN", "IS NULL", "IS NOT NULL"] }
            candidates += words.map { keyword($0) }
        }
        return candidates
    }

    /// `ON` offers the declared foreign keys between the table just joined and the earlier ones.
    private static func joinConditionCandidates(
        _ model: SQLModel, _ blockID: Int, _ segment: SQLModel.Segment, _ segmentIndex: Int, _ clause: SQLModel.Clause,
        _ sources: [SQLResolvedSource], _ catalog: SQLCatalog, _ dialect: SQLDialect
    ) -> [Candidate] {
        // The source the ON belongs to is the one its JOIN introduced.
        let joined = segment.sources.firstIndex { source in
            segment.clauses.indices.contains(source.clause) && segment.clauses[source.clause].keyword == model.tokens.indices.filter { model.word($0) == "JOIN" && $0 < clause.keyword }.last
        }
        guard let joinedIndex = joined, sources.indices.contains(joinedIndex), let joinedRelation = sources[joinedIndex].relation else { return [] }
        var candidates: [Candidate] = []
        func qualified(_ source: SQLResolvedSource, _ column: String) -> String {
            "\(SQLQuoting.insertName(source.qualifier, dialect: dialect)).\(SQLQuoting.insertName(column, dialect: dialect))"
        }
        for (index, other) in sources.enumerated() where index != joinedIndex && index < segment.sources.count {
            guard let otherRelation = other.relation else { continue }
            for key in catalog.foreignKeys(between: joinedRelation, and: otherRelation) {
                let pairs = zip(key.fromColumns, key.toColumns)
                // The key points one way, but on a self-join either side can be the joined one.
                var orientations: [(fromSource: SQLResolvedSource, toSource: SQLResolvedSource)] = []
                if key.fromRelation.caseInsensitiveCompare(joinedRelation) == .orderedSame, key.toRelation.caseInsensitiveCompare(otherRelation) == .orderedSame {
                    orientations.append((sources[joinedIndex], other))
                }
                if key.fromRelation.caseInsensitiveCompare(otherRelation) == .orderedSame, key.toRelation.caseInsensitiveCompare(joinedRelation) == .orderedSame {
                    orientations.append((other, sources[joinedIndex]))
                }
                for orientation in orientations {
                    let text = pairs.map { "\(qualified(orientation.fromSource, $0)) = \(qualified(orientation.toSource, $1))" }.joined(separator: " AND ")
                    candidates.append(Candidate(item: SQLCompletionItem(
                        label: text, kind: .joinCondition, detail: "foreign key" + (key.name.map { " \($0)" } ?? "")
                    ), group: 0))
                }
            }
        }
        return candidates
    }

    // MARK: Helpers

    private static func isOperand(_ model: SQLModel, _ index: Int) -> Bool {
        guard model.tokens.indices.contains(index) else { return false }
        let token = model.tokens[index]
        switch token.kind {
        case .quotedIdentifier, .number, .string, .parameter: return true
        case .symbol: return model.isSymbol(index, ")")
        case .word:
            return !(Self.operandBlockers.contains(model.word(index) ?? ""))
        default: return false
        }
    }

    private static let operandBlockers: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "ON", "BY", "HAVING", "SET", "WHEN", "THEN", "ELSE", "CASE", "IN", "LIKE", "BETWEEN",
        "IS", "JOIN", "DISTINCT", "ALL", "ANY", "EXISTS", "AS", "LIMIT", "OFFSET", "RETURNING", "VALUES", "USING", "UNION", "INTERSECT", "EXCEPT",
        "INTO", "UPDATE", "DELETE", "INSERT", "WITH", "INTERVAL", "ILIKE", "REGEXP", "RLIKE", "GLOB", "ESCAPE",
    ]

    /// The innermost parenthesis around `position` that is not a subquery block.
    private static func enclosingParenthesis(_ model: SQLModel, _ position: Int, within segment: SQLModel.Segment? = nil) -> Int? {
        var best: Int?
        for (open, close) in model.matching where model.isSymbol(open, "(") && open < position && position <= close {
            if model.block(opening: open) != nil { continue }
            if let segment, open < segment.start { continue }
            if best == nil || open > best! { best = open }
        }
        return best
    }

    private static func unquoted(_ item: SQLCompletionItem) -> SQLCompletionItem {
        var item = item
        item.insertText = item.label
        return item
    }

    // MARK: Ranking

    /// Exact, then prefix, then a match at a word boundary (`cid` for `customer_id`), then a
    /// subsequence. Within one rank the context's own group order decides, then catalog order.
    static func rank(_ candidates: [Candidate], prefix: String) -> [SQLCompletionItem] {
        let needle = prefix.lowercased()
        var scored: [(rank: Int, group: Int, order: Int, item: SQLCompletionItem)] = []
        var seen = Set<String>()
        for (order, candidate) in candidates.enumerated() {
            let key = candidate.item.kind.rawValue + "\u{1}" + candidate.item.label
            guard seen.insert(key).inserted else { continue }
            guard let match = matchRank(candidate.item.label.lowercased(), needle) else { continue }
            scored.append((match, candidate.group, order, candidate.item))
        }
        scored.sort { ($0.rank, $0.group, $0.order) < ($1.rank, $1.group, $1.order) }
        return scored.map(\.item)
    }

    private static func matchRank(_ label: String, _ needle: String) -> Int? {
        if needle.isEmpty { return 1 }
        if label == needle { return 0 }
        if label.hasPrefix(needle) { return 1 }
        // The qualified form `alias.col` matches on the part after the dot too.
        if let dot = label.firstIndex(of: "."), label[label.index(after: dot)...].hasPrefix(needle) { return 2 }
        let boundaries = label.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." }).map { String($0) }
        if boundaries.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 2 }
        // A fuzzy match must start where a word starts (`ci` for `customer_id`), so `em` does not
        // find `to_timestamp`.
        guard needle.count >= 2, let first = needle.first else { return nil }
        let wordStarts = Set(label.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." }).compactMap(\.first))
        guard wordStarts.contains(first) else { return nil }
        var index = label.startIndex
        for character in needle {
            guard let found = label[index...].firstIndex(of: character) else { return nil }
            index = label.index(after: found)
        }
        return 3
    }
}

/// Quoting names the way the dialect needs them, so a completion never produces SQL that fails.
public enum SQLQuoting {
    private static let reserved: Set<String> = [
        "ALL", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "CONSTRAINT", "CREATE", "CROSS",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END",
        "EXCEPT", "EXISTS", "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "FULL", "GRANT", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT",
        "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "NATURAL", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER",
        "OVER", "PARTITION", "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "ROW", "ROWS", "SELECT", "SET", "TABLE", "THEN", "TO", "TRUE",
        "UNION", "UNIQUE", "UPDATE", "USER", "USING", "VALUES", "WHEN", "WHERE", "WINDOW", "WITH",
    ]

    /// A bare name is a plain identifier that is not a reserved word and (PostgreSQL) is already
    /// lower case, because PostgreSQL folds an unquoted name to lower case.
    public static func needsQuoting(_ name: String, dialect: SQLDialect) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return true }
        let plain = name.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || ($0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)) }
        if !plain { return true }
        if reserved.contains(name.uppercased()) { return true }
        if dialect == .postgres, name != name.lowercased() { return true }
        return false
    }

    public static func quote(_ name: String, dialect: SQLDialect) -> String {
        let character = dialect.identifierQuote
        return "\(character)\(name.replacingOccurrences(of: String(character), with: "\(character)\(character)"))\(character)"
    }

    public static func insertName(_ name: String, dialect: SQLDialect) -> String {
        needsQuoting(name, dialect: dialect) ? quote(name, dialect: dialect) : name
    }
}

import Foundation

public struct SQLDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning, info }

    public struct Fix: Equatable, Sendable {
        public var title: String
        public var range: NSRange
        public var replacement: String
    }

    public var range: NSRange
    public var severity: Severity
    public var message: String
    /// A stable id (`unknown-table`, `ambiguous-column`, …) for tests, suppression and quick fixes.
    public var code: String
    public var fixes: [Fix]

    init(_ range: NSRange, _ severity: Severity, _ code: String, _ message: String, fixes: [Fix] = []) {
        self.range = range
        self.severity = severity
        self.code = code
        self.message = message
        self.fixes = fixes
    }
}

/// Problems that can be found without running anything.
///
/// The rule that matters: **a name is reported unknown only when the catalog is complete and
/// fresh.** With a partial or stale catalog the object may simply not be loaded, so nothing is
/// said (the UI shows "schema loading" instead). A column is only checked against sources whose
/// columns are all known, and a reference is only a *column* reference where SQL can only mean one,
/// so a keyword or a select alias is never flagged.
public enum SQLDiagnosticsEngine {
    public static func diagnose(text: String, dialect: SQLDialect, catalog: SQLCatalog) -> [SQLDiagnostic] {
        let lexer = SQLLexer(text, dialect: dialect)
        let allTokens = lexer.tokenize()
        let units = lexer.units
        var result: [SQLDiagnostic] = []

        for token in allTokens where !token.isTerminated {
            switch token.kind {
            case .string: result.append(SQLDiagnostic(token.range, .error, "unterminated-string", "This string is never closed."))
            case .quotedIdentifier: result.append(SQLDiagnostic(token.range, .error, "unterminated-identifier", "This quoted name is never closed."))
            case .comment: result.append(SQLDiagnostic(token.range, .warning, "unterminated-comment", "This comment is never closed."))
            default: break
            }
        }

        var tokenIndex = allTokens.startIndex
        for statement in SQLStatementSplitter.split(tokens: allTokens, units: units, dialect: dialect) {
            while tokenIndex < allTokens.endIndex, allTokens[tokenIndex].start < statement.start { tokenIndex += 1 }
            let start = tokenIndex
            while tokenIndex < allTokens.endIndex, allTokens[tokenIndex].end <= statement.end { tokenIndex += 1 }
            let tokens = allTokens[start..<tokenIndex]
                .map { $0.kind == .delimiter ? SQLToken(.symbol, $0.start, $0.end) : $0 }
            let model = SQLModel(tokens: tokens, units: units, dialect: dialect)
            result += parentheses(model)
            result += dialectProblems(model)
            result += functionArity(model)
            for blockID in model.blocks.indices {
                for segmentIndex in model.blocks[blockID].segments.indices {
                    result += segmentProblems(model, blockID, segmentIndex, catalog)
                }
            }
        }
        // One finding per place and code, in the order the text reads.
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.range.location):\($0.range.length):\($0.code)").inserted }
            .sorted { ($0.range.location, $0.code) < ($1.range.location, $1.code) }
    }

    // MARK: Structure

    private static func parentheses(_ model: SQLModel) -> [SQLDiagnostic] {
        var result: [SQLDiagnostic] = []
        var depth = 0
        for (index, token) in model.tokens.enumerated() {
            if model.isSymbol(index, "(") {
                depth += 1
                if (model.matching[index] ?? 0) >= model.tokens.count {
                    result.append(SQLDiagnostic(token.range, .error, "unclosed-parenthesis", "This ( has no matching )."))
                }
            } else if model.isSymbol(index, ")") {
                depth -= 1
                if model.matching[index] == nil {
                    result.append(SQLDiagnostic(token.range, .error, "unmatched-parenthesis", "This ) has no matching (."))
                    depth = max(depth, 0)
                }
            }
        }
        return result
    }

    // MARK: Dialect

    private static func dialectProblems(_ model: SQLModel) -> [SQLDiagnostic] {
        var result: [SQLDiagnostic] = []
        let dialect = model.dialect
        for (index, token) in model.tokens.enumerated() {
            let word = model.word(index)
            func report(_ code: String, _ message: String, severity: SQLDiagnostic.Severity = .warning) {
                result.append(SQLDiagnostic(token.range, severity, code, message))
            }
            switch (word, token.kind) {
            case ("ILIKE", _) where dialect != .postgres:
                report("dialect-ilike", "ILIKE is PostgreSQL's. Use LOWER(a) LIKE LOWER(b) in \(dialect.displayName).")
            case ("RETURNING", _) where dialect == .mysql:
                report("dialect-returning", "MySQL has no RETURNING clause.", severity: .error)
            case ("AUTO_INCREMENT", _) where dialect != .mysql:
                report("dialect-auto-increment", dialect == .sqlite ? "SQLite spells it AUTOINCREMENT, and only after INTEGER PRIMARY KEY." : "PostgreSQL uses GENERATED … AS IDENTITY or SERIAL.")
            case ("SERIAL", _) where dialect != .postgres, ("BIGSERIAL", _) where dialect != .postgres:
                report("dialect-serial", "SERIAL is PostgreSQL's. Use an auto-increment key in \(dialect.displayName).")
            case ("CONFLICT", _) where dialect == .mysql && model.word(index - 1) == "ON":
                report("dialect-on-conflict", "MySQL uses ON DUPLICATE KEY UPDATE instead of ON CONFLICT.", severity: .error)
            case ("DUPLICATE", _) where dialect != .mysql && model.word(index - 1) == "ON":
                report("dialect-on-duplicate", "ON DUPLICATE KEY UPDATE is MySQL's. Use ON CONFLICT … DO UPDATE.", severity: .error)
            case (_, .symbol) where dialect == .postgres && token.length == 1 && model.units[token.start] == 96:
                report("dialect-backtick", "PostgreSQL quotes names with \", not `.", severity: .error)
            case (_, .symbol) where dialect != .postgres && token.length == 2 && model.units[token.start] == 58 && model.units[token.start + 1] == 58:
                report("dialect-cast", "The :: cast is PostgreSQL's. Use CAST(x AS type).", severity: .error)
            default:
                break
            }
        }
        return result
    }

    // MARK: Functions

    /// Arity for functions whose argument count is fixed by the standard or the documentation.
    private static let arity: [String: ClosedRange<Int>] = [
        "coalesce": 1...Int.max, "nullif": 2...2, "replace": 3...3, "lower": 1...1, "upper": 1...1, "length": 1...1,
        "abs": 1...1, "round": 1...2, "trim": 1...3, "avg": 1...1, "sum": 1...1, "min": 1...1, "max": 1...1, "ifnull": 2...2,
        "iif": 3...3, "if": 3...3, "concat_ws": 2...Int.max, "date_trunc": 2...3, "to_char": 2...2,
    ]

    private static func functionArity(_ model: SQLModel) -> [SQLDiagnostic] {
        var result: [SQLDiagnostic] = []
        for (index, token) in model.tokens.enumerated() where token.kind == .word && model.isSymbol(index + 1, "(") {
            let name = token.text(in: model.units).lowercased()
            guard let allowed = arity[name], SQLKeywords.function(named: name, model.dialect) != nil || ["trim", "if", "iif", "ifnull"].contains(name) else { continue }
            let close = min(model.matching[index + 1] ?? model.tokens.count, model.tokens.count)
            guard close < model.tokens.count else { continue }  // unclosed: the parenthesis problem is reported
            var count = 0
            var cursor = index + 2
            var sawContent = false
            while cursor < close {
                if model.isSymbol(cursor, "(") { sawContent = true; cursor = model.skipParen(cursor); continue }
                if model.isSymbol(cursor, ",") { count += 1 } else { sawContent = true }
                cursor += 1
            }
            let arguments = sawContent ? count + 1 : 0
            // `trim(both 'x' from s)` and `count(DISTINCT …)` have their own syntax: only check plain lists.
            if name == "trim", (index + 2..<close).contains(where: { ["BOTH", "LEADING", "TRAILING", "FROM"].contains(model.word($0) ?? "") }) { continue }
            if !allowed.contains(arguments) {
                let expected = allowed.upperBound == Int.max ? "at least \(allowed.lowerBound)" : (allowed.lowerBound == allowed.upperBound ? "\(allowed.lowerBound)" : "\(allowed.lowerBound) to \(allowed.upperBound)")
                result.append(SQLDiagnostic(token.range, .error, "function-arity", "\(name)() takes \(expected) argument\(allowed.upperBound == 1 ? "" : "s"), but \(arguments) \(arguments == 1 ? "is" : "are") given."))
            }
        }
        return result
    }

    // MARK: Names

    private static func segmentProblems(_ model: SQLModel, _ blockID: Int, _ segmentIndex: Int, _ catalog: SQLCatalog) -> [SQLDiagnostic] {
        var result: [SQLDiagnostic] = []
        let segment = model.blocks[blockID].segments[segmentIndex]
        let scopes = model.scopes(block: blockID, segment: segmentIndex, catalog: catalog)
        let sources = scopes.flatMap { $0 }

        // Unknown tables: only when the catalog is whole.
        if catalog.isComplete {
            for source in segment.sources {
                guard case .table(let parts) = source.kind, let table = parts.last else { continue }
                if parts.count == 1, model.findCTE(named: table, from: blockID) != nil { continue }
                if parts.count > 1 {
                    let schema = parts[parts.count - 2]
                    guard parts.count == 2,
                          catalog.defaultSchema?.caseInsensitiveCompare(schema) == .orderedSame else { continue }
                }
                if catalog.relation(qualifiedBy: parts) == nil {
                    let nameToken = model.tokens[source.start + (parts.count - 1) * 2]
                    result.append(SQLDiagnostic(nameToken.range, .error, "unknown-table", "There is no table or view named \"\(table)\"."))
                }
            }
        }
        guard catalog.isComplete, !scopes[0].isEmpty, sources.allSatisfy({ $0.columns != nil }) else { return result }

        let aliases = selectAliases(model, segment)
        for index in segment.start..<min(segment.end, model.tokens.count) {
            guard model.tokens[index].kind == .word || model.tokens[index].kind == .quotedIdentifier, let name = model.name(index) else { continue }
            if !isInsideOwnBlock(model, index, blockID, segment) { continue }
            let nextIsParenthesis = model.isSymbol(index + 1, "(")
            if nextIsParenthesis { continue }
            // Qualified: `q.col`
            if model.isSymbol(index - 1, "."), model.isIdentifier(index - 2), !model.isSymbol(index - 3, ".") {
                guard let qualifier = model.name(index - 2),
                      let source = scopes.lazy.compactMap({ $0.first { $0.qualifier.caseInsensitiveCompare(qualifier) == .orderedSame } }).first,
                      let columns = source.columns else { continue }
                if !columns.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    result.append(SQLDiagnostic(model.tokens[index].range, .error, "unknown-column", "\"\(source.qualifier)\" has no column \"\(name)\"."))
                }
                continue
            }
            guard model.tokens[index].kind == .quotedIdentifier || !isKeywordOrSpecial(model, index), isColumnPosition(model, index, segment) else { continue }
            if model.isSymbol(index + 1, ".") { continue }  // a qualifier, not a column
            if aliases.contains(name.lowercased()), inAliasVisibleClause(model, index, segment) { continue }
            // The innermost scope that has the name decides; ambiguity is only among that scope's sources.
            var owners: [SQLResolvedSource] = []
            for scope in scopes {
                owners = scope.filter { source in source.columns?.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? false }
                if !owners.isEmpty { break }
            }
            if owners.isEmpty {
                // `a.b` qualifier-looking words that match a source are fine.
                if sources.contains(where: { $0.qualifier.caseInsensitiveCompare(name) == .orderedSame }) { continue }
                result.append(SQLDiagnostic(model.tokens[index].range, .error, "unknown-column", "No table in this query has a column \"\(name)\"."))
            } else if owners.count > 1 {
                let range = model.tokens[index].range
                let names = owners.map(\.qualifier)
                result.append(SQLDiagnostic(
                    range, .error, "ambiguous-column", "\"\(name)\" is ambiguous: it is in \(names.map { "\"\($0)\"" }.joined(separator: " and ")).",
                    fixes: owners.map { owner in
                        SQLDiagnostic.Fix(
                            title: "Qualify as \(owner.qualifier).\(name)", range: range,
                            replacement: "\(SQLQuoting.insertName(owner.qualifier, dialect: model.dialect)).\(SQLQuoting.insertName(name, dialect: model.dialect))"
                        )
                    }
                ))
            }
        }
        result += insertCounts(model, segment)
        return result
    }

    /// The names the select list gives its columns, which ORDER BY and HAVING may use.
    private static func selectAliases(_ model: SQLModel, _ segment: SQLModel.Segment) -> Set<String> {
        guard let select = segment.clauses.first(where: { $0.name == "SELECT" }) else { return [] }
        var aliases = Set<String>()
        var index = select.keyword + 1
        while index < select.end {
            if model.isSymbol(index, "(") { index = model.skipParen(index); continue }
            if model.word(index) == "AS", model.isIdentifier(index + 1), let name = model.name(index + 1) { aliases.insert(name.lowercased()) }
            index += 1
        }
        return aliases
    }

    private static func inAliasVisibleClause(_ model: SQLModel, _ index: Int, _ segment: SQLModel.Segment) -> Bool {
        guard let clause = segment.clauses.last(where: { $0.keyword < index }) else { return false }
        return ["ORDER BY", "GROUP BY", "HAVING"].contains(clause.name)
    }

    /// Words inside a subquery belong to that subquery's own segments, which are checked on their own.
    private static func isInsideOwnBlock(_ model: SQLModel, _ index: Int, _ blockID: Int, _ segment: SQLModel.Segment) -> Bool {
        model.blocks.dropFirst().allSatisfy { other in
            other.id == blockID || !(other.start <= index && index < other.end) || other.open < model.blocks[blockID].open
        }
    }

    /// A word is a column reference only where SQL can mean nothing else: after an operator, comma,
    /// parenthesis or a clause keyword, in a clause that holds expressions.
    private static func isColumnPosition(_ model: SQLModel, _ index: Int, _ segment: SQLModel.Segment) -> Bool {
        guard let clause = segment.clauses.last(where: { $0.keyword < index }),
              ["SELECT", "WHERE", "HAVING", "GROUP BY", "ORDER BY", "ON", "SET", "RETURNING"].contains(clause.name) else { return false }
        // In SET, only the right-hand side is checked (the left names a column to write, checked by INSERT/UPDATE rules).
        let previous = index - 1
        guard model.tokens.indices.contains(previous) else { return false }
        if clause.name == "SET", model.isSymbol(previous, ",") || model.word(previous) == "SET" { return false }
        if model.word(previous) == "AS" || model.isSymbol(previous, ".") { return false }
        if clause.name == "SELECT", model.word(index + 1) != nil, !["FROM", "AS", "AND", "OR", "IN", "LIKE", "BETWEEN", "IS", "NOT", "THEN", "ELSE", "END", "WHEN"].contains(model.word(index + 1) ?? ""), !model.isSymbol(index + 1, ",") {
            // `expr alias`: this word is the alias.
            if model.tokens[previous].kind != .symbol || model.isSymbol(previous, ")") { return false }
        }
        switch model.tokens[previous].kind {
        case .symbol: return true
        case .word: return !(["AS", "FROM", "JOIN", "INTO", "TABLE", "UPDATE", "INTERVAL", "TYPE"].contains(model.word(previous) ?? ""))
        default: return false
        }
    }

    private static func isKeywordOrSpecial(_ model: SQLModel, _ index: Int) -> Bool {
        guard let word = model.word(index) else { return false }
        // Whatever the parser took for a clause keyword is not a name.
        for block in model.blocks {
            for segment in block.segments where segment.clauses.contains(where: { $0.start <= index && index <= $0.keyword }) { return true }
        }
        return SQLKeywords.isKeyword(word) || SQLKeywords.function(named: word, model.dialect) != nil
    }

    // MARK: INSERT

    private static func insertCounts(_ model: SQLModel, _ segment: SQLModel.Segment) -> [SQLDiagnostic] {
        guard segment.kind == .insert,
              let into = segment.clauses.first(where: { $0.name == "INTO" }),
              let values = segment.clauses.first(where: { $0.name == "VALUES" }) else { return [] }
        var open = into.keyword + 1
        while open < values.keyword, !model.isSymbol(open, "(") { open += 1 }
        guard open < values.keyword, model.isSymbol(open, "(") else { return [] }
        let columnCount = model.identifiersInside(parenthesis: open).count
        guard columnCount > 0 else { return [] }
        var result: [SQLDiagnostic] = []
        var index = values.keyword + 1
        while index < values.end {
            guard model.isSymbol(index, "(") else { index += 1; continue }
            let close = min(model.matching[index] ?? model.tokens.count, model.tokens.count)
            var count = 1
            var cursor = index + 1
            var empty = true
            while cursor < close {
                if model.isSymbol(cursor, "(") { empty = false; cursor = model.skipParen(cursor); continue }
                if model.isSymbol(cursor, ",") { count += 1 } else { empty = false }
                cursor += 1
            }
            if !empty, close < model.tokens.count, count != columnCount {
                let range = NSRange(location: model.tokens[index].start, length: model.tokens[close].end - model.tokens[index].start)
                result.append(SQLDiagnostic(range, .error, "insert-count", "\(columnCount) column\(columnCount == 1 ? "" : "s") listed but \(count) value\(count == 1 ? "" : "s") given."))
            }
            index = model.skipParen(index)
        }
        return result
    }
}

extension SQLKeywords {
    /// Words that are never a column name in an expression (so they are never flagged unknown).
    public static func isKeyword(_ word: String) -> Bool {
        keywordSet.contains(word.uppercased())
    }

    private static let keywordSet: Set<String> = {
        var words: Set<String> = [
            "NULL", "TRUE", "FALSE", "DEFAULT", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "LOCALTIME",
            "LOCALTIMESTAMP", "ROW", "ROWS", "ASC", "DESC", "NULLS", "FIRST", "LAST", "DISTINCT", "ALL", "ANY", "SOME", "EXISTS", "CASE",
            "WHEN", "THEN", "ELSE", "END", "AND", "OR", "NOT", "IN", "IS", "LIKE", "ILIKE", "BETWEEN", "ESCAPE", "COLLATE", "OVER",
            "PARTITION", "BY", "ORDER", "GROUP", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "RANGE", "GROUPS", "INTERVAL", "AT",
            "TIME", "ZONE", "ONLY", "WITH", "WITHOUT", "AS", "ON", "USING", "FROM", "WHERE", "SELECT", "SET", "VALUES", "LIMIT", "OFFSET",
            "FETCH", "NEXT", "REGEXP", "RLIKE", "GLOB", "MATCH", "XOR", "DIV", "MOD", "BINARY", "UNKNOWN", "SIMILAR", "TO", "FILTER",
            "WITHIN", "TIES", "OTHERS", "EXCLUDE", "NO", "KEY", "ROWID", "OID", "CTID",
            "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "EPOCH", "DOW", "DOY", "WEEK", "QUARTER",
            "HAVING", "UNION", "INTERSECT", "EXCEPT", "MINUS", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER",
            "LATERAL", "INTO", "RETURNING", "WINDOW", "STRAIGHT_JOIN", "TABLESAMPLE", "DELETE", "INSERT", "UPDATE", "REPLACE", "TABLE",
            "BOTH", "LEADING", "TRAILING", "ESCAPE", "ZONE", "FOR", "OF", "CONFLICT", "NOTHING", "DO", "EXCLUDED",
        ]
        words.formUnion(SQLDialect.allCases.flatMap { types($0).map { $0.uppercased() } })
        return words
    }()
}

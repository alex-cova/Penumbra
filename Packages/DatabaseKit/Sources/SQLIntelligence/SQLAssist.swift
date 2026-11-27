import Foundation

public struct SQLHover: Equatable, Sendable {
    public var range: NSRange
    /// Markdown: a bold title line, then detail.
    public var markdown: String
}

public enum SQLDeclaration: Equatable, Sendable {
    /// A table or view of the catalog: the app opens its DDL.
    case relation(String)
    /// A column of a catalog relation.
    case column(relation: String, name: String)
    /// A CTE or alias defined in this text: jump to where it is written.
    case local(NSRange)
}

public struct SQLSignatureHelp: Equatable, Sendable {
    public var function: String
    public var signature: String
    public var summary: String
    /// Zero-based argument the caret is in.
    public var activeParameter: Int
}

public struct SQLTextEdit: Equatable, Sendable {
    public var range: NSRange
    public var newText: String
    public var title: String
}

/// Hover, go to declaration, signature help and code actions on the same model as completion.
public enum SQLAssist {
    // MARK: Identifying what is under the caret

    private struct Target {
        enum Kind {
            case function(String)
            case relation(SQLCatalog.Relation?, name: String)
            case column(source: SQLResolvedSource, column: SQLResolvedColumn)
            case ambiguousColumn(String, [String])
            case alias(source: SQLResolvedSource, range: NSRange?)
            case cte(String, range: NSRange?)
            case unknown
        }
        var kind: Kind
        var range: NSRange
    }

    private static func model(_ text: String, _ dialect: SQLDialect, caret: Int) -> (SQLModel, [UInt16])? {
        let lexer = SQLLexer(text, dialect: dialect)
        let tokens = lexer.tokenize()
        let statements = SQLStatementSplitter.split(tokens: tokens, units: lexer.units, dialect: dialect)
        // A caret after trailing spaces at the end of a statement still being typed belongs to it.
        guard let statement = statements.first(where: { caret >= $0.start && caret <= $0.extendedEnd })
            ?? statements.last(where: { $0.extendedEnd < caret && !$0.isTerminated }) else { return nil }
        let own = tokens.filter { $0.start >= statement.start && $0.end <= statement.end && $0.kind != .directive }
            .map { $0.kind == .delimiter ? SQLToken(.symbol, $0.start, $0.end) : $0 }
        return (SQLModel(tokens: own, units: lexer.units, dialect: dialect), lexer.units)
    }

    private static func target(at caret: Int, _ model: SQLModel, _ catalog: SQLCatalog) -> Target? {
        guard let index = model.tokens.firstIndex(where: { ($0.kind == .word || $0.kind == .quotedIdentifier) && $0.start <= caret && caret <= $0.end }),
              let name = model.name(index) else { return nil }
        let range = model.tokens[index].range
        if model.isSymbol(index + 1, "("), model.tokens[index].kind == .word {
            return Target(kind: .function(name), range: range)
        }
        let position = index
        let blockID = model.innermostBlock(at: position)
        guard let segmentIndex = model.segmentIndex(in: blockID, at: position) else { return nil }
        let segment = model.blocks[blockID].segments[segmentIndex]
        let scopes = model.scopes(block: blockID, segment: segmentIndex, catalog: catalog)

        // The name of a table in FROM/JOIN/INTO/UPDATE, or its alias.
        for source in segment.sources where source.start <= index && index < source.end {
            if case .table(let parts) = source.kind {
                let nameIndex = source.start + (parts.count - 1) * 2
                if index == nameIndex {
                    if parts.count == 1, let (cte, owner) = model.findCTE(named: name, from: blockID) {
                        return Target(kind: .cte(cte.name, range: cteRange(model, cte, owner)), range: range)
                    }
                    let relation = catalog.relation(qualifiedBy: parts)
                    guard relation != nil || catalog.coversName(qualifiedBy: parts) else { return nil }
                    return Target(kind: .relation(relation, name: name), range: range)
                }
            }
            if let alias = source.alias, model.name(index)?.caseInsensitiveCompare(alias) == .orderedSame, index > source.start {
                let resolved = model.resolve(source, block: blockID, catalog: catalog, visiting: [])
                return Target(kind: .alias(source: resolved, range: range), range: range)
            }
        }
        // `qualifier.column`
        if model.isSymbol(index - 1, "."), model.isIdentifier(index - 2), let qualifier = model.name(index - 2) {
            for scope in scopes {
                if let source = scope.first(where: { $0.qualifier.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                    if let column = source.columns?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        return Target(kind: .column(source: source, column: column), range: range)
                    }
                    return Target(kind: .unknown, range: range)
                }
            }
            return Target(kind: .unknown, range: range)
        }
        // `qualifier.` where the word is the qualifier
        if model.isSymbol(index + 1, ".") {
            for scope in scopes {
                if let source = scope.first(where: { $0.qualifier.caseInsensitiveCompare(name) == .orderedSame }) {
                    return Target(kind: .alias(source: source, range: aliasRange(model, segment, name)), range: range)
                }
            }
            return Target(kind: .unknown, range: range)
        }
        // An unqualified column: the innermost scope that has it decides.
        for scope in scopes {
            let owners = scope.filter { $0.columns?.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? false }
            if owners.count == 1, let column = owners[0].columns?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return Target(kind: .column(source: owners[0], column: column), range: range)
            }
            if owners.count > 1 { return Target(kind: .ambiguousColumn(name, owners.map(\.qualifier)), range: range) }
        }
        return Target(kind: .unknown, range: range)
    }

    private static func aliasRange(_ model: SQLModel, _ segment: SQLModel.Segment, _ name: String) -> NSRange? {
        for source in segment.sources {
            if let alias = source.alias, alias.caseInsensitiveCompare(name) == .orderedSame {
                for index in source.start..<source.end where model.name(index)?.caseInsensitiveCompare(alias) == .orderedSame && index > source.start {
                    return model.tokens[index].range
                }
            }
            if case .table(let parts) = source.kind, parts.last?.caseInsensitiveCompare(name) == .orderedSame, source.alias == nil {
                return model.tokens[source.start + (parts.count - 1) * 2].range
            }
        }
        return nil
    }

    private static func cteRange(_ model: SQLModel, _ cte: SQLModel.CTE, _ owner: Int) -> NSRange? {
        // The CTE name is the identifier before `AS (`, in the owning block's WITH list.
        for index in model.blocks[owner].start..<min(model.blocks[owner].end, model.tokens.count) {
            if model.name(index)?.caseInsensitiveCompare(cte.name) == .orderedSame, model.isIdentifier(index) {
                var look = index + 1
                if model.isSymbol(look, "(") { look = model.skipParen(look) }
                if model.word(look) == "AS" { return model.tokens[index].range }
            }
        }
        return nil
    }

    // MARK: Hover

    public static func hover(text: String, caret: Int, dialect: SQLDialect, catalog: SQLCatalog) -> SQLHover? {
        guard let (model, _) = model(text, dialect, caret: caret), let target = target(at: caret, model, catalog) else { return nil }
        switch target.kind {
        case .function(let name):
            guard let function = SQLKeywords.function(named: name, dialect) else { return nil }
            return SQLHover(range: target.range, markdown: "**\(function.signature)**\n\n\(function.summary)")
        case .relation(let relation, let name):
            guard let relation else {
                return catalog.isComplete ? SQLHover(range: target.range, markdown: "**\(name)**\n\nNo table or view with this name.") : nil
            }
            let kind = relation.kind == .view ? "view" : "table"
            guard let columns = relation.columns else { return SQLHover(range: target.range, markdown: "**\(relation.name)** (\(kind))\n\nColumns are still loading.") }
            let list = columns.map { "- `\($0.name)` \($0.typeName)\($0.isPrimaryKey ? " · primary key" : "")" }.joined(separator: "\n")
            return SQLHover(range: target.range, markdown: "**\(relation.name)** (\(kind), \(columns.count) columns)\n\n\(list)")
        case .column(let source, let column):
            var facts: [String] = []
            if !column.typeName.isEmpty { facts.append(column.typeName) }
            if column.column?.isPrimaryKey == true { facts.append("primary key") }
            if column.column?.isNotNull == true { facts.append("not null") }
            if column.column?.isGenerated == true { facts.append("generated") }
            if column.column?.isIdentityAlways == true { facts.append("identity") }
            let owner = source.relation ?? source.qualifier
            return SQLHover(range: target.range, markdown: "**\(owner).\(column.name)**\n\n\(facts.isEmpty ? "column" : facts.joined(separator: ", "))")
        case .ambiguousColumn(let name, let owners):
            return SQLHover(range: target.range, markdown: "**\(name)** is ambiguous\n\nIt is in \(owners.map { "`\($0)`" }.joined(separator: " and ")). Qualify it, for example `\(owners[0]).\(name)`.")
        case .alias(let source, _):
            if let relation = source.relation, relation.caseInsensitiveCompare(source.qualifier) != .orderedSame {
                return SQLHover(range: target.range, markdown: "**\(source.qualifier)** is an alias of `\(relation)`")
            }
            return SQLHover(range: target.range, markdown: "**\(source.qualifier)**\n\n\(source.kind == .cte ? "common table expression" : source.kind == .subquery ? "derived table" : "table")")
        case .cte(let name, _):
            return SQLHover(range: target.range, markdown: "**\(name)**\n\ncommon table expression")
        case .unknown:
            return nil
        }
    }

    // MARK: Go to declaration

    public static func declaration(text: String, caret: Int, dialect: SQLDialect, catalog: SQLCatalog) -> SQLDeclaration? {
        guard let (model, _) = model(text, dialect, caret: caret), let target = target(at: caret, model, catalog) else { return nil }
        switch target.kind {
        case .relation(let relation, _): return relation.map { .relation($0.name) }
        case .column(let source, let column): return source.relation.map { .column(relation: $0, name: column.name) } ?? (nil as SQLDeclaration?)
        case .alias(let source, let range):
            if let range { return .local(range) }
            return source.relation.map { .relation($0) }
        case .cte(_, let range): return range.map { .local($0) }
        default: return nil
        }
    }

    // MARK: Signature help

    public static func signatureHelp(text: String, caret: Int, dialect: SQLDialect) -> SQLSignatureHelp? {
        guard let (model, _) = model(text, dialect, caret: caret) else { return nil }
        // The innermost `(` before the caret that follows a function name.
        var best: Int?
        for (open, close) in model.matching where model.isSymbol(open, "(") && model.tokens[open].end <= caret && caret <= (close < model.tokens.count ? model.tokens[close].start : Int.max) {
            if model.block(opening: open) == nil, open > 0, model.tokens[open - 1].kind == .word, best == nil || open > best! { best = open }
        }
        guard let open = best, let function = SQLKeywords.function(named: model.tokens[open - 1].text(in: model.units), dialect) else { return nil }
        var depth = 0
        var parameter = 0
        var index = open + 1
        while index < model.tokens.count, model.tokens[index].start < caret {
            if model.isSymbol(index, "(") { depth += 1 }
            else if model.isSymbol(index, ")") { depth -= 1 }
            else if model.isSymbol(index, ","), depth == 0 { parameter += 1 }
            index += 1
        }
        return SQLSignatureHelp(function: function.name, signature: function.signature, summary: function.summary, activeParameter: parameter)
    }

    // MARK: Code actions

    /// `SELECT *` (or `alias.*`) under the caret, written out as the columns it stands for.
    public static func expandStar(text: String, caret: Int, dialect: SQLDialect, catalog: SQLCatalog) -> SQLTextEdit? {
        guard let (model, _) = model(text, dialect, caret: caret) else { return nil }
        guard let star = model.tokens.indices.first(where: { model.isSymbol($0, "*") && model.tokens[$0].start <= caret && caret <= model.tokens[$0].end })
        else { return nil }
        let blockID = model.innermostBlock(at: star)
        guard let segmentIndex = model.segmentIndex(in: blockID, at: star) else { return nil }
        let segment = model.blocks[blockID].segments[segmentIndex]
        guard let select = segment.clauses.first(where: { $0.name == "SELECT" }), select.keyword < star, star < select.end else { return nil }
        // `count(*)` is not a select item.
        let previous = star - 1
        let qualified = model.isSymbol(previous, ".") && model.isIdentifier(previous - 1)
        guard qualified || model.isSymbol(previous, ",") || model.word(previous) == "SELECT" || model.word(previous) == "DISTINCT" else { return nil }
        let sources = model.scopes(block: blockID, segment: segmentIndex, catalog: catalog)[0]
        let chosen: [SQLResolvedSource]
        var start = model.tokens[star].start
        if qualified {
            let qualifier = model.name(previous - 1) ?? ""
            chosen = sources.filter { $0.qualifier.caseInsensitiveCompare(qualifier) == .orderedSame }
            start = model.tokens[previous - 1].start
        } else {
            chosen = sources
        }
        guard !chosen.isEmpty, chosen.allSatisfy({ $0.columns != nil }) else { return nil }
        let qualify = chosen.count > 1 || qualified
        let items = chosen.flatMap { source in
            (source.columns ?? []).map { column -> String in
                let name = SQLQuoting.insertName(column.name, dialect: dialect)
                return qualify && !source.qualifier.isEmpty ? "\(SQLQuoting.insertName(source.qualifier, dialect: dialect)).\(name)" : name
            }
        }
        guard !items.isEmpty else { return nil }
        return SQLTextEdit(
            range: NSRange(location: start, length: model.tokens[star].end - start), newText: items.joined(separator: ", "),
            title: "Expand * into \(items.count) column\(items.count == 1 ? "" : "s")"
        )
    }
}

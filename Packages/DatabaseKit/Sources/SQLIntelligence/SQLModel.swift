import Foundation

/// The structure of one statement, recovered from tokens. It is built for text that is *not valid
/// yet*: a missing closing parenthesis, a FROM with nothing after it, an unfinished alias. Every
/// piece it cannot make sense of is left out, never guessed at.
final class SQLModel {
    let dialect: SQLDialect
    let units: [UInt16]
    /// Statement tokens without comments.
    let tokens: [SQLToken]
    /// For `(` the index of its `)` (or `tokens.count` if unclosed); for `)` the index of its `(`.
    private(set) var matching: [Int: Int] = [:]
    private(set) var blocks: [Block] = []

    struct Block {
        var id: Int
        var parent: Int?
        /// Index of the opening parenthesis, or -1 for the statement itself.
        var open: Int
        /// Token indexes of the content, `end` exclusive (the closing parenthesis, or the end).
        var start: Int
        var end: Int
        var ctes: [CTE] = []
        var segments: [Segment] = []
    }

    struct CTE {
        var name: String
        var columns: [String]?
        var block: Int?
    }

    enum SegmentKind { case select, insert, update, delete, values, other }

    struct Segment {
        var start: Int
        var end: Int
        var kind: SegmentKind
        var clauses: [Clause] = []
        var sources: [Source] = []
    }

    struct Clause {
        /// `SELECT`, `FROM`, `JOIN`, `ON`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `SET`, `INTO`,
        /// `VALUES`, `UPDATE`, `DELETE`, `USING`, `LIMIT`, `OFFSET`, `RETURNING`, `FOR`, …
        var name: String
        /// First token of the clause, including `LEFT`/`INNER`/… before `JOIN`.
        var start: Int
        /// The keyword token (`JOIN`, `FROM`, …); content begins after it.
        var keyword: Int
        var end: Int
    }

    struct Source {
        enum Kind: Equatable {
            case table([String])
            case subquery(Int)
            case function(String)
        }
        var kind: Kind
        var alias: String?
        var columnAliases: [String]?
        var start: Int
        var end: Int
        /// The clause (index in `Segment.clauses`) that introduced it.
        var clause: Int
    }

    init(tokens: [SQLToken], units: [UInt16], dialect: SQLDialect) {
        self.dialect = dialect
        self.units = units
        self.tokens = tokens.filter { $0.kind != .comment }
        buildParentheses()
        buildBlocks()
        for index in blocks.indices { parseBlock(index) }
    }

    // MARK: Token helpers

    func word(_ index: Int) -> String? {
        guard tokens.indices.contains(index), tokens[index].kind == .word else { return nil }
        return tokens[index].text(in: units).uppercased()
    }

    func isSymbol(_ index: Int, _ unit: Character) -> Bool {
        guard tokens.indices.contains(index), tokens[index].kind == .symbol, tokens[index].length == 1 else { return false }
        return units[tokens[index].start] == UInt16(unit.asciiValue ?? 0)
    }

    /// An identifier's text, unquoted: `"My Col"` becomes `My Col`, `` `a``b` `` becomes ``a`b``.
    func name(_ index: Int) -> String? {
        guard tokens.indices.contains(index) else { return nil }
        let token = tokens[index]
        switch token.kind {
        case .word:
            return token.text(in: units)
        case .quotedIdentifier:
            let raw = token.text(in: units)
            guard raw.count >= 2 else { return nil }
            let inner = String(raw.dropFirst().dropLast(token.isTerminated ? 1 : 0))
            if raw.hasPrefix("`") { return inner.replacingOccurrences(of: "``", with: "`") }
            if raw.hasPrefix("[") { return inner }
            return inner.replacingOccurrences(of: "\"\"", with: "\"")
        default:
            return nil
        }
    }

    func isIdentifier(_ index: Int) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        return tokens[index].kind == .word || tokens[index].kind == .quotedIdentifier
    }

    // MARK: Parentheses and blocks

    private func buildParentheses() {
        var stack: [Int] = []
        for (index, _) in tokens.enumerated() {
            if isSymbol(index, "(") {
                stack.append(index)
            } else if isSymbol(index, ")"), let open = stack.popLast() {
                matching[open] = index
                matching[index] = open
            }
        }
        for open in stack { matching[open] = tokens.count }  // unclosed: runs to the end
    }

    private func buildBlocks() {
        blocks = [Block(id: 0, parent: nil, open: -1, start: 0, end: tokens.count)]
        for (index, _) in tokens.enumerated() where isSymbol(index, "(") {
            guard let first = word(index + 1), ["SELECT", "WITH", "VALUES", "TABLE"].contains(first) else { continue }
            let close = matching[index] ?? tokens.count
            blocks.append(Block(id: blocks.count, parent: nil, open: index, start: index + 1, end: close))
        }
        // The parent is the smallest block that contains this one.
        for index in blocks.indices.dropFirst() {
            var best = 0
            for candidate in blocks.indices where candidate != index {
                let outer = blocks[candidate]
                if outer.open < blocks[index].open, blocks[index].open < outer.end,
                   outer.end - outer.start < blocks[best].end - blocks[best].start || best == 0 {
                    best = candidate
                }
            }
            blocks[index].parent = best
        }
    }

    /// The block whose parentheses open at token `open`.
    func block(opening open: Int) -> Int? {
        blocks.first { $0.open == open }?.id
    }

    /// Skips from an opening parenthesis to just after its close.
    private func skip(_ index: Int) -> Int {
        isSymbol(index, "(") ? min((matching[index] ?? tokens.count) + 1, tokens.count) : index + 1
    }

    // MARK: Parsing a block

    private func parseBlock(_ id: Int) {
        var index = blocks[id].start
        let end = blocks[id].end
        if word(index) == "WITH" {
            index = parseCTEs(from: index + 1, end: end, block: id)
        }
        blocks[id].segments = parseSegments(from: index, to: end, block: id)
    }

    /// `WITH [RECURSIVE] name [(cols)] AS [[NOT] MATERIALIZED] ( … ) [, …]`
    private func parseCTEs(from start: Int, end: Int, block id: Int) -> Int {
        var index = start
        if word(index) == "RECURSIVE" { index += 1 }
        while index < end {
            guard isIdentifier(index), let cteName = name(index) else { return index }
            index += 1
            var columns: [String]?
            if isSymbol(index, "(") {
                columns = identifiersInside(parenthesis: index)
                index = skip(index)
            }
            guard word(index) == "AS" else {
                // `WITH name` with nothing after yet: the name is known, its body is not.
                blocks[id].ctes.append(CTE(name: cteName, columns: columns, block: nil))
                return index
            }
            index += 1
            if word(index) == "NOT" { index += 1 }
            if word(index) == "MATERIALIZED" { index += 1 }
            var body: Int?
            if isSymbol(index, "(") {
                body = block(opening: index)
                index = skip(index)
            }
            blocks[id].ctes.append(CTE(name: cteName, columns: columns, block: body))
            if isSymbol(index, ",") { index += 1 } else { break }
        }
        return index
    }

    func identifiersInside(parenthesis open: Int) -> [String] {
        let close = min(matching[open] ?? tokens.count, tokens.count)
        var result: [String] = []
        var index = open + 1
        while index < close {
            if isIdentifier(index), let text = name(index) { result.append(text) }
            index += 1
        }
        return result
    }

    private static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "MINUS"]
    private static let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN"]

    private func parseSegments(from start: Int, to end: Int, block id: Int) -> [Segment] {
        var segments: [Segment] = []
        var boundaries: [Int] = [start]  // token index where a segment starts
        var index = start
        var firstKeyword: String?
        while index < end {
            if isSymbol(index, "(") { index = skip(index); continue }
            if let word = word(index) {
                if firstKeyword == nil { firstKeyword = word }
                if Self.setOperators.contains(word) {
                    var next = index + 1
                    if ["ALL", "DISTINCT"].contains(self.word(next) ?? "") { next += 1 }
                    boundaries.append(next)
                    firstKeyword = nil
                    index = next
                    continue
                }
                // The SELECT of an INSERT … SELECT is its own segment.
                if word == "SELECT", let first = firstKeyword, ["INSERT", "REPLACE"].contains(first), index > boundaries.last! {
                    boundaries.append(index)
                    firstKeyword = "SELECT"
                }
            }
            index += 1
        }
        for (position, boundary) in boundaries.enumerated() {
            let boundaryEnd = position + 1 < boundaries.count ? boundaries[position + 1] : end
            // Trim the set operator keyword off the previous segment's tail.
            var segmentEnd = boundaryEnd
            if position + 1 < boundaries.count {
                while segmentEnd > boundary, let w = word(segmentEnd - 1), Self.setOperators.contains(w) || w == "ALL" || w == "DISTINCT" {
                    segmentEnd -= 1
                }
            }
            segments.append(parseSegment(from: boundary, to: max(boundary, segmentEnd), spanEnd: boundaryEnd))
        }
        return segments
    }

    private func parseSegment(from start: Int, to end: Int, spanEnd: Int) -> Segment {
        let kind: SegmentKind
        switch word(start) {
        case "SELECT", "TABLE": kind = .select
        case "INSERT", "REPLACE": kind = .insert
        case "UPDATE": kind = .update
        case "DELETE": kind = .delete
        case "VALUES": kind = .values
        default: kind = .other
        }
        var segment = Segment(start: start, end: spanEnd, kind: kind)
        var starts: [(name: String, start: Int, keyword: Int)] = []
        var index = start
        var seenJoin = false
        while index < end {
            if isSymbol(index, "(") { index = skip(index); continue }
            guard let w = word(index) else { index += 1; continue }
            let previous = word(index - 1)
            switch w {
            case "SELECT" where index == start || kind == .select:
                if index == start { starts.append(("SELECT", index, index)) }
            case "FROM":
                starts.append(("FROM", index, index))
                seenJoin = false
            case "WHERE", "HAVING", "WINDOW", "RETURNING", "LIMIT", "OFFSET", "FETCH":
                starts.append((w, index, index))
            case "GROUP", "ORDER":
                if word(index + 1) == "BY" { starts.append((w + " BY", index, index + 1)) }
            case "SET":
                starts.append(("SET", index, index))
            case "VALUES" where kind == .insert || kind == .values || index == start:
                starts.append(("VALUES", index, index))
            case "INSERT", "REPLACE":
                if index == start { starts.append(("INSERT", index, index)) }
            case "INTO":
                if kind == .insert || kind == .select { starts.append(("INTO", index, index)) }
            case "UPDATE":
                if index == start { starts.append(("UPDATE", index, index)) }
            case "DELETE":
                if index == start { starts.append(("DELETE", index, index)) }
            case "USING":
                if kind == .delete || kind == .update { starts.append(("USING", index, index)) }
            case "JOIN":
                // `LEFT OUTER JOIN`: the clause began at the modifier.
                if let last = starts.last, last.name == "JOIN", last.keyword == index { break }
                starts.append(("JOIN", index, index))
                seenJoin = true
            case "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN":
                var look = index + 1
                if word(look) == "OUTER" { look += 1 }
                if word(look) == "JOIN" || w == "STRAIGHT_JOIN" {
                    let keyword = w == "STRAIGHT_JOIN" ? index : look
                    starts.append(("JOIN", index, keyword))
                    seenJoin = true
                    index = keyword
                }
            case "ON":
                if word(index + 1) == "CONFLICT" || word(index + 1) == "DUPLICATE" {
                    starts.append(("ON CONFLICT", index, index))
                } else if seenJoin, previous != "DUPLICATE" {
                    starts.append(("ON", index, index))
                }
            case "FOR":
                if ["UPDATE", "SHARE", "NO", "KEY"].contains(word(index + 1) ?? "") { starts.append(("FOR", index, index)) }
            default:
                break
            }
            index += 1
        }
        for (position, entry) in starts.enumerated() {
            let clauseEnd = position + 1 < starts.count ? starts[position + 1].start : end
            segment.clauses.append(Clause(name: entry.name, start: entry.start, keyword: entry.keyword, end: max(entry.keyword + 1, clauseEnd)))
        }
        segment.sources = parseSources(in: segment)
        return segment
    }

    // MARK: Sources

    private static let nonAliasWords: Set<String> = [
        "ON", "USING", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "JOIN", "LEFT", "RIGHT", "INNER", "FULL",
        "CROSS", "NATURAL", "OUTER", "UNION", "INTERSECT", "EXCEPT", "SET", "VALUES", "SELECT", "FROM", "WINDOW", "FETCH",
        "RETURNING", "FOR", "WITH", "STRAIGHT_JOIN", "AS", "TABLESAMPLE", "PARTITION", "INDEXED", "NOT", "LATERAL", "DEFAULT",
    ]

    private func parseSources(in segment: Segment) -> [Source] {
        var sources: [Source] = []
        for (clauseIndex, clause) in segment.clauses.enumerated() {
            switch clause.name {
            case "FROM", "USING", "UPDATE", "INTO":
                var index = clause.keyword + 1
                while index < clause.end {
                    // `INTO t (cols)`: the parenthesis is a column list, never a function call.
                    guard let (source, next) = parseSource(
                        at: index, limit: clause.end, clause: clauseIndex, allowFunction: clause.name != "INTO"
                    ) else { break }
                    sources.append(source)
                    index = next
                    // `INTO t (cols)`: the parenthesis is the column list, not a second source.
                    if clause.name == "INTO" { break }
                    if isSymbol(index, ",") { index += 1 } else { break }
                }
            case "JOIN":
                if let (source, _) = parseSource(at: clause.keyword + 1, limit: clause.end, clause: clauseIndex) {
                    sources.append(source)
                }
            default:
                break
            }
        }
        return sources
    }

    /// One table reference, derived table or table function, with its alias. Returns where it ended.
    private func parseSource(at start: Int, limit: Int, clause: Int, allowFunction: Bool = true) -> (Source, Int)? {
        var index = start
        while ["ONLY", "LATERAL"].contains(word(index) ?? "") { index += 1 }
        guard index < limit else { return nil }
        var kind: Source.Kind
        if isSymbol(index, "(") {
            guard let id = block(opening: index) else {
                // A parenthesised join or list: no single source to name.
                return nil
            }
            kind = .subquery(id)
            index = skip(index)
        } else if isIdentifier(index) {
            var parts = [name(index) ?? ""]
            index += 1
            while isSymbol(index, "."), isIdentifier(index + 1), index + 1 < limit {
                parts.append(name(index + 1) ?? "")
                index += 2
            }
            if allowFunction, isSymbol(index, "(") {
                kind = .function(parts.last ?? "")
                index = skip(index)
            } else {
                kind = .table(parts)
            }
        } else {
            return nil
        }
        var alias: String?
        var columnAliases: [String]?
        if word(index) == "AS" { index += 1 }
        if index < limit, isIdentifier(index), !(tokens[index].kind == .word && Self.nonAliasWords.contains(word(index) ?? "")) {
            alias = name(index)
            index += 1
            if isSymbol(index, "(") {
                columnAliases = identifiersInside(parenthesis: index)
                index = skip(index)
            }
        }
        return (Source(kind: kind, alias: alias, columnAliases: columnAliases, start: start, end: index, clause: clause), index)
    }

    // MARK: Lookups

    /// The innermost block whose content covers token position `position` (an insertion point
    /// between tokens, `position - 1` being the last token before it).
    func innermostBlock(at position: Int) -> Int {
        var best = 0
        for block in blocks.dropFirst() where block.start <= position && position <= block.end {
            if blocks[best].open < block.open { best = block.id }
        }
        return best
    }

    func segmentIndex(in blockID: Int, at position: Int) -> Int? {
        let segments = blocks[blockID].segments
        if let hit = segments.firstIndex(where: { $0.start <= position && position <= $0.end }) { return hit }
        return segments.indices.last
    }

    /// The last clause that began before `position`.
    func clauseIndex(in segment: Segment, at position: Int) -> Int? {
        segment.clauses.lastIndex { $0.keyword < position }
    }
}

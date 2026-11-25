import Foundation

/// A column visible in a query: its name, and where it came from when it has a type to show.
struct SQLResolvedColumn: Equatable {
    var name: String
    var typeName: String = ""
    var column: SQLCatalog.Column?
}

/// A name that can qualify a column (`u` in `u.name`), with the columns behind it.
struct SQLResolvedSource {
    var qualifier: String
    /// The real relation (`users` for alias `u`), nil for a CTE, derived table or function.
    var relation: String?
    var kind: Kind
    /// Nil when the columns cannot be known (a table function, a table the catalog has not loaded).
    var columns: [SQLResolvedColumn]?

    enum Kind { case table, view, cte, subquery, function, unknownTable }
}

extension SQLModel {
    // MARK: Visible sources

    /// The scopes a name in `segment` of `blockID` can be looked up in, innermost first. A name
    /// resolves in the innermost scope that has it (an inner `id` shadows an outer one, and is only
    /// ambiguous among *that* scope's sources). A subquery sees its enclosing query's scope; a CTE
    /// body and a derived table in FROM do not.
    func scopes(block blockID: Int, segment segmentID: Int, catalog: SQLCatalog) -> [[SQLResolvedSource]] {
        var result = [blocks[blockID].segments[segmentID].sources.map { resolve($0, block: blockID, catalog: catalog, visiting: []) }]
        var current = blockID
        while let parent = blocks[current].parent, !isIsolated(current),
              let parentSegment = strictSegmentIndex(in: parent, at: blocks[current].open)
        {
            result.append(blocks[parent].segments[parentSegment].sources.map { resolve($0, block: parent, catalog: catalog, visiting: []) })
            current = parent
        }
        return result
    }

    /// Every source visible from here, innermost first (for completion, which offers them all).
    func visibleSources(block blockID: Int, segment segmentID: Int, catalog: SQLCatalog) -> [SQLResolvedSource] {
        scopes(block: blockID, segment: segmentID, catalog: catalog).flatMap { $0 }
    }

    /// A block that cannot see its surroundings: a CTE body, or the query of a FROM item.
    func isIsolated(_ blockID: Int) -> Bool {
        isFromItem(blockID) || blocks.contains { $0.ctes.contains { $0.block == blockID } }
    }

    func strictSegmentIndex(in blockID: Int, at position: Int) -> Int? {
        blocks[blockID].segments.firstIndex { $0.start <= position && position <= $0.end }
    }

    /// Is this block the parenthesised query of a FROM/JOIN item (a derived table)?
    func isFromItem(_ blockID: Int) -> Bool {
        for block in blocks {
            for segment in block.segments {
                if segment.sources.contains(where: { $0.kind == .subquery(blockID) }) { return true }
            }
        }
        return false
    }

    func findCTE(named name: String, from blockID: Int) -> (cte: CTE, block: Int)? {
        var current: Int? = blockID
        while let id = current {
            if let cte = blocks[id].ctes.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return (cte, id) }
            current = blocks[id].parent
        }
        return nil
    }

    func resolve(_ source: Source, block blockID: Int, catalog: SQLCatalog, visiting: Set<Int>) -> SQLResolvedSource {
        var resolved: SQLResolvedSource
        switch source.kind {
        case .table(let parts):
            let table = parts.last ?? ""
            if parts.count == 1, let (cte, _) = findCTE(named: table, from: blockID) {
                var columns: [SQLResolvedColumn]?
                if let explicit = cte.columns {
                    columns = explicit.map { SQLResolvedColumn(name: $0) }
                } else if let body = cte.block, !visiting.contains(body) {
                    columns = outputColumns(of: body, catalog: catalog, visiting: visiting.union([body]))
                }
                resolved = SQLResolvedSource(qualifier: table, relation: nil, kind: .cte, columns: columns)
            } else if let relation = catalog.relation(qualifiedBy: parts) {
                resolved = SQLResolvedSource(
                    qualifier: relation.name, relation: relation.name,
                    kind: relation.kind == .view ? .view : .table,
                    columns: relation.columns?.map { SQLResolvedColumn(name: $0.name, typeName: $0.typeName, column: $0) }
                )
            } else {
                resolved = SQLResolvedSource(qualifier: table, relation: nil, kind: .unknownTable, columns: nil)
            }
        case .subquery(let id):
            let columns = visiting.contains(id) ? nil : outputColumns(of: id, catalog: catalog, visiting: visiting.union([id]))
            resolved = SQLResolvedSource(qualifier: "", relation: nil, kind: .subquery, columns: columns)
        case .function(let name):
            resolved = SQLResolvedSource(qualifier: name, relation: nil, kind: .function, columns: nil)
        }
        if let alias = source.alias { resolved.qualifier = alias }
        if let aliases = source.columnAliases, var columns = resolved.columns {
            for (offset, alias) in aliases.enumerated() where columns.indices.contains(offset) { columns[offset].name = alias }
            resolved.columns = columns
        }
        return resolved
    }

    // MARK: Output columns of a query

    /// The columns a query block produces: the first segment's select list (a `UNION` takes its
    /// names from the first query). A `*` expands to the columns behind it; if any of those are
    /// unknown the result is nil, because a partial list would read as a complete one.
    func outputColumns(of blockID: Int, catalog: SQLCatalog, visiting: Set<Int>) -> [SQLResolvedColumn]? {
        guard let segmentIndex = blocks[blockID].segments.indices.first else { return nil }
        let segment = blocks[blockID].segments[segmentIndex]
        guard segment.kind == .select, let select = segment.clauses.first(where: { $0.name == "SELECT" }) else {
            // `VALUES (…)` has columns named by position: not worth inventing names.
            return nil
        }
        var index = select.keyword + 1
        while let w = word(index), ["DISTINCT", "ALL", "TOP"].contains(w) {
            index += 1
            if w == "DISTINCT", word(index) == "ON", isSymbol(index + 1, "(") { index = skipParen(index + 1) }
        }
        var items: [Range<Int>] = []
        var itemStart = index
        var cursor = index
        while cursor < select.end {
            if isSymbol(cursor, "(") { cursor = skipParen(cursor); continue }
            if isSymbol(cursor, ",") {
                items.append(itemStart..<cursor)
                itemStart = cursor + 1
            }
            cursor += 1
        }
        if itemStart < select.end { items.append(itemStart..<select.end) }

        var sources: [SQLResolvedSource]?
        func visible() -> [SQLResolvedSource] {
            if let sources { return sources }
            let resolved = segment.sources.map { resolve($0, block: blockID, catalog: catalog, visiting: visiting) }
            sources = resolved
            return resolved
        }
        var columns: [SQLResolvedColumn] = []
        for item in items where !item.isEmpty {
            let first = item.lowerBound, last = item.upperBound - 1
            if first == last, isSymbol(first, "*") {
                for source in visible() {
                    guard let expanded = source.columns else { return nil }
                    columns += expanded
                }
            } else if item.count == 3, isIdentifier(first), isSymbol(first + 1, "."), isSymbol(last, "*") {
                let qualifier = name(first) ?? ""
                guard let source = visible().first(where: { $0.qualifier.caseInsensitiveCompare(qualifier) == .orderedSame }),
                      let expanded = source.columns else { return nil }
                columns += expanded
            } else if let output = outputName(of: item) {
                columns.append(SQLResolvedColumn(name: output))
            }
        }
        return columns
    }

    /// `a`, `t.a`, `expr AS a`, `expr a`: the name the item gives its column, or nil when it has none.
    private func outputName(of item: Range<Int>) -> String? {
        let last = item.upperBound - 1
        guard isIdentifier(last) else { return nil }
        if item.count == 1 { return name(last) }
        let previous = last - 1
        if word(previous) == "AS" { return name(last) }
        if isSymbol(previous, ".") { return name(last) }
        // `count(*) total` or `a b`: an implicit alias follows an operand, not an operator.
        if tokens[previous].kind == .word || tokens[previous].kind == .quotedIdentifier
            || tokens[previous].kind == .number || tokens[previous].kind == .string || isSymbol(previous, ")")
        {
            return name(last)
        }
        return nil
    }

    func skipParen(_ open: Int) -> Int {
        min((matching[open] ?? tokens.count) + 1, tokens.count)
    }
}

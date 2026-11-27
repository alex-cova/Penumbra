import Foundation

/// Lays out statement boundaries and query clauses while preserving the text of every token.
public enum SQLFormatter {
    public static func edits(in text: String, dialect: SQLDialect, indentUnit: String = "    ") -> [SQLTextEdit] {
        let lexer = SQLLexer(text, dialect: dialect)
        let tokens = lexer.tokenize()
        guard tokens.allSatisfy(\.isTerminated) else { return [] }
        let source = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let clauses: Set<String> = [
            "FROM", "JOIN", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT",
            "OFFSET", "RETURNING", "VALUES", "SET", "USING", "FOR",
        ]
        var replacements: [SQLTextEdit] = []
        var editedRanges: Set<NSRange> = []
        var lineStarts = [0]
        for (index, unit) in lexer.units.enumerated() where unit == 10 { lineStarts.append(index + 1) }
        var indentationLine = 0
        var indent = ""
        var tokenIndex = tokens.startIndex
        var previous: SQLStatement?
        for statement in SQLStatementSplitter.split(tokens: tokens, units: lexer.units, dialect: dialect) {
            if Task.isCancelled { return [] }
            if indentationLine != statement.startLine {
                indentationLine = statement.startLine
                let start = lineStarts[indentationLine - 1]
                let units = lexer.units[start..<statement.start].prefix { $0 == 32 || $0 == 9 }
                indent = String(decoding: units, as: UTF16.self)
            }

            func breakLine(from start: Int, to end: Int, indent: String) {
                let range = NSRange(location: start, length: end - start)
                let gap = source.substring(with: range)
                guard gap.allSatisfy(\.isWhitespace), !gap.contains("\n"), !gap.contains("\r"),
                      editedRanges.insert(range).inserted else { return }
                replacements.append(SQLTextEdit(range: range, newText: newline + indent, title: "Format SQL"))
            }

            if let previous, previous.isTerminated {
                breakLine(from: previous.extendedEnd, to: statement.start, indent: indent)
            }
            previous = statement
            while tokenIndex < tokens.endIndex, tokens[tokenIndex].start < statement.start { tokenIndex += 1 }
            let first = tokenIndex
            while tokenIndex < tokens.endIndex, tokens[tokenIndex].end <= statement.end { tokenIndex += 1 }
            let model = SQLModel(tokens: Array(tokens[first..<tokenIndex]), units: lexer.units, dialect: dialect)
            guard let root = model.blocks.first, root.segments.contains(where: { $0.kind != .other }) else { continue }

            var depths = Array(repeating: 0, count: model.blocks.count)
            for block in model.blocks {
                let depth = block.parent.map { depths[$0] + 1 } ?? 0
                depths[block.id] = depth
                let alignment = indent + String(repeating: indentUnit, count: depth)
                for segment in block.segments where segment.kind != .other {
                    for clause in segment.clauses where clause.start > segment.start && clauses.contains(clause.name) {
                        let start = model.tokens[clause.start - 1].end
                        let end = model.tokens[clause.start].start
                        breakLine(from: start, to: end, indent: alignment)
                    }
                }
            }
        }
        return replacements.sorted { $0.range.location < $1.range.location }
    }
}

import DatabaseKit
import EditorIntelligence
import Foundation

/// One connected schema for one console. A keystroke reads this snapshot, already in memory;
/// it never queries the database.
public struct SQLCompletionSnapshot: Sendable, Equatable {
    public var engine: DatabaseEngine
    public var tables: [String]
    public var columnsByTable: [String: [SQLColumn]]

    public init(engine: DatabaseEngine, tables: [String], columnsByTable: [String: [SQLColumn]] = [:]) {
        self.engine = engine
        self.tables = tables
        self.columnsByTable = columnsByTable
    }
}

/// Completion for MySQL and PostgreSQL consoles: keywords, tables, columns and a short
/// function list, read from a per-console `SQLCompletionSnapshot`.
///
/// Primary only at those sites, and only for `sql` documents that are consoles (which is what
/// having a snapshot means), so `.sql` files and MongoDB consoles keep ordinary completion.
final class SQLCompletionProvider: CompletionProvider, @unchecked Sendable {
    let name = "SQL"

    private let lock = NSLock()
    private var snapshots: [UUID: SQLCompletionSnapshot] = [:]

    func setSnapshot(_ snapshot: SQLCompletionSnapshot?, for documentID: DocumentID) {
        lock.withLock {
            if let snapshot {
                snapshots[documentID.uuid] = snapshot
            } else {
                snapshots.removeValue(forKey: documentID.uuid)
            }
        }
    }

    func removeSnapshot(for documentID: DocumentID) {
        setSnapshot(nil, for: documentID)
    }

    private func snapshot(for documentID: DocumentID) -> SQLCompletionSnapshot? {
        lock.withLock { snapshots[documentID.uuid] }
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        guard context.document.languageIdentifier == "sql",
              snapshot(for: context.document.id) != nil
        else { return false }
        return site(in: context) != nil
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard context.document.languageIdentifier == "sql",
              let snapshot = snapshot(for: context.document.id),
              let site = site(in: context)
        else { return [] }
        switch site {
        case .keywords:
            return keywordItems(engine: snapshot.engine, context: context)
        case .tables:
            return tableItems(snapshot: snapshot, context: context)
        case .columns(let tables):
            return columnItems(tables: tables, snapshot: snapshot, context: context)
                + functionItems(context: context)
        case .singleTableColumns(let table):
            return columnItems(tables: [table], snapshot: snapshot, context: context)
        }
    }

    private func site(in context: CompletionContext) -> SQLCompletion.Site? {
        let caret = context.cursor.position.utf16Offset
        let start = max(0, caret - SQLCompletion.maximumBackwardLength)
        let slice = context.document.substring(utf16Offset: start, length: max(0, caret - start))
        return SQLCompletion.site(in: slice, caretUTF16: (slice as NSString).length)
    }

    private func keywordItems(engine: DatabaseEngine, context: CompletionContext) -> [CompletionItem] {
        var keywords = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "EXPLAIN"]
        if engine == .mysql {
            keywords.append("SHOW")
        }
        let suffix = needsTrailingSpace(context: context) ? " " : ""
        return keywords.map {
            CompletionItem(
                label: $0,
                insertText: $0 + suffix,
                kind: .keyword,
                range: context.range,
                source: name,
                filterText: $0,
                priority: 1
            )
        }
    }

    private func tableItems(snapshot: SQLCompletionSnapshot, context: CompletionContext) -> [CompletionItem] {
        snapshot.tables.map { table in
            CompletionItem(
                label: table,
                insertText: SQLIdentifiers.insertName(table, engine: snapshot.engine),
                kind: .class,
                range: context.range,
                source: name,
                filterText: table,
                priority: 1
            )
        }
    }

    private func columnItems(
        tables: [String], snapshot: SQLCompletionSnapshot, context: CompletionContext
    ) -> [CompletionItem] {
        let scopes = tables.isEmpty ? snapshot.tables : tables
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for table in scopes {
            for column in columns(of: table, in: snapshot) {
                guard seen.insert(column.name).inserted else { continue }
                items.append(CompletionItem(
                    label: column.name,
                    insertText: SQLIdentifiers.insertName(column.name, engine: snapshot.engine),
                    kind: .field,
                    range: context.range,
                    source: name,
                    filterText: column.name,
                    detail: column.declaredType.isEmpty ? nil : column.declaredType,
                    labelDetail: column.isPrimaryKey ? "PK" : nil,
                    priority: 1
                ))
            }
        }
        return items
    }

    private func columns(of table: String, in snapshot: SQLCompletionSnapshot) -> [SQLColumn] {
        if let exact = snapshot.columnsByTable[table] {
            return exact
        }
        let lower = table.lowercased()
        for (name, columns) in snapshot.columnsByTable where name.lowercased() == lower {
            return columns
        }
        return []
    }

    private func functionItems(context: CompletionContext) -> [CompletionItem] {
        let addsParens = !nextStartsWithParen(context: context)
        return SQLCompletion.functions.map { function in
            CompletionItem(
                label: function,
                insertText: addsParens ? "\(function)()" : function,
                kind: .function,
                range: context.range,
                source: name,
                filterText: function,
                caretOffset: addsParens ? function.count + 1 : nil
            )
        }
    }

    private func needsTrailingSpace(context: CompletionContext) -> Bool {
        let caret = context.cursor.position.utf16Offset
        let next = context.document.substring(utf16Offset: caret, length: 1)
        guard let scalar = next.unicodeScalars.first else { return true }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func nextStartsWithParen(context: CompletionContext) -> Bool {
        let caret = context.cursor.position.utf16Offset
        return context.document.substring(utf16Offset: caret, length: 1) == "("
    }
}

/// Where the caret sits in its statement. A pure function of at most 8 KB before the caret:
/// no tree-sitter walk on the keystroke. `nil` means inside a string or a comment, where the
/// provider steps aside so ordinary word completion still works.
enum SQLCompletion {
    enum Site: Equatable {
        case keywords
        case tables
        case columns(tables: [String])
        case singleTableColumns(table: String)
    }

    /// Farthest the scan reads back from the caret, in UTF-16 units.
    static let maximumBackwardLength = 8_192

    static let functions = ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE"]

    static func site(in text: String, caretUTF16: Int) -> Site? {
        let ns = text as NSString
        let caret = min(max(caretUTF16, 0), ns.length)
        let windowStart = max(0, caret - maximumBackwardLength)
        let slice = ns.substring(with: NSRange(location: windowStart, length: caret - windowStart)) as NSString
        guard let tokens = tokenize(slice, end: slice.length, strict: true) else { return nil }
        let lastSemi = tokens.lastIndex { $0.kind == .symbol && $0.text == ";" }
        let statementStart = lastSemi.map { tokens[$0].end } ?? 0
        let statement = tokens.filter { $0.start >= statementStart }
        let statementText = slice.substring(from: statementStart) as NSString
        let aliases = aliasMap(in: statement)
        if let raw = memberTarget(in: statementText) {
            return .singleTableColumns(table: aliases[raw.lowercased()] ?? raw)
        }
        var work = statement
        if let last = work.last, last.kind == .word, last.end - statementStart == statementText.length {
            work.removeLast()
        }
        var index = work.count - 1
        while index >= 0 {
            let token = work[index]
            if token.kind == .word {
                if tableKeywords.contains(token.upper) {
                    if token.upper == "INTO" {
                        return intoSite(work, at: index)
                    }
                    return .tables
                }
                if columnKeywords.contains(token.upper) {
                    return .columns(tables: referencedTables(in: work))
                }
                if token.upper == "EXPLAIN" || token.upper == "SHOW" {
                    return .keywords
                }
            }
            index -= 1
        }
        return .keywords
    }

    private static let tableKeywords: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "INSERT", "DELETE"]
    private static let columnKeywords: Set<String> = [
        "SELECT", "WHERE", "AND", "OR", "ON", "SET", "HAVING", "GROUP", "ORDER", "BY", "WITH",
    ]
    private static let tableIntroducing: Set<String> = ["FROM", "JOIN", "INTO", "TABLE", "UPDATE"]
    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "ON", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS",
        "GROUP", "ORDER", "BY", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "UPDATE", "SET",
        "INTO", "VALUES", "TABLE", "INSERT", "DELETE", "WITH", "AS", "AND", "OR", "NOT", "NULL",
        "IS", "IN", "EXISTS", "BETWEEN", "LIKE", "CASE", "WHEN", "THEN", "ELSE", "ASC", "DESC",
        "USING", "EXPLAIN", "SHOW",
    ]

    /// `INSERT INTO users (…)` completes that table's columns; `… VALUES (…)` is literal values,
    /// where the provider steps aside.
    private static func intoSite(_ tokens: [SQLToken], at index: Int) -> Site? {
        guard index + 1 < tokens.count, tokens[index + 1].kind == .word else { return .tables }
        let table = tokens[index + 1].text
        var sawValues = false
        var sawParen = false
        for token in tokens[(index + 2)...] {
            if token.kind == .word, token.upper == "VALUES" {
                sawValues = true
            } else if token.kind == .symbol, token.text == "(" {
                sawParen = true
            }
        }
        if sawValues {
            return nil
        }
        return sawParen ? .columns(tables: [table]) : .tables
    }

    private static func referencedTables(in tokens: [SQLToken]) -> [String] {
        var tables: [String] = []
        var index = 0
        while index + 1 < tokens.count {
            let token = tokens[index]
            if token.kind == .word, tableIntroducing.contains(token.upper), tokens[index + 1].kind == .word {
                let table = tokens[index + 1].text
                if !tables.contains(table) {
                    tables.append(table)
                }
            }
            index += 1
        }
        return tables
    }

    private static func aliasMap(in tokens: [SQLToken]) -> [String: String] {
        var aliases: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.kind == .word, token.upper == "FROM" || token.upper == "JOIN" else {
                index += 1
                continue
            }
            guard index + 1 < tokens.count, tokens[index + 1].kind == .word else {
                index += 1
                continue
            }
            let table = tokens[index + 1].text
            var aliasIndex = index + 2
            if aliasIndex < tokens.count, tokens[aliasIndex].kind == .word, tokens[aliasIndex].upper == "AS" {
                aliasIndex += 1
            }
            if aliasIndex < tokens.count, tokens[aliasIndex].kind == .word,
               !clauseKeywords.contains(tokens[aliasIndex].upper)
            {
                aliases[tokens[aliasIndex].text.lowercased()] = table
            }
            index += 1
        }
        return aliases
    }

    /// The table of `users.` or an alias (`u.`) just before the caret, or nil. A `1.5` number is
    /// not member access: its table part starts with a digit.
    private static func memberTarget(in statement: NSString) -> String? {
        var cursor = statement.length
        while cursor > 0, isWordUnit(statement.character(at: cursor - 1)) {
            cursor -= 1
        }
        var dot = cursor
        while dot > 0, isSpaceUnit(statement.character(at: dot - 1)) {
            dot -= 1
        }
        guard dot > 0, statement.character(at: dot - 1) == 46 else { return nil }
        var tableEnd = dot - 1
        while tableEnd > 0, isSpaceUnit(statement.character(at: tableEnd - 1)) {
            tableEnd -= 1
        }
        guard tableEnd > 0 else { return nil }
        let closing = statement.character(at: tableEnd - 1)
        if closing == 34 || closing == 96 || closing == 93 {
            return quotedNameBackwards(in: statement, closingAt: tableEnd - 1)
        }
        var tableStart = tableEnd
        while tableStart > 0, isWordUnit(statement.character(at: tableStart - 1)) {
            tableStart -= 1
        }
        guard tableStart < tableEnd, isIdentifierStart(statement.character(at: tableStart)) else { return nil }
        return statement.substring(with: NSRange(location: tableStart, length: tableEnd - tableStart))
    }

    private static func quotedNameBackwards(in statement: NSString, closingAt: Int) -> String? {
        let closing = statement.character(at: closingAt)
        let opening: UInt16 = closing == 93 ? 91 : closing
        var index = closingAt - 1
        while index >= 0 {
            if statement.character(at: index) == opening {
                let inner = statement.substring(with: NSRange(location: index + 1, length: closingAt - index - 1))
                return unescapeQuoted(inner, quote: opening)
            }
            index -= 1
        }
        return nil
    }

    private static func unescapeQuoted(_ text: String, quote: UInt16) -> String {
        if quote == 91 {
            return text
        }
        let single = quoteCharacter(quote)
        return text.replacingOccurrences(of: single + single, with: single)
    }

    private static func quoteCharacter(_ quote: UInt16) -> String {
        UnicodeScalar(quote).map { String(Character($0)) } ?? ""
    }

    /// One `;`-separated statement: its first and last 1-based lines and its text.
    struct SQLStatement: Equatable {
        var startLine: Int
        var endLine: Int
        var text: String
    }

    /// Every non-blank statement in the console, for the gutter's execute buttons. Forgiving:
    /// an unterminated string or comment runs to the end instead of failing the scan.
    static func statements(in text: String) -> [SQLStatement] {
        let ns = text as NSString
        guard let tokens = tokenize(ns, end: ns.length, strict: false) else { return [] }
        var lineStarts = [0]
        for index in 0..<ns.length where ns.character(at: index) == 10 {
            lineStarts.append(index + 1)
        }
        func line(of offset: Int) -> Int {
            var number = 0
            for start in lineStarts {
                guard start <= offset else { break }
                number += 1
            }
            return max(number, 1)
        }
        var statements: [SQLStatement] = []
        var segmentStart = 0
        var segmentTokens: [SQLToken] = []
        func flush(through segmentEnd: Int) {
            defer {
                segmentStart = segmentEnd
                segmentTokens = []
            }
            // A comment-only segment is not a statement; `{}` still is, for JSON consoles.
            guard segmentTokens.contains(where: {
                $0.kind == .word || ($0.kind == .symbol && ($0.text == "{" || $0.text == "}"))
            }) else { return }
            var start = segmentStart
            var end = segmentEnd
            while start < end, isSpaceUnit(ns.character(at: start)) {
                start += 1
            }
            while end > start,
                  isSpaceUnit(ns.character(at: end - 1)) || ns.character(at: end - 1) == 59
            {
                end -= 1
            }
            guard start < end else { return }
            statements.append(SQLStatement(
                startLine: line(of: start), endLine: line(of: end - 1),
                text: ns.substring(with: NSRange(location: start, length: end - start))
            ))
        }
        for token in tokens {
            if token.kind == .symbol && token.text == ";" {
                flush(through: token.end)
            } else {
                segmentTokens.append(token)
            }
        }
        flush(through: ns.length)
        return statements
    }

    /// The statement enclosing a 1-based line, re-parsed at click time like the HTTP gutter.
    static func statement(atLine line: Int, in text: String) -> String? {
        statements(in: text).first { $0.startLine <= line && line <= $0.endLine }?.text
    }

    /// Words and `; ( ) , .` symbols before `end`, skipping strings and comments. Strict mode
    /// returns nil when the caret is inside a string or a comment.
    fileprivate static func tokenize(_ text: NSString, end: Int, strict: Bool) -> [SQLToken]? {
        var tokens: [SQLToken] = []
        var index = 0
        while index < end {
            let unit = text.character(at: index)
            switch unit {
            case 32, 9, 10, 13, 12, 11:
                index += 1
            case 45 where index + 1 < end && text.character(at: index + 1) == 45:
                var cursor = index + 2
                while cursor < end, text.character(at: cursor) != 10 {
                    cursor += 1
                }
                if cursor >= end, strict {
                    return nil
                }
                index = cursor
            case 35:
                var cursor = index + 1
                while cursor < end, text.character(at: cursor) != 10 {
                    cursor += 1
                }
                if cursor >= end, strict {
                    return nil
                }
                index = cursor
            case 47 where index + 1 < end && text.character(at: index + 1) == 42:
                var cursor = index + 2
                var closed = false
                while cursor < end {
                    if text.character(at: cursor) == 42, cursor + 1 < end, text.character(at: cursor + 1) == 47 {
                        cursor += 2
                        closed = true
                        break
                    }
                    cursor += 1
                }
                if !closed, strict {
                    return nil
                }
                index = cursor
            case 39:
                if let after = skipString(in: text, from: index + 1, end: end, quote: 39) {
                    index = after
                } else if strict {
                    return nil
                } else {
                    index = end
                }
            case 34, 96:
                if let after = skipQuotedIdentifier(in: text, from: index + 1, end: end, quote: unit) {
                    let inner = text.substring(with: NSRange(location: index + 1, length: after - index - 2))
                    tokens.append(SQLToken(
                        kind: .word, text: unescapeQuoted(inner, quote: unit),
                        upper: inner.uppercased(), start: index, end: after
                    ))
                    index = after
                } else {
                    let inner = text.substring(from: index + 1)
                    tokens.append(SQLToken(
                        kind: .word, text: unescapeQuoted(inner, quote: unit),
                        upper: inner.uppercased(), start: index, end: end
                    ))
                    index = end
                }
            case 91:
                if let close = firstUnescaped(in: text, from: index + 1, end: end, quote: 93) {
                    let inner = text.substring(with: NSRange(location: index + 1, length: close - index - 1))
                    tokens.append(SQLToken(
                        kind: .word, text: inner, upper: inner.uppercased(),
                        start: index, end: close + 1
                    ))
                    index = close + 1
                } else {
                    let inner = text.substring(from: index + 1)
                    tokens.append(SQLToken(
                        kind: .word, text: inner, upper: inner.uppercased(), start: index, end: end
                    ))
                    index = end
                }
            case 59, 40, 41, 44, 46, 123, 125:
                tokens.append(SQLToken(
                    kind: .symbol, text: quoteCharacter(unit),
                    upper: "", start: index, end: index + 1
                ))
                index += 1
            default:
                if isWordUnit(unit) {
                    var cursor = index + 1
                    while cursor < end, isWordUnit(text.character(at: cursor)) {
                        cursor += 1
                    }
                    let word = text.substring(with: NSRange(location: index, length: cursor - index))
                    tokens.append(SQLToken(
                        kind: .word, text: word, upper: word.uppercased(), start: index, end: cursor
                    ))
                    index = cursor
                } else {
                    index += 1
                }
            }
        }
        return tokens
    }

    /// Offset after the closing quote, or nil when the caret sits inside the string.
    private static func skipString(in text: NSString, from start: Int, end: Int, quote: UInt16) -> Int? {
        var index = start
        while index < end {
            let unit = text.character(at: index)
            if unit == 92 {
                index += 2
                continue
            }
            if unit == quote {
                if index + 1 < end, text.character(at: index + 1) == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func skipQuotedIdentifier(in text: NSString, from start: Int, end: Int, quote: UInt16) -> Int? {
        firstDoubled(in: text, from: start, end: end, quote: quote)
    }

    private static func firstDoubled(in text: NSString, from start: Int, end: Int, quote: UInt16) -> Int? {
        var index = start
        while index < end {
            if text.character(at: index) == quote {
                if index + 1 < end, text.character(at: index + 1) == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func firstUnescaped(in text: NSString, from start: Int, end: Int, quote: UInt16) -> Int? {
        var index = start
        while index < end {
            if text.character(at: index) == quote {
                return index
            }
            index += 1
        }
        return nil
    }
}

private struct SQLToken: Equatable {
    enum Kind: Equatable {
        case word
        case symbol
    }

    var kind: Kind
    var text: String
    var upper: String
    var start: Int
    var end: Int
}

private func isWordUnit(_ unit: UInt16) -> Bool {
    switch unit {
    case 48...57, 65...90, 95, 97...122, 36:
        return true
    default:
        return unit >= 128
    }
}

private func isSpaceUnit(_ unit: UInt16) -> Bool {
    unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 || unit == 11
}

private func isIdentifierStart(_ unit: UInt16) -> Bool {
    switch unit {
    case 65...90, 95, 97...122:
        return true
    default:
        return unit >= 128
    }
}

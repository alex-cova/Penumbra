import Foundation

/// One statement of a script.
public struct SQLStatement: Equatable, Sendable {
    /// From the first token to the last, excluding the terminator and any comments before the first
    /// token or after the last. UTF-16 offsets.
    public var range: NSRange
    /// End of the terminator when there is one (so a caret just after `;` still belongs to the
    /// statement), otherwise the end of `range`.
    public var extendedEnd: Int
    /// 1-based lines of the first and last token.
    public var startLine: Int
    public var endLine: Int
    public var text: String
    public var isTerminated: Bool

    public init(range: NSRange, extendedEnd: Int, startLine: Int, endLine: Int, text: String, isTerminated: Bool) {
        self.range = range
        self.extendedEnd = extendedEnd
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.isTerminated = isTerminated
    }

    public var start: Int { range.location }
    public var end: Int { range.location + range.length }
}

/// Splits a script into statements by reading it as SQL, never by looking for `;`.
///
/// A `;` ends a statement only outside strings, quoted identifiers and comments, outside PostgreSQL
/// `$$ … $$` bodies, and outside `BEGIN … END` (trigger, procedure and function bodies, and
/// `CASE … END`). MySQL's `DELIMITER //` directive changes what ends a statement. A segment that
/// holds only comments is not a statement.
public enum SQLStatementSplitter {
    public static func split(_ text: String, dialect: SQLDialect) -> [SQLStatement] {
        let lexer = SQLLexer(text, dialect: dialect)
        return split(tokens: lexer.tokenize(), units: lexer.units, dialect: dialect)
    }

    static func split(tokens: [SQLToken], units: [UInt16], dialect: SQLDialect) -> [SQLStatement] {
        let lineStarts = Self.lineStarts(units)
        var statements: [SQLStatement] = []
        var current: [SQLToken] = []
        var depth = 0
        var inRoutine = false
        var previousWord: String?
        var previousKind: SQLToken.Kind?

        func flush(terminator: SQLToken?) {
            defer {
                current = []
                depth = 0
                inRoutine = false
                previousWord = nil
                previousKind = nil
            }
            guard let first = current.first, let last = current.last else { return }
            let range = NSRange(location: first.start, length: last.end - first.start)
            statements.append(SQLStatement(
                range: range,
                extendedEnd: terminator?.end ?? last.end,
                startLine: line(of: first.start, in: lineStarts),
                endLine: line(of: max(first.start, last.end - 1), in: lineStarts),
                text: String(decoding: units[first.start..<last.end], as: UTF16.self),
                isTerminated: terminator != nil
            ))
        }

        for token in tokens {
            switch token.kind {
            case .comment:
                continue
            case .directive:
                flush(terminator: nil)
                continue
            case .delimiter:
                if depth > 0 {
                    current.append(token)
                    previousKind = .delimiter
                    previousWord = nil
                } else {
                    flush(terminator: token)
                }
                continue
            default:
                break
            }
            let word = token.kind == .word ? token.text(in: units).uppercased() : nil
            if let word {
                let isFirstWords = current.count < 12
                if current.first.map({ $0.text(in: units).uppercased() }) == "CREATE", isFirstWords,
                   word == "TRIGGER" || word == "PROCEDURE" || word == "FUNCTION"
                {
                    inRoutine = true
                }
                switch word {
                case "BEGIN" where inRoutine:
                    depth += 1
                case "CASE" where previousWord != "END":
                    depth += 1
                case "END":
                    if depth > 0 { depth -= 1 }
                case "IF", "LOOP", "WHILE", "REPEAT":
                    // A compound-statement opener only at the start of a statement inside a
                    // MySQL routine; `IF(a, b, c)` is a function and `END IF` is a closer.
                    if inRoutine, dialect == .mysql, previousWord != "END",
                       previousKind == .delimiter || ["BEGIN", "THEN", "ELSE", "DO"].contains(previousWord ?? ""),
                       !(word == "IF" && isFollowedByParenthesis(token, tokens: tokens, units: units))
                    {
                        depth += 1
                    }
                default:
                    break
                }
            }
            current.append(token)
            previousWord = word
            previousKind = token.kind
        }
        flush(terminator: nil)
        return statements
    }

    private static func isFollowedByParenthesis(_ token: SQLToken, tokens: [SQLToken], units: [UInt16]) -> Bool {
        guard let index = tokens.firstIndex(of: token) else { return false }
        var next = index + 1
        while next < tokens.count, tokens[next].kind == .comment { next += 1 }
        return next < tokens.count && tokens[next].kind == .symbol && units[tokens[next].start] == 40
    }

    /// The statement the caret is in or touching: inside it, or right after its terminator. Between
    /// two statements it is the one before (a caret at the end of a line you just finished), and
    /// before the first one it is the first.
    public static func statement(containing caret: Int, in statements: [SQLStatement]) -> SQLStatement? {
        if let inside = statements.last(where: { caret >= $0.start && caret <= $0.extendedEnd }) { return inside }
        if let before = statements.last(where: { $0.extendedEnd < caret }) { return before }
        return statements.first
    }

    /// The statement that starts on or contains `line` (1-based), for the gutter's run buttons.
    public static func statement(atLine line: Int, in statements: [SQLStatement]) -> SQLStatement? {
        statements.first { $0.startLine <= line && line <= $0.endLine }
    }

    // MARK: Lines

    private static func lineStarts(_ units: [UInt16]) -> [Int] {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 10 { starts.append(index + 1) }
        return starts
    }

    private static func line(of offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(low, 1)
    }
}

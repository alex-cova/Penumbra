import Foundation

/// One lexical token. Offsets are UTF-16 code units, which is what the editor's `NSString`
/// positions are, so a token's range can be handed straight back to the text view.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case word            // keyword or bare identifier
        case quotedIdentifier
        case string
        case number
        case symbol          // operators and punctuation: ( ) , . [ ] + - * / = <> :: …
        case comment
        case parameter       // ?  ?1  :name  $1  @name
        case delimiter       // the statement terminator: `;`, or what `DELIMITER` set
        case directive       // a whole `DELIMITER xx` line (MySQL client)
    }

    public var kind: Kind
    public var start: Int
    public var end: Int
    /// False for a string, quoted identifier or block comment that runs to the end of the text.
    public var isTerminated: Bool

    public var range: NSRange { NSRange(location: start, length: end - start) }
    public var length: Int { end - start }

    init(_ kind: Kind, _ start: Int, _ end: Int, terminated: Bool = true) {
        self.kind = kind
        self.start = start
        self.end = end
        self.isTerminated = terminated
    }
}

/// A tolerant SQL lexer. It never fails: half-typed text (an open string, an unfinished comment, a
/// stray character) produces tokens that say so, because completion has to work on exactly the
/// text that is invalid.
public struct SQLLexer: Sendable {
    public let dialect: SQLDialect
    let units: [UInt16]

    public init(_ text: String, dialect: SQLDialect) {
        self.dialect = dialect
        self.units = Array(text.utf16)
    }

    public init(units: [UInt16], dialect: SQLDialect) {
        self.dialect = dialect
        self.units = units
    }

    /// All tokens, whitespace omitted. A `DELIMITER` directive changes the terminator for what
    /// follows, so the token stream already says where statements end.
    public func tokenize() -> [SQLToken] {
        var tokens: [SQLToken] = []
        var delimiter: [UInt16] = [59]  // ";"
        var index = 0
        let count = units.count
        var atLineStart = true
        while index < count {
            let unit = units[index]
            if Self.isSpace(unit) {
                if unit == 10 { atLineStart = true }
                index += 1
                continue
            }
            if atLineStart, dialect.supportsDelimiterDirective, let directive = delimiterDirective(at: index) {
                tokens.append(SQLToken(.directive, index, directive.end))
                delimiter = directive.delimiter
                index = directive.end
                continue
            }
            atLineStart = false
            if matches(delimiter, at: index) {
                tokens.append(SQLToken(.delimiter, index, index + delimiter.count))
                index += delimiter.count
                continue
            }
            let token = next(at: index, delimiter: delimiter)
            tokens.append(token)
            index = max(token.end, index + 1)
        }
        return tokens
    }

    // MARK: Scanning one token

    private func next(at start: Int, delimiter: [UInt16]) -> SQLToken {
        let unit = units[start]
        let following = start + 1 < units.count ? units[start + 1] : 0
        switch unit {
        case 45 where following == 45:  // --
            return lineComment(from: start)
        case 35 where dialect.hashComments:  // #
            return lineComment(from: start)
        case 47 where following == 42:  // /*
            return blockComment(from: start)
        case 39:  // '
            return string(from: start, quote: 39, backslash: dialect.backslashEscapesInStrings, kind: .string)
        case 34:  // "
            if dialect.doubleQuotesAreStrings {
                return string(from: start, quote: 34, backslash: true, kind: .string)
            }
            return string(from: start, quote: 34, backslash: false, kind: .quotedIdentifier)
        case 96 where dialect.backtickIdentifiers:  // `
            return string(from: start, quote: 96, backslash: false, kind: .quotedIdentifier)
        case 91 where dialect.bracketIdentifiers:  // [
            return bracketIdentifier(from: start)
        case 36 where dialect.dollarQuotes:  // $
            if let token = dollarToken(from: start) { return token }
            return SQLToken(.symbol, start, start + 1)
        case 36 where dialect == .sqlite && Self.isDigit(following):
            var end = start + 1
            while end < units.count, Self.isDigit(units[end]) { end += 1 }
            return SQLToken(.parameter, start, end)
        case 63:  // ?
            var end = start + 1
            while end < units.count, Self.isDigit(units[end]) { end += 1 }
            return SQLToken(.parameter, start, end)
        case 58 where following == 58:  // ::
            return SQLToken(.symbol, start, start + 2)
        case 58 where Self.isIdentifierStart(following):  // :name
            var end = start + 1
            while end < units.count, Self.isIdentifierPart(units[end]) { end += 1 }
            return SQLToken(.parameter, start, end)
        case 64 where dialect == .mysql || Self.isIdentifierStart(following) || following == 64:  // @name, @@var
            var end = start + 1
            if end < units.count, units[end] == 64 { end += 1 }
            while end < units.count, Self.isIdentifierPart(units[end]) { end += 1 }
            return SQLToken(.parameter, start, end)
        case 48...57:
            return number(from: start)
        case 46 where Self.isDigit(following):  // .5
            return number(from: start)
        default:
            break
        }
        if Self.isIdentifierStart(unit) {
            var end = start + 1
            while end < units.count, Self.isIdentifierPart(units[end]) { end += 1 }
            // A one-letter prefix directly before a quote belongs to that string (`E'a\\nb'`, `N'x'`).
            if end - start == 1, end < units.count, units[end] == 39,
               let scalar = Unicode.Scalar(unit), dialect.stringPrefixes().contains(Character(scalar))
            {
                let escapes = dialect.backslashEscapesInStrings || (dialect == .postgres && (unit == 69 || unit == 101))
                let token = string(from: end, quote: 39, backslash: escapes, kind: .string)
                return SQLToken(.string, start, token.end, terminated: token.isTerminated)
            }
            return SQLToken(.word, start, end)
        }
        // Operators: take the longest run that is a known multi-character operator.
        for length in [3, 2] where start + length <= units.count {
            if Self.operators.contains(String(decoding: units[start..<(start + length)], as: UTF16.self)) {
                return SQLToken(.symbol, start, start + length)
            }
        }
        return SQLToken(.symbol, start, start + 1)
    }

    private static let operators: Set<String> = [
        "<=", ">=", "<>", "!=", "||", "->", "#>", "@>", "<@", ":=", "<<", ">>", "&&", "~*", "!~", "=>",
        "->>", "#>>", "!~*", "<=>",
    ]

    private func lineComment(from start: Int) -> SQLToken {
        var end = start
        while end < units.count, units[end] != 10 { end += 1 }
        return SQLToken(.comment, start, end)
    }

    private func blockComment(from start: Int) -> SQLToken {
        var depth = 1
        var index = start + 2
        while index < units.count {
            if units[index] == 42, index + 1 < units.count, units[index + 1] == 47 {
                depth -= 1
                index += 2
                if depth == 0 { return SQLToken(.comment, start, index) }
                continue
            }
            if dialect.nestedBlockComments, units[index] == 47, index + 1 < units.count, units[index + 1] == 42 {
                depth += 1
                index += 2
                continue
            }
            index += 1
        }
        return SQLToken(.comment, start, units.count, terminated: false)
    }

    /// `'…'`, `"…"` or `` `…` ``: a doubled quote is an escaped quote, and a backslash escapes the
    /// next unit where the dialect says so.
    private func string(from start: Int, quote: UInt16, backslash: Bool, kind: SQLToken.Kind) -> SQLToken {
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            if backslash, unit == 92 {
                index += 2
                continue
            }
            if unit == quote {
                if index + 1 < units.count, units[index + 1] == quote {
                    index += 2
                    continue
                }
                return SQLToken(kind, start, index + 1)
            }
            index += 1
        }
        return SQLToken(kind, start, units.count, terminated: false)
    }

    private func bracketIdentifier(from start: Int) -> SQLToken {
        var index = start + 1
        while index < units.count {
            if units[index] == 93 { return SQLToken(.quotedIdentifier, start, index + 1) }
            if units[index] == 10 { break }  // a name does not span lines: this is a lone `[`
            index += 1
        }
        return SQLToken(.symbol, start, start + 1)
    }

    /// `$1` is a parameter; `$$ … $$` and `$tag$ … $tag$` are strings.
    private func dollarToken(from start: Int) -> SQLToken? {
        var index = start + 1
        if index < units.count, Self.isDigit(units[index]) {
            while index < units.count, Self.isDigit(units[index]) { index += 1 }
            return SQLToken(.parameter, start, index)
        }
        while index < units.count, Self.isIdentifierPart(units[index]), units[index] != 36 { index += 1 }
        guard index < units.count, units[index] == 36 else { return nil }
        let opening = Array(units[start...index])
        var search = index + 1
        while search + opening.count <= units.count {
            if units[search] == 36, Array(units[search..<(search + opening.count)]) == opening {
                return SQLToken(.string, start, search + opening.count)
            }
            search += 1
        }
        return SQLToken(.string, start, units.count, terminated: false)
    }

    private func number(from start: Int) -> SQLToken {
        var index = start
        if units[index] == 48, index + 1 < units.count, units[index + 1] == 120 || units[index + 1] == 88 {
            index += 2
            while index < units.count, Self.isHexDigit(units[index]) { index += 1 }
            return SQLToken(.number, start, index)
        }
        while index < units.count, Self.isDigit(units[index]) || units[index] == 95 { index += 1 }
        if index < units.count, units[index] == 46, index + 1 >= units.count || units[index + 1] != 46 {
            index += 1
            while index < units.count, Self.isDigit(units[index]) { index += 1 }
        }
        if index < units.count, units[index] == 101 || units[index] == 69 {
            var probe = index + 1
            if probe < units.count, units[probe] == 43 || units[probe] == 45 { probe += 1 }
            if probe < units.count, Self.isDigit(units[probe]) {
                while probe < units.count, Self.isDigit(units[probe]) { probe += 1 }
                index = probe
            }
        }
        return SQLToken(.number, start, index)
    }

    // MARK: DELIMITER

    /// `DELIMITER //` on its own line (MySQL client syntax): what follows is the new terminator.
    private func delimiterDirective(at start: Int) -> (end: Int, delimiter: [UInt16])? {
        let keyword = Array("DELIMITER".utf16)
        guard start + keyword.count < units.count else { return nil }
        for (offset, unit) in keyword.enumerated() {
            let value = units[start + offset]
            guard value == unit || value == unit + 32 else { return nil }
        }
        var index = start + keyword.count
        guard index < units.count, units[index] == 32 || units[index] == 9 else { return nil }
        while index < units.count, units[index] == 32 || units[index] == 9 { index += 1 }
        let begin = index
        while index < units.count, !Self.isSpace(units[index]) { index += 1 }
        guard index > begin else { return nil }
        return (index, Array(units[begin..<index]))
    }

    private func matches(_ delimiter: [UInt16], at index: Int) -> Bool {
        guard index + delimiter.count <= units.count else { return false }
        for (offset, unit) in delimiter.enumerated() where units[index + offset] != unit { return false }
        return true
    }

    // MARK: Character classes

    static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 || unit == 11 }
    static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    static func isHexDigit(_ unit: UInt16) -> Bool { isDigit(unit) || (unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102) }
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit >= 128
    }
    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == 36
    }
}

extension SQLToken {
    /// The token's text in `units`.
    func text(in units: [UInt16]) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }
}

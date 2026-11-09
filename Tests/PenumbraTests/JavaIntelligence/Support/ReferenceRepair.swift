import Foundation

/// The completion repair as it was before it moved to UTF-8 bytes (`JavaCompletionRepair`): `NSString`
/// and `String +`, with the `Character`-based method-body check. Copied from the last commit that had
/// it, unchanged but for the names, and used only as the oracle in `JavaRepairedTextEquivalenceTests`.
enum ReferenceRepair {
    static func repairedText(_ text: String, insertingDummyAt utf16Offset: Int) -> String {
        let ns = text as NSString
        let location = min(max(0, utf16Offset), ns.length)
        let restOfLine = ns.substring(from: location).prefix { $0 != "\n" && $0 != "\r\n" }
        let closesStatement = restOfLine.allSatisfy { $0 == " " || $0 == "\t" } && isInsideMethodBody(ns.substring(to: location))
        let closers = closesStatement ? unclosedParentheses(onLineEndingAt: location, in: ns) : 0
        let before = blankingBrokenStatements(in: ns, before: location)
        return before + "__penumbra__" + String(repeating: ")", count: closers) + (closesStatement ? ";" : "") + ns.substring(from: location)
    }

    /// How many lines above the caret's are looked at for a broken statement.
    static let brokenStatementWindow = 40

    /// `ns` up to `location`, with the unmatched `(` of an earlier statement that ended in `;`
    /// without closing them (`println(x.length(;`) replaced by `+`. Left as written, those
    /// parentheses are still open at the caret, so the grammar reads the caret's line as one more
    /// argument and statement completion has nothing to offer. A one-character replacement keeps every
    /// offset before the caret where it was, which the request relies on (positions come from the
    /// original text). It has to be `+`, not a space: `System.out.println itemKept.length ;` reads
    /// as a declaration of a local `itemKept` and shadows the real one, whereas `a+b+;` is an
    /// expression missing its operand, a syntax error that stays inside the statement. A line that opens a `for (` header
    /// legitimately ends in `;` with its parenthesis open and is left alone, as are lines whose
    /// parentheses balance or close more than they open.
    static func blankingBrokenStatements(in text: NSString, before location: Int) -> String {
        // Only the lines near the caret are read: a completion runs per keystroke, and this must not
        // grow with the file. The window starts at a line start, `brokenStatementWindow` lines above
        // the caret's own line.
        var windowStart = location
        var lineBreaks = 0
        while windowStart > 0 {
            if text.character(at: windowStart - 1) == 0x0A {
                lineBreaks += 1
                if lineBreaks > brokenStatementWindow { break }
            }
            windowStart -= 1
        }
        let window = text.substring(with: NSRange(location: windowStart, length: location - windowStart))
        guard window.contains(";") else { return text.substring(to: location) }
        var utf16 = Array(window.utf16)
        // The caret's own line is repaired by `unclosedParentheses`; start at the line above it.
        var lineEnd = utf16.count
        while lineEnd > 0, utf16[lineEnd - 1] != 0x0A { lineEnd -= 1 }
        var changed = false
        while lineEnd > 0 {
            let end = lineEnd - 1                       // the line break before the line below
            var start = end
            while start > 0, utf16[start - 1] != 0x0A { start -= 1 }
            lineEnd = start
            if let positions = unmatchedOpeningParentheses(in: utf16, from: start, to: end) {
                for position in positions { utf16[position] = 0x2B }
                changed = true
            }
        }
        guard changed else { return text.substring(to: location) }
        return text.substring(to: windowStart) + String(decoding: utf16, as: UTF16.self)
    }

    /// The offsets of `(` that the line `start..<end` leaves open, when it ends in `;` and is not a
    /// `for` header; `nil` otherwise. Strings, character literals and `//` comments are skipped.
    static func unmatchedOpeningParentheses(in text: [UInt16], from start: Int, to end: Int) -> [Int]? {
        func isIdentifierCharacter(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24
        }
        /// Whether the token just before `position` is the keyword `for`.
        func followsFor(_ position: Int) -> Bool {
            var cursor = position
            while cursor > start, text[cursor - 1] == 0x20 || text[cursor - 1] == 0x09 { cursor -= 1 }
            guard cursor - start >= 3, String(decoding: text[(cursor - 3)..<cursor], as: UTF16.self) == "for" else { return false }
            return cursor - 3 == start || !isIdentifierCharacter(text[cursor - 4])
        }
        var open: [Int] = []
        var quote: UInt16?
        var lastSignificant: UInt16 = 0x20
        var isForHeader = false
        var index = start
        while index < end {
            let character = text[index]
            if let delimiter = quote {
                if character == 0x5C { index += 1 } else if character == delimiter { quote = nil }
                lastSignificant = character
            } else if character == 0x22 || character == 0x27 {
                quote = character
                lastSignificant = character
            } else if character == 0x2F, index + 1 < end, text[index + 1] == 0x2F {
                break
            } else {
                if character == 0x28 {
                    if open.isEmpty, followsFor(index) { isForHeader = true }
                    open.append(index)
                } else if character == 0x29, !open.isEmpty {
                    open.removeLast()
                }
                if character != 0x20 && character != 0x09 && character != 0x0D { lastSignificant = character }
            }
            index += 1
        }
        guard lastSignificant == 0x3B, !open.isEmpty, !isForHeader else { return nil }
        return open
    }

    /// How many `(` the caret's line leaves open (`if (a instanceof B b && b.__penumbra__`).
    /// Without the closing parentheses the grammar's error recovery reads the tail as a type and
    /// drops the pattern variable. Strings and character literals are skipped; a line that closes
    /// more than it opens counts as balanced.
    static func unclosedParentheses(onLineEndingAt location: Int, in text: NSString) -> Int {
        var lineStart = location
        while lineStart > 0, text.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        var depth = 0
        var quote: unichar?
        var index = lineStart
        while index < location {
            let character = text.character(at: index)
            if let open = quote {
                if character == 0x5C { index += 1 } else if character == open { quote = nil }
            } else if character == 0x22 || character == 0x27 {
                quote = character
            } else if character == 0x28 {
                depth += 1
            } else if character == 0x29, depth > 0 {
                depth -= 1
            }
            index += 1
        }
        return depth
    }

    /// Cheap check that the caret is inside a block rather than at class-body level, where a
    /// stray `;` would be harmless anyway but a member declaration (`private Str|`) must not end.
    static func isInsideMethodBody(_ before: String) -> Bool {
        var depth = 0
        var methodDepths: [Int] = []
        var previousSignificant: Character = " "
        for character in before {
            switch character {
            case "{":
                depth += 1
                // `) {` / `-> {` / `else {` open code blocks; `class X {` opens a type body.
                if previousSignificant == ")" || previousSignificant == ">" || !methodDepths.isEmpty {
                    methodDepths.append(depth)
                }
            case "}":
                if methodDepths.last == depth { methodDepths.removeLast() }
                depth -= 1
            default:
                break
            }
            if !character.isWhitespace { previousSignificant = character }
        }
        return !methodDepths.isEmpty
    }

}

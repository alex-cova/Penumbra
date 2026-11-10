import Foundation

/// The text a completion request parses: the buffer with a dummy identifier at the caret and a few
/// repairs around it, so tree-sitter gets a tree it can use while the user is mid-expression.
///
/// It works on UTF-8 bytes and builds the result with one allocation. Doing it through `NSString`
/// and `String +` cost five whole-document copies per request and, for any file with a non-ASCII
/// character, a UTF-16 copy of the document besides (`docs/JAVA_COMPLETION_BASELINE.md`); the
/// behaviour is the original's, which `JavaRepairedTextEquivalenceTests` keeps as the oracle.
enum JavaCompletionRepair {
    struct Result {
        let text: String
        /// The caret's UTF-8 offset. Everything the repair changes is at or after the caret, or swaps
        /// one ASCII byte for another, so the same offset holds in the original text and the repaired one.
        let caretByteOffset: Int
        /// False when the requested UTF-16 offset was past the end and the caret was put at the end.
        let reachedRequestedOffset: Bool
    }

    /// How many lines above the caret's are looked at for a broken statement.
    private static let brokenStatementLines = 40

    /// `text` with ``JavaCompletionProvider/dummyIdentifier`` inserted at `utf16Offset`. When nothing but
    /// whitespace follows the caret on its line (typing `products.` at the end of a line), a `;` closes
    /// the statement too: otherwise `products.__penumbra__` runs into the next line's statement and
    /// tree-sitter's error recovery can re-shape the surrounding methods, putting the caret in the
    /// wrong one. A lambda block or anonymous class body opened on the caret's line inside a call that is
    /// still open (`build(s, (l, v) -> { l.`) is closed too, in nesting order (see
    /// ``closingSequence(_:onLineEndingAt:)``). An earlier statement that ended in `;` with a parenthesis still open has that
    /// parenthesis replaced by `+` (see ``brokenStatementWindow(in:before:)``).
    static func repair(_ text: String, insertingDummyAtUTF16Offset utf16Offset: Int) -> Result {
        var source = text
        struct Plan {
            var caret = 0
            var reached = true
            var closesStatement = false
            var closing: [UInt8] = []
            var window: (start: Int, replacement: String)?
        }
        let plan = source.withUTF8 { bytes -> Plan in
            var plan = Plan()
            let scan = JavaUTF8Offsets.scan(forUTF16Offset: max(0, utf16Offset), in: bytes)
            plan.caret = scan.byteOffset
            plan.reached = scan.utf16Units == max(0, utf16Offset)
            plan.closesStatement = restOfLineIsBlank(bytes, from: plan.caret) && isInsideMethodBody(bytes, before: plan.caret)
            plan.closing = plan.closesStatement ? closingSequence(bytes, onLineEndingAt: plan.caret) : []
            plan.window = brokenStatementWindow(in: bytes, before: plan.caret)
            return plan
        }

        // `source` is contiguous UTF-8 now, so slicing by byte offset is direct.
        let utf8 = source.utf8
        let caretIndex = utf8.index(utf8.startIndex, offsetBy: plan.caret)
        var result = String()
        result.reserveCapacity(utf8.count + JavaCompletionProvider.dummyIdentifier.utf8.count + plan.closing.count + 1)
        if let window = plan.window {
            result.append(contentsOf: source[..<utf8.index(utf8.startIndex, offsetBy: window.start)])
            result.append(window.replacement)
        } else {
            result.append(contentsOf: source[..<caretIndex])
        }
        result.append(JavaCompletionProvider.dummyIdentifier)
        if !plan.closing.isEmpty { result.append(String(decoding: plan.closing, as: UTF8.self)) }
        if plan.closesStatement { result.append(";") }
        result.append(contentsOf: source[caretIndex...])
        return Result(text: result, caretByteOffset: plan.caret, reachedRequestedOffset: plan.reached)
    }

    /// `text` up to `utf16Offset` with the broken statements before it blanked: the prefix half of
    /// ``repair(_:insertingDummyAtUTF16Offset:)``, for the tests that pin that behaviour.
    static func blankingBrokenStatements(in text: String, beforeUTF16Offset utf16Offset: Int) -> String {
        var source = text
        let (caret, window) = source.withUTF8 { bytes -> (Int, (start: Int, replacement: String)?) in
            let caret = JavaUTF8Offsets.byteOffset(forUTF16Offset: max(0, utf16Offset), in: bytes)
            return (caret, brokenStatementWindow(in: bytes, before: caret))
        }
        let utf8 = source.utf8
        guard let window else { return String(source[..<utf8.index(utf8.startIndex, offsetBy: caret)]) }
        return String(source[..<utf8.index(utf8.startIndex, offsetBy: window.start)]) + window.replacement
    }

    // MARK: - The line around the caret

    /// Whether only spaces and tabs follow `caret` on its line. A line ends at `\n` or `\r\n`; a lone
    /// `\r` is content.
    static func restOfLineIsBlank(_ bytes: UnsafeBufferPointer<UInt8>, from caret: Int) -> Bool {
        var index = caret
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A { return true }
            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { return true }
            if byte != 0x20 && byte != 0x09 { return false }
            index += 1
        }
        return true
    }

    /// How many `(` the caret's line leaves open (`if (a instanceof B b && b.__penumbra__`).
    /// Without the closing parentheses the grammar's error recovery reads the tail as a type and
    /// drops the pattern variable. Strings and character literals are skipped; a line that closes
    /// more than it opens counts as balanced.
    static func unclosedParentheses(_ bytes: UnsafeBufferPointer<UInt8>, onLineEndingAt caret: Int) -> Int {
        var lineStart = caret
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var depth = 0
        var quote: UInt8?
        var index = lineStart
        while index < caret {
            let byte = bytes[index]
            if let open = quote {
                if byte == 0x5C { index += 1 } else if byte == open { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29, depth > 0 {
                depth -= 1
            }
            index += 1
        }
        return depth
    }

    /// What closes the brackets the caret's line leaves open, innermost first, so the statement parses
    /// whole: `)` for each `(`, and `;}` for a `{` that is a lambda block or a class or method body
    /// (the `{` follows `->` or `)`) **and** sits inside a `(` that is still open on this line.
    ///
    /// The second condition is what keeps this from being brace insertion in general. A block that
    /// stands on its own (`if (a) { foo.`, `void m() { x.`) is not closed, as before: the file's own `}`
    /// below the caret does that. A brace inside an open call has to be closed *before* the call's `)`,
    /// or tree-sitter reads `build(s, (l, v) -> { if (l.__penumbra__));` as an unterminated block and
    /// turns the call into a flat `ERROR` with no argument list; `n -> { n.__penumbra__);` loses the
    /// lambda altogether. The `;` before `}` ends the statement under the caret (`if (c) ;` is a valid
    /// empty statement; in a class body a stray `;` is a valid empty member). Braces that are not a
    /// body (array initializers, `{` after `=`) are left alone.
    ///
    /// A line without `{` takes the old path: one pass counting `(`. Strings and character literals are
    /// skipped; a `)` or `}` with nothing on this line to close is ignored.
    static func closingSequence(_ bytes: UnsafeBufferPointer<UInt8>, onLineEndingAt caret: Int) -> [UInt8] {
        var lineStart = caret
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var depth = 0
        var sawBrace = false
        var quote: UInt8?
        var index = lineStart
        while index < caret {
            let byte = bytes[index]
            if let open = quote {
                if byte == 0x5C { index += 1 } else if byte == open { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29, depth > 0 {
                depth -= 1
            } else if byte == 0x7B {
                sawBrace = true
                break
            }
            index += 1
        }
        guard sawBrace else { return depth > 0 ? Array(repeating: 0x29, count: depth) : [] }

        // `(` is a paren, `{` a body brace (closable), `.` any other brace.
        var stack: [UInt8] = []
        stack.reserveCapacity(8)
        quote = nil
        index = lineStart
        while index < caret {
            let byte = bytes[index]
            if let open = quote {
                if byte == 0x5C { index += 1 } else if byte == open { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x28 {
                stack.append(0x28)
            } else if byte == 0x29 {
                if let paren = stack.lastIndex(of: 0x28) { stack.removeSubrange(paren...) }
            } else if byte == 0x7B {
                stack.append(opensBody(bytes, at: index, lineStart: lineStart) ? 0x7B : 0x2E)
            } else if byte == 0x7D {
                if let top = stack.last, top != 0x28 { stack.removeLast() }
            }
            index += 1
        }
        var closing: [UInt8] = []
        var parenthesesBelow = stack.reduce(0) { $1 == 0x28 ? $0 + 1 : $0 }
        for opener in stack.reversed() {
            switch opener {
            case 0x28:
                closing.append(0x29)
                parenthesesBelow -= 1
            case 0x7B where parenthesesBelow > 0:
                closing.append(0x3B)
                closing.append(0x7D)
            default:
                break
            }
        }
        return closing
    }

    /// Whether the `{` at `index` opens a lambda block or a class or method body: the last thing
    /// before it on the line is `->` or `)`.
    private static func opensBody(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int, lineStart: Int) -> Bool {
        var before = index - 1
        while before >= lineStart, bytes[before] == 0x20 || bytes[before] == 0x09 { before -= 1 }
        guard before >= lineStart else { return false }
        if bytes[before] == 0x29 { return true }
        return bytes[before] == 0x3E && before - 1 >= lineStart && bytes[before - 1] == 0x2D
    }

    // MARK: - Broken statements above the caret

    /// The lines above the caret, from a line start up to the caret, with the unmatched `(` of an
    /// earlier statement that ended in `;` without closing them (`println(x.length(;`) replaced by `+`;
    /// `nil` when nothing is replaced. Left as written, those parentheses are still open at the caret,
    /// so the grammar reads the caret's line as one more argument and statement completion has
    /// nothing to offer. A one-character replacement keeps every offset before the caret where it
    /// was, which the request relies on (positions come from the original text). It has to be `+`,
    /// not a space: `System.out.println itemKept.length ;` reads as a declaration of a local
    /// `itemKept` and shadows the real one, whereas `a+b+;` is an expression missing its operand, a
    /// syntax error that stays inside the statement. A line that opens a `for (` header legitimately
    /// ends in `;` with its parenthesis open and is left alone, as are lines whose parentheses
    /// balance or close more than they open.
    ///
    /// Only the lines near the caret are read: a completion runs per keystroke, and this must not
    /// grow with the file.
    static func brokenStatementWindow(
        in bytes: UnsafeBufferPointer<UInt8>, before caret: Int
    ) -> (start: Int, replacement: String)? {
        var windowStart = caret
        var lineBreaks = 0
        while windowStart > 0 {
            if bytes[windowStart - 1] == 0x0A {
                lineBreaks += 1
                if lineBreaks > brokenStatementLines { break }
            }
            windowStart -= 1
        }
        guard windowStart < caret else { return nil }
        let slice = UnsafeBufferPointer(rebasing: bytes[windowStart..<caret])
        guard slice.contains(0x3B) else { return nil }
        guard let blanked = blankedWindow(String(decoding: slice, as: UTF8.self)) else { return nil }
        return (windowStart, blanked)
    }

    /// `window` with the offending parentheses replaced, or `nil` when there are none.
    private static func blankedWindow(_ window: String) -> String? {
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
        return changed ? String(decoding: utf16, as: UTF16.self) : nil
    }

    /// The offsets of `(` that the line `start..<end` leaves open, when it ends in `;` and is not a
    /// `for` header; `nil` otherwise. Strings, character literals and `//` comments are skipped.
    private static func unmatchedOpeningParentheses(in text: [UInt16], from start: Int, to end: Int) -> [Int]? {
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

    // MARK: - Inside a method body?

    /// Cheap check that the caret is inside a block rather than at class-body level, where a stray
    /// `;` would be harmless anyway but a member declaration (`private Str|`) must not end.
    ///
    /// The answer depends only on the braces and, at each `{`, on the last non-whitespace character
    /// before it, so the scan stops at braces (eight bytes per step; no multibyte UTF-8 sequence
    /// contains an ASCII byte, so a brace byte is a brace) and looks back from an opening brace
    /// only. Transcoding the prefix to UTF-16 and testing every unit was 3.4 of the 3.8 ms
    /// `repairedText` cost on a 120,000-line file.
    static func isInsideMethodBody(_ bytes: UnsafeBufferPointer<UInt8>, before end: Int) -> Bool {
        let end = min(end, bytes.count)
        var depth = 0
        var methodDepths: [Int] = []
        var index = 0
        while let brace = nextBrace(in: bytes, from: index, to: end) {
            if bytes[brace] == 0x7B {
                depth += 1
                // `) {` / `-> {` / `else {` open code blocks; `class X {` opens a type body.
                let previous = previousSignificantByte(in: bytes, before: brace)
                if previous == 0x29 || previous == 0x3E || !methodDepths.isEmpty {
                    methodDepths.append(depth)
                }
            } else {
                if methodDepths.last == depth { methodDepths.removeLast() }
                depth -= 1
            }
            index = brace + 1
        }
        return !methodDepths.isEmpty
    }

    /// The first `{` or `}` in `bytes[from..<to]`.
    private static func nextBrace(in bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int? {
        guard from < to, let base = bytes.baseAddress else { return nil }
        let raw = UnsafeRawPointer(base)
        let low7: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        // The top bit of a byte is set exactly when that byte of `x` is zero.
        @inline(__always) func zeroBytes(_ x: UInt64) -> UInt64 { ~(((x & low7) &+ low7) | x | low7) }
        var index = from
        while to - index >= 8 {
            let word = raw.loadUnaligned(fromByteOffset: index, as: UInt64.self)
            let hits = zeroBytes(word ^ 0x7B7B_7B7B_7B7B_7B7B) | zeroBytes(word ^ 0x7D7D_7D7D_7D7D_7D7D)
            if hits != 0 { return index + hits.trailingZeroBitCount / 8 }
            index += 8
        }
        while index < to {
            if base[index] == 0x7B || base[index] == 0x7D { return index }
            index += 1
        }
        return nil
    }

    /// The last character before `position` that is not Unicode white space, as its byte for an
    /// ASCII character and `0xFF` for any other; a space when there is none. Only `)` and `>` matter
    /// to the caller, so a non-ASCII character just has to be told apart from them.
    private static func previousSignificantByte(in bytes: UnsafeBufferPointer<UInt8>, before position: Int) -> UInt8 {
        var index = position
        while index > 0 {
            let byte = bytes[index - 1]
            if byte < 0x80 {
                if (0x09...0x0D).contains(byte) || byte == 0x20 { index -= 1; continue }
                return byte
            }
            // A multibyte scalar: back up to its first byte and decode it.
            var start = index - 1
            while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            guard let scalar = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self).unicodeScalars.first,
                  scalar.value <= 0xFFFF, isWhitespace(UInt16(scalar.value)) else { return 0xFF }
            index = start
        }
        return 0x20
    }

    /// Unicode White_Space, which is what `Character.isWhitespace` tests.
    private static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
}

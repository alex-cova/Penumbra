import Foundation

/// Finds the byte range of the expression immediately before a trigger character (the `.` that
/// asked for member completion), by scanning backward from it. Deliberately text-based rather than
/// tree-based: re-parsing the live buffer *including* the dangling trailing `.` is unreliable --
/// tree-sitter-java's error recovery keeps a bare `identifier.` well-contained inside its enclosing
/// block, but a `this.` or a longer call chain ending in a bare `.` can collapse the *entire*
/// surrounding declaration into one `ERROR` node at the file's root (confirmed empirically; see
/// `JavaSyntaxTreeGroundTruthTests`). ``JavaExpressionTyper`` instead feeds just the extracted
/// receiver text (never including the trailing dot) into a small synthetic, syntactically complete
/// snippet before parsing it.
enum JavaReceiverScanner {
    /// Scans backward from `dotOffset` (the byte offset of the `.` itself) to find where the
    /// receiver expression starts. Handles balanced `()`/`[]` (so `foo.bar(a, b).baz` and
    /// `list[0]` scan correctly), a top-level `<...>` generic-argument list immediately before a
    /// `(` (so `new HashMap<String, Integer>()` scans as a whole -- see
    /// `scanBackwardOverAngleBrackets`), the `new` keyword prefixing a constructor call, and dotted
    /// chains. It stops at the first token that can't be part of an expression continuing
    /// rightward -- an operator, a statement/block delimiter, or whitespace directly followed by
    /// another token (e.g. `return foo` stops right after `return `, leaving `foo` as the
    /// receiver).
    ///
    /// `<`/`>` are *not* tracked as a general bracket type the way `()`/`[]` are: unlike those,
    /// `>` is extremely common as a plain comparison/lambda-arrow operator, and doing so caused a
    /// real false match inside a lambda argument (`list.filter(x -> x > 0).though` mis-scanned the
    /// lambda's own `>` as a generic-list closer). Generic-argument scanning is therefore only
    /// attempted in the isolated helper below, and only when a `>` is reached at depth 0 (never
    /// while already inside a balanced `()`/`[]`, which is precisely where that false match came
    /// from) -- so a lambda's `>` two levels deep inside a call's arguments is simply consumed as
    /// ordinary content, exactly as it should be.
    ///
    /// Known limitation: a string/char literal used as a call argument earlier in the chain (e.g.
    /// `foo(")").bar`) can confuse the `()`/`[]` balance, since brackets inside literals aren't
    /// distinguished from real ones. Rare enough in practice (an argument to a call two hops back
    /// from the cursor) to accept rather than implement a full lexer here.
    static func receiverRange(in bytes: [UInt8], dotOffset: Int) -> Range<Int>? {
        guard dotOffset >= 0, dotOffset < bytes.count, bytes[dotOffset] == UInt8(ascii: ".") else { return nil }

        // Skip any whitespace directly before the dot itself (`foo .bar`, unusual but legal) so
        // the main scan below starts from the receiver's real last character.
        var end = dotOffset
        while end > 0, isWhitespaceByte(bytes[end - 1]) {
            end -= 1
        }
        guard end > 0 else { return nil }

        var i = end
        var bracketStack: [UInt8] = []

        while i > 0 {
            let c = bytes[i - 1]
            if !bracketStack.isEmpty {
                switch c {
                case UInt8(ascii: ")"), UInt8(ascii: "]"):
                    bracketStack.append(c)
                    i -= 1
                case UInt8(ascii: "("):
                    guard bracketStack.last == UInt8(ascii: ")") else { return finish(i, end) }
                    bracketStack.removeLast()
                    i -= 1
                case UInt8(ascii: "["):
                    guard bracketStack.last == UInt8(ascii: "]") else { return finish(i, end) }
                    bracketStack.removeLast()
                    i -= 1
                default:
                    i -= 1 // inside a balanced () or []: consume anything (arguments, nested exprs, lambdas' own `>`/`<`, ...).
                }
                continue
            }

            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                // A string/char literal used directly as a receiver, e.g. `"hello".length()`.
                guard let opening = scanBackwardOverQuotedLiteral(bytes, closingQuoteAt: i - 1, quote: c) else {
                    return finish(i, end)
                }
                i = opening
            case UInt8(ascii: ")"), UInt8(ascii: "]"):
                bracketStack.append(c)
                i -= 1
            case UInt8(ascii: ">"):
                if let matched = scanBackwardOverAngleBrackets(bytes, from: i) {
                    i = matched
                } else {
                    return finish(i, end)
                }
            case UInt8(ascii: "."):
                i -= 1
            case let ch where isIdentifierByte(ch):
                i -= 1
            case let ch where isWhitespaceByte(ch):
                // Whitespace at depth 0 is normally a token boundary (`return foo` stops right
                // after `return `) -- except when the word just before it is `new`, which prefixes
                // a constructor call and is part of the same expression (`new Foo().bar` should
                // scan the whole `new Foo()`).
                if let afterNew = consumeNewKeyword(bytes, before: i) {
                    i = afterNew
                } else {
                    return finish(i, end)
                }
            default:
                return finish(i, end)
            }
        }
        return finish(i, end)
    }

    private static func finish(_ start: Int, _ end: Int) -> Range<Int>? {
        start < end ? start..<end : nil
    }

    private static func isWhitespaceByte(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r")
    }

    private static func isIdentifierByte(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
            || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
            || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
            || c >= 0x80 // permissive: treat any non-ASCII byte as part of an identifier (UTF-8 continuation bytes included).
    }

    /// Called with `i` pointing just past a `>` found at depth 0 (`bytes[i-1] == ">"`). Scans
    /// backward with its own independent angle-bracket depth counter (nested `<...>` allowed, for
    /// `Map<String, List<Integer>>`), consuming identifiers/`.`/`,`/`?`/whitespace/`extends`/
    /// `super` freely, and returns the index right before the matching unnested `<` if one is
    /// found before the buffer runs out or a token that clearly can't appear in a type-argument
    /// list is hit (`;`, `{`, `}`, an unmatched `(`/`)`). Returns `nil` (meaning: treat `>` as an
    /// ordinary stop token, not a generic-list closer) otherwise -- e.g. for a real comparison.
    private static func scanBackwardOverAngleBrackets(_ bytes: [UInt8], from i: Int) -> Int? {
        var j = i
        var depth = 0
        while j > 0 {
            let c = bytes[j - 1]
            switch c {
            case UInt8(ascii: ">"):
                depth += 1
                j -= 1
            case UInt8(ascii: "<"):
                depth -= 1
                j -= 1
                if depth == 0 { return j }
                if depth < 0 { return nil }
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ";"):
                return nil
            default:
                j -= 1
            }
        }
        return nil
    }

    /// Called with the index of a closing `"`/`'`. Scans backward for the matching (unescaped)
    /// opening quote of the same kind, and returns its index, or `nil` if the buffer runs out
    /// first (a malformed/mid-edit literal).
    private static func scanBackwardOverQuotedLiteral(_ bytes: [UInt8], closingQuoteAt: Int, quote: UInt8) -> Int? {
        var j = closingQuoteAt
        while j > 0 {
            j -= 1
            if bytes[j] == quote {
                // An odd number of preceding backslashes means this quote is escaped, not the
                // literal's real boundary.
                var backslashes = 0
                var k = j
                while k > 0, bytes[k - 1] == UInt8(ascii: "\\") {
                    backslashes += 1
                    k -= 1
                }
                if backslashes % 2 == 0 { return j }
            }
        }
        return nil
    }

    /// Called with `i` pointing at a whitespace byte that stopped the main scan
    /// (`bytes[i-1]` is whitespace). If the identifier immediately before that whitespace run is
    /// exactly `new`, returns the index right before `new`; otherwise `nil`.
    private static func consumeNewKeyword(_ bytes: [UInt8], before i: Int) -> Int? {
        var j = i
        while j > 0, isWhitespaceByte(bytes[j - 1]) {
            j -= 1
        }
        let wordEnd = j
        while j > 0, isIdentifierByte(bytes[j - 1]) {
            j -= 1
        }
        guard j < wordEnd, String(decoding: bytes[j..<wordEnd], as: UTF8.self) == "new" else { return nil }
        return j
    }
}

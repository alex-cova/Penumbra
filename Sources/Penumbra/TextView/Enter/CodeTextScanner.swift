import Foundation

/// Textual scanning helpers for C-style code that need no syntax tree, so they work on code that
/// does not parse yet and cost time in proportion to the text they are given.
enum CodeTextScanner {
    /// The index after the string or character literal that starts at `start`, which holds
    /// `quote`. A literal does not continue past a line break.
    static func skipQuoted(_ units: [UInt16], from start: Int, quote: UInt16) -> Int {
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            if unit == UInt16(ascii: "\\") {
                index += 2
                continue
            }
            if unit == quote {
                return index + 1
            }
            if unit == 10 || unit == 13 {
                return index
            }
            index += 1
        }
        return units.count
    }

    /// Whether the end of `lineBeforeCaret` (a line's text up to the caret) is inside a string or
    /// character literal, or a `//` comment, that started on that line.
    static func endsInsideLiteralOrLineComment(_ lineBeforeCaret: String) -> Bool {
        let units = Array(lineBeforeCaret.utf16)
        let slash = UInt16(ascii: "/"), star = UInt16(ascii: "*")
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == slash, index + 1 < units.count {
                if units[index + 1] == slash {
                    return true
                }
                if units[index + 1] == star {
                    guard let end = blockCommentEnd(units, from: index + 2) else {
                        return true
                    }
                    index = end
                    continue
                }
            }
            if unit == UInt16(ascii: "\"") || unit == UInt16(ascii: "'") || unit == UInt16(ascii: "`") {
                let end = skipQuoted(units, from: index, quote: unit)
                if end >= units.count, !isClosed(units, quoteAt: index, end: end) {
                    return true
                }
                index = end
                continue
            }
            index += 1
        }
        return false
    }

    /// The index after the `*/` that closes a block comment whose body starts at `start`, or
    /// `nil` when it is not closed within `units`.
    static func blockCommentEnd(_ units: [UInt16], from start: Int) -> Int? {
        var index = start
        while index + 1 < units.count {
            if units[index] == UInt16(ascii: "*"), units[index + 1] == UInt16(ascii: "/") {
                return index + 2
            }
            index += 1
        }
        return nil
    }

    private static func isClosed(_ units: [UInt16], quoteAt start: Int, end: Int) -> Bool {
        end - 1 > start && units[end - 1] == units[start] && units[end - 2] != UInt16(ascii: "\\")
    }
}

/// Decides whether the `{` the caret follows is still waiting for its `}`.
enum UnmatchedBraceScanner {
    enum Result: Equatable {
        /// A `}` closes it, at an indentation that belongs to it.
        case matched
        /// No `}` closes it, or the first one belongs to an enclosing block.
        case unmatched
        /// `text` ended inside the block with more document after it.
        case needsMoreText
    }

    /// - Parameters:
    ///   - text: The document after the caret.
    ///   - openerIndent: Leading whitespace of the line holding the `{`.
    ///   - isEndOfDocument: Whether `text` reaches the end of the document.
    static func scan(text: String, openerIndent: String, isEndOfDocument: Bool) -> Result {
        let units = Array(text.utf16)
        let openerWidth = indentWidth(of: openerIndent.utf16)
        let slash = UInt16(ascii: "/"), star = UInt16(ascii: "*")
        let open = UInt16(ascii: "{"), close = UInt16(ascii: "}")
        let quote = UInt16(ascii: "\"")
        var depth = 1
        var lineStart = 0
        var seenLineBreak = false
        var index = 0
        while index < units.count {
            let unit = units[index]
            switch unit {
            case 10, 13:
                seenLineBreak = true
                index += 1
                lineStart = index
            case slash where index + 1 < units.count && units[index + 1] == slash:
                while index < units.count, units[index] != 10, units[index] != 13 {
                    index += 1
                }
            case slash where index + 1 < units.count && units[index + 1] == star:
                guard let end = CodeTextScanner.blockCommentEnd(units, from: index + 2) else {
                    return isEndOfDocument ? .unmatched : .needsMoreText
                }
                index = end
            case quote where index + 2 < units.count && units[index + 1] == quote && units[index + 2] == quote:
                // A text block runs to its closing delimiter, across lines.
                index += 3
                var closed = false
                while index + 2 < units.count {
                    if units[index] == UInt16(ascii: "\\") {
                        index += 2
                    } else if units[index] == quote, units[index + 1] == quote, units[index + 2] == quote {
                        index += 3
                        closed = true
                        break
                    } else {
                        index += 1
                    }
                }
                if !closed {
                    return isEndOfDocument ? .unmatched : .needsMoreText
                }
            case quote, UInt16(ascii: "'"), UInt16(ascii: "`"):
                index = CodeTextScanner.skipQuoted(units, from: index, quote: unit)
            case open:
                depth += 1
                index += 1
            case close:
                depth -= 1
                if depth == 0 {
                    // The closer on the opener's own line cannot be told from the next block's.
                    guard seenLineBreak else {
                        return .matched
                    }
                    let closerIndent = indentWidth(of: units[lineStart ..< index].prefix { $0 == 0x20 || $0 == 0x09 })
                    return closerIndent < openerWidth ? .unmatched : .matched
                }
                index += 1
            default:
                index += 1
            }
        }
        return isEndOfDocument ? .unmatched : .needsMoreText
    }

    private static func indentWidth<S: Sequence>(of units: S) -> Int where S.Element == UInt16 {
        units.reduce(0) { $0 + ($1 == 0x09 ? 4 : 1) }
    }
}

import Foundation

private func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\t"
}

/// Enter between matching brackets: `{|}` → the closing bracket moves to its own line and the caret
/// lands on an indented blank line between them.
@MainActor
enum EnterBetweenBracesHandler {
    static func edit(for context: EnterContext) -> EnterEdit? {
        guard let opener = context.textBeforeCaret.last(where: { !isBlank($0) }),
              let closer = context.textAfterCaret.first(where: { !isBlank($0) }),
              (opener == "{" && closer == "}") || (opener == "[" && closer == "]") else {
            return nil
        }
        let closing: String
        let middle: String
        if context.usesSmartIndent {
            middle = context.indentString(textAfterCaret: "")
            closing = context.indentString(textAfterCaret: String(closer))
        } else {
            closing = context.leadingWhitespace
            middle = closing + context.normalIndent
        }
        let first = context.lineBreak + middle
        let range = NSRange(location: context.selectedRange.location,
                            length: context.selectedRange.length + context.leadingWhitespaceLengthAfterCaret)
        return EnterEdit(replacementRange: range,
                         text: first + context.lineBreak + closing,
                         caretOffset: first.utf16.count)
    }
}

/// Enter in and around block comments: generates the closing delimiter after `/**`, continues the
/// ` * ` prefix on following lines, and moves a trailing `*/` to its own line.
@MainActor
enum BlockCommentEnterHandler {
    private static let maximumLinesScannedUpward = 500

    static func edit(for context: EnterContext) -> EnterEdit? {
        guard let start = context.behavior?.blockCommentStart,
              let end = context.behavior?.blockCommentEnd else {
            return nil
        }
        let trimmedBefore = context.textBeforeCaret.drop(while: isBlank)
        let trimmedAfter = context.textAfterCaret.drop(while: isBlank)
        let whitespace = context.leadingWhitespace
        let lineBreak = context.lineBreak
        let afterWhitespaceLength = context.leadingWhitespaceLengthAfterCaret
        let selection = context.selectedRange

        let starWhitespace: String
        if trimmedBefore.hasPrefix(start) {
            let rest = trimmedBefore.dropFirst(start.count)
            if rest.contains(end) {
                return nil
            }
            starWhitespace = whitespace + " "
            let isBareOpening = rest.isEmpty || rest == "*"
            if isBareOpening, trimmedAfter.isEmpty, !isAlreadyClosed(context) {
                let first = lineBreak + starWhitespace + "* "
                return EnterEdit(replacementRange: NSRange(location: selection.location,
                                                           length: selection.length + afterWhitespaceLength),
                                 text: first + lineBreak + starWhitespace + end,
                                 caretOffset: first.utf16.count)
            }
        } else if trimmedBefore.hasPrefix("*"), !trimmedBefore.hasPrefix(end), isInsideBlockComment(context, start: start, end: end) {
            starWhitespace = whitespace
        } else {
            return nil
        }

        let first = lineBreak + starWhitespace + "* "
        if trimmedAfter.hasPrefix(end) {
            let consumed = afterWhitespaceLength + end.utf16.count
            return EnterEdit(replacementRange: NSRange(location: selection.location, length: selection.length + consumed),
                             text: first + lineBreak + starWhitespace + end,
                             caretOffset: first.utf16.count)
        }
        return EnterEdit(replacementRange: NSRange(location: selection.location,
                                                   length: selection.length + afterWhitespaceLength),
                         text: first,
                         caretOffset: nil)
    }

    /// A following ` * …` line means the comment already has its body/closing.
    private static func isAlreadyClosed(_ context: EnterContext) -> Bool {
        var offset = 1
        while let line = context.textOfLine(atRowOffset: offset) {
            let trimmed = line.drop(while: isBlank)
            if !trimmed.isEmpty {
                return trimmed.hasPrefix("*")
            }
            offset += 1
        }
        return false
    }

    /// Walks up through consecutive `*` lines looking for the `/*` that opens them.
    private static func isInsideBlockComment(_ context: EnterContext, start: String, end: String) -> Bool {
        for step in 1 ... maximumLinesScannedUpward {
            guard let line = context.textOfLine(atRowOffset: -step) else {
                return false
            }
            let trimmed = line.drop(while: isBlank)
            if trimmed.hasPrefix(start) {
                return !trimmed.dropFirst(start.count).contains(end)
            }
            if !trimmed.hasPrefix("*") || trimmed.hasPrefix(end) {
                return false
            }
        }
        return false
    }
}

/// Enter inside a string literal: splits it as `"abc" +` / `"def"`.
@MainActor
enum StringLiteralEnterHandler {
    static func edit(for context: EnterContext) -> EnterEdit? {
        guard let concatenation = context.behavior?.stringConcatenationOperator,
              isInsideSingleLineString(before: context.textBeforeCaret),
              hasClosingQuote(in: context.textAfterCaret) else {
            return nil
        }
        // A string that starts on an earlier line is a text block; leave it alone.
        for node in context.enclosingSyntaxNodes where node.type.contains("string") {
            if node.startLocation.lineNumber != node.endLocation.lineNumber {
                return nil
            }
        }
        let trimmedBefore = context.textBeforeCaret.drop(while: isBlank)
        let continuesSplit = trimmedBefore.hasPrefix("\"") || trimmedBefore.hasPrefix(concatenation)
        let indent = continuesSplit
            ? context.leadingWhitespace
            : context.leadingWhitespace + String(repeating: context.normalIndent, count: context.behavior?.continuationIndentLevels ?? 2)
        return EnterEdit(replacementRange: context.selectedRange,
                         text: "\" " + concatenation + context.lineBreak + indent + "\"",
                         caretOffset: nil)
    }

    private static func isInsideSingleLineString(before: String) -> Bool {
        let units = Array(before.utf16)
        let quote = UInt16(ascii: "\""), slash = UInt16(ascii: "/"), backslash = UInt16(ascii: "\\"), apostrophe = UInt16(ascii: "'")
        var inString = false
        var index = 0
        while index < units.count {
            let unit = units[index]
            if inString {
                if unit == backslash {
                    if index + 1 >= units.count {
                        return false
                    }
                    index += 2
                    continue
                }
                if unit == quote {
                    inString = false
                }
            } else if unit == slash, index + 1 < units.count, units[index + 1] == slash {
                return false
            } else if unit == slash, index + 1 < units.count, units[index + 1] == UInt16(ascii: "*") {
                var scan = index + 2
                var closed = false
                while scan + 1 < units.count {
                    if units[scan] == UInt16(ascii: "*"), units[scan + 1] == slash {
                        closed = true
                        break
                    }
                    scan += 1
                }
                if !closed {
                    return false
                }
                index = scan + 2
                continue
            } else if unit == quote {
                if index + 2 < units.count, units[index + 1] == quote, units[index + 2] == quote {
                    return false
                }
                inString = true
            } else if unit == apostrophe {
                index += 1
                while index < units.count, units[index] != apostrophe {
                    index += units[index] == backslash ? 2 : 1
                }
            }
            index += 1
        }
        return inString
    }

    private static func hasClosingQuote(in after: String) -> Bool {
        let units = Array(after.utf16)
        var index = 0
        while index < units.count {
            if units[index] == UInt16(ascii: "\\") {
                index += 2
                continue
            }
            if units[index] == UInt16(ascii: "\"") {
                return true
            }
            index += 1
        }
        return false
    }
}

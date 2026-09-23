import Foundation

/// Structure-aware indentation for C-family languages (Java-style Enter).
///
/// Lexes the text before the caret (skipping comments, strings and char literals), tracks the
/// stack of unclosed brackets with the indent of the line each was opened on, and derives the new
/// line's indent from that structure rather than from the previous line:
/// block indent inside `{}`, continuation indent inside `()` or after an unfinished expression,
/// and one extra level after a brace-less `if`/`for`/`while`/`else`/`do`.
struct CStyleLineIndentProvider {
    let behavior: EnterBehavior
    let normalIndent: String
    let continuationIndent: String

    private enum Token: Equatable {
        case word(String)
        case punct(String)
        case group(UInt16)
        case literal
    }

    private struct Frame {
        var opener: UInt16
        var openerLineIndent: String
        var isArrayInit = false
        var isEnumBody = false
        var caseActive = false
        var tokens: [Token] = []

        var isRoot: Bool { opener == 0 }
    }

    private static let unfinishedOperators: Set<String> = [
        "+", "-", "*", "/", "%", "=", "&", "|", "^", "?", ":", ".", "->",
        "&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ","
    ]
    private static let threeCharOperators: Set<String> = ["...", "<<=", ">>=", ">>>"]
    private static let twoCharOperators: Set<String> = [
        "->", "::", "++", "--", "&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "<<", ">>"
    ]

    /// - Parameters:
    ///   - textBefore: Document text before the caret. Should start at a line start.
    ///   - textAfter: Text that will follow the caret on the new line.
    ///   - isTruncated: `true` when `textBefore` doesn't begin at the document start, so the outermost
    ///     structure is unknown.
    /// - Returns: The indentation, or `nil` when it can't be determined.
    func indent(textBefore: String, textAfter: String, isTruncated: Bool) -> String? {
        let stack = scan(Array(textBefore.utf16))
        guard let top = stack.last else {
            return nil
        }
        if isTruncated && top.isRoot {
            return nil
        }
        if let first = textAfter.first(where: { $0 != " " && $0 != "\t" }), ")]}".contains(first) {
            return top.openerLineIndent
        }
        if !top.isRoot && !top.isArrayInit && (top.opener == UInt16(ascii: "(") || top.opener == UInt16(ascii: "[")) {
            return top.openerLineIndent + continuationIndent
        }
        var base = top.isRoot ? "" : top.openerLineIndent + normalIndent
        if top.caseActive {
            base += normalIndent
        }
        let (headerCount, consumed) = controlHeaders(in: top.tokens)
        base += String(repeating: normalIndent, count: headerCount)
        if consumed == top.tokens.count {
            return base
        }
        if isUnfinished(top) {
            return base + continuationIndent
        }
        return base
    }

    // MARK: - Statement analysis

    private func controlHeaders(in tokens: [Token]) -> (count: Int, consumed: Int) {
        var index = 0
        var count = 0
        while index < tokens.count {
            guard case .word(let word) = tokens[index], behavior.controlKeywords.contains(word) else {
                break
            }
            switch word {
            case "else":
                index += 1
                if index + 1 < tokens.count, tokens[index] == .word("if"), tokens[index + 1] == .group(UInt16(ascii: "(")) {
                    index += 2
                }
            case "do":
                index += 1
            default:
                guard index + 1 < tokens.count, tokens[index + 1] == .group(UInt16(ascii: "(")) else {
                    return (count, index)
                }
                index += 2
            }
            count += 1
        }
        return (count, index)
    }

    private func isUnfinished(_ frame: Frame) -> Bool {
        guard case .punct(let op)? = frame.tokens.last, Self.unfinishedOperators.contains(op) else {
            return false
        }
        if op == "," && (frame.isArrayInit || frame.isEnumBody) {
            return false
        }
        return true
    }

    // MARK: - Lexing

    private func scan(_ units: [UInt16]) -> [Frame] {
        var stack = [Frame(opener: 0, openerLineIndent: "")]
        let count = units.count
        var index = 0
        var lineIndent = Self.leadingWhitespace(in: units, from: 0)

        func isNewline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }

        while index < count {
            let unit = units[index]
            if isNewline(unit) {
                index += 1
                lineIndent = Self.leadingWhitespace(in: units, from: index)
                continue
            }
            if unit == 0x20 || unit == 0x09 {
                index += 1
                continue
            }
            if unit == UInt16(ascii: "/"), index + 1 < count {
                if units[index + 1] == UInt16(ascii: "/") {
                    while index < count, !isNewline(units[index]) { index += 1 }
                    continue
                }
                if units[index + 1] == UInt16(ascii: "*") {
                    index += 2
                    while index < count, !(units[index] == UInt16(ascii: "*") && index + 1 < count && units[index + 1] == UInt16(ascii: "/")) {
                        if isNewline(units[index]) {
                            lineIndent = Self.leadingWhitespace(in: units, from: index + 1)
                        }
                        index += 1
                    }
                    index = min(count, index + 2)
                    continue
                }
            }
            if unit == UInt16(ascii: "\"") {
                if index + 2 < count, units[index + 1] == unit, units[index + 2] == unit {
                    index += 3
                    while index < count {
                        if units[index] == UInt16(ascii: "\\") {
                            index += 2
                            continue
                        }
                        if units[index] == unit, index + 2 < count,
                           units[index + 1] == unit, units[index + 2] == unit {
                            index += 3
                            break
                        }
                        if isNewline(units[index]) {
                            lineIndent = Self.leadingWhitespace(in: units, from: index + 1)
                        }
                        index += 1
                    }
                } else {
                    index = Self.skipQuoted(units, from: index, quote: unit)
                }
                stack[stack.count - 1].tokens.append(.literal)
                continue
            }
            if unit == UInt16(ascii: "'") {
                index = Self.skipQuoted(units, from: index, quote: unit)
                stack[stack.count - 1].tokens.append(.literal)
                continue
            }
            if Self.isIdentifierUnit(unit) {
                let start = index
                let isNumber = unit >= 0x30 && unit <= 0x39
                index += 1
                while index < count, Self.isIdentifierUnit(units[index]) || (isNumber && units[index] == UInt16(ascii: ".")) {
                    index += 1
                }
                let word = String(decoding: units[start ..< index], as: UTF16.self)
                stack[stack.count - 1].tokens.append(isNumber ? .literal : .word(word))
                continue
            }
            handlePunctuation(units, index: &index, stack: &stack, lineIndent: lineIndent)
        }
        return stack
    }

    private func handlePunctuation(_ units: [UInt16], index: inout Int, stack: inout [Frame], lineIndent: String) {
        let unit = units[index]
        let topIndex = stack.count - 1
        switch unit {
        case UInt16(ascii: "("), UInt16(ascii: "["):
            stack.append(Frame(opener: unit, openerLineIndent: lineIndent))
            index += 1
        case UInt16(ascii: "{"):
            let top = stack[topIndex]
            let previous = top.tokens.last
            var frame = Frame(opener: unit, openerLineIndent: lineIndent)
            if top.opener == UInt16(ascii: "(") || top.opener == UInt16(ascii: "[") {
                frame.isArrayInit = previous == nil || previous == .punct(",") || previous == .punct("=")
            } else if top.isArrayInit {
                frame.isArrayInit = previous == nil || previous == .punct(",")
            } else {
                frame.isArrayInit = previous == .punct("=") || previous == .group(UInt16(ascii: "["))
            }
            frame.isEnumBody = !frame.isArrayInit && top.tokens.contains(.word("enum"))
            stack.append(frame)
            index += 1
        case UInt16(ascii: ")"), UInt16(ascii: "]"), UInt16(ascii: "}"):
            let expectedOpener: UInt16
            switch unit {
            case UInt16(ascii: ")"): expectedOpener = UInt16(ascii: "(")
            case UInt16(ascii: "]"): expectedOpener = UInt16(ascii: "[")
            default: expectedOpener = UInt16(ascii: "{")
            }
            index += 1
            guard stack.count > 1, stack[topIndex].opener == expectedOpener else {
                return
            }
            let frame = stack.removeLast()
            let parent = stack.count - 1
            if frame.opener == UInt16(ascii: "{") && !frame.isArrayInit {
                stack[parent].tokens.removeAll()
            } else {
                stack[parent].tokens.append(.group(frame.opener))
            }
        case UInt16(ascii: ";"):
            stack[topIndex].tokens.removeAll()
            index += 1
        case UInt16(ascii: ":"):
            let top = stack[topIndex]
            let isSingleColon = !(index + 1 < units.count && units[index + 1] == UInt16(ascii: ":"))
                && !(index > 0 && units[index - 1] == UInt16(ascii: ":"))
            if isSingleColon, top.opener == UInt16(ascii: "{"), let first = top.tokens.first,
               first == .word("case") || first == .word("default") {
                stack[topIndex].tokens.removeAll()
                stack[topIndex].caseActive = true
                index += 1
            } else {
                appendOperator(units, index: &index, to: &stack)
            }
        default:
            appendOperator(units, index: &index, to: &stack)
        }
    }

    private func appendOperator(_ units: [UInt16], index: inout Int, to stack: inout [Frame]) {
        func string(_ length: Int) -> String? {
            guard index + length <= units.count else { return nil }
            return String(decoding: units[index ..< index + length], as: UTF16.self)
        }
        let symbol: String
        if let three = string(3), Self.threeCharOperators.contains(three) {
            symbol = three
        } else if let two = string(2), Self.twoCharOperators.contains(two) {
            symbol = two
        } else {
            symbol = string(1) ?? ""
        }
        index += max(symbol.utf16.count, 1)
        stack[stack.count - 1].tokens.append(.punct(symbol))
    }

    // MARK: - Helpers

    private static func skipQuoted(_ units: [UInt16], from start: Int, quote: UInt16) -> Int {
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

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39)
            || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit == 0x24 || unit >= 0x80
    }

    private static func leadingWhitespace(in units: [UInt16], from start: Int) -> String {
        var end = start
        while end < units.count, units[end] == 0x20 || units[end] == 0x09 {
            end += 1
        }
        return String(decoding: units[start ..< end], as: UTF16.self)
    }
}

extension UInt16 {
    /// A UTF-16 code unit from an ASCII scalar literal, e.g. `UInt16(ascii: "{")`.
    init(ascii scalar: Unicode.Scalar) {
        self.init(scalar.value)
    }
}

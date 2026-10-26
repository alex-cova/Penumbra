import Foundation

struct GraphQLToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case name
        /// One of `{ } ( ) [ ] : = ! | & @ $`.
        case punctuator
        case spread
        case number
        /// `text` is the decoded value.
        case string
        case blockString
    }

    var kind: Kind
    var text: String
    /// UTF-16 offsets into the lexed text.
    var range: Range<Int>
    /// A string that reached the end of the text before its closing quote.
    var isUnterminated = false

    func isPunctuator(_ value: Character) -> Bool {
        kind == .punctuator && text == String(value)
    }

    func isName(_ value: String) -> Bool {
        kind == .name && text == value
    }
}

/// Splits GraphQL source into tokens. It never fails: a character it does not know is skipped, so
/// half-typed input still yields the tokens before the caret. Commas, whitespace and `#` comments
/// are dropped.
enum GraphQLLexer {
    struct Output: Sendable {
        var tokens: [GraphQLToken]
        /// The text ends inside a `#` comment.
        var endsInComment: Bool
    }

    static func lex(_ text: String) -> Output {
        let units = Array(text.utf16)
        var tokens: [GraphQLToken] = []
        var index = 0
        var endsInComment = false
        let count = units.count

        func isNameStart(_ unit: UInt16) -> Bool {
            unit == 0x5F || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        }
        func isDigit(_ unit: UInt16) -> Bool {
            unit >= 0x30 && unit <= 0x39
        }
        func string(_ range: Range<Int>) -> String {
            String(decoding: units[range], as: UTF16.self)
        }

        while index < count {
            let unit = units[index]
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0xFEFF:
                index += 1
            case 0x23:
                while index < count, units[index] != 0x0A, units[index] != 0x0D {
                    index += 1
                }
                if index >= count {
                    endsInComment = true
                }
            case 0x2E where index + 2 < count && units[index + 1] == 0x2E && units[index + 2] == 0x2E:
                tokens.append(GraphQLToken(kind: .spread, text: "...", range: index..<(index + 3)))
                index += 3
            case 0x22:
                if index + 2 < count, units[index + 1] == 0x22, units[index + 2] == 0x22 {
                    let start = index
                    index += 3
                    var value: [UInt16] = []
                    var closed = false
                    while index < count {
                        if units[index] == 0x5C, index + 3 < count, units[index + 1] == 0x22,
                           units[index + 2] == 0x22, units[index + 3] == 0x22 {
                            value.append(contentsOf: [0x22, 0x22, 0x22])
                            index += 4
                            continue
                        }
                        if units[index] == 0x22, index + 2 < count, units[index + 1] == 0x22, units[index + 2] == 0x22 {
                            index += 3
                            closed = true
                            break
                        }
                        value.append(units[index])
                        index += 1
                    }
                    var token = GraphQLToken(
                        kind: .blockString,
                        text: dedentBlockString(String(decoding: value, as: UTF16.self)),
                        range: start..<index
                    )
                    token.isUnterminated = !closed
                    tokens.append(token)
                } else {
                    let start = index
                    index += 1
                    var value: [UInt16] = []
                    var closed = false
                    while index < count {
                        let current = units[index]
                        if current == 0x0A || current == 0x0D {
                            break
                        }
                        if current == 0x22 {
                            index += 1
                            closed = true
                            break
                        }
                        if current == 0x5C, index + 1 < count {
                            let escaped = units[index + 1]
                            index += 2
                            switch escaped {
                            case 0x6E: value.append(0x0A)
                            case 0x74: value.append(0x09)
                            case 0x72: value.append(0x0D)
                            case 0x62: value.append(0x08)
                            case 0x66: value.append(0x0C)
                            case 0x75:
                                if index + 4 <= count,
                                   let scalar = UInt16(string(index..<(index + 4)), radix: 16) {
                                    value.append(scalar)
                                    index += 4
                                }
                            default: value.append(escaped)
                            }
                            continue
                        }
                        value.append(current)
                        index += 1
                    }
                    var token = GraphQLToken(
                        kind: .string,
                        text: String(decoding: value, as: UTF16.self),
                        range: start..<index
                    )
                    // A string that ran into the end of the text is the one the caret is inside.
                    token.isUnterminated = !closed && index >= count
                    tokens.append(token)
                }
            case _ where isNameStart(unit):
                let start = index
                while index < count, isNameStart(units[index]) || isDigit(units[index]) {
                    index += 1
                }
                tokens.append(GraphQLToken(kind: .name, text: string(start..<index), range: start..<index))
            case _ where isDigit(unit) || (unit == 0x2D && index + 1 < count && isDigit(units[index + 1])):
                let start = index
                index += 1
                while index < count {
                    let current = units[index]
                    let isExponentSign = (current == 0x2B || current == 0x2D)
                        && (units[index - 1] == 0x65 || units[index - 1] == 0x45)
                    if isDigit(current) || current == 0x2E || current == 0x65 || current == 0x45 || isExponentSign {
                        index += 1
                    } else {
                        break
                    }
                }
                tokens.append(GraphQLToken(kind: .number, text: string(start..<index), range: start..<index))
            case 0x7B, 0x7D, 0x28, 0x29, 0x5B, 0x5D, 0x3A, 0x3D, 0x21, 0x7C, 0x26, 0x40, 0x24:
                tokens.append(GraphQLToken(kind: .punctuator, text: string(index..<(index + 1)), range: index..<(index + 1)))
                index += 1
            default:
                index += 1
            }
        }
        return Output(tokens: tokens, endsInComment: endsInComment)
    }

    /// The spec's BlockStringValue: common indentation of every line but the first is removed, and
    /// blank lines at both ends are dropped.
    static func dedentBlockString(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var common = Int.max
        for line in lines.dropFirst() {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent < line.count {
                common = min(common, indent)
            }
        }
        if common != Int.max, common > 0 {
            for index in lines.indices.dropFirst() {
                lines[index] = String(lines[index].dropFirst(min(common, lines[index].count)))
            }
        }
        func isBlank(_ line: String) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }
        while let first = lines.first, isBlank(first) {
            lines.removeFirst()
        }
        while let last = lines.last, isBlank(last) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

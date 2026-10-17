import Foundation

/// Pure decision logic for "Complete Current Statement" (⇧⌘↵): what to append to a line of
/// C-style code (Java and friends) so it becomes a finished statement.
///
/// In order, it closes an unterminated string, closes unclosed `(` and `[`, closes an unclosed
/// array initializer `{`, then ends the line with `;` for a statement or ` {}` for a construct
/// that takes a body (`if`, `for`, `while`, `switch`, `try`, `catch`, `synchronized`, `else`,
/// class-like declarations, methods and constructors). `do` becomes ` {} while ();`. A switch
/// expression (`= switch (x)`) gets a body and a semicolon. A line that is already finished, or
/// that clearly continues (trailing operator or comma, annotation, comment, an opening block
/// `{`), gets nothing appended.
///
/// The check is textual. The caller passes the caret line plus at most
/// ``maximumLookbehindLines`` lines above it, so the work stays bounded by the statement and
/// never by the document, and it works on code that doesn't parse yet. It skips string and
/// character literals and `//` and `/* */` comments; text blocks (`"""`) are left alone.
enum StatementCompletionService {
    /// How many lines above the caret may belong to the same statement.
    static let maximumLookbehindLines = 30

    struct Completion: Equatable {
        /// UTF-16 offset in the caret line where `appended` goes: the end of the code, before any
        /// trailing `//` comment or whitespace.
        var insertionOffset: Int
        var appended: String
        /// Where the caret goes within `appended`, or nil to put it at the end of the line.
        /// Set for a body (`{|}`), so a line break then splits the braces. Negative lands before
        /// the insertion, inside an empty `()` that was already closed.
        var caretOffsetInAppended: Int?
        /// Where the following line break goes within `appended`, when that is not the caret.
        /// Empty `if ()` keeps the caret in the parentheses while `{}` still splits.
        var lineBreakOffsetInAppended: Int?
    }

    /// Words that start a header taking a parenthesized condition and then a body.
    private static let parenthesizedHeaders: Set<String> = [
        "if", "for", "while", "switch", "catch", "synchronized"
    ]
    /// Headers whose empty condition leaves the caret between the parentheses.
    private static let emptyConditionHeaders: Set<String> = ["if", "for", "while"]
    /// Headers that take a body with no condition (`try` may have a resource list). `do` is
    /// handled on its own so it can grow a `while ()`.
    private static let bareHeaders: Set<String> = ["else", "try", "finally"]
    private static let typeDeclarations: Set<String> = ["class", "interface", "enum", "record"]
    private static let modifiers: Set<String> = [
        "public", "protected", "private", "static", "final", "abstract",
        "native", "default", "strictfp", "sealed"
    ]
    private static let notADeclaration: Set<String> = [
        "return", "throw", "new", "else", "yield", "assert", "break", "continue", "case",
        "package", "import", "var"
    ]
    private static let continuationSuffixes = [
        ",", "+", "-", "*", "/", "%", "&&", "||", "&", "|", "^", "?", ":", "=", "->", ".", "::", "<", ">"
    ]
    private static let danglingStart: Set<Character> = [
        ",", "+", "-", "*", "/", "%", "&", "|", "^", "?", ":", "=", ".", "<", ">", ")", "]"
    ]

    static func complete(line: String, precedingLines: [String] = [], extraControlKeywords: Set<String> = []) -> Completion? {
        guard let scan = scan(precedingLines + [line]) else {
            return nil
        }
        let head = scan.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            return nil
        }
        let quote = scan.unterminatedQuote.map(String.init) ?? ""
        let prefix = quote + scan.closers
        func completion(_ appended: String, caret: Int? = nil, lineBreak: Int? = nil) -> Completion {
            Completion(insertionOffset: scan.codeEnd,
                       appended: appended,
                       caretOffsetInAppended: caret,
                       lineBreakOffsetInAppended: lineBreak)
        }
        func body() -> Completion {
            let appended = prefix + " {}"
            return completion(appended, caret: (appended as NSString).length - 1)
        }
        func emptyCondition() -> Completion {
            let appended = prefix + " {}"
            let brace = (appended as NSString).range(of: "}", options: .backwards).location
            let caret = prefix.hasSuffix(")") ? (prefix as NSString).length - 1 : -1
            return completion(appended, caret: caret, lineBreak: brace == NSNotFound ? nil : brace)
        }
        func doWhile() -> Completion {
            let appended = prefix + " {} while ();"
            return completion(appended, caret: (prefix as NSString).length + 2)
        }
        func switchExpression(empty: Bool) -> Completion {
            let appended = prefix + " {};"
            let base = (prefix as NSString).length
            if empty {
                let caret = prefix.hasSuffix(")") ? base - 1 : -1
                return completion(appended, caret: caret, lineBreak: base + 2)
            }
            return completion(appended, caret: base + 2)
        }

        // Not code, or a line that opens a block: nothing to add. An initializer `{` is not a block.
        if head.hasPrefix("*") || head.hasPrefix("/*") || scan.hasOpenBlock {
            return completion("")
        }
        // A trailing operator or comma means the expression goes on. Inside an unterminated
        // string a trailing comma is just text, so only test when the string is closed.
        if quote.isEmpty, continues(head) {
            return completion("")
        }

        let closed = head + prefix
        if closed.hasSuffix(";") || isAnnotationOnly(closed) {
            return completion(prefix)
        }

        let afterBrace = closed.hasPrefix("}")
        let statement = afterBrace ? String(closed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : closed
        let words = leadingWords(of: stripLeadingAnnotations(statement))
        let header = words.first { !modifiers.contains($0) } ?? words.first ?? ""
        let parenthesized = parenthesizedHeaders.union(extraControlKeywords)
        let switchExpressionStatement = isSwitchExpression(sawSwitch: scan.sawSwitch, closed: closed)

        if afterBrace, header == "while" {
            // `} while (x)` closes a do loop.
            return completion(prefix + ";")
        }
        // `else` is also handed in as an extra control keyword; it still takes a body, and
        // `else if` takes a condition. Decide that before the parenthesized-header rule.
        if isElseIf(words) {
            switch headerCondition(in: closed, keyword: "if") {
            case .absent:
                let appended = prefix + " () {}"
                let base = (prefix as NSString).length
                return completion(appended, caret: base + 2, lineBreak: base + 5)
            case .empty:
                return emptyCondition()
            case .present:
                return closed.hasSuffix(")") ? body() : completion(prefix)
            }
        }
        if header == "do", !afterBrace {
            return doWhile()
        }
        if bareHeaders.contains(header) {
            return body()
        }
        if parenthesized.contains(header) {
            if switchExpressionStatement {
                let condition = headerCondition(in: closed, keyword: "switch")
                return switchExpression(empty: condition == .empty)
            }
            let condition = headerCondition(in: closed, keyword: header)
            if condition == .empty, emptyConditionHeaders.contains(header) {
                return emptyCondition()
            }
            return closed.hasSuffix(")") ? body() : completion(prefix)
        }
        if closed.hasSuffix("}") {
            // A closed block is finished, but an assignment or an array initializer still needs
            // its `;`. `new int[]{1, 2}` has no `=` and still needs one.
            let needsSemicolon = !afterBrace && (assignsValue(closed) || scan.closedInitializer || prefix.contains("}"))
            return completion(prefix + (needsSemicolon ? ";" : ""))
        }
        if switchExpressionStatement {
            return switchExpression(empty: headerCondition(in: closed, keyword: "switch") == .empty)
        }
        if !afterBrace {
            if words.contains(where: { typeDeclarations.contains($0) }) || words.first == "@interface" {
                return body()
            }
            if isMethodOrConstructor(closed) {
                if words.contains("abstract") || words.contains("native") {
                    return completion(prefix + ";")
                }
                return body()
            }
        }
        return completion(prefix + ";")
    }

    /// Whether `previousLine` is still part of the statement whose text so far is `fragment`
    /// (the caret line, then the lines already joined above it). A blank line, a `;`, a block
    /// `{`, or a `}` ends the statement above. A line that stops mid-expression, or a fragment
    /// that begins with an operator, stays attached.
    static func attaches(previousLine: String, toFragment fragment: String) -> Bool {
        if previousLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        guard let boundary = scanLine(previousLine) else {
            return false
        }
        if boundary.endsStatement {
            return false
        }
        if boundary.opensIntoNext {
            return true
        }
        return fragmentDangles(fragment)
    }

    private static func continues(_ head: String) -> Bool {
        if head.hasSuffix("++") || head.hasSuffix("--") {
            return false
        }
        return continuationSuffixes.contains { head.hasSuffix($0) }
    }

    private static func fragmentDangles(_ fragment: String) -> Bool {
        let trimmed = fragment.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard let first = trimmed.first else {
            return false
        }
        return danglingStart.contains(first)
    }

    private static func isElseIf(_ words: [String]) -> Bool {
        words.count >= 2 && words[0] == "else" && words[1] == "if"
    }

    /// A `switch` that produces a value (`int x = switch`, `return switch`, `= switch`) rather
    /// than a statement. The block still needs a semicolon. An assignment inside the selector
    /// (`switch (a = b)`) is still a statement.
    private static func isSwitchExpression(sawSwitch: Bool, closed: String) -> Bool {
        guard sawSwitch, let range = keywordRange(in: closed, keyword: "switch") else {
            return false
        }
        let before = String(closed[..<range.lowerBound])
        let lastWord = before.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }.last.map(String.init)
        if lastWord == "return" || lastWord == "yield" {
            return true
        }
        return assignsValue(before)
    }

    /// Whether the text holds a plain assignment `=` (not `==`, `<=`, `>=`, `!=`).
    private static func assignsValue(_ text: String) -> Bool {
        let units = Array(text.unicodeScalars)
        for (index, scalar) in units.enumerated() where scalar == "=" {
            let before = index > 0 ? units[index - 1] : " "
            let after = index + 1 < units.count ? units[index + 1] : " "
            if before != "=" && before != "<" && before != ">" && before != "!" && after != "=" {
                return true
            }
        }
        return false
    }

    // MARK: - Scanning

    private enum Bracket {
        case paren
        case square
        case brace(initializer: Bool)
    }

    private struct Carry {
        var stack: [Bracket] = []
        var quote: Character?
        var inBlockComment = false
        var terminated = false
        var closedInitializer = false
        var sawSwitch = false
        var lastSignificant: Character?
        var beforeLast: Character?
        var failed = false
    }

    private struct LineFacts {
        var code: String
        var codeEnd: Int
        var endsStatement: Bool
        var opensIntoNext: Bool
    }

    private struct Scan {
        /// The code of the whole statement, comments excluded from the bracket count but kept in
        /// the text, trailing whitespace on each line excluded.
        var code: String
        /// UTF-16 length of the caret line's code. The insertion point in that line.
        var codeEnd: Int
        var closers: String
        var unterminatedQuote: Character?
        var hasOpenBlock: Bool
        var closedInitializer: Bool
        var sawSwitch: Bool
    }

    /// Walks every line of the statement. Returns nil when it can't be completed sensibly: an
    /// unclosed block comment, a text block, or mismatched brackets.
    private static func scan(_ lines: [String]) -> Scan? {
        guard let caret = lines.last else {
            return nil
        }
        var carry = Carry()
        var parts: [String] = []
        for line in lines.dropLast() {
            guard let facts = consume(line, carry: &carry), !carry.failed else {
                return nil
            }
            parts.append(facts.code)
        }
        guard let caretFacts = consume(caret, carry: &carry), !carry.failed, !carry.inBlockComment else {
            return nil
        }
        parts.append(caretFacts.code)
        let hasOpenBlock = carry.stack.contains { bracket in
            if case .brace(false) = bracket { return true }
            return false
        }
        var closers = ""
        if !hasOpenBlock {
            for open in carry.stack.reversed() {
                switch open {
                case .paren: closers.append(")")
                case .square: closers.append("]")
                case .brace(true): closers.append("}")
                case .brace(false): break
                }
            }
        }
        return Scan(code: parts.joined(separator: "\n"),
                    codeEnd: caretFacts.codeEnd,
                    closers: closers,
                    unterminatedQuote: carry.quote,
                    hasOpenBlock: hasOpenBlock,
                    closedInitializer: carry.closedInitializer,
                    sawSwitch: carry.sawSwitch)
    }

    /// One line, for the lookbehind decision. Nil means the line can't be joined safely.
    private static func scanLine(_ line: String) -> LineFacts? {
        var carry = Carry()
        guard let facts = consume(line, carry: &carry), !carry.failed, !carry.inBlockComment else {
            return nil
        }
        return facts
    }

    private static func consume(_ line: String, carry: inout Carry) -> LineFacts? {
        if line.contains("\"\"\"") {
            return nil
        }
        var codeEndIndex = line.startIndex
        var index = line.startIndex
        var escaped = false
        var word = ""
        func flushWord() {
            if word == "switch" {
                carry.sawSwitch = true
            }
            word = ""
        }
        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)
            if carry.inBlockComment {
                if char == "*", next < line.endIndex, line[next] == "/" {
                    carry.inBlockComment = false
                    index = line.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if let openQuote = carry.quote {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == openQuote {
                    carry.quote = nil
                }
                codeEndIndex = next
                index = next
                continue
            }
            if char == "/", next < line.endIndex {
                let following = line[next]
                if following == "/" {
                    break
                }
                if following == "*" {
                    carry.inBlockComment = true
                    index = line.index(after: next)
                    continue
                }
            }
            switch char {
            case "\"", "'":
                carry.quote = char
                carry.terminated = false
            case "(":
                carry.stack.append(.paren)
                carry.terminated = false
                carry.closedInitializer = false
            case "[":
                carry.stack.append(.square)
                carry.terminated = false
                carry.closedInitializer = false
            case "{":
                let initializer = isInitializerBrace(last: carry.lastSignificant, before: carry.beforeLast, stack: carry.stack)
                carry.stack.append(.brace(initializer: initializer))
                carry.terminated = false
                carry.closedInitializer = false
            case ")", "]":
                if let top = carry.stack.last {
                    guard matches(open: top, close: char) else {
                        carry.failed = true
                        return nil
                    }
                    carry.stack.removeLast()
                }
                carry.terminated = false
                carry.closedInitializer = false
            case "}":
                if let top = carry.stack.last {
                    guard matches(open: top, close: char) else {
                        carry.failed = true
                        return nil
                    }
                    if case .brace(let initializer) = top {
                        carry.closedInitializer = initializer
                    }
                    carry.stack.removeLast()
                    carry.terminated = carry.stack.isEmpty
                } else {
                    carry.terminated = true
                    carry.closedInitializer = false
                }
            case ";":
                if carry.stack.isEmpty {
                    carry.terminated = true
                }
                carry.closedInitializer = false
            default:
                if !char.isWhitespace, carry.stack.isEmpty {
                    carry.terminated = false
                    carry.closedInitializer = false
                }
            }
            if char.isLetter || char.isNumber || char == "_" || char == "$" {
                word.append(char)
            } else {
                flushWord()
            }
            if !char.isWhitespace {
                carry.beforeLast = carry.lastSignificant
                carry.lastSignificant = char
                codeEndIndex = next
            }
            index = next
        }
        flushWord()
        let code = String(line[line.startIndex..<codeEndIndex])
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOpenBlock = carry.stack.contains { bracket in
            if case .brace(false) = bracket { return true }
            return false
        }
        let endsStatement = hasOpenBlock || (carry.terminated && carry.stack.isEmpty && carry.quote == nil)
        let opensIntoNext = !endsStatement && (
            carry.quote != nil
                || trimmed.hasSuffix("(")
                || trimmed.hasSuffix("[")
                || (trimmed.hasSuffix("{") && !hasOpenBlock)
                || continues(trimmed)
        )
        return LineFacts(code: code,
                         codeEnd: (code as NSString).length,
                         endsStatement: endsStatement,
                         opensIntoNext: opensIntoNext)
    }

    private static func isInitializerBrace(last: Character?, before: Character?, stack: [Bracket]) -> Bool {
        if last == "]" {
            return true
        }
        if last == "=" {
            let previous = before ?? " "
            if previous != "=" && previous != "<" && previous != ">" && previous != "!" {
                return true
            }
        }
        if last == "{" || last == "," {
            if case .brace(let initializer) = stack.last, initializer {
                return true
            }
        }
        return false
    }

    private static func matches(open: Bracket, close: Character) -> Bool {
        switch open {
        case .paren: return close == ")"
        case .square: return close == "]"
        case .brace: return close == "}"
        }
    }

    // MARK: - Classification

    private enum HeaderCondition {
        case absent
        case empty
        case present
    }

    /// The condition of `keyword (` in text whose brackets are already closed.
    private static func headerCondition(in text: String, keyword: String) -> HeaderCondition {
        guard let range = keywordRange(in: text, keyword: keyword) else {
            return .absent
        }
        var index = range.upperBound
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "(" else {
            return .absent
        }
        var depth = 0
        var content = ""
        var cursor = index
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "(" {
                depth += 1
                if depth > 1 { content.append(char) }
            } else if char == ")" {
                depth -= 1
                if depth == 0 { break }
                content.append(char)
            } else if depth >= 1 {
                content.append(char)
            }
            cursor = text.index(after: cursor)
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        return .present
    }

    private static func keywordRange(in text: String, keyword: String) -> Range<String.Index>? {
        var search = text.startIndex
        while search < text.endIndex {
            guard let found = text.range(of: keyword, range: search..<text.endIndex) else {
                return nil
            }
            let beforeOK = found.lowerBound == text.startIndex || !isWord(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex || !isWord(text[found.upperBound])
            if beforeOK && afterOK {
                return found
            }
            search = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    /// The words before the first `(`, `{`, `=` or `;`: modifiers, keywords, types and names.
    private static func leadingWords(of text: String) -> [String] {
        let limit = text.firstIndex { "({=;".contains($0) } ?? text.endIndex
        return text[..<limit]
            .split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "@") }
            .prefix(12)
            .map(String.init)
    }

    private static let annotationOnly = try? NSRegularExpression(pattern: #"^@[\w.$]+\s*(\(.*\))?$"#)
    private static let leadingAnnotation = try? NSRegularExpression(pattern: #"^@(?!interface\b)[\w.$]+\s*(\([^)]*\))?\s*"#)
    private static let methodDeclaration = try? NSRegularExpression(
        pattern: #"^(?:(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>]*>\s+)?[\w.$]+(?:<[^()]*>)?(?:\[\])*\s+[\w$]+\s*\([^;]*\)(?:\s+throws\s+[\w.$,\s]+)?$"#)
    private static let modifiedConstructor = try? NSRegularExpression(
        pattern: #"^(?:(?:public|protected|private)\s+)+[\w$]+\s*\([^;]*\)(?:\s+throws\s+[\w.$,\s]+)?$"#)

    private static func isAnnotationOnly(_ head: String) -> Bool {
        matches(annotationOnly, in: head) && !head.hasPrefix("@interface")
    }

    private static func stripLeadingAnnotations(_ head: String) -> String {
        var result = head
        while let regex = leadingAnnotation,
              let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: (result as NSString).length)),
              match.range.length > 0 {
            result = (result as NSString).substring(from: match.range.upperBound)
        }
        return result
    }

    private static func isMethodOrConstructor(_ head: String) -> Bool {
        let stripped = stripLeadingAnnotations(head)
        let first = leadingWords(of: stripped).first ?? ""
        guard !notADeclaration.contains(first) else {
            return false
        }
        return matches(methodDeclaration, in: stripped) || matches(modifiedConstructor, in: stripped)
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else {
            return false
        }
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return regex.firstMatch(in: flattened, range: NSRange(location: 0, length: (flattened as NSString).length)) != nil
    }
}

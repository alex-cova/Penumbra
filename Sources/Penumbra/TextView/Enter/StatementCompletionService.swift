import Foundation

/// Pure decision logic for "Complete Current Statement" (⇧⌘↵): what to append to a line of
/// C-style code (Java and friends) so it becomes a finished statement.
///
/// In order, it closes an unterminated string, closes unclosed `(` and `[`, then ends the line
/// with `;` for a statement or ` {}` for a construct that takes a body (`if`, `for`, `while`,
/// `switch`, `try`, `catch`, `synchronized`, `else`, class-like declarations, methods and
/// constructors). A line that is already finished, or that clearly continues (trailing operator
/// or comma, annotation, comment, an opening `{`), gets nothing appended.
///
/// The check is textual and looks at the one line, so it never depends on document size and
/// works on code that doesn't parse yet. It skips string and character literals and `//` and
/// `/* */` comments; text blocks (`"""`) are left alone.
enum StatementCompletionService {
    struct Completion: Equatable {
        /// UTF-16 offset in the line where `appended` goes: the end of the code, before any
        /// trailing `//` comment or whitespace.
        var insertionOffset: Int
        var appended: String
        /// Where the caret goes within `appended`, or nil to put it at the end of the line.
        /// Set for a body (`{|}`), so a line break then splits the braces.
        var caretOffsetInAppended: Int?
    }

    /// Words that start a header taking a parenthesized condition and then a body.
    private static let parenthesizedHeaders: Set<String> = [
        "if", "for", "while", "switch", "catch", "synchronized"
    ]
    /// Headers that take a body with no condition (`try` may have a resource list).
    private static let bareHeaders: Set<String> = ["else", "do", "try", "finally"]
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

    static func complete(line: String, extraControlKeywords: Set<String> = []) -> Completion? {
        guard let scan = scan(line) else {
            return nil
        }
        let head = scan.code.trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else {
            return nil
        }
        let quote = scan.unterminatedQuote.map(String.init) ?? ""
        let prefix = quote + scan.closers
        func completion(_ appended: String, caret: Int? = nil) -> Completion {
            Completion(insertionOffset: scan.codeEnd, appended: appended, caretOffsetInAppended: caret)
        }
        func body() -> Completion {
            let appended = prefix + " {}"
            return completion(appended, caret: (appended as NSString).length - 1)
        }

        // Not code, or a line that opens a block: nothing to add.
        if head.hasPrefix("*") || head.hasPrefix("/*") || scan.hasOpenBrace {
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
        let statement = afterBrace ? String(closed.dropFirst()).trimmingCharacters(in: .whitespaces) : closed
        let words = leadingWords(of: stripLeadingAnnotations(statement))
        let header = words.first { !modifiers.contains($0) } ?? words.first ?? ""
        let parenthesized = parenthesizedHeaders.union(extraControlKeywords)

        if afterBrace, header == "while" {
            // `} while (x)` closes a do loop.
            return completion(prefix + ";")
        }
        if parenthesized.contains(header) {
            return closed.hasSuffix(")") ? body() : completion(prefix)
        }
        if bareHeaders.contains(header) {
            return body()
        }
        if closed.hasSuffix("}") {
            // A closed block is finished, but `int[] a = {1, 2}` and `Runnable r = () -> {}` are
            // assignments that still need their `;`.
            return completion(prefix + (afterBrace ? "" : (assignsValue(closed) ? ";" : "")))
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

    private static func continues(_ head: String) -> Bool {
        if head.hasSuffix("++") || head.hasSuffix("--") {
            return false
        }
        return continuationSuffixes.contains { head.hasSuffix($0) }
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

    private struct Scan {
        /// The code before any trailing comment, trailing whitespace excluded.
        var code: String
        /// UTF-16 length of `code`.
        var codeEnd: Int
        /// Closing brackets for the unclosed `(` and `[`, innermost first.
        var closers: String
        var unterminatedQuote: Character?
        var hasOpenBrace: Bool
    }

    /// Walks the line once. Returns nil when the line can't be completed sensibly: an unclosed
    /// block comment, a text block, or mismatched brackets.
    private static func scan(_ line: String) -> Scan? {
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        var codeEndIndex = line.startIndex
        var index = line.startIndex
        let characters = line
        if characters.contains("\"\"\"") {
            return nil
        }
        while index < characters.endIndex {
            let char = characters[index]
            let next = characters.index(after: index)
            if let openQuote = quote {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == openQuote {
                    quote = nil
                }
                codeEndIndex = next
                index = next
                continue
            }
            if char == "/", next < characters.endIndex {
                let following = characters[next]
                if following == "/" {
                    break
                }
                if following == "*" {
                    // A block comment inside the line: skip it; unclosed means we can't tell.
                    let searchStart = characters.index(after: next)
                    guard let close = characters.range(of: "*/", range: searchStart..<characters.endIndex) else {
                        return nil
                    }
                    index = close.upperBound
                    continue
                }
            }
            switch char {
            case "\"", "'":
                quote = char
            case "(", "[", "{":
                stack.append(char)
            case ")", "]", "}":
                if let top = stack.last {
                    guard matches(open: top, close: char) else {
                        return nil
                    }
                    stack.removeLast()
                }
            default:
                break
            }
            if !char.isWhitespace {
                codeEndIndex = next
            }
            index = next
        }
        let code = String(characters[characters.startIndex..<codeEndIndex])
        let hasOpenBrace = stack.contains("{")
        var closers = ""
        if !hasOpenBrace {
            for open in stack.reversed() {
                closers.append(open == "(" ? ")" : "]")
            }
        }
        return Scan(code: code,
                    codeEnd: (code as NSString).length,
                    closers: closers,
                    unterminatedQuote: quote,
                    hasOpenBrace: hasOpenBrace)
    }

    private static func matches(open: Character, close: Character) -> Bool {
        (open == "(" && close == ")") || (open == "[" && close == "]") || (open == "{" && close == "}")
    }

    // MARK: - Classification

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
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

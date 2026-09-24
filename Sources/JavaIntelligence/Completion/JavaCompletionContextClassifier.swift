import Foundation

/// Where in a Java file the caret is, as far as completion cares -- decides which candidates make
/// sense (members after `.`, only annotation types after `@`, only packages/classes in an
/// `import`, enum constants after `case`, ...).
public enum JavaCompletionSite: Equatable, Sendable {
    /// `receiver.<prefix>`; the offset is the `.`'s byte offset.
    case memberAccess(dotOffset: Int)
    /// `receiver::<prefix>`; the offset is the first `:`'s byte offset.
    case methodReference(colonOffset: Int)
    /// `import [static] a.b.<prefix>` (`qualifier` is `a.b`, empty for the first segment).
    case importPath(qualifier: String, isStatic: Bool)
    /// `package a.b.<prefix>`.
    case packagePath(qualifier: String)
    /// `@<prefix>`.
    case annotation
    /// `@Foo(<prefix>` / `@Foo(a = 1, <prefix>`; `annotationName` as written.
    case annotationAttribute(annotationName: String)
    /// `new <prefix>`.
    case newExpression
    /// Only a type makes sense: after `extends`, `implements`, `throws`, `instanceof`, `catch (`.
    case typeOnly(keyword: String)
    /// `case <prefix>` inside a `switch`; `selectorText` is the switch's parenthesized selector.
    case caseLabel(selectorText: String)
    /// Directly inside a class/interface/enum/record body, where members are declared.
    case classBody
    /// Outside any type declaration.
    case topLevel
    /// Inside a method body, initializer, or field initializer.
    case statement
    /// `(String|` or a parenthesized expression, where a cast to the expected type can be inserted.
    case cast
    /// Inside a string literal or comment: no Java completion.
    case stringOrComment
}

/// Classifies the completion position from the live tree plus a short textual look-back (the tree
/// is unreliable right after a trigger character, see ``JavaReceiverScanner``).
public enum JavaCompletionContextClassifier {
    /// Words that can precede `(` without it being a method call.
    /// `keyword (` opens an expression that may be a cast or a parenthesized value.
    private static let nonCallKeywords: Set<String> = [
        "return", "throw", "assert", "new", "else", "do", "yield"
    ]
    /// `keyword (` opens a condition or header, not a cast: statement completion applies.
    private static let controlKeywords: Set<String> = ["if", "for", "while", "switch", "synchronized", "try"]

    public static func classify(bytes: [UInt8], tree: JavaSyntaxTree, prefixStart: Int) -> JavaCompletionSite {
        if isInsideStringOrComment(tree: tree, bytes: bytes, offset: prefixStart) {
            return .stringOrComment
        }
        let before = skipWhitespace(backwardFrom: prefixStart, in: bytes)
        let previousByte: UInt8? = before > 0 ? bytes[before - 1] : nil

        // `import`/`package` statements: `import java.util.Li|`.
        if let path = importOrPackagePath(bytes: bytes, prefixStart: prefixStart) {
            return path
        }
        if previousByte == UInt8(ascii: ".") && before == prefixStart {
            return .memberAccess(dotOffset: prefixStart - 1)
        }
        if previousByte == UInt8(ascii: ":"), before >= 2, bytes[before - 2] == UInt8(ascii: ":") {
            return .methodReference(colonOffset: before - 2)
        }
        if previousByte == UInt8(ascii: "@") && before == prefixStart {
            return .annotation
        }
        if let annotationName = enclosingAnnotationArgumentList(bytes: bytes, before: before) {
            return .annotationAttribute(annotationName: annotationName)
        }

        let previousWord = word(endingAt: before, in: bytes)
        switch previousWord {
        case "new":
            return .newExpression
        case "extends", "implements", "throws", "instanceof":
            return .typeOnly(keyword: previousWord!)
        case "case":
            if let selector = switchSelector(tree: tree, bytes: bytes, offset: prefixStart) {
                return .caseLabel(selectorText: selector)
            }
        default:
            break
        }
        if previousByte == UInt8(ascii: "(") {
            let wordBefore = word(endingAt: skipWhitespace(backwardFrom: before - 1, in: bytes), in: bytes)
            if wordBefore == "catch" {
                return .typeOnly(keyword: "catch")
            }
            if let wordBefore, controlKeywords.contains(wordBefore) {
                return structuralSite(tree: tree, bytes: bytes, offset: prefixStart)
            }
            if wordBefore == nil || nonCallKeywords.contains(wordBefore!) {
                return .cast
            }
        }
        if previousByte == UInt8(ascii: "|"), isInsideCatchParameter(bytes: bytes, before: before) {
            return .typeOnly(keyword: "catch")
        }

        return structuralSite(tree: tree, bytes: bytes, offset: prefixStart)
    }

    // MARK: - Structure

    /// Walks up from the caret: the first enclosing body decides between member-declaration and
    /// statement positions. `offset` points into the identifier being completed (the provider
    /// parses with a dummy identifier at the caret, so there always is one).
    private static func structuralSite(tree: JavaSyntaxTree, bytes: [UInt8], offset: Int) -> JavaCompletionSite {
        // Outside every `{…}` is file level, whatever tree-sitter made of the dummy identifier
        // there (it parses as an expression statement).
        if braceDepth(bytes: bytes, before: offset) == 0 {
            return .topLevel
        }
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        var sawTypeDeclaration = false
        while let node = current {
            switch node.type {
            case "block", "constructor_body", "lambda_expression", "switch_block", "variable_declarator",
                 "argument_list", "static_initializer", "expression_statement", "return_statement",
                 "if_statement", "for_statement", "enhanced_for_statement", "while_statement":
                return .statement
            case "class_body", "interface_body", "enum_body", "enum_body_declarations", "annotation_type_body":
                // The node right before the caret might be a finished member; the caret after it
                // is still at member level.
                return .classBody
            case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
                sawTypeDeclaration = true
            case "program":
                return sawTypeDeclaration ? .classBody : .topLevel
            default:
                break
            }
            current = node.parent
        }
        return .statement
    }

    /// Unclosed `{` before `offset`, skipping string, character and text-block literals and
    /// comments.
    static func braceDepth(bytes: [UInt8], before offset: Int) -> Int {
        var depth = 0
        var index = 0
        let end = min(offset, bytes.count)
        while index < end {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            case UInt8(ascii: "/") where index + 1 < end && bytes[index + 1] == UInt8(ascii: "/"):
                while index < end, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            case UInt8(ascii: "/") where index + 1 < end && bytes[index + 1] == UInt8(ascii: "*"):
                index += 2
                while index + 1 < end, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                index += 1
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                let isTextBlock = byte == UInt8(ascii: "\"") && index + 2 < end && bytes[index + 1] == byte && bytes[index + 2] == byte
                if isTextBlock {
                    index += 3
                    while index + 2 < end, !(bytes[index] == byte && bytes[index + 1] == byte && bytes[index + 2] == byte) { index += 1 }
                    index += 2
                } else {
                    index += 1
                    while index < end, bytes[index] != byte, bytes[index] != UInt8(ascii: "\n") {
                        if bytes[index] == UInt8(ascii: "\\") { index += 1 }
                        index += 1
                    }
                }
            default:
                break
            }
            index += 1
        }
        return depth
    }

    private static func isInsideStringOrComment(tree: JavaSyntaxTree, bytes: [UInt8], offset: Int) -> Bool {
        guard offset > 0 else { return false }
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            switch node.type {
            case "line_comment", "block_comment", "comment":
                return offset > node.startByte && (node.type != "line_comment" || offset <= node.endByte)
            case "string_literal", "character_literal", "text_block", "string_fragment":
                return offset > node.startByte && offset < node.endByte
            case "block", "class_body", "program":
                return false
            default:
                current = node.parent
            }
        }
        return false
    }

    private static func switchSelector(tree: JavaSyntaxTree, bytes: [UInt8], offset: Int) -> String? {
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            if node.type == "switch_expression" || node.type == "switch_statement",
               let condition = node.child(byFieldName: "condition") {
                var text = condition.text
                if text.hasPrefix("("), text.hasSuffix(")") {
                    text = String(text.dropFirst().dropLast())
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
            current = node.parent
        }
        return nil
    }

    // MARK: - Textual look-back

    private static func importOrPackagePath(bytes: [UInt8], prefixStart: Int) -> JavaCompletionSite? {
        // Collect `a.b.` (identifiers and dots, whitespace between keyword and path) backwards.
        var cursor = prefixStart
        while cursor > 0, isIdentifierByte(bytes[cursor - 1]) || bytes[cursor - 1] == UInt8(ascii: ".") {
            cursor -= 1
        }
        let path = String(decoding: bytes[cursor..<prefixStart], as: UTF8.self)
        guard path.isEmpty || path.hasSuffix(".") || !path.contains(".") else { return nil }
        let keywordEnd = skipWhitespace(backwardFrom: cursor, in: bytes)
        guard keywordEnd < cursor || path.isEmpty else { return nil }
        let keyword = word(endingAt: keywordEnd, in: bytes)
        let qualifier = path.hasSuffix(".") ? String(path.dropLast()) : ""
        switch keyword {
        case "import":
            guard isStatementStart(bytes: bytes, before: keywordEnd - "import".utf8.count) else { return nil }
            return .importPath(qualifier: qualifier, isStatic: false)
        case "static":
            let staticStart = keywordEnd - "static".utf8.count
            let importEnd = skipWhitespace(backwardFrom: staticStart, in: bytes)
            guard word(endingAt: importEnd, in: bytes) == "import",
                  isStatementStart(bytes: bytes, before: importEnd - "import".utf8.count) else { return nil }
            return .importPath(qualifier: qualifier, isStatic: true)
        case "package":
            guard isStatementStart(bytes: bytes, before: keywordEnd - "package".utf8.count) else { return nil }
            return .packagePath(qualifier: qualifier)
        default:
            return nil
        }
    }

    /// Whether only whitespace/comments separate `offset` from the previous statement (`;`, `}`,
    /// `{`) or the start of the file.
    private static func isStatementStart(bytes: [UInt8], before offset: Int) -> Bool {
        let end = JavaReceiverScanner.skipTrivia(bytes, before: offset) ?? skipWhitespace(backwardFrom: offset, in: bytes)
        guard end > 0 else { return true }
        let byte = bytes[end - 1]
        return byte == UInt8(ascii: ";") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "/")
    }

    /// `@Name(` ... caret with no closing `)` in between -> `Name`.
    private static func enclosingAnnotationArgumentList(bytes: [UInt8], before: Int) -> String? {
        var depth = 0
        var cursor = before
        var scanned = 0
        while cursor > 0, scanned < 400 {
            cursor -= 1
            scanned += 1
            let byte = bytes[cursor]
            if byte == UInt8(ascii: ")") {
                depth += 1
            } else if byte == UInt8(ascii: "(") {
                if depth == 0 {
                    let nameEnd = skipWhitespace(backwardFrom: cursor, in: bytes)
                    var nameStart = nameEnd
                    while nameStart > 0, isIdentifierByte(bytes[nameStart - 1]) || bytes[nameStart - 1] == UInt8(ascii: ".") {
                        nameStart -= 1
                    }
                    guard nameStart > 0, nameStart < nameEnd, bytes[nameStart - 1] == UInt8(ascii: "@") else { return nil }
                    // Only attribute-name positions: right after `(` or `,`.
                    let last = before > 0 ? bytes[before - 1] : 0
                    guard last == UInt8(ascii: "(") || last == UInt8(ascii: ",") else { return nil }
                    return String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                }
                depth -= 1
            } else if byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
                return nil
            }
        }
        return nil
    }

    private static func isInsideCatchParameter(bytes: [UInt8], before: Int) -> Bool {
        var cursor = before
        while cursor > 0 {
            cursor -= 1
            let byte = bytes[cursor]
            if byte == UInt8(ascii: "(") {
                return word(endingAt: skipWhitespace(backwardFrom: cursor, in: bytes), in: bytes) == "catch"
            }
            if byte == UInt8(ascii: ")") || byte == UInt8(ascii: ";") || byte == UInt8(ascii: "{") {
                return false
            }
        }
        return false
    }

    /// The identifier/keyword that ends exactly at `end`, if any.
    static func word(endingAt end: Int, in bytes: [UInt8]) -> String? {
        var start = end
        while start > 0, isIdentifierByte(bytes[start - 1]) {
            start -= 1
        }
        guard start < end else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    static func skipWhitespace(backwardFrom offset: Int, in bytes: [UInt8]) -> Int {
        var cursor = min(offset, bytes.count)
        while cursor > 0, isWhitespace(bytes[cursor - 1]) {
            cursor -= 1
        }
        return cursor
    }

    static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte == 36 || byte >= 0x80
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}

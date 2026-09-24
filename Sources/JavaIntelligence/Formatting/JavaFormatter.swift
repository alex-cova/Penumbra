import Foundation

/// How ``JavaFormatter`` lays code out.
public struct JavaFormattingOptions: Sendable, Equatable {
    /// One level of indentation: four spaces, a tab, ….
    public var indentUnit: String
    /// How many levels a wrapped line is indented past the statement it continues.
    public var continuationLevels: Int
    /// The most blank lines kept in a row; longer runs are cut to this. `nil` keeps every line
    /// break as written, which range formatting needs so line numbers stay put.
    public var maxBlankLines: Int?

    public init(indentUnit: String = "    ", continuationLevels: Int = 2, maxBlankLines: Int? = 2) {
        self.indentUnit = indentUnit
        self.continuationLevels = continuationLevels
        self.maxBlankLines = maxBlankLines
    }
}

/// A built-in Java formatter that only ever changes whitespace: indentation, the spaces between
/// tokens, trailing spaces, and runs of blank lines. It never joins or splits lines, moves a
/// brace, or reorders anything, so the author's line breaks survive.
///
/// The layout is the usual Java one (four-space blocks, `case` labels indented in a `switch`,
/// continuation lines indented two levels, `K&R`-neutral braces, spaces around binary operators
/// and after commas and control keywords). Comments and string literals are never edited; only the
/// `*` lines of a block comment are re-aligned.
///
/// It refuses a file that does not parse cleanly (`nil`), and as a safety net refuses its own
/// result if the non-whitespace characters changed. Formatting formatted code changes nothing.
public enum JavaFormatter {
    public static func format(_ source: String, options: JavaFormattingOptions = JavaFormattingOptions()) -> String? {
        guard let tree = JavaSyntaxParser().parse(source), !tree.rootNode.hasError else { return nil }
        guard let formatted = Layout(source: source, tree: tree, options: options)?.run() else { return nil }
        guard formatted.filter({ !$0.isWhitespace }) == source.filter({ !$0.isWhitespace }) else { return nil }
        return formatted
    }
}

// MARK: - Tokens

private struct Token {
    let node: SyntaxNode
    let type: String
    let text: String
    let start: Int
    let end: Int
    let startLine: Int
    let endLine: Int

    var parentType: String { node.parent?.type ?? "" }
    var isComment: Bool { type == "line_comment" || type == "block_comment" }
    var isWordLike: Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return first == "_" || first == "$" || first == "\"" || first == "'" || CharacterSet.alphanumerics.contains(first)
    }
    /// A keyword or other reserved word: a leaf whose type is its own text.
    var isKeyword: Bool {
        type == text && (text.first?.isLetter ?? false)
    }
    var isFirstChildOfParent: Bool {
        guard let first = node.parent?.child(at: 0) else { return false }
        return first.byteRange == node.byteRange
    }
}

// MARK: - Layout

private final class Layout {
    let source: String
    let bytes: [UInt8]
    let options: JavaFormattingOptions
    let tokens: [Token]
    let lineStarts: [Int]
    let lineEnding: String
    /// The indentation given to each original line whose first token this run has placed.
    var lineIndent: [Int: String] = [:]

    private static let atomicTypes: Set<String> = [
        "string_literal", "character_literal", "text_block", "block_comment", "line_comment"
    ]

    /// Nodes whose `{ … }` holds an indented body. The body sits one level in from ``baseLine``.
    private static let braceContainers: Set<String> = [
        "block", "class_body", "interface_body", "enum_body", "annotation_type_body", "switch_block",
        "array_initializer", "element_value_array_initializer", "constructor_body", "switch_block_statement_group"
    ]

    private static let declarations: Set<String> = [
        "method_declaration", "constructor_declaration", "class_declaration", "interface_declaration",
        "enum_declaration", "record_declaration", "annotation_type_declaration", "field_declaration",
        "annotation_type_element_declaration", "compact_constructor_declaration", "local_variable_declaration"
    ]

    init?(source: String, tree: JavaSyntaxTree, options: JavaFormattingOptions) {
        self.source = source
        self.bytes = tree.sourceBytes
        self.options = options
        self.lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        var starts = [0]
        for (index, byte) in tree.sourceBytes.enumerated() where byte == 10 { starts.append(index + 1) }
        self.lineStarts = starts

        var collected: [Token] = []
        var stack = [tree.rootNode]
        // Depth-first in source order: children are pushed reversed so the first pops first.
        while let node = stack.popLast() {
            let atomic = Self.atomicTypes.contains(node.type)
            if atomic || node.childCount == 0 {
                guard node.endByte > node.startByte else { continue }
                collected.append(Token(
                    node: node, type: node.type, text: node.text, start: node.startByte, end: node.endByte,
                    startLine: 0, endLine: 0
                ))
            } else {
                stack.append(contentsOf: node.children.reversed())
            }
        }
        var located: [Token] = []
        for token in collected {
            located.append(Token(
                node: token.node, type: token.type, text: token.text, start: token.start, end: token.end,
                startLine: Self.line(of: token.start, in: starts), endLine: Self.line(of: max(token.start, token.end - 1), in: starts)
            ))
        }
        self.tokens = located
    }

    static func line(of offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Emit

    func run() -> String? {
        guard !tokens.isEmpty else { return source }
        var out = ""
        var previous: Token?
        for token in tokens {
            let gapBytes = bytes[(previous?.end ?? 0)..<token.start]
            let gap = String(decoding: gapBytes, as: UTF8.self)
            // Only whitespace may sit between tokens; anything else means a token was missed.
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
            let newlines = gap.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            var indent: String?
            if previous == nil {
                indent = indentation(for: token, previous: nil)
            } else if newlines > 0 {
                let kept = options.maxBlankLines.map { min(newlines, $0 + 1) } ?? newlines
                out += String(repeating: lineEnding, count: kept)
                indent = indentation(for: token, previous: previous)
            } else if let previous {
                out += spacing(previous, token, original: gap)
            }
            if let indent {
                out += indent
                lineIndent[token.startLine] = indent
            }
            out += emittedText(of: token, startsLine: indent != nil, indent: indent ?? "")
            previous = token
        }
        // Whatever followed the last token: line breaks are kept (at most one blank line's worth
        // when collapsing), spaces are dropped.
        let tail = String(decoding: bytes[(tokens.last?.end ?? 0)...], as: UTF8.self)
        let tailBreaks = tail.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        out += String(repeating: lineEnding, count: options.maxBlankLines.map { _ in min(tailBreaks, 1) } ?? tailBreaks)
        return out
    }

    /// A token's text, re-aligning the `*` lines of a block comment that starts its line.
    private func emittedText(of token: Token, startsLine: Bool, indent: String) -> String {
        guard token.type == "block_comment", startsLine, token.text.contains("\n") else { return token.text }
        var lines = token.text.components(separatedBy: "\n")
        for index in lines.indices.dropFirst() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") { lines[index] = indent + " " + trimmed }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Indentation

    private func unit(_ count: Int) -> String {
        String(repeating: options.indentUnit, count: max(0, count))
    }

    /// The indentation of an original line: what this run gave it, else what it already has.
    private func indent(ofLine line: Int) -> String {
        if let known = lineIndent[line] { return known }
        guard line >= 0, line < lineStarts.count else { return "" }
        var end = lineStarts[line]
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return String(decoding: bytes[lineStarts[line]..<end], as: UTF8.self)
    }

    private func line(of node: SyntaxNode) -> Int {
        Self.line(of: node.startByte, in: lineStarts)
    }

    /// The line a container's body is measured from. A `{` inside an expression (a lambda, an
    /// anonymous class, an array initializer) is measured from its own line; anywhere else, from
    /// the line the statement or declaration starts on, so a wrapped `if (` header does not push
    /// its body in.
    private func baseLine(of container: SyntaxNode) -> Int {
        let expressionLike: Set<String> = ["lambda_expression", "object_creation_expression", "enum_constant"]
        let parentType = container.parent?.type ?? ""
        if container.type == "array_initializer" || container.type == "element_value_array_initializer"
            || expressionLike.contains(parentType) {
            return line(of: container)
        }
        return container.parent.map(line(of:)) ?? line(of: container)
    }

    private func indentation(for token: Token, previous: Token?) -> String {
        // The first line of a file starts at the left edge unless it is somehow nested.
        let parent = token.node.parent

        // A closing brace, or an opening one on its own line, sits with the construct it belongs to.
        if (token.text == "}" || token.text == "{"), let container = parent, Self.braceContainers.contains(container.type) {
            if container.type == "switch_block_statement_group" { return indent(ofLine: line(of: container)) }
            return indent(ofLine: baseLine(of: container))
        }
        // `else`, `catch`, `finally` and the `while` of a do-while line up with their statement.
        if ["else", "catch", "finally"].contains(token.text) || (token.text == "while" && parent?.type == "do_statement"),
           var statement = parent {
            // `catch` and `finally` are the first token of their own clause; the statement is the `try`.
            if statement.type == "catch_clause" || statement.type == "finally_clause", let tryStatement = statement.parent {
                statement = tryStatement
            }
            return indent(ofLine: line(of: statement))
        }
        if token.text == ")" , let statement = parent, token.startLine != line(of: statement) {
            return indent(ofLine: line(of: statement))
        }

        // Find the innermost brace container the token is inside, and the item of it that holds
        // the token.
        var item = token.node
        var current = token.node.parent
        while let container = current {
            // The file itself: a declaration starts at the left edge, a wrapped one continues.
            if container.type == "program" {
                let itemLine = line(of: item)
                if itemLine == token.startLine || afterLeadingAnnotations(token, in: item, previous: previous) { return "" }
                return indent(ofLine: itemLine) + unit(options.continuationLevels)
            }
            // The statement after a label lines up with the label.
            if container.type == "labeled_statement", item.type != "identifier", line(of: item) == token.startLine {
                return indent(ofLine: line(of: container))
            }
            // A statement with no braces as the body of an `if`, `for`, `while`, `do` or `else`
            // is one level in from that statement; wrapped, it continues from its own start.
            if Self.bracelessBodyParents.contains(container.type), item.type != "block",
               isBody(item, of: container) {
                let itemLine = line(of: item)
                if itemLine == token.startLine { return indent(ofLine: line(of: container)) + unit(1) }
                return indent(ofLine: itemLine) + unit(options.continuationLevels)
            }
            if Self.braceContainers.contains(container.type) {
                // A `case` label heads its group; it belongs to the `switch` body around it.
                if container.type == "switch_block_statement_group", container.startByte == item.startByte {
                    item = container
                    current = container.parent
                    continue
                }
                // `;`-separated enum members are one node; the member is what counts.
                var member = item
                if member.type == "enum_body_declarations", let inner = child(of: member, containing: token.start) {
                    member = inner
                }
                let memberLine = line(of: member)
                if memberLine == token.startLine || afterLeadingAnnotations(token, in: member, previous: previous) {
                    let base = container.type == "switch_block_statement_group"
                        ? indent(ofLine: line(of: container))
                        : indent(ofLine: baseLine(of: container))
                    return base + unit(1)
                }
                return indent(ofLine: memberLine) + unit(options.continuationLevels)
            }
            item = container
            current = container.parent
        }
        return ""
    }

    private static let bracelessBodyParents: Set<String> = [
        "if_statement", "for_statement", "enhanced_for_statement", "while_statement", "do_statement"
    ]

    /// Whether `item` is the statement a control statement runs (its `consequence`, `alternative`
    /// or `body`), as opposed to its condition or loop header.
    private func isBody(_ item: SyntaxNode, of statement: SyntaxNode) -> Bool {
        return ["consequence", "alternative", "body"].contains { name in
            statement.child(byFieldName: name)?.byteRange == item.byteRange
        }
    }

    private func child(of node: SyntaxNode, containing offset: Int) -> SyntaxNode? {
        node.children.first { $0.startByte <= offset && offset < $0.endByte }
    }

    /// True for the first token of a declaration whose annotations sit on the lines above:
    /// `@Override` on one line, `public void m()` on the next, both at the declaration's indent.
    private func afterLeadingAnnotations(_ token: Token, in member: SyntaxNode, previous: Token?) -> Bool {
        guard Self.declarations.contains(member.type), let previous, previous.endLine < token.startLine else { return false }
        // The token before is the end of an annotation of this declaration, however long its arguments.
        var node = previous.node.parent
        while let current = node, current.startByte >= member.startByte, current.endByte <= member.endByte {
            if current.type == "annotation" || current.type == "marker_annotation" { return current.parent?.type == "modifiers" }
            if current.type == member.type { break }
            node = current.parent
        }
        return false
    }

    // MARK: Spacing

    private static let binaryRoles: Set<String> = [
        "binary_expression", "assignment_expression", "variable_declarator", "element_value_pair", "ternary_expression",
        "lambda_expression", "switch_rule", "enhanced_for_statement", "assert_statement", "type_bound"
    ]
    private static let operatorTexts: Set<String> = [
        "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "&", "|", "^", "<<", ">>", ">>>",
        "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=", "->", "?", ":"
    ]
    /// Keywords that take a space before a parenthesis: `if (`, `return (`.
    private static let spacedBeforeParenthesis: Set<String> = [
        "if", "for", "while", "switch", "catch", "synchronized", "try", "return", "throw", "else", "do",
        "assert", "case", "yield", "instanceof", "new"
    ]
    private static let callParents: Set<String> = [
        "argument_list", "formal_parameters", "annotation_argument_list", "record_pattern"
    ]

    private func isBinaryOperator(_ token: Token) -> Bool {
        Self.operatorTexts.contains(token.text) && Self.binaryRoles.contains(token.parentType)
            && !(token.text == ":" && token.parentType == "switch_rule")
    }

    private func isTypeAngle(_ token: Token) -> Bool {
        (token.text == "<" || token.text == ">") && (token.parentType == "type_arguments" || token.parentType == "type_parameters")
    }

    private func spacing(_ p: Token, _ n: Token, original: String) -> String {
        let space = " ", none = ""
        // Comments keep whatever spacing they had, so aligned trailing comments stay aligned.
        if p.isComment || n.isComment { return original }
        let pt = p.text, nt = n.text

        if nt == "," || nt == ";" { return none }
        if pt == "," { return space }
        if pt == ";" { return nt == ")" ? none : space }
        if pt == "(" || pt == "[" { return none }
        if nt == ")" || nt == "]" { return none }
        if pt == "." || nt == "." || pt == "::" || nt == "::" { return none }
        if nt == "..." { return none }
        if pt == "..." { return space }
        if pt == "@" { return none }

        // Braces: `{}` and array initializers are tight; blocks and bodies get a space inside.
        if pt == "{" && nt == "}" { return none }
        if pt == "{" { return isArrayBrace(p) ? none : space }
        if nt == "}" { return isArrayBrace(n) ? none : space }
        if nt == "{" { return space }

        // Generics.
        if nt == "<" && isTypeAngle(n) { return p.isKeyword ? space : none }
        if pt == "<" && isTypeAngle(p) { return none }
        if nt == ">" && isTypeAngle(n) { return none }
        if pt == ">" && isTypeAngle(p) {
            // `Collections.<String>emptyList()`: the type arguments belong to the call.
            if p.node.parent?.parent?.type == "method_invocation" { return none }
            if nt == "(" || nt == "[" || nt == ">" { return none }
            if n.isWordLike { return space }
        }

        if pt == ")" && p.parentType == "cast_expression" { return space }
        if isBinaryOperator(p) || isBinaryOperator(n) { return space }
        if (["!", "~", "+", "-", "++", "--"].contains(pt)) && (p.parentType == "unary_expression" || p.parentType == "update_expression") && p.isFirstChildOfParent {
            return none
        }
        if (nt == "++" || nt == "--") && n.parentType == "update_expression" && !n.isFirstChildOfParent { return none }

        // Labels and switch cases.
        if nt == ":" && (n.parentType == "switch_block_statement_group" || n.parentType == "labeled_statement") { return none }
        if pt == ":" && (p.parentType == "switch_block_statement_group" || p.parentType == "labeled_statement") { return space }

        if nt == "(" {
            if p.isKeyword && Self.spacedBeforeParenthesis.contains(pt) { return space }
            if Self.callParents.contains(n.parentType) || pt == "this" || pt == "super" { return none }
        }
        if nt == "[" { return none }
        if p.isKeyword { return space }
        if (pt == ")" || pt == "}" || pt == "]") && n.isWordLike { return space }
        if p.isWordLike && n.isWordLike { return space }
        return original.isEmpty ? none : space
    }

    private func isArrayBrace(_ token: Token) -> Bool {
        token.parentType == "array_initializer" || token.parentType == "element_value_array_initializer"
    }
}

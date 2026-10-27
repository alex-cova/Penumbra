import Foundation
import LanguageSyntax

/// How ``SwiftFormatter`` lays code out.
public struct SwiftFormattingOptions: Sendable, Equatable {
    /// One level of indentation: four spaces, a tab, ….
    public var indentUnit: String
    /// The most blank lines kept in a row; longer runs are cut to this. `nil` keeps every line
    /// break as written, which range formatting needs so line numbers stay put.
    public var maxBlankLines: Int?

    public init(indentUnit: String = "    ", maxBlankLines: Int? = 2) {
        self.indentUnit = indentUnit
        self.maxBlankLines = maxBlankLines
    }
}

/// A built-in Swift formatter that only ever changes whitespace: the indentation of each line,
/// trailing spaces, and runs of blank lines. It never joins or splits lines, never touches the
/// spaces inside a line, and never edits a string literal, a comment, or a regex — so the
/// author's line breaks and token spacing survive.
///
/// Indentation is one level per nesting `{[(` depth, with `case` labels one level into their
/// `switch`, `switch` bodies two, leading-dot chains one past their receiver statement, and
/// `else`/`catch`/trailing-`while` aligned with the statement they close. Closers dedent.
///
/// It refuses a file that does not parse cleanly (`nil`), and as a safety net refuses its own
/// result when the non-whitespace characters changed. Formatting formatted code changes nothing.
public enum SwiftFormatter {
    /// Why ``format(_:options:)`` left a file alone. Byte offsets are into the UTF-8 of the source.
    public enum Refusal: Error, Sendable, Equatable {
        /// The parser produced no tree.
        case noTree
        /// The file has a syntax problem; `firstByte` is where the first one starts.
        case syntaxProblem(firstByte: Int?)
        /// The tree holds an error or missing node the layout cannot place.
        case unplaceableNode
        /// Something other than whitespace sits between two tokens, so a token was missed.
        case nonWhitespaceGap(byte: Int)
        /// The result would change something other than whitespace.
        case contentChanged
    }

    public static func format(_ source: String, options: SwiftFormattingOptions = SwiftFormattingOptions()) -> String? {
        try? attempt(source, options: options).get()
    }

    /// The reason ``format(_:options:)`` returns `nil` for `source`, or `nil` when it formats.
    public static func diagnose(_ source: String, options: SwiftFormattingOptions = SwiftFormattingOptions()) -> Refusal? {
        if case .failure(let refusal) = attempt(source, options: options) { return refusal }
        return nil
    }

    private static func attempt(_ source: String, options: SwiftFormattingOptions) -> Result<String, Refusal> {
        guard let parsed = SwiftAnalysis.parse(source) else { return .failure(.noTree) }
        guard parsed.model.errors.isEmpty, !parsed.tree.rootNode.hasError else {
            return .failure(.syntaxProblem(firstByte: parsed.model.errors.first?.bytes.lowerBound))
        }
        guard let layout = Layout(source: source, tree: parsed.tree, options: options) else {
            return .failure(.unplaceableNode)
        }
        guard let formatted = layout.run() else {
            return .failure(.nonWhitespaceGap(byte: layout.gapByte ?? 0))
        }
        guard formatted.filter({ !$0.isWhitespace }) == source.filter({ !$0.isWhitespace }) else {
            return .failure(.contentChanged)
        }
        return .success(formatted)
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
}

// MARK: - Layout

private final class Layout {
    let bytes: [UInt8]
    let options: SwiftFormattingOptions
    let tokens: [Token]
    let lineStarts: [Int]
    let lineEnding: String
    /// The indentation given to each original line whose first token this run has placed.
    var lineIndent: [Int: String] = [:]
    var depth = 0
    /// Where `run()` found something other than whitespace between two tokens.
    var gapByte: Int?

    /// Nodes whose whole text is one token: strings (interpolations included), regexes and
    /// comments are never edited, and their brackets never count towards the nesting depth.
    private static let atomicTypes: Set<String> = [
        "line_string_literal", "multi_line_string_literal", "raw_string_literal", "regex_literal",
        "comment", "multiline_comment"
    ]

    init?(source: String, tree: SyntaxTree, options: SwiftFormattingOptions) {
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
            if node.isMissing || node.isError { return nil }
            if node.childCount == 0 || Self.atomicTypes.contains(node.type) {
                guard node.endByte > node.startByte else { continue }
                collected.append(Token(
                    node: node, type: node.type, text: node.text, start: node.startByte, end: node.endByte,
                    startLine: Self.line(of: node.startByte, in: starts)
                ))
            } else {
                stack.append(contentsOf: node.children.reversed())
            }
        }
        // An explicit `;` is a hidden `_explicit_semi`: it takes up bytes but leaves no node, so
        // the walk above never sees it. Synthesize one token per `;` that sits in a gap (a `;`
        // inside a token belongs to that token: a string, a comment, or an enum entry's own node).
        var merged: [Token] = []
        merged.reserveCapacity(collected.count)
        var cursor = 0
        for token in collected {
            while cursor < token.start {
                if tree.sourceBytes[cursor] == 0x3B {
                    merged.append(Token(
                        node: token.node, type: ";", text: ";", start: cursor, end: cursor + 1,
                        startLine: Self.line(of: cursor, in: starts)
                    ))
                }
                cursor += 1
            }
            merged.append(token)
            cursor = max(cursor, token.end)
        }
        while cursor < tree.sourceBytes.count {
            if tree.sourceBytes[cursor] == 0x3B {
                merged.append(Token(
                    node: tree.rootNode, type: ";", text: ";", start: cursor, end: cursor + 1,
                    startLine: Self.line(of: cursor, in: starts)
                ))
            }
            cursor += 1
        }
        self.tokens = merged
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

    private static func isOpener(_ text: String) -> Bool {
        text == "{" || text == "[" || text == "("
    }

    private static func isCloser(_ text: String) -> Bool {
        text == "}" || text == "]" || text == ")"
    }

    // MARK: Emit

    func run() -> String? {
        guard !tokens.isEmpty else { return "" }
        var out = ""
        var previous: Token?
        for token in tokens {
            let gapBytes = bytes[(previous?.end ?? 0)..<token.start]
            // Only whitespace may sit between tokens; anything else means a token was missed.
            guard gapBytes.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }) else {
                // A slice keeps the source's indices, so this is the byte offset in the source.
                gapByte = gapBytes.firstIndex { !($0 == 32 || $0 == 9 || $0 == 10 || $0 == 13) }
                return nil
            }
            let newlines = gapBytes.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            let lineFirst = newlines > 0 || previous == nil
            // A closer's own line is measured without the depth it closes.
            if lineFirst, Self.isCloser(token.text) { depth = max(0, depth - 1) }
            if newlines > 0 {
                let kept = options.maxBlankLines.map { min(newlines, $0 + 1) } ?? newlines
                out += String(repeating: lineEnding, count: kept)
                let indent = indentation(for: token)
                out += indent
                lineIndent[token.startLine] = indent
            } else if previous != nil {
                out += String(decoding: gapBytes, as: UTF8.self)
            } else {
                let indent = indentation(for: token)
                out += indent
                lineIndent[token.startLine] = indent
            }
            out += token.text
            if Self.isOpener(token.text) {
                depth += 1
            } else if !lineFirst, Self.isCloser(token.text) {
                depth = max(0, depth - 1)
            }
            previous = token
        }
        // Whatever followed the last token: line breaks are kept (at most one blank line's worth
        // when collapsing), spaces are dropped.
        let tail = bytes[(tokens.last?.end ?? 0)...]
        let tailBreaks = tail.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        out += String(repeating: lineEnding, count: options.maxBlankLines.map { _ in min(tailBreaks, 1) } ?? tailBreaks)
        return out
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

    /// Nodes whose `{ … }` holds an indented body. The walk climbs through anything else (argument
    /// lists, expressions, `switch_entry`) to the statement a leading dot continues.
    private static let bodyContainers: Set<String> = [
        "function_body", "class_body", "enum_class_body", "protocol_body", "lambda_literal",
        "computed_property", "willset_didset_block", "switch_statement", "if_statement",
        "guard_statement", "for_statement", "while_statement", "repeat_while_statement",
        "do_statement", "catch_block"
    ]

    private func indentation(for token: Token) -> String {
        // A closer sits with the construct it closes; the emit loop already removed its depth.
        if Self.isCloser(token.text) {
            return unit(depth)
        }
        // A leading-dot chain (`\n.font(…)`) sits one level past the statement it continues.
        if token.text == "." {
            var member = token.node
            var current = token.node.parent
            while let container = current, !Self.bodyContainers.contains(container.type) {
                member = container
                current = container.parent
            }
            let memberLine = line(of: member)
            if memberLine < token.startLine {
                return indent(ofLine: memberLine) + unit(1)
            }
            return unit(depth)
        }
        // `case`/`default` labels sit one level into their `switch`; the statements they head sit two.
        if token.text == "case" || token.type == "default_keyword" {
            if let entry = ancestor(of: token.node, type: "switch_entry"),
               let statement = ancestor(of: entry, type: "switch_statement") {
                let switchLine = line(of: statement)
                if let colon = entry.children.first(where: { !$0.isNamed && $0.text == ":" }),
                   token.end > colon.startByte {
                    return indent(ofLine: switchLine) + unit(2)
                }
                return indent(ofLine: switchLine) + unit(1)
            }
            return unit(depth)
        }
        // `else`, `catch` and a trailing `while` line up with the statement they close.
        if token.text == "else" || token.text == "catch"
            || (token.text == "while" && token.node.parent?.type == "repeat_while_statement") {
            var current = token.node.parent
            while let node = current {
                if node.startByte < token.start
                    && ["if_statement", "guard_statement", "do_statement", "repeat_while_statement"].contains(node.type) {
                    return indent(ofLine: line(of: node))
                }
                current = node.parent
            }
            return unit(depth)
        }
        // The statements a `case`/`default` label heads sit two levels into their `switch`
        // (a pattern continued onto another line sits one in, with its label).
        if let entry = ancestor(of: token.node, type: "switch_entry"),
           let statement = ancestor(of: entry, type: "switch_statement") {
            let switchLine = line(of: statement)
            if let colon = entry.children.first(where: { !$0.isNamed && $0.text == ":" }) {
                if token.start >= colon.endByte {
                    return indent(ofLine: switchLine) + unit(2)
                }
                return indent(ofLine: switchLine) + unit(1)
            }
            return indent(ofLine: switchLine) + unit(1)
        }
        return unit(depth)
    }

    private func ancestor(of node: SyntaxNode, type: String) -> SyntaxNode? {
        var current = node.parent
        while let candidate = current {
            if candidate.type == type { return candidate }
            current = candidate.parent
        }
        return nil
    }
}

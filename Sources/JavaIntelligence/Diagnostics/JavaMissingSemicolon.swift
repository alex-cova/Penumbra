import Foundation
import LanguageSyntax

/// A missing `;` whose error spilled onto the next line, repositioned where it belongs.
///
/// When a statement loses its `;`, tree-sitter-java's recovery glues the next line's first
/// token into the statement as an `ERROR` child: `Unexpected 'System'` on line 56 for a `;`
/// missing at the end of line 55. `javac` and IntelliJ instead report `';' expected` where
/// the `;` belongs, on line 55. This rewrite detects that shape and converts the row to a
/// missing `;` anchored at the end of the previous line, so the stripe lands on line 55 like
/// everywhere else. Anything else keeps the generic row.
///
/// The gates are deliberately narrow, and each bails toward the generic row:
/// - only `unexpected` problems (a `MISSING ";"` already reports itself correctly);
/// - the error must climb to a `;`-terminated statement kind through expression-shaped nodes
///   only: anything delimiter-shaped (`argument_list`, blocks, lambdas, …) means a different
///   breakage (an unclosed paren, a broken body) and bails;
/// - every call on the climb whose arguments are present must be closed: an unclosed `(` is
///   a missing `)`, not a missing `;`;
/// - the error's first token must start on a later line than the token before it (the
///   spillover itself; same-line juxtapositions keep the generic row);
/// - that token must be able to end a statement (`)`, `]`, `}`, an identifier or literal…):
///   an opener or operator there means something else broke.
enum JavaMissingSemicolon {
    /// Statements terminated by `;`.
    private static let statementTypes: Set<String> = [
        "expression_statement", "local_variable_declaration", "field_declaration",
        "return_statement", "throw_statement", "break_statement", "continue_statement",
        "assert_statement",
    ]

    /// Expression-shaped nodes the climb may pass through. Everything else on the way up
    /// (blocks, argument lists, lambdas, …) ends the search: that is a different breakage.
    private static let transparentTypes: Set<String> = [
        "method_invocation", "field_access", "object_creation_expression",
        "assignment_expression", "binary_expression", "unary_expression",
        "update_expression", "cast_expression", "ternary_expression",
    ]

    /// Leaf types that can end a statement. Anything else before the error (an opener, an
    /// operator, a keyword) means something else broke.
    private static let statementEndTypes: Set<String> = [
        ")", "]", "}",
        "identifier", "this", "super", "true", "false", "null", "null_literal",
        "character_literal",
        "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal",
        "binary_integer_literal", "decimal_floating_point_literal", "hex_floating_point_literal",
    ]

    static func adjust(_ problem: SyntaxProblem, in tree: SyntaxTree, source: String) -> SyntaxProblem {
        guard case .unexpected = problem.kind else { return problem }
        guard let error = deepestError(containing: problem.bytes.lowerBound, in: tree.rootNode) else {
            return problem
        }
        let starts = lineStarts(in: source)
        guard let anchor = semicolonAnchor(for: error, lineStarts: starts) else { return problem }
        return SyntaxProblem(bytes: anchor..<anchor, kind: .missing(token: ";"))
    }

    /// The deepest `ERROR` node containing `byte`, if any.
    private static func deepestError(containing byte: Int, in root: SyntaxNode) -> SyntaxNode? {
        var current = root
        var found: SyntaxNode? = root.isError ? root : nil
        while let next = current.children.first(where: { $0.startByte <= byte && byte < $0.endByte }) {
            if next.isError { found = next }
            current = next
        }
        return found
    }

    /// Where the missing `;` belongs: the end of the last token before the error, or `nil`
    /// when the shape is anything but a spilled missing `;`.
    private static func semicolonAnchor(for error: SyntaxNode, lineStarts: [Int]) -> Int? {
        // Climb from the error's parent to the statement through expression-shaped nodes
        // only, and require every call on the way to be closed: an unclosed `(` is a
        // missing `)`, not a `;`.
        var node: SyntaxNode? = error.parent
        var statement: SyntaxNode?
        while let current = node {
            if statementTypes.contains(current.type) {
                statement = current
                break
            }
            guard transparentTypes.contains(current.type) else { return nil }
            if current.type == "method_invocation" || current.type == "object_creation_expression" {
                guard isCallClosed(current) else { return nil }
            }
            node = current.parent
        }
        guard statement != nil else { return nil }

        // The token before the error, skipping comments: it must be able to end a statement,
        // and it must sit on an earlier line than the error (the spillover itself).
        guard let previous = previousTerminal(before: error) else { return nil }
        guard isStatementEnd(previous) else { return nil }
        guard line(of: previous.endByte, starts: lineStarts) < line(of: error.startByte, starts: lineStarts) else { return nil }
        return previous.endByte
    }

    /// Whether the call's argument list, when present, is closed. Only direct children are
    /// examined: a missing `)` deeper inside is that subtree's own error.
    private static func isCallClosed(_ node: SyntaxNode) -> Bool {
        for child in node.children where child.type == "argument_list" {
            for grandchild in child.children where grandchild.type == ")" {
                return true
            }
            return false
        }
        return true
    }

    /// Whether `node` can end a statement. Closed strings and characters qualify by their
    /// closing quote; an unterminated string is a different breakage and bails.
    private static func isStatementEnd(_ node: SyntaxNode) -> Bool {
        if node.type == "string_literal" || node.type == "text_block" {
            return node.text.hasSuffix("\"")
        }
        return statementEndTypes.contains(node.type)
    }

    /// The closest terminal before the error in document order, skipping comments (extras).
    /// Found by walking previous siblings from the error node itself and descending to each
    /// sibling's last leaf, so the search stays inside the broken statement instead of
    /// wandering to an earlier sibling statement.
    private static func previousTerminal(before error: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = error
        while let candidate = current {
            if let sibling = candidate.previousSibling {
                var leaf = sibling
                while let last = leaf.children.last { leaf = last }
                if !leaf.isExtra { return leaf }
                current = leaf
            } else {
                current = candidate.parent
            }
        }
        return nil
    }

    /// Byte offsets where each 0-based line starts.
    private static func lineStarts(in source: String) -> [Int] {
        var starts = [0]
        var count = 0
        for unit in source.utf8 {
            count += 1
            if unit == UInt8(ascii: "\n") { starts.append(count) }
        }
        return starts
    }

    /// 0-based line number of `byte`.
    private static func line(of byte: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        var line = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= byte {
                line = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return line
    }
}

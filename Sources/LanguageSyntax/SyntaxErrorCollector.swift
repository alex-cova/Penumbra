import Foundation
import TreeSitter

/// One syntax problem found in a tree-sitter tree, in javac/IntelliJ wording.
public struct SyntaxProblem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A zero-width `MISSING` node: the grammar expected `token` here.
        case missing(token: String)
        /// Text inside an `ERROR` node that the grammar did not accept.
        case unexpected(token: String)
    }

    /// UTF-8 byte range to squiggle. Zero-width for a missing token, where it is widened
    /// onto the preceding character by the diagnostic provider.
    public let bytes: Range<Int>
    public let kind: Kind
    /// Best-effort lookahead: the tokens the grammar accepted just before the error.
    /// Kept only when it has 1–3 entries; empty when unknown or too many.
    public let expected: [String]

    public init(bytes: Range<Int>, kind: Kind, expected: [String] = []) {
        self.bytes = bytes
        self.kind = kind
        self.expected = expected
    }

    /// `';' expected`, `<identifier> expected`, `';' or ')' expected`, `Unexpected 'foo'`.
    public func message(tokenName: @Sendable (String) -> String = SyntaxProblem.defaultTokenName) -> String {
        switch kind {
        case .missing(let token):
            return "\(tokenName(token)) expected"
        case .unexpected(let token):
            if !expected.isEmpty {
                return expected.map(tokenName).joined(separator: " or ") + " expected"
            }
            return "Unexpected '\(token)'"
        }
    }

    /// Punctuation is quoted (`;` → `';'`), names are wrapped (`identifier` →
    /// `<identifier>`, `type_identifier` → `<type identifier>`).
    public static func defaultTokenName(_ symbol: String) -> String {
        if !symbol.isEmpty, symbol.allSatisfy({ !$0.isLetter && !$0.isNumber && $0 != "_" }) {
            return "'\(symbol)'"
        }
        return "<\(symbol.replacingOccurrences(of: "_", with: " "))>"
    }

    /// javac's spelling: every identifier-shaped symbol is `<identifier>`.
    public static func javacTokenName(_ symbol: String) -> String {
        if symbol.lowercased().contains("identifier") { return "<identifier>" }
        return defaultTokenName(symbol)
    }
}

/// Syntax errors straight from the tree-sitter tree, shared by every language with a grammar.
///
/// A clean file costs one `rootNode.hasError` check. A broken file costs only the paths to its
/// errors: the walk descends only into children whose `hasError` is true, and each `ERROR`
/// node is reported once and not descended into. The walk is iterative with an explicit stack,
/// because real-world trees can be deep.
public enum SyntaxErrorCollector {
    /// At most `limit` problems, in document order.
    public static func problems(in tree: SyntaxTree, limit: Int = 100) -> [SyntaxProblem] {
        let root = tree.rootNode
        guard root.hasError || root.isError || root.isMissing else { return [] }
        var result: [SyntaxProblem] = []
        var stack: [SyntaxNode] = [root]
        while let node = stack.popLast() {
            if result.count >= limit { break }
            if node.isMissing {
                result.append(missing(node, in: tree))
                continue
            }
            if node.isError {
                result.append(unexpected(node, in: tree))
                continue
            }
            // Children are ordered, so pushing them reversed pops them in document order.
            // A missing or error node always sets `hasError` on its ancestors, but the
            // node itself is checked directly in case a grammar reports otherwise.
            for index in stride(from: node.childCount - 1, through: 0, by: -1) {
                guard let child = node.child(at: index) else { continue }
                if child.hasError || child.isError || child.isMissing {
                    stack.append(child)
                }
            }
        }
        return result
    }

    // MARK: - Problem shapes

    /// A missing token is zero-width. It is reported at the end of the previous token, the way
    /// IntelliJ and javac place "`;` expected".
    private static func missing(_ node: SyntaxNode, in tree: SyntaxTree) -> SyntaxProblem {
        let anchor = previousLeaf(before: node.startByte, in: tree)?.endByte ?? node.startByte
        let expected = expectedTokens(before: node.startByte, in: tree)
        return SyntaxProblem(bytes: anchor..<anchor, kind: .missing(token: node.type), expected: expected)
    }

    /// An `ERROR` node can span the rest of the file, so only its first real token is squiggled.
    private static func unexpected(_ node: SyntaxNode, in tree: SyntaxTree) -> SyntaxProblem {
        let leaf = firstRealLeaf(in: node) ?? node.firstLeaf
        var token = leaf.text
        if token.isEmpty { token = leaf.type }
        if token.count > 30 { token = String(token.prefix(30)) }
        let expected = expectedTokens(before: node.startByte, in: tree)
        return SyntaxProblem(bytes: leaf.byteRange, kind: .unexpected(token: token), expected: expected)
    }

    /// The first terminal in `node`'s subtree in document order that is not an extra
    /// (a comment the parser skipped over).
    private static func firstRealLeaf(in node: SyntaxNode) -> SyntaxNode? {
        var stack: [SyntaxNode] = [node]
        while let current = stack.popLast() {
            if current.childCount == 0 {
                if !current.isExtra { return current }
                continue
            }
            for index in stride(from: current.childCount - 1, through: 0, by: -1) {
                if let child = current.child(at: index) { stack.append(child) }
            }
        }
        return nil
    }

    // MARK: - Lookbehind and lookahead

    /// The last non-extra terminal ending at or before `byte`, found by descending to the last
    /// qualifying child at each level (children are ordered, so this is logarithmic per level,
    /// not a scan of the file).
    private static func previousLeaf(before byte: Int, in tree: SyntaxTree) -> SyntaxNode? {
        guard byte > 0 else { return nil }
        var node = tree.rootNode
        var best: SyntaxNode? = nil
        while true {
            guard let child = lastChild(endingAtOrBefore: byte, in: node) else { break }
            if child.childCount == 0 {
                best = child
                break
            }
            node = child
        }
        // Comments are extras, not tokens: step back past them.
        while best?.isExtra == true {
            best = previousLeaf(of: best!)
        }
        return best
    }

    private static func lastChild(endingAtOrBefore byte: Int, in node: SyntaxNode) -> SyntaxNode? {
        var low = 0
        var high = node.childCount - 1
        var found: SyntaxNode? = nil
        while low <= high {
            let mid = (low + high) / 2
            guard let child = node.child(at: mid) else { break }
            if child.endByte <= byte {
                found = child
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// The leaf immediately before `node` in document order, or nil at the start of the file.
    private static func previousLeaf(of node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let candidate = current {
            if let sibling = candidate.previousSibling {
                var leaf = sibling
                while let last = leaf.child(at: leaf.childCount - 1) { leaf = last }
                return leaf
            }
            current = candidate.parent
        }
        return nil
    }

    /// The tokens the grammar accepted in the state just before the error: a `ts_lookahead_iterator`
    /// over the previous non-extra leaf's `nextParseState`. Kept only for a short, useful list.
    private static func expectedTokens(before byte: Int, in tree: SyntaxTree) -> [String] {
        guard let previous = previousLeaf(before: byte, in: tree),
              let language = tree.language
        else { return [] }
        let state = previous.nextParseState
        guard let iterator = ts_lookahead_iterator_new(language, state) else { return [] }
        defer { ts_lookahead_iterator_delete(iterator) }
        var names: [String] = []
        repeat {
            let symbol = ts_lookahead_iterator_current_symbol(iterator)
            guard let cName = ts_lookahead_iterator_current_symbol_name(iterator) else { continue }
            let name = String(cString: cName)
            // A new iterator starts on the `ERROR` symbol itself.
            if name == "ERROR" { continue }
            let type = ts_language_symbol_type(language, symbol)
            if type == TSSymbolTypeSupertype || type == TSSymbolTypeAuxiliary { continue }
            names.append(name)
            if names.count > 3 { return [] }
        } while ts_lookahead_iterator_next(iterator)
        return names
    }
}

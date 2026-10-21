import Foundation
import TreeSitter

/// A tree-sitter parse that any language can share. Java keeps its inspection memo on
/// ``attachment``; the type is named here rather than `SyntaxTree` in call sites that also import
/// EditorIntelligence, whose `SyntaxTree` is the symbol-index protocol. This module's own name
/// wins inside `LanguageSyntax`.
///
/// Parses whole documents, or incrementally after ``apply(_:)`` edits via
/// ``SyntaxParser/parseIncremental(oldTree:source:)``.
public final class SyntaxTree: @unchecked Sendable {
    /// UTF-8 bytes of the parsed source. tree-sitter's byte offsets are UTF-8 byte offsets, so
    /// every node's `startByte`/`endByte` indexes directly into this array.
    package let sourceBytes: [UInt8]
    private let tree: OpaquePointer
    /// A language-specific memo that lives as long as this parse. Java stores its declaration cache.
    package let attachment = SyntaxAttachment()

    fileprivate init(tree: OpaquePointer, sourceBytes: [UInt8]) {
        self.tree = tree
        self.sourceBytes = sourceBytes
    }

    deinit {
        ts_tree_delete(tree)
    }

    fileprivate var treeForParsing: OpaquePointer { tree }

    /// An independent copy (tree-sitter shares the nodes, so this is cheap) that can be edited
    /// for an incremental reparse while other code still reads this tree.
    package func copy() -> SyntaxTree {
        SyntaxTree(tree: ts_tree_copy(tree), sourceBytes: sourceBytes)
    }

    /// Shifts node coordinates to match a buffer edit before an incremental reparse.
    package func apply(_ edit: ParseEdit) {
        var raw = edit.rawValue
        ts_tree_edit(tree, &raw)
    }

    public var rootNode: SyntaxNode {
        SyntaxNode(raw: ts_tree_root_node(tree), tree: self)
    }

    /// The grammar this tree was parsed with, for lookahead queries.
    package var language: OpaquePointer? {
        ts_tree_language(tree)
    }

    /// The smallest node spanning a single byte offset (tree-sitter's own
    /// `ts_node_descendant_for_byte_range` with a zero-length range) -- the standard way to find
    /// "what's at the cursor" including inside `ERROR` subtrees, which is where a lot of
    /// completion-time lookups land given incomplete/still-being-typed code.
    public func node(atByteOffset offset: Int) -> SyntaxNode {
        let clamped = max(0, min(offset, sourceBytes.count))
        let raw = ts_node_descendant_for_byte_range(ts_tree_root_node(tree), UInt32(clamped), UInt32(clamped))
        return SyntaxNode(raw: raw, tree: self)
    }

    /// The smallest node spanning the whole byte range -- for a token's own range, that token.
    package func node(inByteRange range: Range<Int>) -> SyntaxNode {
        let lower = max(0, min(range.lowerBound, sourceBytes.count))
        let upper = max(lower, min(range.upperBound, sourceBytes.count))
        let raw = ts_node_descendant_for_byte_range(ts_tree_root_node(tree), UInt32(lower), UInt32(upper))
        return SyntaxNode(raw: raw, tree: self)
    }

    /// Decodes a byte range of the source as UTF-8 text.
    package func text(in range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= sourceBytes.count, range.lowerBound <= range.upperBound else {
            return ""
        }
        return String(decoding: sourceBytes[range], as: UTF8.self)
    }
}

/// Parses source into a ``SyntaxTree``. Not thread-safe by itself (mirrors `ts_parser_t`'s
/// own single-threaded contract) — callers create one per parse or confine an instance to one
/// task/actor. Pass the grammar (`tree_sitter_java()`, `tree_sitter_swift()`, …). Java's
/// no-argument initializer lives on `JavaSyntaxParser` in JavaIntelligence.
public final class SyntaxParser {
    private let parser: OpaquePointer

    /// `language` is a `tree_sitter_*()` pointer and must stay valid for the parser's lifetime.
    public init(language: OpaquePointer) {
        parser = ts_parser_new()
        ts_parser_set_language(parser, language)
    }

    deinit {
        ts_parser_delete(parser)
    }

    public func parse(_ source: String) -> SyntaxTree? {
        let bytes = Array(source.utf8)
        guard let tsTree = source.withCString({ cString in
            ts_parser_parse_string(parser, nil, cString, UInt32(bytes.count))
        }) else {
            return nil
        }
        return SyntaxTree(tree: tsTree, sourceBytes: bytes)
    }

    /// Re-parses `source` incrementally after `oldTree` has been edited with ``SyntaxTree/apply(_:)``.
    package func parseIncremental(oldTree: SyntaxTree, source: String) -> SyntaxTree? {
        let bytes = Array(source.utf8)
        guard let tsTree = source.withCString({ cString in
            ts_parser_parse_string(parser, oldTree.treeForParsing, cString, UInt32(bytes.count))
        }) else {
            return nil
        }
        return SyntaxTree(tree: tsTree, sourceBytes: bytes)
    }
}

/// A single tree-sitter node, addressed by byte range into its owning ``SyntaxTree``'s source.
/// Value type wrapping the underlying `TSNode` (itself a small value struct); the tree it points
/// into must be kept alive by the caller for as long as any of its nodes are used.
public struct SyntaxNode {
    private let raw: TSNode
    package let tree: SyntaxTree

    init(raw: TSNode, tree: SyntaxTree) {
        self.raw = raw
        self.tree = tree
    }

    public var type: String {
        String(cString: ts_node_type(raw))
    }

    public var isNamed: Bool {
        ts_node_is_named(raw)
    }

    public var isMissing: Bool {
        ts_node_is_missing(raw)
    }

    /// Whether this node is an `ERROR` node (as opposed to merely containing one).
    public var isError: Bool {
        ts_node_is_error(raw)
    }

    /// Whether this node is an extra (a comment or other out-of-grammar token the parser
    /// skipped over). Extras are ignored when picking the unexpected token of an `ERROR` node.
    public var isExtra: Bool {
        ts_node_is_extra(raw)
    }

    /// Whether this subtree contains a syntax error or a missing node.
    public var hasError: Bool {
        ts_node_has_error(raw)
    }

    public var startByte: Int { Int(ts_node_start_byte(raw)) }
    public var endByte: Int { Int(ts_node_end_byte(raw)) }
    public var byteRange: Range<Int> { startByte..<endByte }

    public var text: String {
        tree.text(in: byteRange)
    }

    public var childCount: Int { Int(ts_node_child_count(raw)) }
    public var namedChildCount: Int { Int(ts_node_named_child_count(raw)) }

    public func child(at index: Int) -> SyntaxNode? {
        guard index >= 0, index < childCount else { return nil }
        return SyntaxNode(raw: ts_node_child(raw, UInt32(index)), tree: tree)
    }

    public func namedChild(at index: Int) -> SyntaxNode? {
        guard index >= 0, index < namedChildCount else { return nil }
        return SyntaxNode(raw: ts_node_named_child(raw, UInt32(index)), tree: tree)
    }

    public var parent: SyntaxNode? {
        let parent = ts_node_parent(raw)
        guard !ts_node_is_null(parent) else { return nil }
        return SyntaxNode(raw: parent, tree: tree)
    }

    public var previousSibling: SyntaxNode? {
        let sibling = ts_node_prev_sibling(raw)
        guard !ts_node_is_null(sibling) else { return nil }
        return SyntaxNode(raw: sibling, tree: tree)
    }

    /// The first terminal below this node, following first children down.
    public var firstLeaf: SyntaxNode {
        var node = self
        while let first = node.child(at: 0) { node = first }
        return node
    }

    /// The parse state after this node, for lookahead queries on the leaf before an error.
    package var nextParseState: TSStateId {
        ts_node_next_parse_state(raw)
    }

    /// One cursor walk: `ts_node_child(i)` walks from the first child every time, so asking for
    /// each index is quadratic, which a class with thousands of members turns into milliseconds.
    public var children: [SyntaxNode] {
        var result: [SyntaxNode] = []
        result.reserveCapacity(childCount)
        walkChildren { node in
            result.append(node)
            return true
        }
        return result
    }

    public var namedChildren: [SyntaxNode] {
        var result: [SyntaxNode] = []
        result.reserveCapacity(namedChildCount)
        walkChildren { node in
            if node.isNamed { result.append(node) }
            return true
        }
        return result
    }

    /// Calls `body` for each direct child in order until it returns `false`.
    private func walkChildren(_ body: (SyntaxNode) -> Bool) {
        var cursor = ts_tree_cursor_new(raw)
        defer { ts_tree_cursor_delete(&cursor) }
        guard ts_tree_cursor_goto_first_child(&cursor) else { return }
        repeat {
            if !body(SyntaxNode(raw: ts_tree_cursor_current_node(&cursor), tree: tree)) { return }
        } while ts_tree_cursor_goto_next_sibling(&cursor)
    }

    /// Every direct child, anonymous tokens included, in order, with the grammar field it fills
    /// (`nil` when it fills none). One cursor walk: linear in the child count, where calling
    /// ``child(at:)`` per index is not. Needed for grammars that reuse one field name for several
    /// children (tree-sitter-swift's `name:` is both a declaration's name and its types).
    public func enumerateChildren(_ body: (_ child: SyntaxNode, _ field: String?) -> Void) {
        var cursor = ts_tree_cursor_new(raw)
        defer { ts_tree_cursor_delete(&cursor) }
        guard ts_tree_cursor_goto_first_child(&cursor) else { return }
        repeat {
            let field = ts_tree_cursor_current_field_name(&cursor).map { String(cString: $0) }
            body(SyntaxNode(raw: ts_tree_cursor_current_node(&cursor), tree: tree), field)
        } while ts_tree_cursor_goto_next_sibling(&cursor)
    }

    /// The children collected by ``enumerateChildren(_:)``.
    public var childrenWithFields: [(node: SyntaxNode, field: String?)] {
        var result: [(node: SyntaxNode, field: String?)] = []
        enumerateChildren { result.append(($0, $1)) }
        return result
    }

    /// The child bound to a grammar field name, e.g. `name:` in `class_declaration name: (identifier)`.
    public func child(byFieldName fieldName: String) -> SyntaxNode? {
        let node = fieldName.withCString { cName in
            ts_node_child_by_field_name(raw, cName, UInt32(fieldName.utf8.count))
        }
        guard !ts_node_is_null(node) else { return nil }
        return SyntaxNode(raw: node, tree: tree)
    }

    /// Direct named children of a given grammar type, e.g. every `(modifiers)` child.
    public func namedChildren(ofType type: String) -> [SyntaxNode] {
        namedChildren.filter { $0.type == type }
    }

    public func firstNamedChild(ofType type: String) -> SyntaxNode? {
        var found: SyntaxNode?
        walkChildren { node in
            guard node.isNamed, node.type == type else { return true }
            found = node
            return false
        }
        return found
    }

    /// tree-sitter's debug S-expression for this subtree, e.g. `(class_declaration name: (identifier))`.
    /// Useful for grammar exploration and in test failure messages.
    public var sExpression: String {
        guard let cString = ts_node_string(raw) else { return "" }
        defer { free(cString) }
        return String(cString: cString)
    }
}

/// One extra object owned by a ``SyntaxTree``. Java's declaration cache is stored here so the
/// tree itself stays free of Java types.
public final class SyntaxAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AnyObject?

    public init() {}

    /// The object of `type` already stored, or `create()` saved for the next call.
    package func object<T: AnyObject>(_ type: T.Type, create: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage as? T { return existing }
        let created = create()
        storage = created
        return created
    }
}

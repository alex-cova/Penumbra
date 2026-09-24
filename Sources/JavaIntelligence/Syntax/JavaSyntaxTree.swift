import Foundation
import TreeSitter
import TreeSitterJava

/// A minimal, from-scratch wrapper over the tree-sitter C API for parsing Java source, kept
/// self-contained within `JavaIntelligence` rather than reusing `Penumbra`'s internal
/// `TreeSitterParser`/`TreeSitterNode` (those are `internal` to the `Penumbra` module, and this
/// module must not depend on `Penumbra` at all -- see the EIP/Penumbra adapter boundary in
/// CLAUDE.md). It only supports one-shot whole-document parsing (no incremental re-parse), which
/// is all the source-stub builder needs.
public final class JavaSyntaxTree: @unchecked Sendable {
    /// UTF-8 bytes of the parsed source. tree-sitter's byte offsets are UTF-8 byte offsets, so
    /// every node's `startByte`/`endByte` indexes directly into this array.
    let sourceBytes: [UInt8]
    private let tree: OpaquePointer

    fileprivate init(tree: OpaquePointer, sourceBytes: [UInt8]) {
        self.tree = tree
        self.sourceBytes = sourceBytes
    }

    deinit {
        ts_tree_delete(tree)
    }

    public var rootNode: SyntaxNode {
        SyntaxNode(raw: ts_tree_root_node(tree), tree: self)
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
    func node(inByteRange range: Range<Int>) -> SyntaxNode {
        let lower = max(0, min(range.lowerBound, sourceBytes.count))
        let upper = max(lower, min(range.upperBound, sourceBytes.count))
        let raw = ts_node_descendant_for_byte_range(ts_tree_root_node(tree), UInt32(lower), UInt32(upper))
        return SyntaxNode(raw: raw, tree: self)
    }

    /// Decodes a byte range of the source as UTF-8 text.
    func text(in range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= sourceBytes.count, range.lowerBound <= range.upperBound else {
            return ""
        }
        return String(decoding: sourceBytes[range], as: UTF8.self)
    }
}

/// Parses Java source into a ``JavaSyntaxTree``. Not thread-safe by itself (mirrors
/// `ts_parser_t`'s own single-threaded contract) -- callers create one per parse or confine an
/// instance to one task/actor.
public final class JavaSyntaxParser {
    private let parser: OpaquePointer

    public init() {
        parser = ts_parser_new()
        ts_parser_set_language(parser, tree_sitter_java())
    }

    deinit {
        ts_parser_delete(parser)
    }

    public func parse(_ source: String) -> JavaSyntaxTree? {
        let bytes = Array(source.utf8)
        guard let tsTree = source.withCString({ cString in
            ts_parser_parse_string(parser, nil, cString, UInt32(bytes.count))
        }) else {
            return nil
        }
        return JavaSyntaxTree(tree: tsTree, sourceBytes: bytes)
    }
}

/// A single tree-sitter node, addressed by byte range into its owning ``JavaSyntaxTree``'s source.
/// Value type wrapping the underlying `TSNode` (itself a small value struct); the tree it points
/// into must be kept alive by the caller for as long as any of its nodes are used.
public struct SyntaxNode {
    private let raw: TSNode
    let tree: JavaSyntaxTree

    init(raw: TSNode, tree: JavaSyntaxTree) {
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
        let raw = ts_node_parent(raw)
        guard !ts_node_is_null(raw) else { return nil }
        return SyntaxNode(raw: raw, tree: tree)
    }

    public var children: [SyntaxNode] {
        (0..<childCount).compactMap { child(at: $0) }
    }

    public var namedChildren: [SyntaxNode] {
        (0..<namedChildCount).compactMap { namedChild(at: $0) }
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
        namedChildren.first { $0.type == type }
    }

    /// tree-sitter's debug S-expression for this subtree, e.g. `(class_declaration name: (identifier))`.
    /// Useful for grammar exploration and in test failure messages.
    public var sExpression: String {
        guard let cString = ts_node_string(raw) else { return "" }
        defer { free(cString) }
        return String(cString: cString)
    }
}

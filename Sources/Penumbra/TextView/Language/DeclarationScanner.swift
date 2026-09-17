import Foundation

/// A position span within the document, derived from a tree-sitter node. Byte offsets are already
/// converted to UTF-16 code units and columns are already halved (tree-sitter reports UTF-16 byte
/// columns), matching the convention in `TreeSitterSyntaxTree.makeRange`.
struct DeclarationSpan: Equatable {
    var startUTF16: Int
    var endUTF16: Int
    var startRow: Int
    var startColumn: Int
    var endRow: Int
    var endColumn: Int

    init(startUTF16: Int, endUTF16: Int, startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
    }

    init(node: TreeSitterNode) {
        self.startUTF16 = node.startByte.utf16Length
        self.endUTF16 = node.endByte.utf16Length
        self.startRow = Int(node.startPoint.row)
        self.startColumn = Int(node.startPoint.column) / 2
        self.endRow = Int(node.endPoint.row)
        self.endColumn = Int(node.endPoint.column) / 2
    }
}

/// One declaration found by ``DeclarationScanner``.
struct ScannedDeclaration: Equatable {
    var kind: DeclarationKind
    /// Empty when the matched rule has no name node types or none was found.
    var name: String
    var isMethodSeparatorAnchor: Bool
    var isBreadcrumbSegment: Bool
    /// The whole declaration (used for breadcrumb / outline containment).
    var container: DeclarationSpan
    /// The name node, or a zero-length span at the container's start when unnamed.
    var name_span: DeclarationSpan
    /// Nesting depth among *matched* declarations (0 = top level).
    var depth: Int
}

/// Walks a tree-sitter tree once and reports the declarations a ``LanguageConfiguration``
/// recognises. Shared by breadcrumb/outline symbol extraction and the method-separator overlay.
///
/// Structurally this is `TreeSitterLineFoldProvider.collectFoldRegions` with rule matching in
/// place of the substring heuristic, plus name extraction and a matched-declaration depth counter.
enum DeclarationScanner {
    /// - Parameters:
    ///   - root: The tree root (`tree.rootNode` or `languageMode.rootSyntaxNode`).
    ///   - configuration: The rules to match against.
    ///   - text: Document text, for name extraction. Pass `nil` when only spans are needed
    ///     (the method-separator overlay), and every ``ScannedDeclaration/name`` will be empty.
    ///   - rowWindow: Optional inclusive row range; subtrees entirely outside it are skipped.
    /// - Note: The returned values copy everything needed out of the tree; no `TreeSitterNode` is
    ///   retained, so the result stays valid across the next reparse.
    static func scan(
        root: TreeSitterNode,
        configuration: LanguageConfiguration,
        text: NSString?,
        rowWindow: ClosedRange<Int>? = nil
    ) -> [ScannedDeclaration] {
        guard !configuration.declarations.isEmpty else {
            return []
        }
        var result: [ScannedDeclaration] = []
        walk(node: root, configuration: configuration, text: text, rowWindow: rowWindow, depth: 0, into: &result)
        return result
    }

    private static func walk(
        node: TreeSitterNode,
        configuration: LanguageConfiguration,
        text: NSString?,
        rowWindow: ClosedRange<Int>?,
        depth: Int,
        into result: inout [ScannedDeclaration]
    ) {
        let startRow = Int(node.startPoint.row)
        let endRow = Int(node.endPoint.row)
        if let rowWindow, endRow < rowWindow.lowerBound || startRow > rowWindow.upperBound {
            return
        }
        var childDepth = depth
        if let type = node.type, let rule = configuration.rule(forNodeType: type) {
            let container = DeclarationSpan(node: node)
            let nameNode = rule.nameNodeTypes.isEmpty ? nil : firstChild(of: node, ofAnyType: rule.nameNodeTypes)
            let nameSpan = nameNode.map(DeclarationSpan.init) ?? DeclarationSpan(
                startUTF16: container.startUTF16,
                endUTF16: container.startUTF16,
                startRow: container.startRow,
                startColumn: container.startColumn,
                endRow: container.startRow,
                endColumn: container.startColumn
            )
            let name: String
            if let nameNode, let text {
                name = substring(of: nameNode, in: text)
            } else {
                name = ""
            }
            result.append(ScannedDeclaration(
                kind: rule.kind,
                name: name,
                isMethodSeparatorAnchor: rule.isMethodSeparatorAnchor,
                isBreadcrumbSegment: rule.isBreadcrumbSegment,
                container: container,
                name_span: nameSpan,
                depth: depth
            ))
            childDepth = depth + 1
        }
        for index in 0 ..< node.childCount {
            if let child = node.child(at: index) {
                walk(node: child, configuration: configuration, text: text, rowWindow: rowWindow, depth: childDepth, into: &result)
            }
        }
    }

    private static func firstChild(of node: TreeSitterNode, ofAnyType types: [String]) -> TreeSitterNode? {
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index), let type = child.type else {
                continue
            }
            if types.contains(type) {
                return child
            }
        }
        return nil
    }

    private static func substring(of node: TreeSitterNode, in text: NSString) -> String {
        let start = node.startByte.utf16Length
        let end = node.endByte.utf16Length
        guard end > start, start >= 0, end <= text.length else {
            return ""
        }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

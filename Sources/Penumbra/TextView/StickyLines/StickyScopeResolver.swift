import Foundation

/// A block whose first line stays pinned to the top of the editor while the block scrolls by.
struct StickyScope: Equatable {
    /// The line shown: the signature row of a declaration (not its annotations), the `if (…) {` row
    /// of a statement.
    var headerRow: Int
    /// The last row of the block, its closing brace included.
    var endRow: Int
}

/// Finds the blocks around a row that sticky lines pin: type and function declarations from the
/// language's ``LanguageConfiguration/declarations`` plus its ``LanguageConfiguration/stickyNodeTypes``
/// (`if`, loops, `switch`, `try`).
///
/// One descent from the root to the row and a walk up through at most
/// ``maximumAncestorDepth`` parents, so it is cheap enough to run when the scroll position moves
/// onto a different row. Callers cache by row.
enum StickyScopeResolver {
    static let maximumAncestorDepth = 64

    /// The scopes enclosing `row` whose header lies above it, outermost first.
    static func scopes(
        containingRow row: Int,
        root: TreeSitterNode,
        configuration: LanguageConfiguration
    ) -> [StickyScope] {
        guard row > 0 else {
            return []
        }
        let point = TreeSitterTextPoint(row: UInt32(row), column: 0)
        var node: TreeSitterNode? = root.descendantForRange(from: point, to: point)
        var scopes: [StickyScope] = []
        // After an `if`, a following `if` ancestor (directly in Java, through `else_clause` in
        // JavaScript) means the first one was an `else if`; its outer `if` would repeat the chain.
        var followsIf = false
        var steps = 0
        while let current = node, steps < maximumAncestorDepth {
            steps += 1
            let type = current.type
            if let type {
                let isElseIf = followsIf && type == "if_statement"
                if !isElseIf,
                   let scope = scope(for: current, type: type, row: row, configuration: configuration),
                   scopes.last?.headerRow != scope.headerRow {
                    scopes.append(scope)
                }
                if type == "if_statement" {
                    followsIf = true
                } else if type != "else_clause" {
                    followsIf = false
                }
            }
            node = current.parent
        }
        return scopes.reversed()
    }

    private static func scope(
        for node: TreeSitterNode,
        type: String,
        row: Int,
        configuration: LanguageConfiguration
    ) -> StickyScope? {
        let rule = configuration.rule(forNodeType: type)
        let isDeclaration = rule.map { $0.kind == .type || $0.kind == .function } ?? false
        guard isDeclaration || configuration.stickyNodeTypes.contains(type) else {
            return nil
        }
        let startRow = Int(node.startPoint.row)
        var endRow = Int(node.endPoint.row)
        // A node that ends at column 0 of a row does not include that row.
        if node.endPoint.column == 0, endRow > startRow {
            endRow -= 1
        }
        var headerRow = startRow
        if isDeclaration, let rule, !rule.nameNodeTypes.isEmpty,
           let name = DeclarationScanner.firstChild(of: node, ofAnyType: rule.nameNodeTypes) {
            headerRow = Int(name.startPoint.row)
        }
        guard endRow > headerRow, headerRow < row, row <= endRow else {
            return nil
        }
        return StickyScope(headerRow: headerRow, endRow: endRow)
    }
}

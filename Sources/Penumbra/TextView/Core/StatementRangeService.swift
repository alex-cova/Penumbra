import Foundation

/// Finds the row span of the syntactic statement enclosing a position, so "move statement
/// up/down" (⌘⇧↑/↓) can relocate a whole `if` / function / block as a unit instead of a
/// single physical line. Feeds its result into the existing `MoveLinesService`.
struct StatementRangeService {
    /// Node types that act as statement *containers* — climbing stops when the parent is one of
    /// these, leaving `node` as the statement directly inside it.
    private static let containerHints = [
        "block", "body", "suite", "program", "source_file", "module",
        "compound_statement", "statement_block", "declaration_list", "field_declaration_list"
    ]

    /// Row range (0-based, inclusive) of the statement enclosing `node`, or `nil` if nothing
    /// suitable is found.
    func statementRowRange(around node: TreeSitterNode) -> ClosedRange<Int>? {
        var current = node
        // Never treat the whole file as a movable statement.
        while let parent = current.parent, parent.parent != nil {
            if let parentType = parent.type, Self.isContainer(parentType) {
                break
            }
            // Climb out of expression fragments / identifiers into their enclosing statement,
            // but stop once climbing would swallow additional rows beyond the parent's first
            // line — i.e. keep the smallest multi-line ancestor within the same container.
            current = parent
        }
        let start = Int(current.startPoint.row)
        let end = Int(current.endPoint.row)
        guard end >= start else {
            return nil
        }
        return start...end
    }

    private static func isContainer(_ type: String) -> Bool {
        containerHints.contains { type == $0 || type.hasSuffix("_" + $0) }
    }
}

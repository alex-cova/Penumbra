import EditorIntelligence
import Foundation

/// Which declaration "Show History for Method / Class" means, from the structure outline.
enum IDEDeclarationHistory {
    enum Kind {
        case method
        case type

        /// What the History panel calls it ("History of method put(String, int)").
        var noun: String {
            switch self {
            case .method: "method"
            case .type: "class"
            }
        }

        var missingTitle: String {
            switch self {
            case .method: "No Method at the Caret"
            case .type: "No Class at the Caret"
            }
        }

        func matches(_ kind: StructureKind) -> Bool {
            switch self {
            case .method: kind == .method || kind == .constructor || kind == .function
            case .type: kind == .type
            }
        }
    }

    /// The nodes whose body holds `offset` (UTF-16), outermost first.
    static func path(in roots: [StructureNode], containing offset: Int) -> [StructureNode] {
        var path: [StructureNode] = []
        var level = roots
        while let next = level.first(where: { contains($0, offset) }) {
            path.append(next)
            level = next.children
        }
        return path
    }

    /// The innermost declaration of `kind` around `offset`: the method a caret inside a lambda in
    /// it belongs to, the nested class a caret in it belongs to.
    static func declaration(in roots: [StructureNode], containing offset: Int, kind: Kind) -> StructureNode? {
        path(in: roots, containing: offset).last { kind.matches($0.kind) }
    }

    /// The panel's heading: `method put(String, int)`.
    static func title(of node: StructureNode, kind: Kind) -> String {
        "\(kind.noun) \(node.title)"
    }

    private static func contains(_ node: StructureNode, _ offset: Int) -> Bool {
        // Same rule as `StructureNode.deepestNode(containing:)`: the caret just after a body counts.
        node.bodyRange.contains(offset) || node.bodyRange.upperBound == offset
    }
}

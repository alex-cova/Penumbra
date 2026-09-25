import JavaIntelligence
import Observation

/// The Structure tool window's tree state: the type at the caret, its members, and caret sync.
@MainActor
@Observable
final class IDEJavaStructureStore {
    struct Row: Identifiable {
        let node: JavaStructureNode
        let depth: Int
        let isExpanded: Bool
        let canExpand: Bool

        var id: String { node.id }
    }

    private(set) var root: JavaStructureNode?
    private(set) var message: String?
    private(set) var selectedID: String?
    private var expanded: Set<String> = []

    var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        func visit(_ node: JavaStructureNode, depth: Int) {
            let canExpand = !node.children.isEmpty
            let isExpanded = expanded.contains(node.id)
            result.append(Row(node: node, depth: depth, isExpanded: isExpanded, canExpand: canExpand))
            if isExpanded {
                for child in node.children {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return result
    }

    func show(root: JavaStructureNode, selectedID: String?) {
        self.root = root
        message = nil
        expanded = Set(allExpandableIDs(in: root))
        self.selectedID = selectedID ?? root.id
    }

    func show(message: String) {
        root = nil
        self.message = message
        expanded = []
        selectedID = nil
    }

    func clear() {
        root = nil
        message = nil
        expanded = []
        selectedID = nil
    }

    func toggle(_ node: JavaStructureNode) {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    func select(_ id: String) {
        selectedID = id
    }

    func node(withID id: String) -> JavaStructureNode? {
        guard let root else { return nil }
        return findNode(id: id, in: root)
    }

    func moveSelection(by delta: Int) {
        let visible = rows
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? -1
        selectedID = visible[min(max(0, current + delta), visible.count - 1)].id
    }

    private func allExpandableIDs(in node: JavaStructureNode) -> [String] {
        var ids: [String] = []
        if !node.children.isEmpty {
            ids.append(node.id)
        }
        for child in node.children {
            ids.append(contentsOf: allExpandableIDs(in: child))
        }
        return ids
    }

    private func findNode(id: String, in node: JavaStructureNode) -> JavaStructureNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id: id, in: child) { return found }
        }
        return nil
    }
}

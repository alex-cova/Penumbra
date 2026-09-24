import JavaIntelligence
import Observation
import SwiftUI

@MainActor
@Observable
final class IDECallHierarchyStore {
    enum Direction: String, CaseIterable, Identifiable {
        case callers = "Callers"
        case callees = "Callees"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let node: JavaCallHierarchyNode
        let depth: Int
        let isExpanded: Bool
        let isLoading: Bool
        let canExpand: Bool
        var id: String { node.id }
    }

    typealias Loader = @MainActor (JavaCallHierarchyNode, Direction, URL?) async -> [JavaCallHierarchyNode]

    private(set) var root: JavaCallHierarchyNode?
    private(set) var message: String?
    private(set) var direction: Direction = .callers
    private(set) var file: URL?
    var selectedID: String?

    @ObservationIgnored var loader: Loader?
    private var children: [String: [JavaCallHierarchyNode]] = [:]
    private var expanded: Set<String> = []
    private var loading: Set<String> = []
    private var generation = 0

    var hasContent: Bool { root != nil || message != nil }

    var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        appendRows(for: root, depth: 0, into: &result)
        return result
    }

    func show(root: JavaCallHierarchyNode, file: URL?) {
        generation += 1
        self.root = root
        message = nil
        self.file = file
        selectedID = root.id
        children = [:]
        expanded = []
        loading = []
    }

    func show(message: String) {
        generation += 1
        root = nil
        self.message = message
        file = nil
        selectedID = nil
        children = [:]
        expanded = []
        loading = []
    }

    func clear() {
        generation += 1
        root = nil
        message = nil
        file = nil
        selectedID = nil
        children = [:]
        expanded = []
        loading = []
    }

    func setDirection(_ direction: Direction) {
        guard self.direction != direction else { return }
        self.direction = direction
        children = [:]
        expanded = []
        loading = []
        generation += 1
    }

    func toggle(_ node: JavaCallHierarchyNode) {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
            return
        }
        expanded.insert(node.id)
        guard children[node.id] == nil, !loading.contains(node.id) else { return }
        loading.insert(node.id)
        let token = generation
        guard let loader else { return }
        let direction = direction
        let file = file
        Task { [weak self] in
            let loaded = await loader(node, direction, file)
            guard let self, self.generation == token else { return }
            self.children[node.id] = loaded
            self.loading.remove(node.id)
        }
    }

    private func appendRows(for node: JavaCallHierarchyNode, depth: Int, into rows: inout [Row]) {
        let childList = children[node.id]
        let isExpanded = expanded.contains(node.id)
        let isLoading = loading.contains(node.id)
        let canExpand = childList.map { !$0.isEmpty } ?? true
        rows.append(Row(node: node, depth: depth, isExpanded: isExpanded, isLoading: isLoading, canExpand: canExpand))
        if isExpanded, let childList {
            for child in childList {
                appendRows(for: child, depth: depth + 1, into: &rows)
            }
        }
    }
}

struct IDECallHierarchyPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let store = workspace.callHierarchy
        VStack(spacing: 0) {
            if let root = store.root {
                header(store, root: root)
                Divider()
                tree(store)
            } else {
                emptyState(store.message ?? "Place the caret in a Java method and open Call Hierarchy")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ store: IDECallHierarchyStore, root: JavaCallHierarchyNode) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Picker("Direction", selection: Binding(
                get: { store.direction },
                set: { store.setDirection($0) }
            )) {
                ForEach(IDECallHierarchyStore.Direction.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Text(root.displayName)
                .font(IDEAppearance.Typography.body.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button { workspace.closeCallHierarchy() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func tree(_ store: IDECallHierarchyStore) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.rows) { row in
                    HStack(spacing: 4) {
                        Color.clear.frame(width: CGFloat(row.depth) * 14)
                        Button {
                            if row.canExpand { store.toggle(row.node) }
                        } label: {
                            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                                .opacity(row.canExpand ? 1 : 0.3)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 12)
                        Text(row.node.displayName)
                            .font(IDEAppearance.Typography.body)
                            .foregroundStyle(store.selectedID == row.node.id ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.foreground)
                        Spacer()
                        if row.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedID = row.node.id }
                    .onTapGesture(count: 2) { workspace.openCallHierarchyNode(row.node) }
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(IDEAppearance.Typography.body)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(IDEAppearance.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct IDECallHierarchyTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(title)
                    .lineLimit(1)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

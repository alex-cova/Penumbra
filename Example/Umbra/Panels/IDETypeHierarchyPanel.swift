import EditorIntelligence
import Observation
import SwiftUI

/// What the Type Hierarchy tab shows: one type and its supertype or subtype tree, expanded a level
/// at a time (a subtype expansion scans the project's classes, so nothing is computed until asked).
@MainActor
@Observable
final class IDETypeHierarchyStore {
    enum Direction: String, CaseIterable, Identifiable {
        case supertypes = "Supertypes"
        case subtypes = "Subtypes"

        var id: String { rawValue }
    }

    /// Whose hierarchy the tab shows: a type's, or a method's (the same tree over the classes that
    /// declare it, each marked by what it does with it).
    enum Kind {
        case type
        case method

        var title: String { self == .type ? "Type Hierarchy" : "Method Hierarchy" }
    }

    struct Row: Identifiable {
        let node: HierarchyItem
        let depth: Int
        let isExpanded: Bool
        let isLoading: Bool
        /// `false` once a node is known to have no children in the current direction.
        let canExpand: Bool

        var id: String { node.id }
    }

    typealias Loader = @MainActor (HierarchyItem, Direction, HierarchyScope, URL?) async -> [HierarchyItem]

    private(set) var root: HierarchyItem?
    /// A line shown instead of a tree, e.g. when the caret is not in a type.
    private(set) var message: String?
    private(set) var direction: Direction = .supertypes
    private(set) var kind: Kind = .type
    /// Which of the project's classes a subtype search covers.
    private(set) var scope: HierarchyScope = .all
    /// The language the hierarchy was asked for. Its nodes carry that language's own records, so
    /// expanding or opening one goes back to the provider that made it, even if the active editor
    /// has since switched to another language.
    private(set) var languageIdentifier: String?
    /// The file the hierarchy was asked from, which decides the source set that scopes lookups.
    private(set) var file: URL?
    var selectedID: String?

    @ObservationIgnored var loader: Loader?
    private var children: [String: [HierarchyItem]] = [:]
    private var expanded: Set<String> = []
    private var loading: Set<String> = []
    /// Bumped whenever the tree is replaced, so a slow load for the old tree is dropped.
    private var generation = 0

    /// Whether the tab has anything to show.
    var hasContent: Bool { root != nil || message != nil }

    /// The visible rows, depth first.
    var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        func visit(_ node: HierarchyItem, depth: Int) {
            let isExpanded = expanded.contains(node.id)
            let known = children[node.id]
            result.append(Row(
                node: node, depth: depth, isExpanded: isExpanded, isLoading: loading.contains(node.id),
                canExpand: known?.isEmpty != true
            ))
            if isExpanded, let known {
                for child in known { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }

    /// Shows `root` and expands its first level. A method hierarchy starts from the topmost
    /// declaration, so it opens downward.
    func show(root: HierarchyItem, file: URL?, kind: Kind = .type, languageIdentifier: String? = nil) {
        self.root = root
        self.file = file
        self.kind = kind
        self.languageIdentifier = languageIdentifier
        if kind == .method { direction = .subtypes }
        message = nil
        resetTree()
        selectedID = root.id
        expand(root)
    }

    func show(message: String) {
        root = nil
        self.message = message
        resetTree()
    }

    func clear() {
        root = nil
        message = nil
        resetTree()
    }

    func setDirection(_ newDirection: Direction) {
        guard newDirection != direction else { return }
        direction = newDirection
        guard let root else { return }
        resetTree()
        expand(root)
    }

    func setScope(_ newScope: HierarchyScope) {
        guard newScope != scope else { return }
        scope = newScope
        guard let root else { return }
        resetTree()
        expand(root)
    }

    /// A copy of what the tab shows now, with its own expansion state, for Pin Tab.
    func copy() -> IDETypeHierarchyStore {
        let copy = IDETypeHierarchyStore()
        copy.root = root
        copy.message = message
        copy.direction = direction
        copy.kind = kind
        copy.scope = scope
        copy.languageIdentifier = languageIdentifier
        copy.file = file
        copy.loader = loader
        copy.children = children
        copy.expanded = expanded
        copy.selectedID = selectedID
        return copy
    }

    func toggle(_ node: HierarchyItem) {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expand(node)
        }
    }

    func node(withID id: String) -> HierarchyItem? {
        rows.first { $0.id == id }?.node
    }

    /// Moves the selection by `delta` visible rows.
    func moveSelection(by delta: Int) {
        let visible = rows
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? -1
        selectedID = visible[min(max(0, current + delta), visible.count - 1)].id
    }

    private func resetTree() {
        generation += 1
        children = [:]
        expanded = []
        loading = []
        selectedID = root?.id
    }

    private func expand(_ node: HierarchyItem) {
        expanded.insert(node.id)
        guard children[node.id] == nil, !loading.contains(node.id), let loader else { return }
        loading.insert(node.id)
        let token = generation
        let direction = direction
        let scope = scope
        let file = file
        Task { [weak self] in
            let loaded = await loader(node, direction, scope, file)
            guard let self, self.generation == token else { return }
            self.children[node.id] = loaded
            self.loading.remove(node.id)
        }
    }
}

/// The bottom panel's Type Hierarchy tab: a Supertypes/Subtypes switch over an expandable tree.
/// Double-click or Return opens the selected type's declaration.
struct IDETypeHierarchyPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var isFocused: Bool

    var body: some View {
        let store = workspace.visibleTypeHierarchy
        VStack(spacing: 0) {
            if !workspace.pinnedTypeHierarchies.isEmpty {
                IDEHierarchyPinStrip(
                    pins: workspace.pinnedTypeHierarchies.map { ($0.id, $0.title) },
                    selected: workspace.selectedTypeHierarchyPinID,
                    onSelect: { workspace.selectedTypeHierarchyPinID = $0 },
                    onUnpin: { workspace.unpinTypeHierarchy($0) }
                )
                Divider()
            }
            if let root = store.root {
                header(store, root: root)
                Divider()
                tree(store)
            } else {
                emptyState(store.message ?? "Place the caret in a type and press ⌃H, or in a method and press ⇧⌘H")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ store: IDETypeHierarchyStore, root: HierarchyItem) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Picker("Direction", selection: Binding(
                get: { store.direction },
                set: { store.setDirection($0) }
            )) {
                ForEach(IDETypeHierarchyStore.Direction.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            IDEHierarchyScopeMenu(scope: store.scope, isEnabled: store.direction == .subtypes) { store.setScope($0) }

            Text(store.kind == .method ? "\(store.kind.title): \(root.name)" : root.name)
                .font(IDEAppearance.Typography.body.weight(.medium))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer()
            Button {
                workspace.pinTypeHierarchy()
            } label: {
                Image(systemName: "pin")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Pin Tab: keep this hierarchy when the next one opens")
            .accessibilityLabel("Pin hierarchy")
            Button {
                workspace.closeTypeHierarchy()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Close Hierarchy")
            .accessibilityLabel("Close hierarchy")
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func tree(_ store: IDETypeHierarchyStore) -> some View {
        let rows = store.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    IDETypeHierarchyRowView(
                        row: row,
                        isSelected: store.selectedID == row.id,
                        onToggle: { store.toggle(row.node) },
                        onSelect: {
                            store.selectedID = row.id
                            isFocused = true
                        },
                        onOpen: { workspace.openTypeHierarchyNode(row.node, in: store) }
                    )
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            if let id = store.selectedID, let node = store.node(withID: id) { workspace.openTypeHierarchyNode(node, in: store) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            store.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            store.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if let id = store.selectedID, let row = rows.first(where: { $0.id == id }), !row.isExpanded { store.toggle(row.node) }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if let id = store.selectedID, let row = rows.first(where: { $0.id == id }), row.isExpanded { store.toggle(row.node) }
            return .handled
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 18))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct IDETypeHierarchyRowView: View {
    let row: IDETypeHierarchyStore.Row
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            Button(action: onToggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                    .opacity(row.canExpand ? 1 : 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .disabled(!row.canExpand)
            .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")

            Image(systemName: kindSymbol)
                .font(.system(size: 11))
                .foregroundStyle((row.node.origin == .project) ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(row.node.name)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            if !row.node.detail.isEmpty {
                Text(row.node.detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            if let badge {
                Text(badge)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.horizontal, 4)
                    .background(IDEAppearance.ColorToken.tabInactive, in: RoundedRectangle(cornerRadius: 3))
            }
            if row.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, 2)
        .background(isSelected ? IDEAppearance.ColorToken.tabActive : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.node.name), \(kindName)")
        .accessibilityAddTraits(.isButton)
    }

    private var kindSymbol: String {
        switch row.node.kind {
        case .classType: return "c.square"
        case .interfaceType: return "i.square"
        case .enumType: return "e.square"
        case .recordType: return "r.square"
        case .annotationType: return "at"
        case .method: return "m.square"
        }
    }

    private var kindName: String {
        switch row.node.kind {
        case .classType: return "class"
        case .interfaceType: return "interface"
        case .enumType: return "enum"
        case .recordType: return "record"
        case .annotationType: return "annotation"
        case .method: return "method"
        }
    }

    private var badge: String? { row.node.badge }
}

/// The Type Hierarchy tab in the bottom panel's tab strip.
struct IDETypeHierarchyTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text(title)
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected { return IDEAppearance.ColorToken.tabActive }
        if isHovering { return IDEAppearance.ColorToken.tabHover }
        return IDEAppearance.ColorToken.tabInactive
    }
}

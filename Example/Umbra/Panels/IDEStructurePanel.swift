import EditorIntelligence
import SwiftUI

/// The sidebar's Structure tab, listing the type at the caret and its members.
struct IDEStructurePanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var isFocused: Bool

    var body: some View {
        let store = workspace.structureStore
        VStack(alignment: .leading, spacing: 0) {
            if let root = store.root {
                tree(store, root: root)
            } else {
                emptyState(store.message ?? "No outline for this file")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }

    private func tree(_ store: IDEStructureStore, root: StructureNode) -> some View {
        let rows = store.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    IDEStructureRowView(
                        row: row,
                        isSelected: store.selectedID == row.id,
                        onToggle: { store.toggle(row.node) },
                        onSelect: {
                            store.select(row.id)
                            isFocused = true
                            workspace.selectStructureNode(row.node)
                        }
                    )
                    .contextMenu {
                        // A test class or test method runs or debugs from here, as in IntelliJ.
                        if let target = workspace.structureTestTarget(for: row.node) {
                            Button("Run ‘\(target.title)’") { workspace.runTests(scope: target.scope, title: target.title) }
                            Button("Debug ‘\(target.title)’") { workspace.debugTests(scope: target.scope, title: target.title) }
                        }
                    }
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            if let id = store.selectedID, let node = store.node(withID: id) {
                workspace.selectStructureNode(node)
            }
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
            if let id = store.selectedID, let row = rows.first(where: { $0.id == id }), !row.isExpanded {
                store.toggle(row.node)
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if let id = store.selectedID, let row = rows.first(where: { $0.id == id }), row.isExpanded {
                store.toggle(row.node)
            }
            return .handled
        }
        .accessibilityLabel("Structure of \(root.title)")
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 18))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

private struct IDEStructureRowView: View {
    let row: IDEStructureStore.Row
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovering = false

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
                .foregroundStyle(kindTint)
                .frame(width: 14)

            Text(row.node.title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.node.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: some View {
        Group {
            if isSelected {
                IDEAppearance.ColorToken.tabActive
            } else if isHovering {
                IDEAppearance.ColorToken.controlHover
            } else {
                Color.clear
            }
        }
    }

    private var kindSymbol: String { row.node.kind.iconSystemName }

    private var kindTint: Color { Color(nsColor: row.node.kind.iconTint) }
}

#Preview {
    IDEStructurePanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.structureStore.show(
                root: StructureNode(
                    id: "type-0",
                    title: "Outer<T>",
                    kind: .type,
                    nameRange: 0..<5,
                    bodyRange: 0..<100,
                    children: [
                        StructureNode(
                            id: "field-10",
                            title: "field: int",
                            kind: .field,
                            nameRange: 10..<15,
                            bodyRange: 10..<20
                        ),
                        StructureNode(
                            id: "method-30",
                            title: "top()",
                            kind: .method,
                            nameRange: 30..<33,
                            bodyRange: 30..<50
                        )
                    ]
                ),
                selectedID: "field-10"
            )
            return workspace
        }())
        .frame(width: 220, height: 320)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}

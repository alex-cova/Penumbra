import JavaIntelligence
import SwiftUI

/// Left tool window listing the Java type at the caret and its members.
struct IDEJavaStructurePanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @FocusState private var isFocused: Bool

    var body: some View {
        let store = workspace.javaStructure
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)

            if let root = store.root {
                tree(store, root: root)
            } else {
                emptyState(store.message ?? "Open a Java file")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private var header: some View {
        Text("Structure")
            .font(IDEAppearance.Typography.sidebarHeader)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func tree(_ store: IDEJavaStructureStore, root: JavaStructureNode) -> some View {
        let rows = store.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    IDEJavaStructureRowView(
                        row: row,
                        isSelected: store.selectedID == row.id,
                        onToggle: { store.toggle(row.node) },
                        onSelect: {
                            store.select(row.id)
                            isFocused = true
                            workspace.selectStructureNode(row.node)
                        }
                    )
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

private struct IDEJavaStructureRowView: View {
    let row: IDEJavaStructureStore.Row
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

    private var kindSymbol: String {
        switch row.node.kind {
        case .type: return "c.circle.fill"
        case .field: return "f.circle.fill"
        case .method, .constructor: return "m.circle.fill"
        case .enumConstant: return "e.circle.fill"
        case .recordComponent: return "r.circle.fill"
        }
    }

    private var kindTint: Color {
        switch row.node.kind {
        case .type: return .blue
        case .field: return .purple
        case .method, .constructor: return .orange
        case .enumConstant: return .green
        case .recordComponent: return .teal
        }
    }
}

#Preview {
    IDEJavaStructurePanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.javaStructure.show(
                root: JavaStructureNode(
                    id: "type-0",
                    title: "Outer<T>",
                    kind: .type,
                    nameByteRange: 0..<5,
                    bodyByteRange: 0..<100,
                    children: [
                        JavaStructureNode(
                            id: "field-10",
                            title: "field: int",
                            kind: .field,
                            nameByteRange: 10..<15,
                            bodyByteRange: 10..<20
                        ),
                        JavaStructureNode(
                            id: "method-30",
                            title: "top()",
                            kind: .method,
                            nameByteRange: 30..<33,
                            bodyByteRange: 30..<50
                        )
                    ]
                ),
                selectedID: "field-10"
            )
            return workspace
        }())
        .frame(width: 220, height: 320)
        .preferredColorScheme(.dark)
}

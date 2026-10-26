import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The model's checklist, under the header: collapsed to its progress, expandable to the items.
struct IDEAgentTodoListView: View {
    let items: [TodoItem]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEDisclosureChevron(
                        isExpanded: isExpanded,
                        size: IDEAppearance.IconSize.breadcrumbChevron
                    )
                    Text("Checklist")
                    Text("\(items.filter { $0.status == .completed }.count)/\(items.count)")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Spacer(minLength: 0)
                }
                .font(IDEAppearance.Typography.sectionHeader)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    IDEAgentTodoRow(item: item)
                }
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card.opacity(IDEAppearance.Opacity.dimmed))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checklist, \(items.filter { $0.status == .completed }.count) of \(items.count) done")
    }

}

/// One item of the model's checklist: shared by the strip under the header and the Plan tab.
struct IDEAgentTodoRow: View {
    let item: TodoItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: Self.symbol(item.status))
                .foregroundStyle(item.status == .inProgress ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(item.content)
                .strikethrough(item.status == .completed)
                .foregroundStyle(item.status == .completed ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(IDEAppearance.Typography.caption)
    }

    private static func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        }
    }
}

// MARK: - Empty state, disclosure, settings

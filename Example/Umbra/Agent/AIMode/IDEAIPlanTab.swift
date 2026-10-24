import AgentKit
import SwiftUI

/// The selected chat's plan and checklist, kept in view while the conversation scrolls: the checklist
/// the model keeps with its `todo` tool, with progress, and the latest plan it proposed in Plan mode
/// (approve it or ask for changes from here).
struct IDEAIPlanTab: View {
    @Environment(IDEWorkspace.self) private var workspace

    private var conversation: IDEAgentConversation { workspace.agent.selected }

    /// The newest `exit_plan_mode` call in the transcript.
    private var planEntry: IDEAgentEntry? {
        conversation.entries.last { $0.kind == .toolCall(name: "exit_plan_mode") && $0.planText != nil }
    }

    var body: some View {
        let todos = conversation.todos
        let plan = planEntry
        if todos.isEmpty && plan == nil {
            IDEAIInspectorEmptyState(
                symbol: "list.bullet.clipboard", title: "No plan yet",
                message: "Use /plan, or ⇧Tab in the message field, to have the agent plan before it changes anything. Its checklist appears here too.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    if !todos.isEmpty { checklist(todos) }
                    if let plan { IDEAgentPlanCard(entry: plan, isInInspector: true) }
                }
                .padding(IDEAppearance.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func checklist(_ items: [TodoItem]) -> some View {
        let done = items.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                Label("Checklist", systemImage: "checklist")
                    .font(IDEAppearance.Typography.sectionHeader)
                Spacer()
                Text("\(done)/\(items.count)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(IDEAppearance.ColorToken.accent)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                IDEAgentTodoRow(item: item)
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checklist, \(done) of \(items.count) done")
    }
}

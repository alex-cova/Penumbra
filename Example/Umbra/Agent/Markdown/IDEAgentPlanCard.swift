import AgentKit
import SwiftUI

extension IDEAgentEntry {
    /// The plan text of an `exit_plan_mode` call: what is waiting for a decision, else read from the call's arguments.
    var planText: String? {
        if let plan { return plan }
        return (try? JSONValue(parsing: text))?.objectValue?["plan"]?.stringValue
    }
}

/// The model's plan, with the user's decision: approve it (and in which mode), or keep planning.
struct IDEAgentPlanCard: View {
    let entry: IDEAgentEntry
    @Environment(IDEWorkspace.self) private var workspace
    @State private var isRevising = false
    @State private var feedback = ""

    private var agent: IDEAgentController { workspace.agent }
    private var isPending: Bool { entry.plan != nil && entry.output == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                Label("Plan", systemImage: "list.bullet.clipboard")
                    .font(IDEAppearance.Typography.sectionHeader)
                Spacer()
                if let outcome = entry.planOutcome {
                    Text(outcome)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            if let plan = entry.planText {
                ScrollView {
                    IDEAgentMarkdownView(text: plan)
                        .padding(IDEAppearance.Spacing.xs)
                }
                .frame(maxHeight: isPending ? 420 : 220)
            } else {
                Text("Writing the plan…")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if isPending { actions }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .strokeBorder(isPending ? Color.teal.opacity(0.6) : .clear))
    }

    @ViewBuilder private var actions: some View {
        if isRevising {
            TextField("What should change?", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .controlSize(.small)
                .onSubmit(sendFeedback)
            HStack {
                Button("Send Feedback", action: sendFeedback)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { isRevising = false }
                    .controlSize(.small)
                Spacer()
            }
        } else {
            HStack {
                Button("Approve · Accept Edits") { approve(.acceptEdits) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Carry the plan out; edits apply at once and commands ask")
                Button("Approve · Manual") { approve(.manual) }
                    .controlSize(.small)
                    .help("Carry the plan out, asking before every edit and command")
                Button("Keep Planning…") { isRevising = true }
                    .controlSize(.small)
                Spacer()
                if let plan = entry.planText {
                    Button {
                        workspace.agentOpenText(title: "Plan", text: plan)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the plan in an editor tab")
                    .accessibilityLabel("Open the plan in an editor tab")
                }
            }
        }
    }

    private func approve(_ mode: PermissionMode) {
        guard let callID = entry.callID else { return }
        agent.selected.approvePlan(callID: callID, mode: mode)
    }

    private func sendFeedback() {
        guard let callID = entry.callID else { return }
        agent.selected.revisePlan(callID: callID, feedback: feedback)
        isRevising = false
        feedback = ""
    }
}

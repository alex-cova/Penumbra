import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// "N files changed" for a run: each file opens in the diff viewer, and the whole run reverts.
struct IDEAgentChangesCard: View {
    let entry: IDEAgentEntry
    @Environment(IDEWorkspace.self) private var workspace

    private var agent: IDEAgentController { workspace.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                Label(
                    "\(entry.fileChanges.count) \(entry.fileChanges.count == 1 ? "file" : "files") changed",
                    systemImage: entry.isReverted ? "arrow.uturn.backward.circle" : "pencil.circle")
                    .font(IDEAppearance.Typography.sectionHeader)
                Spacer()
                if entry.isReverted {
                    Text("Reverted").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                } else {
                    Button("Revert Run") { agent.revert(entryID: entry.id) }
                        .controlSize(.small)
                        .disabled(agent.isRunning)
                        .help("Restore every file this run changed; files you edited afterwards are left alone")
                }
            }
            ForEach(entry.fileChanges) { change in
                let isConflict = entry.conflicts.contains { $0.path == change.path }
                Button {
                    agent.showDiff(for: change)
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Image(systemName: change.isCreation ? "plus.circle" : "doc.text")
                            .foregroundStyle(change.isCreation ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.gitModified)
                        Text(change.path)
                            .font(IDEAppearance.Typography.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if isConflict {
                            Text("changed since")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.error)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what changed")
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

/// The question on a command's card: what will run, where, why, and anything worth a second look.
struct IDEAgentApprovalView: View {
    let request: ApprovalRequest
    let decide: (ApprovalDecision) -> Void
    /// Approves this call and also changes what is asked from now on (an "always allow" rule, or Accept Edits).
    let approveWith: (IDEAgentConversation.ApprovalShortcut) -> Void

    @State private var command: String
    @State private var isEditing = false
    @State private var isDenying = false
    @State private var note = ""

    init(
        request: ApprovalRequest, decide: @escaping (ApprovalDecision) -> Void,
        approveWith: @escaping (IDEAgentConversation.ApprovalShortcut) -> Void
    ) {
        self.request = request
        self.decide = decide
        self.approveWith = approveWith
        _command = State(initialValue: request.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label(request.title, systemImage: request.diff == nil ? "terminal" : "doc.badge.gearshape")
                .font(IDEAppearance.Typography.sectionHeader)
            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let diff = request.diff {
                Text(request.command)
                    .font(IDEAppearance.Typography.monoSmall)
                    .textSelection(.enabled)
                IDEAgentDiffView(diff: diff)
            } else if isEditing {
                TextField("Command", text: $command, axis: .vertical)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(3...8)
                    .frame(minHeight: 54, maxHeight: 140)
                    .padding(IDEAppearance.Spacing.xs)
                    .background(IDEAppearance.ColorToken.editor)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            } else {
                Text(request.command)
                    .font(IDEAppearance.Typography.monoSmall)
                    .textSelection(.enabled)
                    .padding(IDEAppearance.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IDEAppearance.ColorToken.editor)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            }
            if let directory = request.workingDirectory {
                Text("in \(directory)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ForEach(request.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(request.notes, id: \.self) { text in
                Label(text, systemImage: "info.circle")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDenying {
                TextField("Tell the agent why or what to do instead (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { decide(.deny(note: note)) }
            }
            HStack {
                Button(request.diff == nil ? "Run" : "Apply") { decide(isEditing && command != request.command ? .approveEditing(command) : .approve) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if request.editableArgument != nil {
                    Button(isEditing ? "Done Editing" : "Edit…") { isEditing.toggle() }
                        .controlSize(.small)
                }
                alwaysAllowMenu
                Button(isDenying ? (request.diff == nil ? "Send Denial" : "Send Rejection") : (request.diff == nil ? "Deny…" : "Reject…")) {
                    if isDenying { decide(.deny(note: note)) } else { isDenying = true }
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
    }
}

extension IDEAgentApprovalView {
    private var suggestedRule: PermissionRule? { request.suggestedRule.flatMap(PermissionRule.init(parsing:)) }

    /// "git status:*" as the user thinks of it: "git status …".
    private func described(_ rule: PermissionRule) -> String {
        (rule.pattern ?? rule.tool).replacingOccurrences(of: ":*", with: " …")
    }

    @ViewBuilder fileprivate var alwaysAllowMenu: some View {
        if request.diff != nil {
            Menu("Always…") {
                Button("Accept all edits in this chat") { approveWith(.acceptEdits) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Apply this edit, and stop asking about edits in this chat")
        } else if let rule = suggestedRule {
            Menu("Always…") {
                Button("Allow “\(described(rule))” in this chat") { approveWith(.allowForChat(rule)) }
                Button("Always allow “\(described(rule))” in this project") { approveWith(.allowInProject(rule)) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Run this command, and stop asking about commands like it")
        }
    }
}

struct IDEAgentToolCard: View {
    let name: String
    let entry: IDEAgentEntry
    @Environment(IDEWorkspace.self) private var workspace
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                        .frame(width: 10)
                    Text(IDEAgentToolSummary.title(name: name, arguments: entry.text))
                        .font(IDEAppearance.Typography.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let outcome = entry.approvalOutcome ?? entry.questionOutcome ?? entry.elicitationOutcome {
                        Text(outcome)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(outcome == "Denied" || outcome == "Declined" ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    }
                    statusIcon
                }
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let request = entry.approval, entry.output == nil {
                Divider().overlay(IDEAppearance.ColorToken.border)
                IDEAgentApprovalView(
                    request: request,
                    decide: { workspace.agent.decide(callID: request.callID, $0) },
                    approveWith: { workspace.agent.selected.approve(callID: request.callID, shortcut: $0) })
            }

            if let question = entry.question, entry.output == nil {
                Divider().overlay(IDEAppearance.ColorToken.border)
                IDEAgentQuestionView(question: question) { answer in
                    workspace.agent.answer(callID: question.callID, text: answer)
                }
            }

            if let elicitation = entry.elicitation, entry.output == nil {
                Divider().overlay(IDEAppearance.ColorToken.border)
                IDEAgentQuestionView(
                    question: UserQuestion(
                        callID: elicitation.toolCallId ?? entry.callID ?? "",
                        question: elicitation.message.isEmpty ? elicitation.title : elicitation.message)
                ) { answer in
                    workspace.agent.answerElicitation(
                        callID: elicitation.toolCallId ?? entry.callID ?? "", text: answer)
                }
            }

            // A running command shows its output as it arrives; a finished one, in full on request.
            if isExpanded || (!entry.liveOutput.isEmpty && entry.output == nil) {
                Divider().overlay(IDEAppearance.ColorToken.border)
                Text(entry.liveOutput.isEmpty ? (entry.output?.text ?? "Running…") : entry.liveOutput)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(entry.output?.isError == true ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(IDEAppearance.Spacing.sm)
                    // A huge file read must not make the transcript heavy; the model got all of it.
                    .frame(maxHeight: 240)
            }
        }
        .background(IDEAppearance.ColorToken.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }

    @ViewBuilder private var statusIcon: some View {
        if let output = entry.output {
            Image(systemName: output.isError ? "xmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(output.isError ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// The model's `ask_user` question: suggested answers as buttons, a field for any other, and Skip.
struct IDEAgentQuestionView: View {
    let question: UserQuestion
    let answer: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label(question.question, systemImage: "questionmark.bubble")
                .font(IDEAppearance.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.self) { option in
                Button(option) { answer(option) }
                    .controlSize(.small)
            }
            HStack {
                TextField("Your answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Skip") { answer(nil) }
                    .controlSize(.small)
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.card)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer(trimmed)
    }
}

import AgentKit
import SwiftUI

/// Settings ▸ Agent ▸ Permissions: the rules in force, where each came from, and a way to add one or
/// to ask whether a command would run.
struct IDEAgentPermissionsSection: View {
    let mode: PermissionMode
    /// Owned here, so an error message survives the section being redrawn.
    @State private var model: IDEAgentPermissionsModel

    init(agent: IDEAgentController) {
        mode = agent.mode
        _model = State(initialValue: agent.makePermissionsModel())
    }

    @State private var draft = ""
    @State private var kind: PermissionRules.Kind = .allow
    @State private var scope: IDEAgentPermissionFiles.Scope = .project
    @State private var probe = ""
    @State private var probeResult: String?

    var body: some View {
        Section("Permissions") {
            Text("Rules decide what runs without asking, what always asks, and what never runs. Deny wins, then ask, then allow; a command that joins several with && or | must have every part allowed. Rules apply to edits and commands.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            if model.isEmpty {
                Text("No rules yet. “Always…” on an approval card adds one.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(model.groups.filter { !$0.entries.isEmpty }) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.origin.title)
                        .font(IDEAppearance.Typography.sectionHeader)
                    ForEach(group.entries) { entry in
                        HStack(spacing: IDEAppearance.Spacing.xs) {
                            Text(Self.label(entry.kind))
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(Self.tint(entry.kind))
                                .frame(width: 40, alignment: .leading)
                            Text(entry.rule.description)
                                .font(IDEAppearance.Typography.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            if entry.origin.isEditable {
                                Button {
                                    model.remove(entry)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove this rule")
                                .accessibilityLabel("Remove \(entry.rule.description)")
                            }
                        }
                    }
                }
            }

            HStack {
                TextField("Bash(npm test:*) or Edit(src/**)", text: $draft)
                    .font(IDEAppearance.Typography.monoSmall)
                    .onSubmit(add)
                Picker("", selection: $kind) {
                    Text("Allow").tag(PermissionRules.Kind.allow)
                    Text("Ask").tag(PermissionRules.Kind.ask)
                    Text("Deny").tag(PermissionRules.Kind.deny)
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $scope) {
                    Text("This project").tag(IDEAgentPermissionFiles.Scope.project)
                    Text("This Mac").tag(IDEAgentPermissionFiles.Scope.app)
                }
                .labelsHidden()
                .fixedSize()
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.error {
                Text(error)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }

            HStack {
                TextField("Try a command: would it run?", text: $probe)
                    .font(IDEAppearance.Typography.monoSmall)
                    .onSubmit(test)
                Button("Check", action: test)
                    .disabled(probe.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let probeResult {
                Text("In \(mode.title) mode: \(probeResult)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .onAppear { model.reload() }
    }

    private func add() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.add(text, kind: kind, scope: scope)
        if model.error == nil { draft = "" }
    }

    private func test() {
        let command = probe
        Task {
            let verdict = await model.verdict(forCommand: command, mode: mode)
            probeResult = IDEAgentPermissionsModel.describe(verdict)
        }
    }

    private static func label(_ kind: PermissionRules.Kind) -> String {
        switch kind {
        case .allow: "Allow"
        case .ask: "Ask"
        case .deny: "Deny"
        }
    }

    private static func tint(_ kind: PermissionRules.Kind) -> Color {
        switch kind {
        case .allow: IDEAppearance.ColorToken.gitAdded
        case .ask: IDEAppearance.ColorToken.muted
        case .deny: IDEAppearance.ColorToken.error
        }
    }
}

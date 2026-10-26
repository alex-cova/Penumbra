import SwiftUI

/// Choose a message to go back to, and what to undo: the conversation, the files the agent changed
/// since, or both. The chosen message returns to the message field.
struct IDEAgentRewindSheet: View {
    let agent: IDEAgentController
    let request: IDEAgentRewindRequest
    let dismiss: () -> Void

    @State private var selectedID: UUID?
    @State private var scope: IDEAgentRewind.Scope = .both
    @State private var isWorking = false

    private var targets: [IDEAgentRewindTarget] { agent.selected.rewindTargets }
    private var selected: IDEAgentRewindTarget? { targets.first { $0.id == (selectedID ?? request.entryID ?? targets.first?.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Rewind")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("Go back to just before one of your messages.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            if targets.isEmpty {
                Text("There is no earlier message to go back to. Messages from before the conversation was shortened cannot be reached.")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(targets) { target in
                            row(target)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(IDEAppearance.ColorToken.editor)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))

                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                    ForEach(IDEAgentRewind.Scope.allCases, id: \.self) { option in
                        Button {
                            scope = option
                        } label: {
                            HStack(alignment: .top, spacing: IDEAppearance.Spacing.sm) {
                                Image(systemName: scope == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(scope == option ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title).font(IDEAppearance.Typography.body)
                                    Text(option.detail)
                                        .font(IDEAppearance.Typography.caption)
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selected, scope != .conversation, selected.files > 0 {
                    Label(
                        "\(selected.files) \(selected.files == 1 ? "file" : "files") the agent changed since will be put back. Files you edited afterwards are left as they are.",
                        systemImage: "exclamationmark.triangle")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Fork from Here") {
                    guard let selected else { return }
                    let chat = agent.selected.id
                    Task {
                        await agent.fork(chat, before: selected.id)
                        dismiss()
                    }
                }
                .disabled(selected == nil || isWorking)
                .help("Continue from that point in a new tab and leave this chat as it is")
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Rewind") {
                    guard let selected else { return }
                    isWorking = true
                    Task {
                        await agent.selected.rewind(to: selected.id, scope: scope)
                        agent.composerFocusRequest += 1
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || isWorking || agent.selected.isRunning)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 460)
        .onAppear { selectedID = request.entryID ?? targets.first?.id }
    }

    private func row(_ target: IDEAgentRewindTarget) -> some View {
        let isSelected = target.id == selected?.id
        var parts: [String] = []
        if target.laterMessages > 0 { parts.append("\(target.laterMessages) later \(target.laterMessages == 1 ? "message" : "messages")") }
        if target.files > 0 { parts.append("\(target.files) \(target.files == 1 ? "file" : "files") changed") }
        let detail = parts.joined(separator: " · ")
        return Button {
            selectedID = target.id
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.text)
                    .font(IDEAppearance.Typography.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !detail.isEmpty {
                    Text(detail)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .background(isSelected ? IDEAppearance.ColorToken.controlHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

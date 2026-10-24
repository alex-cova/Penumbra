import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

struct IDEAgentEntryView: View {
    let entry: IDEAgentEntry

    var body: some View {
        switch entry.kind {
        case .user:
            IDEAgentUserRow(entry: entry)
        case .assistant:
            IDEAgentAssistantText(entry: entry)
        case .toolCall(let name) where name == "exit_plan_mode":
            IDEAgentPlanCard(entry: entry)
        case .toolCall(let name):
            IDEAgentToolCard(name: name, entry: entry)
        case .changes:
            IDEAgentChangesCard(entry: entry)
        case .notice:
            IDEAgentNoticeText(text: entry.text)
        case .error:
            IDEAgentErrorRow(entry: entry)
        }
    }
}

/// A failed send. Network failures offer Retry, which sends the same message again.
struct IDEAgentErrorRow: View {
    let entry: IDEAgentEntry
    @Environment(IDEWorkspace.self) private var workspace

    private var agent: IDEAgentController { workspace.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.canRetry {
                Button("Retry") { agent.retry() }
                    .controlSize(.small)
                    .disabled(agent.isRunning || agent.selected.isCompacting)
                    .help("Send this message again")
            }
            if entry.canResume {
                Button("Resume") { agent.resume() }
                    .controlSize(.small)
                    .disabled(agent.isRunning || agent.selected.isCompacting)
                    .help("Carry on from the last saved step")
            }
        }
    }
}

/// One of the user's messages, with Rewind and Fork when the pointer is over it.
struct IDEAgentUserRow: View {
    let entry: IDEAgentEntry
    @Environment(IDEWorkspace.self) private var workspace
    @State private var isHovering = false

    private var agent: IDEAgentController { workspace.agent }
    private var canGoBack: Bool { entry.itemIndex != nil && !agent.selected.isRunning }

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: .topTrailing) {
                if isHovering, canGoBack {
                    HStack(spacing: 2) {
                        control("arrow.uturn.backward", "Rewind to before this message…") {
                            agent.rewindRequest = IDEAgentRewindRequest(entryID: entry.id)
                        }
                        control("arrow.triangle.branch", "Fork a new chat from before this message") {
                            let chat = agent.selected.id
                            let entryID = entry.id
                            Task { await agent.fork(chat, before: entryID) }
                        }
                    }
                    .padding(IDEAppearance.Spacing.xs)
                }
            }
    }

    private func control(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 22, height: 20)
                .background(IDEAppearance.ColorToken.controlHover)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var content: some View {
        Group {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text(IDEAgentFormat.userMessage(entry.text))
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .textSelection(.enabled)
                if !entry.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.attachments, id: \.self) { attachment in
                            Label(attachment, systemImage: "paperclip")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let detail = entry.detail {
                    DisclosureGroup("What the agent was sent") {
                        Text(detail)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.card)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        }
    }
}

struct IDEAgentEmptyState: View {
    let settings: IDEAgentSettings
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("Ask about this project")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text("The agent reads and searches the project, edits files, runs builds and tests, and checks problems. Edits apply right away and Revert Run undoes a whole run; every command asks you first.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
            if let hint = settings.setupHint {
                Text(hint)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .multilineTextAlignment(.center)
                Button("Agent Settings…", action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IDEAgentDisclosureCard: View {
    let settings: IDEAgentSettings
    /// The provider whose endpoint is being accepted; the global one when not given.
    var provider: IDEAgentProvider?

    var body: some View {
        let provider = provider ?? settings.provider
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label("Your code leaves this Mac", systemImage: "network")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("When you send a message, file contents the agent reads and the editor's problems are sent to \(settings.endpointHost(for: provider)). Nothing is sent before then.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Sending to \(settings.endpointHost(for: provider))") { settings.acceptDisclosure(for: provider) }
                .controlSize(.small)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

/// One assistant message: plain text while it streams, Markdown blocks once it is complete. Shared by
/// the agent's transcript and the Chat tab's.
struct IDEAgentAssistantText: View {
    let entry: IDEAgentEntry

    var body: some View {
        Group {
            if entry.isStreaming {
                Text(entry.text)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .textSelection(.enabled)
            } else {
                IDEAgentMarkdownView(text: entry.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line the transcript says on its own behalf (a summary, a stop reason): small and muted.
struct IDEAgentNoticeText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

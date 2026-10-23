import AgentKit
import SwiftUI

/// Chat: a plain conversation. A greeting and a centered message field while the chat is empty; a
/// transcript above the field once it has begun. The model is picked under the field.
struct IDEAIChatView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var composerState = IDEAgentComposerState()
    @State private var composerHeight: CGFloat = 22
    @State private var acceptRequest = 0

    private var chat: IDEAIChatController { workspace.aiChat }
    private var conversation: IDEAIChatConversation { chat.selected }

    var body: some View {
        VStack(spacing: 0) {
            header
            if conversation.isEmpty {
                emptyGreeting
            } else {
                transcript
            }
            // One composer for both states: a field that moved between the empty greeting and
            // the transcript would be destroyed and recreated, dropping focus on the first send.
            composerColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { chat.composerFocusRequest += 1 }
        .onChange(of: chat.modelRequest) { workspace.isAIModelsPresented = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(conversation.isEmpty ? "New chat" : conversation.title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if conversation.usage.inputTokens + conversation.usage.outputTokens > 0 {
                Text("\(IDEAgentFormat.tokens(conversation.usage.inputTokens + conversation.usage.outputTokens)) tokens"
                    + (conversation.cost.map { " · ~" + IDEAgentPrices.format($0) } ?? ""))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Input \(conversation.usage.inputTokens) (\(conversation.usage.cachedInputTokens) cached), output \(conversation.usage.outputTokens)"
                        + (conversation.cost == nil ? "" : "\nCost is an estimate from the price table in Settings ▸ Agent."))
            }
            IDEAgentIconButton(
                systemImage: "square.and.arrow.up", help: "Export Chat as Markdown…", isDisabled: conversation.isEmpty
            ) { exportChat() }
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
    }

    private func exportChat() {
        let title = conversation.title
        IDEAgentController.presentSavePanel(
            name: IDEAgentTranscriptExport.fileName(for: title),
            text: IDEAgentTranscriptExport.markdown(title: title, entries: conversation.entries))
    }

    // MARK: - Empty state

    /// The greeting above the composer while the chat is empty. The composer itself lives outside
    /// this branch so the field keeps focus when the first message is sent.
    private var emptyGreeting: some View {
        VStack(spacing: IDEAppearance.Spacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: "bubbles.and.sparkles")
                .font(.system(size: 28))
                .foregroundStyle(IDEAppearance.ColorToken.accent)
            Text("What's on your mind?")
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            if let hint = conversation.setupHint {
                IDEAISetupButton(hint: hint) { workspace.requestAIModelSetup(for: .chat) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript

    private static let bottomID = "chat-bottom"

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    ForEach(conversation.entries) { entry in
                        IDEAIChatMessageView(entry: entry, retry: conversation.retry).id(entry.id)
                    }
                    if let status = conversation.status {
                        HStack(spacing: IDEAppearance.Spacing.xs) {
                            IDEATypingDots()
                            Text(status)
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: IDEAIChatView.columnWidth)
                .padding(IDEAppearance.Spacing.md)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.entries.count) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: conversation.entries.last?.text) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: conversation.id) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    // MARK: - Composer

    /// With no usable model, Send asks for one instead of doing nothing.
    private func send() {
        if conversation.setupHint != nil, !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspace.requestAIModelSetup(for: .chat)
        } else {
            chat.submit()
        }
    }

    /// Long lines stay readable.
    static let columnWidth: CGFloat = 760

    private var composerColumn: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !conversation.hasConsent {
                IDEAIChatDisclosureCard(settings: workspace.agent.settings, provider: conversation.effectiveChoice.provider)
            }
            if composerState.isShowingSuggestions {
                IDEAgentSuggestionList(state: composerState) { index in
                    composerState.selectedIndex = index
                    acceptRequest += 1
                }
            }
            VStack(spacing: IDEAppearance.Spacing.xs) {
                @Bindable var conversation = conversation
                HStack(alignment: .bottom, spacing: IDEAppearance.Spacing.sm) {
                    IDEAgentComposerField(
                        text: $conversation.draft, height: $composerHeight,
                        placeholder: "Message the model",
                        state: composerState, focusRequest: chat.composerFocusRequest, acceptRequest: acceptRequest,
                        suggestions: { chat.suggestions(for: $0) },
                        onSend: send,
                        onStop: { conversation.stop() },
                        onAccept: { chat.perform($0) })
                        .frame(height: composerHeight)
                    if conversation.isRunning {
                        IDEAgentIconButton(
                            systemImage: "stop.fill", help: "Stop", tint: IDEAppearance.ColorToken.error, action: conversation.stop)
                    } else {
                        IDEAgentIconButton(
                            systemImage: "arrow.up.circle.fill", help: "Send", tint: IDEAppearance.ColorToken.accent,
                            isDisabled: !conversation.canSend, action: send)
                    }
                }
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Spacer(minLength: 0)
                    if let fraction = conversation.contextFraction {
                        IDEAgentContextMeter(
                            fraction: fraction, tokens: conversation.contextTokens ?? 0,
                            window: workspace.agent.settings.contextWindow(for: conversation.effectiveChoice) ?? 0,
                            isBusy: conversation.isRunning
                        ) {
                            let target = conversation
                            Task { await target.compact() }
                        }
                    }
                    IDEAIModelPicker(
                        settings: workspace.agent.settings, choice: conversation.effectiveChoice, mode: .chat,
                        onSelect: { workspace.selectAIModel($0, for: .chat) }, onManage: { workspace.isAIModelsPresented = true })
                }
            }
            .padding(IDEAppearance.Spacing.sm)
            .background(IDEAppearance.ColorToken.card)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                    .stroke(IDEAppearance.ColorToken.border, lineWidth: 1))
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.bottom, IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity)
    }
}

/// One message: yours in a card, the model's as Markdown, and what went wrong as a line of red text.
private struct IDEAIChatMessageView: View {
    let entry: IDEAgentEntry
    let retry: () -> Void

    var body: some View {
        switch entry.kind {
        case .user:
            // Yours hugs the trailing edge, as in a chat app; the model's stays full-width.
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 48)
                Text(entry.text)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .textSelection(.enabled)
                    .padding(IDEAppearance.Spacing.sm)
                    .background(IDEAppearance.ColorToken.card)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
                    .accessibilityLabel("You: \(entry.text)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            // Plain text while it streams; Markdown once the message is complete.
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
        case .notice:
            Text(entry.text)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Label(entry.text, systemImage: "exclamationmark.triangle")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
                if entry.canRetry { Button("Retry", action: retry).controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .toolCall, .changes:
            EmptyView()
        }
    }
}

/// The first message to a remote endpoint needs the user's say-so, as in Code.
private struct IDEAIChatDisclosureCard: View {
    let settings: IDEAgentSettings
    let provider: IDEAgentProvider

    var body: some View {
        let host = settings.endpointHost(for: provider)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label("Your messages leave this Mac", systemImage: "network")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("What you write in this chat is sent to \(host) when you send it. Nothing is sent before then.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Sending to \(host)") { settings.acceptDisclosure(for: provider) }
                .controlSize(.small)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

// MARK: - The list

/// Sidebar rows for Chat: the open chats, then the saved ones they do not already show.
struct IDEAIChatList: View {
    @Environment(IDEWorkspace.self) private var workspace
    let query: String
    @State private var renaming: IDEAIChatConversation?
    @State private var renameDraft = ""
    @State private var isRenamingPresented = false

    private var chat: IDEAIChatController { workspace.aiChat }

    private var openChats: [IDEAIChatConversation] {
        let live = chat.conversations.filter { !$0.isEmpty || $0.isRunning }
        guard !query.isEmpty else { return live }
        return live.filter { !IDEAgentHistorySearch.rank([SessionSummary(id: $0.id, title: $0.title, updatedAt: Date())], query: query, requiresMatch: true).isEmpty }
    }

    private var savedRows: [SessionSummary] {
        let open = Set(chat.conversations.map(\.conversationID))
        return IDEAgentHistorySearch.rank(chat.history.filter { !open.contains($0.id) }, query: query, requiresMatch: !query.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(openChats) { conversation in
                IDEAISidebarRow(
                    title: conversation.title, isSelected: conversation.id == chat.selectedID,
                    status: conversation.isRunning ? .running : (conversation.isUnread ? .unread : .none),
                    action: { chat.select(conversation.id) }
                )
                .contextMenu {
                    Button("Rename…") {
                        renameDraft = conversation.title
                        renaming = conversation
                        isRenamingPresented = true
                    }
                    if !conversation.isRunning { Button("Close") { chat.close(conversation.id) } }
                }
            }
            ForEach(savedRows) { row in
                IDEAISidebarRow(title: row.title, isSelected: false, action: { chat.resume(row.id) })
                    .help(row.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .contextMenu { Button("Delete", role: .destructive) { chat.delete(row.id) } }
            }
            if openChats.isEmpty && savedRows.isEmpty {
                Text(query.isEmpty ? "No chats yet" : "No chats match “\(query)”.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
        .alert("Rename Chat", isPresented: $isRenamingPresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renaming { chat.rename(renaming.id, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the first message.")
        }
    }
}

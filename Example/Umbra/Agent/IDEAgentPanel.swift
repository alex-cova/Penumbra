import AgentKit
import AgentKitMLX
import LocalModelStore
import SwiftUI

/// The agent tool window: transcript, tool-call cards, composer and the settings sheet.
struct IDEAgentPanel: View {
    let agent: IDEAgentController
    var placement: IDEAgentPlacement = .docked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettingsPresented = false
    @State private var isHistoryPresented = false
    @State private var lastEscape: Date?
    @State private var composerState = IDEAgentComposerState()
    @State private var composerHeight: CGFloat = 22
    @State private var acceptRequest = 0

    private var settings: IDEAgentSettings { agent.settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            if agent.conversations.count > 1 { IDEAgentTabsBar(agent: agent) }
            if !agent.todos.isEmpty { IDEAgentTodoListView(items: agent.todos) }
            transcript
            Divider().overlay(IDEAppearance.ColorToken.border)
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(placement == .page ? Color.clear : IDEAppearance.ColorToken.panel)
        .sheet(isPresented: $isSettingsPresented) {
            IDEAgentSettingsSheet(settings: settings)
        }
        .sheet(item: Bindable(agent).rewindRequest) { request in
            IDEAgentRewindSheet(agent: agent, request: request) { agent.rewindRequest = nil }
        }
        .onChange(of: agent.settingsRequest) { isSettingsPresented = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            headerTitle

            if agent.usage.inputTokens + agent.usage.outputTokens > 0 {
                Text("\(IDEAgentFormat.tokens(agent.usage.inputTokens + agent.usage.outputTokens)) tokens"
                    + (agent.cost.map { " · ~" + IDEAgentPrices.format($0) } ?? ""))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Input \(agent.usage.inputTokens) (\(agent.usage.cachedInputTokens) cached), output \(agent.usage.outputTokens)"
                        + (agent.cost == nil ? "" : "\nCost is an estimate from the price table in Settings ▸ Agent."))
                    .padding(.trailing, IDEAppearance.Spacing.xs)
            }
            IDEAgentIconButton(systemImage: "square.and.pencil", help: "New Chat (⌥⌘T)", isDisabled: agent.entries.isEmpty && !agent.isRunning) {
                agent.newConversation()
            }
            IDEAgentIconButton(systemImage: "clock.arrow.circlepath", help: "Earlier Chats", isActive: isHistoryPresented) {
                isHistoryPresented.toggle()
            }
            .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                IDEAgentHistoryPopover(agent: agent) { isHistoryPresented = false }
            }
            .onAppear { agent.restoreLatestIfNeeded() }
            if placement == .docked {
                IDEAgentIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand over the editor") {
                    expandOverEditor()
                }
            }
            IDEAgentIconButton(systemImage: "gearshape", help: "Agent Settings", isActive: isSettingsPresented) {
                isSettingsPresented = true
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    @ViewBuilder private var headerTitle: some View {
        if placement == .docked {
            IDEPanelTitle("Agent")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if agent.conversations.count < 2 {
            Text(agent.selected.title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func expandOverEditor() {
        if reduceMotion {
            settings.opensAsPage = true
        } else {
            withAnimation(.easeOut(duration: 0.15)) { settings.opensAsPage = true }
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        if agent.entries.isEmpty {
            IDEAgentEmptyState(settings: settings, openSettings: { isSettingsPresented = true })
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                        ForEach(agent.entries) { entry in
                            IDEAgentEntryView(entry: entry).id(entry.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(IDEAppearance.Spacing.md)
                }
                .onChange(of: agent.entries.count) { scrollToBottom(proxy) }
                .onChange(of: agent.entries.last?.text) { scrollToBottom(proxy) }
            }
        }
    }

    private static let bottomID = "agent-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !settings.hasAcceptedDisclosure {
                IDEAgentDisclosureCard(settings: settings)
            }
            if let status = agent.status {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            if !agent.selected.queue.isEmpty {
                IDEAgentQueuedMessages(queue: agent.selected.queue) { agent.selected.removeQueued($0) }
            }
            if composerState.isShowingSuggestions {
                IDEAgentSuggestionList(state: composerState) { index in
                    composerState.selectedIndex = index
                    acceptRequest += 1
                }
            }
            HStack(alignment: .bottom, spacing: IDEAppearance.Spacing.sm) {
                @Bindable var agent = agent
                IDEAgentComposerField(
                    text: $agent.draft, height: $composerHeight,
                    placeholder: agent.isRunning ? "Write what to do next; it is sent at the next step…" : "Ask about this project…",
                    state: composerState, focusRequest: agent.composerFocusRequest, acceptRequest: acceptRequest,
                    suggestions: { agent.suggestions(for: $0) },
                    onSend: { agent.submit() },
                    onStop: {
                        if agent.isRunning { agent.stop(); return }
                        // Esc twice in an empty field: go back to an earlier message.
                        guard agent.draft.isEmpty, !agent.selected.rewindTargets.isEmpty else { return }
                        if let last = lastEscape, Date().timeIntervalSince(last) < 0.6 {
                            lastEscape = nil
                            agent.rewindRequest = IDEAgentRewindRequest()
                        } else {
                            lastEscape = Date()
                        }
                    },
                    onCycleMode: { agent.selected.cycleMode() },
                    onAccept: { agent.perform($0) },
                    onUserEdit: { agent.selected.promptRecall.reset() },
                    onHistory: { agent.recallPrompt($0) },
                    onDropFiles: { urls in
                        urls.map { IDEAgentMentionToken.format(path: IDEAgentMentionPath.relative($0, root: agent.projectRoot)) }
                            .joined(separator: " ") + " "
                    }
                )
                .frame(height: composerHeight)
                .padding(IDEAppearance.Spacing.sm)
                .background(IDEAppearance.ColorToken.card)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))

                if agent.isRunning {
                    IDEAgentIconButton(
                        systemImage: "stop.fill", help: "Stop", tint: IDEAppearance.ColorToken.error, action: agent.stop)
                } else {
                    IDEAgentIconButton(
                        systemImage: "arrow.up.circle.fill", help: "Send", tint: IDEAppearance.ColorToken.accent,
                        isDisabled: agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: agent.submit)
                }
            }
            HStack {
                IDEAgentModeChip(mode: agent.mode) { agent.selected.setMode($0) }
                IDEAgentModelChip(settings: settings) { isSettingsPresented = true }
                Spacer(minLength: IDEAppearance.Spacing.sm)
                if let fraction = agent.selected.contextFraction {
                    IDEAgentContextMeter(
                        fraction: fraction, tokens: agent.selected.contextTokens ?? 0, window: settings.contextWindow ?? 0,
                        isBusy: agent.selected.isRunning || agent.selected.isCompacting
                    ) {
                        let chat = agent.selected
                        Task { await chat.compact(focus: nil) }
                    }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.xs)
        }
        .padding(IDEAppearance.Spacing.sm)
    }
}

/// Messages written while the agent works, waiting for its next step. ✕ takes one back.
private struct IDEAgentQueuedMessages: View {
    let queue: [IDEAgentConversation.QueuedMessage]
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(queue) { message in
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text(message.text)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        remove(message.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Take this message back")
                    .accessibilityLabel("Remove queued message")
                }
            }
            Text("Sent at the agent's next step")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

/// How full the model's window is: a ring and a percentage, turning orange and then red as it fills.
/// The menu summarizes the earlier conversation to make room.
private struct IDEAgentContextMeter: View {
    let fraction: Double
    let tokens: Int
    let window: Int
    let isBusy: Bool
    let compact: () -> Void

    private var tint: Color {
        switch fraction {
        case ..<0.75: IDEAppearance.ColorToken.muted
        case ..<0.9: .orange
        default: IDEAppearance.ColorToken.error
        }
    }

    var body: some View {
        Menu {
            Text("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in use")
            Button("Summarize the Earlier Conversation", action: compact)
                .disabled(isBusy)
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(IDEAppearance.ColorToken.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(tint)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in the model's window. Older messages are summarized automatically as it fills; /compact does it now.")
        .accessibilityLabel("Context window \(Int((fraction * 100).rounded())) percent full")
    }
}

/// The chat's permission mode. A menu to pick one; ⇧Tab in the message field walks through them.
private struct IDEAgentModeChip: View {
    let mode: PermissionMode
    let select: (PermissionMode) -> Void

    private var tint: Color {
        switch mode {
        case .manual: IDEAppearance.ColorToken.muted
        case .acceptEdits: IDEAppearance.ColorToken.accent
        case .auto: .orange
        case .plan: .teal
        }
    }

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { candidate in
                Button {
                    select(candidate)
                } label: {
                    Label(candidate.title, systemImage: candidate == mode ? "checkmark" : candidate.symbol)
                }
                .help(candidate.detail)
            }
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(mode.title): \(mode.detail)\nPress ⇧Tab in the message field to switch.")
        .accessibilityLabel("Permission mode: \(mode.title)")
    }
}

/// The model this chat uses. Opens agent settings, where the model and provider are chosen.
private struct IDEAgentModelChip: View {
    let settings: IDEAgentSettings
    let openSettings: () -> Void

    private var title: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? settings.provider.title : model
    }

    var body: some View {
        Button(action: openSettings) {
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 180)
        .help(settings.provider.title)
        .accessibilityLabel("Model: \(title)")
    }
}

// MARK: - Entries

private struct IDEAgentEntryView: View {
    let entry: IDEAgentEntry

    var body: some View {
        switch entry.kind {
        case .user:
            IDEAgentUserRow(entry: entry)
        case .assistant:
            // Plain text while it streams; Markdown blocks once the message is complete.
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
        case .toolCall(let name) where name == "exit_plan_mode":
            IDEAgentPlanCard(entry: entry)
        case .toolCall(let name):
            IDEAgentToolCard(name: name, entry: entry)
        case .changes:
            IDEAgentChangesCard(entry: entry)
        case .notice:
            Text(entry.text)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            IDEAgentErrorRow(entry: entry)
        }
    }
}

/// A failed send. Network failures offer Retry, which sends the same message again.
private struct IDEAgentErrorRow: View {
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
        }
    }
}

/// One of the user's messages, with Rewind and Fork when the pointer is over it.
private struct IDEAgentUserRow: View {
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

/// "N files changed" for a run: each file opens in the diff viewer, and the whole run reverts.
private struct IDEAgentChangesCard: View {
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

/// A unified diff, additions and removals tinted, in a box of bounded height so a large edit
/// doesn't push the buttons out of view.
private struct IDEAgentDiffView: View {
    let diff: String

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let tint: Color?
    }

    private var lines: [Line] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let text = String(raw)
            let tint: Color? = if text.hasPrefix("+++") || text.hasPrefix("---") { nil }
            else if text.hasPrefix("+") { Color.green.opacity(0.18) }
            else if text.hasPrefix("-") { Color.red.opacity(0.18) }
            else { nil }
            return Line(id: index, text: text, tint: tint)
        }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(line.text.hasPrefix("@@") ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.tint ?? .clear)
                }
            }
            .textSelection(.enabled)
            .padding(IDEAppearance.Spacing.xs)
        }
        .frame(maxHeight: 260)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }
}

/// The question on a command's card: what will run, where, why, and anything worth a second look.
private struct IDEAgentApprovalView: View {
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
                TextEditor(text: $command)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(minHeight: 54, maxHeight: 140)
                    .scrollContentBackground(.hidden)
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

private struct IDEAgentToolCard: View {
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
                    if let outcome = entry.approvalOutcome ?? entry.questionOutcome {
                        Text(outcome)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(outcome == "Denied" ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
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
private struct IDEAgentQuestionView: View {
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

/// The model's checklist, under the header: collapsed to its progress, expandable to the items.
private struct IDEAgentTodoListView: View {
    let items: [TodoItem]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                        .frame(width: 10)
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
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card.opacity(0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checklist, \(items.filter { $0.status == .completed }.count) of \(items.count) done")
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

private struct IDEAgentEmptyState: View {
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

private struct IDEAgentDisclosureCard: View {
    let settings: IDEAgentSettings

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label("Your code leaves this Mac", systemImage: "network")
                .font(IDEAppearance.Typography.sectionHeader)
            Text("When you send a message, file contents the agent reads and the editor's problems are sent to \(settings.endpointHost). Nothing is sent before then.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Sending to \(settings.endpointHost)") { settings.acceptDisclosure() }
                .controlSize(.small)
        }
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

/// Agent configuration from the chat, as a window sheet. Changes apply as they are edited.
/// Done and Escape close it.
private struct IDEAgentSettingsSheet: View {
    let settings: IDEAgentSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isModelsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Settings")
                    .font(IDEAppearance.Typography.titlebarTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(IDEAppearance.Spacing.md)
            Divider().overlay(IDEAppearance.ColorToken.border)
            IDEAgentSettingsView(settings: settings, width: nil, manageModels: { isModelsPresented = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 460, height: 560)
        .background(IDEAppearance.ColorToken.panel)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
        .onExitCommand { dismiss() }
        .sheet(isPresented: $isModelsPresented) {
            IDELocalModelsView(store: .shared, settings: settings)
                .preferredColorScheme(IDEAppearance.preferredColorScheme)
        }
    }
}

/// The agent's settings, in the panel's sheet (provider and behavior) and in Settings ▸ Agent
/// (also steps, context, environment, protected files and history).
struct IDEAgentSettingsView: View {
    let settings: IDEAgentSettings
    var agent: IDEAgentController?
    var isFullPane = false
    var width: CGFloat? = 380
    let manageModels: () -> Void
    @State private var keyDraft = ""
    @State private var isConfirmingClear = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Provider", selection: $settings.provider) {
                ForEach(IDEAgentProvider.allCases) { Text($0.title).tag($0) }
            }
            if settings.provider != .mlx {
                TextField("Base URL", text: $settings.baseURL)
                    .onSubmit { Task { await refreshModelsIfOllama() } }
            }

            switch settings.provider {
            case .ollama: ollamaSection(settings)
            case .mlx: mlxSection(settings)
            case .openAIResponses, .chatCompletions: TextField("Model", text: $settings.model)
            }

            Picker("Reasoning", selection: $settings.reasoningEffort) {
                ForEach(IDEAgentSettings.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Text(settings.provider == .openAIResponses || settings.provider == .chatCompletions
                ? "Use Off for models without reasoning; they reject the setting."
                : "Thinking makes each step slower. It applies to models that support it.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            Section("Behavior") {
                Picker("Mode for new chats", selection: $settings.mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(settings.mode.detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("Each chat can change its own with the chip under the message field, or ⇧Tab.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Toggle("Offer commands and skills from ~/.claude", isOn: $settings.loadsUserSkills)
                Text("Commands (/name) and skills are also read from .umbra and .claude in the project, and from Umbra's own folder. Turn this off if a sandboxed build cannot read your home folder.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            if isFullPane { advancedSections(settings) }

            if settings.provider != .mlx {
            Section(settings.requiresAPIKey ? "API key for \(settings.endpointHost)" : "API key (optional)") {
                SecureField(settings.hasAPIKey ? "Saved in the Keychain" : "Paste a key", text: $keyDraft)
                    .onSubmit(saveKey)
                HStack {
                    Button("Save Key", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove Key") { settings.removeAPIKey() }.disabled(!settings.hasAPIKey)
                }
                if let error = settings.keyError {
                    Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
                }
                if settings.isLocalEndpoint {
                    Label("This server runs on this Mac: nothing is sent elsewhere.", systemImage: "lock.shield")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            }
        }
        .formStyle(.grouped)
        .frame(width: width)
        .onChange(of: settings.baseURL) { settings.refreshKeyState() }
        .onChange(of: settings.provider) { Task { await refreshModelsIfOllama() } }
        .task { await refreshModelsIfOllama() }
    }

    @ViewBuilder private func advancedSections(_ settings: IDEAgentSettings) -> some View {
        @Bindable var settings = settings
        Section("Limits") {
            Picker("Steps per message", selection: $settings.iterationCap) {
                ForEach(Set(IDEAgentSettings.iterationCapChoices + [settings.iterationCap]).sorted(), id: \.self) { Text("\($0)").tag($0) }
            }
            Text("After this many model turns the run pauses; sending “continue” goes on.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if settings.provider == .openAIResponses || settings.provider == .chatCompletions {
                Picker("Context window", selection: $settings.contextWindowOverride) {
                    Text("Automatic").tag(0)
                    ForEach([32_768, 65_536, 131_072, 200_000, 400_000, 1_000_000], id: \.self) { Text(IDEAgentFormat.tokens($0)).tag($0) }
                }
                Text("Older tool output is cleared, then older messages summarized, as the conversation nears this size. Automatic knows common OpenAI models; for other models compaction starts when the server reports an overflow.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        if settings.provider == .openAIResponses || settings.provider == .chatCompletions {
            Section("Prices") {
                TextEditor(text: $settings.priceTableText)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(minHeight: 70, maxHeight: 130)
                HStack {
                    Button("Reset to Defaults") { settings.priceTableText = IDEAgentPrices.defaultText }
                        .disabled(settings.priceTableText == IDEAgentPrices.defaultText)
                }
                Text("US dollars per million tokens: model prefix, input, cached input, output. The panel shows an estimate for models listed here; the built-in rows are not checked against current prices. Local models show no cost.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        if let agent {
            IDEAgentPermissionsSection(agent: agent)
        }
        Section("Protected files") {
            TextEditor(text: $settings.secretFilePatternsText)
                .font(IDEAppearance.Typography.monoSmall)
                .frame(minHeight: 60, maxHeight: 120)
            Text("One glob per line, such as config/*.yaml or **/secrets/**. The agent will not read these or search inside them, in addition to .env files, private keys and keystores.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        Section("Command environment") {
            TextEditor(text: $settings.commandEnvironmentText)
                .font(IDEAppearance.Typography.monoSmall)
                .frame(minHeight: 60, maxHeight: 120)
            Text("One KEY=VALUE per line, added to the environment of commands the agent runs. A PATH entry goes in front of the usual path. Commands never inherit the app's environment.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        if let agent {
            Section("History") {
                Button("Clear History for This Project…", role: .destructive) { isConfirmingClear = true }
                    .confirmationDialog("Delete every saved agent conversation for this project?", isPresented: $isConfirmingClear) {
                        Button("Delete Conversations", role: .destructive) { agent.clearHistory() }
                    }
                Text("Conversations are saved on this Mac, in Application Support, so they can be resumed.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    @ViewBuilder private func ollamaSection(_ settings: IDEAgentSettings) -> some View {
        @Bindable var settings = settings
        HStack {
            Picker("Model", selection: $settings.model) {
                if settings.model.isEmpty { Text("Choose…").tag("") }
                ForEach(settings.ollamaModels) { model in
                    Text(IDEAgentOllamaLabel.title(model)).tag(model.name).disabled(!model.supportsTools)
                }
                if !settings.model.isEmpty, settings.selectedOllamaModel == nil { Text(settings.model).tag(settings.model) }
            }
            if settings.isLoadingOllamaModels {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await settings.refreshOllamaModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload the installed models")
            }
        }
        if let error = settings.ollamaError {
            Text(error).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        } else if let info = settings.selectedOllamaModel, !info.supportsTools {
            Text("This model does not support tool calling, so the agent cannot use it.")
                .font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        }
        Picker("Context", selection: $settings.localContextLength) {
            ForEach(IDEAgentSettings.contextChoices, id: \.self) { Text(IDEAgentFormat.tokens($0)).tag($0) }
        }
        Text("A larger window needs more memory and slows the first reply. The model's own maximum is \(settings.selectedOllamaModel?.contextLength.map(IDEAgentFormat.tokens) ?? "unknown"); the request uses \(IDEAgentFormat.tokens(settings.effectiveContextLength)).")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    @ViewBuilder private func mlxSection(_ settings: IDEAgentSettings) -> some View {
        @Bindable var settings = settings
        let store = IDELocalModelsStore.shared
        Picker("Model", selection: $settings.model) {
            if settings.model.isEmpty { Text("Choose…").tag("") }
            ForEach(store.installed) { model in
                let info = store.info(for: model)
                Text(LocalModelFormat.shortName(model.id) + (info.hasChatTemplate && !info.supportsTools ? " (no tool support)" : ""))
                    .tag(model.id)
                    .disabled(info.hasChatTemplate && !info.supportsTools)
            }
            if !settings.model.isEmpty, settings.selectedMLXModel == nil { Text(settings.model).tag(settings.model) }
        }
        Button("Manage On-Device Models…", action: manageModels)
        Label("Runs on this Mac's GPU. Nothing is sent anywhere.", systemImage: "lock.shield")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
        Picker("Context", selection: $settings.localContextLength) {
            ForEach(IDEAgentSettings.contextChoices, id: \.self) { Text(IDEAgentFormat.tokens($0)).tag($0) }
        }
        let status = MLXAvailability.currentStatus()
        if status != .available {
            Text(MLXAvailability.message(for: status)).font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
        }
    }

    private func refreshModelsIfOllama() async {
        if settings.provider == .ollama { await settings.refreshOllamaModels() }
    }

    private func saveKey() {
        settings.saveAPIKey(keyDraft)
        keyDraft = ""
    }
}

enum IDEAgentOllamaLabel {
    /// "qwen-fixed:latest · 27.3B Q4_K_M · 17 GB", or why it can't be used.
    static func title(_ model: OllamaModel) -> String {
        var parts = [model.name]
        let detail = [model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: " ")
        if !detail.isEmpty { parts.append(detail) }
        if model.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)) }
        let label = parts.joined(separator: " · ")
        return model.supportsTools ? label : label + " (no tool support)"
    }
}

private struct IDEAgentIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color?
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(tint ?? IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .background(isActive || isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .focusable(false)
    }
}

enum IDEAgentFormat {
    /// "1.2K" for 1_234; whole numbers below a thousand.
    static func tokens(_ count: Int) -> String {
        count < 1_000 ? "\(count)" : String(format: "%.1fK", Double(count) / 1_000)
    }

    /// A user's message as typed, with a leading `/command` in bold and `@file` mentions marked.
    static func userMessage(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        func mark(_ range: NSRange) {
            guard let swiftRange = Range(range, in: text), let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result)
            else { return }
            result[lower..<upper].foregroundColor = IDEAppearance.ColorToken.accent
        }
        if text.hasPrefix("/"), let end = text.firstIndex(where: \.isWhitespace) ?? Optional(text.endIndex) {
            mark(NSRange(text.startIndex..<end, in: text))
        }
        for token in IDEAgentMentionToken.scan(text) { mark(token.range) }
        return result
    }

    /// Inline Markdown with line breaks kept; plain text if it doesn't parse.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

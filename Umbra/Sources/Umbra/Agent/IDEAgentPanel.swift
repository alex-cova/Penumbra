import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
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

    @Environment(IDEWorkspace.self) private var workspace

    private var settings: IDEAgentSettings { agent.settings }

    private var isChecklistInInspector: Bool {
        placement == .aiMode && workspace.showsAIInspector && workspace.aiInspectorTab == .plan
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if placement != .aiMode, agent.conversations.count > 1 { IDEAgentTabsBar(agent: agent) }
            // The Plan tab beside the conversation shows the checklist, so the strip would say it twice.
            if !agent.todos.isEmpty, !isChecklistInInspector { IDEAgentTodoListView(items: agent.todos) }
            if placement == .aiMode, agent.entries.isEmpty {
                aiEmptyGreeting
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                transcript
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                if placement != .aiMode { Divider().overlay(IDEAppearance.ColorToken.border) }
            }
            // One composer for both states: a field that moved between the empty greeting and
            // the transcript would be destroyed and recreated, dropping focus on the first send.
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(placement == .docked ? IDEAppearance.ColorToken.panel : Color.clear)
        // On send the empty session's greeting slides up and out, as in Chat. The welcome
        // backdrop lives one level up, in IDEAICodeView, so it fills the whole card.
        .animation(placement == .aiMode ? .easeOut(duration: 0.35) : nil, value: agent.entries.isEmpty)
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
            if placement != .aiMode {
                IDEIconButton(systemImage: "square.and.pencil", help: "New Chat (⌥⌘T)", isDisabled: agent.entries.isEmpty && !agent.isRunning) {
                    agent.newConversation()
                }
                IDEIconButton(systemImage: "clock.arrow.circlepath", help: "Earlier Chats", isActive: isHistoryPresented) {
                    isHistoryPresented.toggle()
                }
                .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                    IDEAgentHistoryPopover(agent: agent) { isHistoryPresented = false }
                }
                .onAppear { agent.restoreLatestIfNeeded() }
            }
            if placement == .docked {
                IDEIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand over the editor") {
                    expandOverEditor()
                }
            }
            if placement == .aiMode {
                IDEIconButton(
                    systemImage: "square.and.arrow.up", help: "Export Chat as Markdown…", isDisabled: agent.entries.isEmpty
                ) { agent.exportTranscript() }
            }
            // AI mode's toolbar already has Settings.
            if placement != .aiMode {
                IDEIconButton(systemImage: "gearshape", help: "Agent Settings", isActive: isSettingsPresented) {
                    isSettingsPresented = true
                }
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    @ViewBuilder private var headerTitle: some View {
        if placement == .docked {
            IDEPanelTitle("Agent")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if agent.conversations.count < 2 || placement == .aiMode {
            Text(agent.selected.isEmpty ? "New session" : agent.selected.title)
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

    private var isAIMode: Bool { placement == .aiMode }
    private var choice: IDEAIModelChoice { agent.selected.effectiveChoice }

    /// The composer's glint holds still with the greeting effects.
    private var motionEnabled: Bool {
        !reduceMotion && !workspace.preferences.welcomeAnimationDisabled
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !agent.selected.hasConsent {
                IDEAgentDisclosureCard(settings: settings, provider: choice.provider)
            }
            if let status = agent.status {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEATypingDots()
                    Text(status)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            if !agent.selected.queue.isEmpty {
                IDEAgentQueuedMessages(queue: agent.selected.queue) { agent.selected.removeQueued($0) }
            }
            if isAIMode, let browser = workspace.aiBrowser, !browser.annotations.userOpenItems.isEmpty {
                IDEAgentBrowserNotesChip(
                    notes: browser.annotations.userOpenItems, isAttached: agent.selected.attachesBrowserNotes,
                    toggle: { agent.selected.attachesBrowserNotes.toggle() },
                    show: { workspace.toggleAIInspector(tab: .browser) })
            }
            if composerState.isShowingSuggestions {
                IDEAgentSuggestionList(state: composerState) { index in
                    composerState.selectedIndex = index
                    acceptRequest += 1
                }
            }
            if isAIMode {
                // One card holds the field and its chips, like the message box of a chat app.
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    fieldRow
                    chipRow
                }
                .padding(IDEAppearance.Spacing.sm)
                .background(IDEAppearance.ColorToken.card)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                        .stroke(IDEAppearance.ColorToken.border, lineWidth: 1))
                // The same glint as Chat's field while the session is empty. Sending a
                // message removes it with the greeting, which stops the animation.
                .overlay {
                    if isAIMode, agent.entries.isEmpty, motionEnabled {
                        IDEAIMirrorBorder()
                            .transition(.opacity)
                    }
                }
            } else {
                fieldRow
                chipRow
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: IDEAppearance.Spacing.sm) {
            @Bindable var agent = agent
            let field = IDEAgentComposerField(
                text: $agent.draft, height: $composerHeight,
                placeholder: placeholder,
                state: composerState, focusRequest: agent.composerFocusRequest, acceptRequest: acceptRequest,
                suggestions: { agent.suggestions(for: $0) },
                onSend: send,
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
            if isAIMode {
                field
            } else {
                field
                    .padding(IDEAppearance.Spacing.sm)
                    .background(IDEAppearance.ColorToken.card)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            }

            if agent.isRunning {
                IDEIconButton(
                    systemImage: "stop.fill", help: "Stop", tint: IDEAppearance.ColorToken.error, action: agent.stop)
            } else {
                IDEIconButton(
                    systemImage: "arrow.up.circle.fill", help: "Send",
                    tint: IDEAppearance.ColorToken.accent,
                    isDisabled: agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
            }
        }
    }

    private var placeholder: String {
        if agent.isRunning { return "Write what to do next; it is sent at the next step…" }
        return isAIMode ? "Describe a task or ask a question" : "Ask about this project…"
    }

    private func send() {
        // A message that would be sent (not a /command) with no usable model asks for one first.
        if isAIMode, !agent.draft.hasPrefix("/"), workspace.aiModelSetupHint(for: .code) != nil {
            workspace.requestAIModelSetup(for: .code)
            return
        }
        agent.submit()
    }

    private var chipRow: some View {
        HStack {
            if isAIMode {
                IDEAIProjectChip()
                IDEAIBranchChip()
            }
            IDEAgentModeChip(mode: agent.mode) { agent.selected.setMode($0) }
            if agent.selected.isACPConversation {
                IDEACPModeChip(conversation: agent.selected)
                if !agent.selected.acpConfigOptions.isEmpty {
                    IDEACPConfigChip(options: agent.selected.acpConfigOptions)
                }
                Button("Restart Agent") { agent.selected.restartACP() }
                    .buttonStyle(.borderless)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Kill the ACP agent process; it restarts on the next message")
            } else if !isAIMode {
                IDEAgentModelChip(settings: settings) { isSettingsPresented = true }
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            if let fraction = agent.selected.contextFraction {
                IDEAgentContextMeter(
                    fraction: fraction, tokens: agent.selected.contextTokens ?? 0,
                    window: settings.contextWindow(for: choice) ?? 0,
                    isBusy: agent.selected.isRunning || agent.selected.isCompacting
                ) {
                    let chat = agent.selected
                    Task { await chat.compact(focus: nil) }
                }
            }
            if isAIMode {
                IDEAIModelPicker(
                    settings: settings, choice: choice, mode: .code,
                    onSelect: { workspace.selectAIModel($0, for: .code) },
                    onManage: { workspace.isAIModelsPresented = true })
            }
        }
    }

    // MARK: - AI mode's empty session

    /// The greeting above the composer while the session is empty. The composer itself lives
    /// outside this branch so the field keeps focus when the first message is sent.
    private var aiEmptyGreeting: some View {
        VStack(spacing: IDEAppearance.Spacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26))
                .foregroundStyle(IDEAppearance.ColorToken.accent)
            Text(workspace.project.rootURL.map { "What should we do in \($0.lastPathComponent)?" } ?? "Let's build something")
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .multilineTextAlignment(.center)
            if let hint = workspace.aiModelSetupHint(for: .code) {
                IDEAISetupButton(hint: hint) { workspace.requestAIModelSetup(for: .code) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

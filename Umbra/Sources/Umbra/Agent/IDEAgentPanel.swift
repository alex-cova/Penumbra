import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isDiscardWorktreePresented = false

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
                    .ideTransition(.move(edge: .top).combined(with: .opacity))
            } else {
                transcript
                    .ideTransition(.opacity.combined(with: .move(edge: .bottom)))
                if placement != .aiMode { Divider().overlay(IDEAppearance.ColorToken.border) }
            }
            // One composer for both states: a field that moved between the empty greeting and
            // the transcript would be destroyed and recreated, dropping focus on the first send.
            IDEAgentComposerView(
                agent: agent, settings: settings, isAIMode: isAIMode, composerState: composerState,
                composerHeight: $composerHeight, acceptRequest: $acceptRequest, lastEscape: $lastEscape,
                openSettings: { isSettingsPresented = true })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(placement == .docked ? IDEAppearance.ColorToken.panel : Color.clear)
        // On send the empty session's greeting slides up and out, as in Chat. The welcome
        // backdrop lives one level up, in IDEAICodeView, so it fills the whole card.
        .ideAnimation(placement == .aiMode ? IDEAppearance.Motion.panel : nil, value: agent.entries.isEmpty)
        .sheet(isPresented: $isSettingsPresented) {
            IDEAgentSettingsSheet(settings: settings, agent: agent)
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
            IDEACPProviderMenu(agent: agent, openSettings: { isSettingsPresented = true })

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
                .contextMenu {
                    Button("New Chat in Worktree…") {
                        agent.startWorktreeConversation(title: agent.selected.customTitle ?? "")
                    }
                    if agent.isWorktreeChat {
                        Button("Discard Worktree…", role: .destructive) {
                            isDiscardWorktreePresented = true
                        }
                    }
                }
                .confirmationDialog(
                    "Discard this chat's worktree?",
                    isPresented: $isDiscardWorktreePresented,
                    titleVisibility: .visible
                ) {
                    Button("Discard Worktree", role: .destructive) {
                        agent.discardWorktreeConversation()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes the worktree folder and deletes its branch. The chat keeps its transcript.")
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
            IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { settings.opensAsPage = true }
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

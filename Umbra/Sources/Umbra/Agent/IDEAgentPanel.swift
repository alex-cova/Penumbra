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
    /// Work groups the user opened or closed, by group id; the others follow `isLive`.
    @State private var groupToggles: [UUID: Bool] = [:]
    /// Whether each card waiting on the user is on screen, as its row reports it. A card that never
    /// reported (not built yet, far below) counts as hidden after a moment.
    @State private var pendingVisibility: [UUID: Bool] = [:]
    @State private var scrollTarget: UUID?
    @State private var findQuery = ""
    @State private var findMatches: [UUID] = []
    @State private var findCurrent: UUID?
    @State private var findFocusRequest = 0
    @State private var scrollPosition = IDEAgentScrollPosition()
    @State private var transcriptWidth: CGFloat = 0

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
            // AI mode has the Changes tab beside the conversation.
            if placement != .aiMode { IDEAgentChangesPill(agent: agent) }
            if agent.isFindBarOpen {
                IDEAgentFindBar(
                    query: $findQuery,
                    position: IDEAgentTranscriptFind.position(of: findCurrent, in: findMatches),
                    hasMatches: !findMatches.isEmpty, focusRequest: findFocusRequest,
                    step: stepFind, close: closeFind,
                    focusChanged: { agent.isFindFieldFocused = $0 })
            }
            if placement == .aiMode, agent.entries.isEmpty {
                aiEmptyGreeting
                    .ideTransition(.move(edge: .top).combined(with: .opacity))
            } else {
                transcript
                    .ideTransition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if agent.isCommandsDrawerOpen, hasCommands {
                IDEAgentCommandsDrawer(
                    items: commandItems, close: { agent.isCommandsDrawerOpen = false }, showInTranscript: reveal)
                    .ideTransition(.move(edge: .bottom).combined(with: .opacity))
            }
            // One composer for both states: a field that moved between the empty greeting and
            // the transcript would be destroyed and recreated, dropping focus on the first send.
            IDEAgentComposerView(
                agent: agent, settings: settings, isAIMode: isAIMode, composerState: composerState,
                composerHeight: $composerHeight, acceptRequest: $acceptRequest, lastEscape: $lastEscape,
                openSettings: { isSettingsPresented = true },
                isPendingCardVisible: agent.selected.pendingDecision.map { pendingVisibility[$0.id] ?? true } ?? true,
                showEntry: { scrollTarget = $0 })
        }
        .onChange(of: agent.findRequest) { findFocusRequest += 1 }
        .onChange(of: findQuery) { findCurrent = nil }
        .onChange(of: agent.selectedID) { findCurrent = nil }
        .task(id: FindKey(query: agent.isFindBarOpen ? findQuery : "", chat: agent.selectedID, count: agent.entries.count)) {
            // Typing settles first; the transcript growing finds again without moving the view.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            findMatches = IDEAgentTranscriptFind.matches(agent.isFindBarOpen ? findQuery : "", in: agent.entries)
            if findCurrent.map({ !findMatches.contains($0) }) ?? true {
                findCurrent = findMatches.first
                if let findCurrent { reveal(findCurrent) }
            }
        }
        .task(id: agent.selected.pendingDecision?.id) {
            // A card that has not said whether it is on screen (its row was never built) is out of view.
            guard let id = agent.selected.pendingDecision?.id else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, pendingVisibility[id] == nil { pendingVisibility[id] = false }
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
        .sheet(isPresented: Bindable(agent).isShowingUsage) {
            IDEAgentUsageSheet(sources: .init(
                agentStore: agent.usageStore, projectRoot: agent.host?.agentProjectRoot?.path,
                chatStore: workspace.aiChat.usageStore)) { agent.isShowingUsage = false }
        }
        .sheet(isPresented: Bindable(agent).isShowingSchedules) {
            IDEAgentSchedulesSheet(agent: agent) { agent.isShowingSchedules = false }
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
            if hasCommands {
                IDEIconButton(
                    systemImage: "terminal", help: "Commands this chat ran, with their output",
                    isActive: agent.isCommandsDrawerOpen
                ) {
                    IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { agent.isCommandsDrawerOpen.toggle() }
                }
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
            IDEAgentEmptyState(agent: agent, openSettings: { isSettingsPresented = true })
        } else {
            IDEAgentFollowingScrollView(
                resetKey: agent.selectedID,
                pinKey: agent.entries.last(where: { $0.kind == .user })?.id,
                attention: agent.selected.isAwaitingUser ? "Waiting for you" : nil,
                scrollTarget: $scrollTarget,
                position: scrollPosition
            ) {
                LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    ForEach(IDEAgentTranscriptRows.make(agent.entries, isRunning: agent.isRunning)) { row in
                        switch row {
                        case .entry(let entry) where entry.isWaitingForUser:
                            IDEAgentEntryView(entry: entry).id(entry.id)
                                .ideFindHighlight(entry.id == findCurrent)
                                .onScrollVisibilityChange(threshold: 0.3) { pendingVisibility[entry.id] = $0 }
                                // A lazy row that is dropped reports no change; gone is out of view.
                                .onDisappear { pendingVisibility[entry.id] = false }
                        case .entry(let entry):
                            IDEAgentEntryView(entry: entry).id(entry.id)
                                .ideFindHighlight(entry.id == findCurrent)
                        case .work(let group):
                            IDEAgentWorkGroupView(group: group, isExpanded: expansion(of: group), highlightedID: findCurrent)
                                .id(group.id)
                        }
                    }
                }
                .padding(IDEAppearance.Spacing.md)
                .padding(.trailing, showsMinimap ? IDEAgentMinimapRail.width : 0)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transcriptWidth = $0 }
            .overlay(alignment: .trailing) {
                if showsMinimap {
                    IDEAgentMinimapRail(items: minimapItems, position: scrollPosition, select: reveal)
                        .padding(.trailing, 2)
                }
            }
        }
    }

    private var minimapItems: [IDEAgentMinimapItem] { IDEAgentMinimapItems.make(agent.entries) }

    private var commandItems: [IDEAgentCommandItem] { IDEAgentCommandLog.items(agent.entries) }

    /// Whether the chat ran a command, by tool name only, so the header does not parse arguments on every
    /// streamed update.
    private var hasCommands: Bool {
        agent.entries.contains { entry in
            if case .toolCall(let name) = entry.kind { IDEAgentTranscriptRows.commandTools.contains(name) } else { false }
        }
    }

    /// From four messages on, and not in a docked panel too narrow to spare the width.
    private var showsMinimap: Bool {
        transcriptWidth >= 380
            && agent.entries.lazy.filter { $0.kind == .user }.prefix(IDEAgentMinimapItems.minimumTurns).count
                >= IDEAgentMinimapItems.minimumTurns
    }

    // MARK: - Find

    private struct FindKey: Hashable {
        var query: String
        var chat: UUID
        var count: Int
    }

    private func stepFind(_ step: Int) {
        guard let next = IDEAgentTranscriptFind.next(after: findCurrent, by: step, in: findMatches) else { return }
        findCurrent = next
        reveal(next)
    }

    private func closeFind() {
        agent.isFindBarOpen = false
        findCurrent = nil
        findMatches = []
        agent.isFindFieldFocused = false
        agent.composerFocusRequest += 1
    }

    /// Scrolls to an entry, opening the work group it is folded into first.
    private func reveal(_ entryID: UUID) {
        let rows = IDEAgentTranscriptRows.make(agent.entries, isRunning: agent.isRunning)
        guard let rowID = IDEAgentTranscriptRows.rowID(containing: entryID, in: rows) else { return }
        if rowID != entryID, groupToggles[rowID] != true {
            groupToggles[rowID] = true
            // The group's cards exist only after it has opened.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                scrollTarget = entryID
            }
        } else {
            scrollTarget = entryID
        }
    }

    /// A group the user has not toggled is open while the run is adding to it, and closed after.
    private func expansion(of group: IDEAgentWorkGroup) -> Binding<Bool> {
        Binding(
            get: { groupToggles[group.id] ?? group.isLive },
            set: { groupToggles[group.id] = $0 })
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

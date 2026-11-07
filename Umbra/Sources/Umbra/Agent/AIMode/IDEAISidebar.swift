import AgentKit
import SwiftUI

/// AI mode's list: a New button, a search field, and the sessions of the tab being shown. Code lists
/// the window's chats and the saved sessions of every project; Chat lists the conversations that have
/// no project.
struct IDEAISidebar: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""
    @State private var highlightedSavedID: UUID?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: IDEAppearance.Spacing.xs) {
                IDEAISidebarAction(title: workspace.aiTab == .chat ? "New Chat" : "New Session", systemImage: "plus", action: startNew)
                searchField
            }
            .padding(IDEAppearance.Spacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                    switch workspace.aiTab {
                    case .code: IDEAICodeList(query: query, highlightedSavedID: highlightedSavedID)
                    case .chat: IDEAIChatList(query: query, highlightedSavedID: highlightedSavedID)
                    }
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleListKey(press)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.panel)
        .onChange(of: workspace.aiTab) { _, _ in highlightedSavedID = nil }
        .onChange(of: query) { _, _ in
            if let highlightedSavedID, !keyboardRows.contains(.saved(highlightedSavedID)) {
                self.highlightedSavedID = nil
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField(workspace.aiTab == .chat ? "Search chats" : "Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.caption)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) {
                    isListFocused = true
                    if currentRow == nil { move(by: 1) }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if query.isEmpty { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 5)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }

    private func startNew() {
        query = ""
        highlightedSavedID = nil
        switch workspace.aiTab {
        case .code:
            workspace.agent.newConversation()
            workspace.agent.composerFocusRequest += 1
        case .chat:
            workspace.aiChat.newChat()
        }
    }

    private var keyboardRows: [IDEAISidebarKeyboard.Row] {
        switch workspace.aiTab {
        case .chat:
            let chat = workspace.aiChat
            return IDEAISidebarKeyboard.chatOrder(
                openIDs: IDEAIChatList.openChats(in: chat, query: query).map(\.id),
                savedIDs: IDEAIChatList.savedRows(in: chat, query: query).map(\.id)
            )
        case .code:
            let agent = workspace.agent
            let groups = IDEAISessions.groups(
                current: agent.history, currentRoot: agent.projectRoot?.path,
                others: workspace.aiSessions.summaries, query: query)
            return IDEAISidebarKeyboard.codeOrder(groups: groups.map { group in
                let isCurrent = isCurrent(group)
                return (
                    openIDs: IDEAISessionGroupView.openChats(agent: agent, isCurrent: isCurrent, query: query).map(\.id),
                    savedIDs: IDEAISessionGroupView.savedRows(in: group, agent: agent).map(\.id)
                )
            })
        }
    }

    private func isCurrent(_ group: IDEAISessionGroup) -> Bool {
        guard let root = workspace.agent.projectRoot else { return false }
        return URL(fileURLWithPath: group.projectRoot).standardizedFileURL == root.standardizedFileURL
    }

    private var currentRow: IDEAISidebarKeyboard.Row? {
        if let highlightedSavedID { return .saved(highlightedSavedID) }
        switch workspace.aiTab {
        case .chat: return .open(workspace.aiChat.selectedID)
        case .code: return .open(workspace.agent.selectedID)
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            move(by: press.key == .downArrow ? 1 : -1)
            return .handled
        case .return:
            typeahead.reset()
            activate(currentRow)
            return .handled
        case .escape:
            typeahead.reset()
            if isSearchFocused {
                isSearchFocused = false
                return .handled
            }
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            let titles = titlesByRow
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: keyboardRows,
                selected: currentRow,
                title: { titles[$0] ?? "" }
            ) {
                highlight(row)
            }
            return .handled
        }
    }

    private var titlesByRow: [IDEAISidebarKeyboard.Row: String] {
        var titles: [IDEAISidebarKeyboard.Row: String] = [:]
        switch workspace.aiTab {
        case .chat:
            let chat = workspace.aiChat
            for conversation in IDEAIChatList.openChats(in: chat, query: query) {
                titles[.open(conversation.id)] = conversation.title
            }
            for row in IDEAIChatList.savedRows(in: chat, query: query) {
                titles[.saved(row.id)] = row.title
            }
        case .code:
            let agent = workspace.agent
            let groups = IDEAISessions.groups(
                current: agent.history, currentRoot: agent.projectRoot?.path,
                others: workspace.aiSessions.summaries, query: query)
            for group in groups {
                let isCurrent = isCurrent(group)
                for conversation in IDEAISessionGroupView.openChats(agent: agent, isCurrent: isCurrent, query: query) {
                    titles[.open(conversation.id)] = conversation.title
                }
                for row in IDEAISessionGroupView.savedRows(in: group, agent: agent) {
                    titles[.saved(row.id)] = row.title
                }
            }
        }
        return titles
    }

    private func move(by delta: Int) {
        guard let next = IDEListNeighbor.move(currentRow, in: keyboardRows, by: delta) else { return }
        highlight(next)
        isListFocused = true
    }

    private func highlight(_ row: IDEAISidebarKeyboard.Row) {
        switch row {
        case .open(let id):
            highlightedSavedID = nil
            switch workspace.aiTab {
            case .chat: workspace.aiChat.select(id)
            case .code: workspace.agent.select(id)
            }
        case .saved(let id):
            highlightedSavedID = id
        }
    }

    private func activate(_ row: IDEAISidebarKeyboard.Row?) {
        guard case .saved(let id) = row else { return }
        highlightedSavedID = nil
        switch workspace.aiTab {
        case .chat:
            workspace.aiChat.resume(id)
        case .code:
            let groups = IDEAISessions.groups(
                current: workspace.agent.history, currentRoot: workspace.agent.projectRoot?.path,
                others: workspace.aiSessions.summaries, query: query)
            if let group = groups.first(where: { $0.rows.contains { $0.id == id } }) {
                if isCurrent(group) {
                    workspace.agent.resume(id)
                } else {
                    workspace.openProjectInAIMode(URL(fileURLWithPath: group.projectRoot), resumeChat: id)
                }
            }
        }
    }
}

// MARK: - Code

private struct IDEAICodeList: View {
    @Environment(IDEWorkspace.self) private var workspace
    let query: String
    var highlightedSavedID: UUID?

    private var agent: IDEAgentController { workspace.agent }

    var body: some View {
        let groups = IDEAISessions.groups(
            current: agent.history, currentRoot: agent.projectRoot?.path,
            others: workspace.aiSessions.summaries, query: query)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !workspace.hasOpenProject && query.isEmpty { IDEAIProjectsSection() }
            ForEach(groups) { group in
                IDEAISessionGroupView(group: group, isCurrent: isCurrent(group), query: query, highlightedSavedID: highlightedSavedID)
            }
            if groups.isEmpty && !query.isEmpty {
                Text("No sessions match “\(query)”.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
        .task(id: agent.history) { await workspace.aiSessions.reload() }
    }

    private func isCurrent(_ group: IDEAISessionGroup) -> Bool {
        guard let root = agent.projectRoot else { return false }
        return URL(fileURLWithPath: group.projectRoot).standardizedFileURL == root.standardizedFileURL
    }
}

/// The projects to start a session in, shown while this window has none.
private struct IDEAIProjectsSection: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Projects")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)
                .padding(.horizontal, IDEAppearance.Spacing.xs)
            IDEAISidebarAction(title: "Open Folder…", systemImage: "folder", action: workspace.chooseProjectInAIMode)
            ForEach(workspace.recentProjectURLs.prefix(6), id: \.self) { url in
                IDEAISidebarAction(title: url.lastPathComponent, systemImage: "shippingbox") {
                    workspace.openProjectInAIMode(url)
                }
                .help(url.path)
            }
        }
    }
}

private struct IDEAISessionGroupView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let group: IDEAISessionGroup
    let isCurrent: Bool
    let query: String
    var highlightedSavedID: UUID?
    @State private var renaming: IDEAgentConversation?
    @State private var renameDraft = ""
    @State private var isRenamingPresented = false

    private var agent: IDEAgentController { workspace.agent }

    static func openChats(agent: IDEAgentController, isCurrent: Bool, query: String) -> [IDEAgentConversation] {
        guard isCurrent else { return [] }
        let live = agent.conversations.filter { !$0.isEmpty || $0.isRunning }
        guard !query.isEmpty else { return live }
        return live.filter { IDEAgentHistorySearch.rank([SessionSummary(id: $0.id, title: $0.title, updatedAt: Date())], query: query, requiresMatch: true).isEmpty == false }
    }

    static func savedRows(in group: IDEAISessionGroup, agent: IDEAgentController) -> [SessionSummary] {
        let open = Set(agent.conversations.map(\.conversationID))
        return group.rows.filter { !open.contains($0.id) }
    }

    /// Chats of this window with something in them, then saved sessions they do not already show.
    private var openChats: [IDEAgentConversation] { Self.openChats(agent: agent, isCurrent: isCurrent, query: query) }
    private var savedRows: [SessionSummary] { Self.savedRows(in: group, agent: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(group.name)
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .help(group.projectRoot)
                Spacer(minLength: 0)
                IDEIconButton(systemImage: "plus", help: "New session in \(group.name)") { newSession() }
                    .ideIconButtonSize(.compact)
            }
            .padding(.horizontal, IDEAppearance.Spacing.xs)

            ForEach(openChats) { conversation in
                IDEAISidebarRow(
                    title: conversation.title,
                    isSelected: conversation.id == agent.selectedID,
                    status: status(of: conversation),
                    action: { agent.select(conversation.id) }
                )
                .contextMenu {
                    Button("Rename…") {
                        renameDraft = conversation.title
                        renaming = conversation
                        isRenamingPresented = true
                    }
                    if !conversation.isRunning { Button("Close") { agent.close(conversation.id) } }
                }
            }
            ForEach(savedRows) { row in
                IDEAISidebarRow(
                    title: row.title,
                    isSelected: false,
                    isHighlighted: highlightedSavedID == row.id,
                    status: .none,
                    action: { open(row) }
                )
                    .help(row.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .contextMenu {
                        if isCurrent { Button("Delete", role: .destructive) { agent.deleteConversation(row.id) } }
                    }
            }
            if openChats.isEmpty && savedRows.isEmpty {
                Text("No sessions yet")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
        .alert("Rename Session", isPresented: $isRenamingPresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renaming { agent.rename(renaming.id, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the first message.")
        }
    }

    private func status(of conversation: IDEAgentConversation) -> IDEAISidebarRow.Status {
        if conversation.isAwaitingUser { return .waiting }
        if conversation.isRunning { return .running }
        if conversation.isUnread { return .unread }
        return .none
    }

    private func open(_ row: SessionSummary) {
        if isCurrent {
            agent.resume(row.id)
        } else {
            workspace.openProjectInAIMode(URL(fileURLWithPath: group.projectRoot), resumeChat: row.id)
        }
    }

    private func newSession() {
        if isCurrent {
            agent.newConversation()
            agent.composerFocusRequest += 1
        } else {
            workspace.openProjectInAIMode(URL(fileURLWithPath: group.projectRoot))
        }
    }
}

// MARK: - Shared pieces

/// A row of the list: a title and, at the trailing edge, what the chat is doing.
struct IDEAISidebarRow: View {
    enum Status { case none, running, waiting, unread }

    let title: String
    let isSelected: Bool
    var isHighlighted = false
    var status: Status = .none
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(title)
                    .font(IDEAppearance.Typography.tabLabel)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                switch status {
                case .none: EmptyView()
                case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
                case .waiting: Circle().fill(Color.orange).frame(width: 7, height: 7)
                case .unread: Circle().fill(IDEAppearance.ColorToken.accent).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected || isHighlighted
                    ? IDEAppearance.ColorToken.card
                    : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityTitle: String {
        switch status {
        case .none: title
        case .running: "\(title), working"
        case .waiting: "\(title), waiting for you"
        case .unread: "\(title), new reply"
        }
    }
}

/// A plain action in the list: an icon and a label.
struct IDEAISidebarAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16)
                Text(title)
                    .font(IDEAppearance.Typography.tabLabel)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

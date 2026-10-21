import AgentKit
import SwiftUI

/// AI mode's list: a New button, a search field, and the sessions of the tab being shown. Code lists
/// the window's chats and the saved sessions of every project; Chat lists the conversations that have
/// no project.
struct IDEAISidebar: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var query = ""

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
                    case .code: IDEAICodeList(query: query)
                    case .chat: IDEAIChatList(query: query)
                    }
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.sm)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.panel)
    }

    private var searchField: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField(workspace.aiTab == .chat ? "Search chats" : "Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.caption)
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
        switch workspace.aiTab {
        case .code:
            workspace.agent.newConversation()
            workspace.agent.composerFocusRequest += 1
        case .chat:
            workspace.aiChat.newChat()
        }
    }
}

// MARK: - Code

private struct IDEAICodeList: View {
    @Environment(IDEWorkspace.self) private var workspace
    let query: String

    private var agent: IDEAgentController { workspace.agent }

    var body: some View {
        let groups = IDEAISessions.groups(
            current: agent.history, currentRoot: agent.projectRoot?.path,
            others: workspace.aiSessions.summaries, query: query)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !workspace.hasOpenProject && query.isEmpty { IDEAIProjectsSection() }
            ForEach(groups) { group in
                IDEAISessionGroupView(group: group, isCurrent: isCurrent(group), query: query)
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
    @State private var renaming: IDEAgentConversation?
    @State private var renameDraft = ""

    private var agent: IDEAgentController { workspace.agent }

    /// Chats of this window with something in them, then saved sessions they do not already show.
    private var openChats: [IDEAgentConversation] {
        guard isCurrent else { return [] }
        let live = agent.conversations.filter { !$0.isEmpty || $0.isRunning }
        guard !query.isEmpty else { return live }
        return live.filter { IDEAgentHistorySearch.rank([SessionSummary(id: $0.id, title: $0.title, updatedAt: Date())], query: query, requiresMatch: true).isEmpty == false }
    }

    private var savedRows: [SessionSummary] {
        let open = Set(agent.conversations.map(\.conversationID))
        return group.rows.filter { !open.contains($0.id) }
    }

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
                Button(action: newSession) {
                    Image(systemName: "plus")
                        .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New session in \(group.name)")
                .accessibilityLabel("New session in \(group.name)")
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
                    }
                    if !conversation.isRunning { Button("Close") { agent.close(conversation.id) } }
                }
            }
            ForEach(savedRows) { row in
                IDEAISidebarRow(title: row.title, isSelected: false, status: .none, action: { open(row) })
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
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
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
            .background(isSelected ? IDEAppearance.ColorToken.card : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
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

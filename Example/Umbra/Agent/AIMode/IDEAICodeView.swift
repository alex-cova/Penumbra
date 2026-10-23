import SwiftUI

/// Code: the agent working in a project, in a readable column. The conversations are the window's own
/// (`IDEWorkspace.agent`), so permissions, plan mode, checkpoints, commands and @ mentions are the
/// ones the docked panel has. A new session starts empty, with the message field in the middle.
struct IDEAICodeView: View {
    @Environment(IDEWorkspace.self) private var workspace

    private var agent: IDEAgentController { workspace.agent }

    var body: some View {
        IDEAgentPanel(agent: agent, placement: .aiMode)
            .frame(maxWidth: Self.columnWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, IDEAppearance.Spacing.lg)
            .onAppear {
                // AI mode begins with a new session; it does not continue the project's latest one.
                agent.startFresh()
                agent.refreshHistory()
                agent.isShownInAIMode = true
                if let choice = IDEAISettings.shared.codeChoice {
                    agent.newChatChoice = choice
                    // A session that has not begun starts with the model last picked here.
                    if agent.selected.isEmpty, agent.selected.modelChoice == nil { agent.selected.modelChoice = choice }
                }
                agent.composerFocusRequest += 1
            }
            .onDisappear { agent.isShownInAIMode = false }
    }

    /// Long lines stay readable, as on the expanded chat page.
    static let columnWidth: CGFloat = 800
}

/// The project a session works in, as a chip in the message box: a menu of recent projects and Open Folder….
struct IDEAIProjectChip: View {
    @Environment(IDEWorkspace.self) private var workspace

    private var name: String { workspace.project.rootURL?.lastPathComponent ?? "Project or folder" }

    var body: some View {
        Menu {
            if let root = workspace.project.rootURL {
                Text(root.path)
                Divider()
            }
            ForEach(workspace.recentProjectURLs.prefix(8), id: \.self) { url in
                Button(url.lastPathComponent) { workspace.openProjectInAIMode(url) }
            }
            if !workspace.recentProjectURLs.isEmpty { Divider() }
            Button("Open Folder…", action: workspace.chooseProjectInAIMode)
        } label: {
            Label(name, systemImage: "folder")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(workspace.hasOpenProject ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(workspace.project.rootURL?.path ?? "Choose the folder this session works in (none: it uses a scratch folder)")
        .accessibilityLabel("Project: \(name)")
    }
}

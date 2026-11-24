import SwiftUI

/// The docked panel's and page's line under the header: "3 files changed  +120 −34", which opens the
/// same list as AI mode's Changes tab in a popover. Shown only while the chat's runs have changed files
/// that are not reverted.
struct IDEAgentChangesPill: View {
    let agent: IDEAgentController
    @Environment(IDEWorkspace.self) private var workspace
    @State private var isPresented = false

    private var conversation: IDEAgentConversation { agent.selected }

    var body: some View {
        let files = IDEAIChangedFiles.summarize(conversation.entries)
        let live = files.filter { !$0.isReverted }.count
        if live > 0 {
            let totals = workspace.aiChanges.totals
            Button { isPresented.toggle() } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: "plusminus.circle")
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text(Self.label(files: live))
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    if totals.added + totals.removed > 0 {
                        Text("+\(totals.added)").foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                        Text("−\(totals.removed)").foregroundStyle(IDEAppearance.ColorToken.error)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .font(IDEAppearance.Typography.monoSmall)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .background(isPresented ? IDEAppearance.ColorToken.controlHover : IDEAppearance.ColorToken.card)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.bottom, IDEAppearance.Spacing.xs)
            .help("Show what this chat changed: a diff per file, the diff viewer, Revert All")
            .accessibilityLabel(Self.accessibilityLabel(files: live, added: totals.added, removed: totals.removed))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                IDEAIChangesTab(onDismiss: { isPresented = false })
                    .environment(workspace)
                    .frame(width: 460, height: 440)
            }
            // The totals are worked out here too, so the line shows them before the list is opened.
            .ideAIChangesRefresh(files: files, isRunning: conversation.isRunning, workspace: workspace)
        }
    }

    static func label(files: Int) -> String {
        "\(files) \(files == 1 ? "file" : "files") changed"
    }

    static func accessibilityLabel(files: Int, added: Int, removed: Int) -> String {
        let lines = added + removed > 0 ? ", \(added) lines added, \(removed) removed" : ""
        return label(files: files) + lines + ". Show the changes"
    }
}

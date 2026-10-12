import GitIntelligence
import SwiftUI

/// The merge, rebase, cherry-pick or revert in progress: what it is, how many files still have
/// conflicts, and Resolve, Continue, Skip and Abort. It sits at the top of the Changes tab.
struct IDEGitOperationBanner: View {
    @Environment(IDEWorkspace.self) private var workspace
    let gitStatus: IDEGitStatusModel

    var body: some View {
        if let presentation = gitStatus.operationPresentation {
            let conflicts = gitStatus.conflictedChanges
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.title)
                            .font(IDEAppearance.Typography.tabLabel.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle(presentation, conflicts: conflicts.count))
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    if let first = conflicts.first {
                        Button("Resolve…") { workspace.openMergeTool(forPath: first.path) }
                            .help("Open the first conflicted file in the merge tool")
                    }
                    Button("Continue") { gitStatus.requestContinue() }
                        .disabled(!conflicts.isEmpty || gitStatus.isBusy)
                        .help(conflicts.isEmpty ? "Go on" : "Resolve the conflicts first")
                    if presentation.canSkip {
                        Button("Skip") { gitStatus.skipOperation() }
                            .disabled(gitStatus.isBusy)
                            .help("Drop this commit and go on")
                    }
                    Button("Abort", role: .destructive) { gitStatus.requestAbort() }
                        .disabled(gitStatus.isBusy)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .padding(IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IDEAppearance.ColorToken.gitConflict.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.bottom, IDEAppearance.Spacing.sm)
        }
    }

    private func subtitle(_ presentation: IDEGitOperationPresentation, conflicts: Int) -> String {
        var parts: [String] = []
        if let progress = presentation.progress { parts.append(progress) }
        parts.append(conflicts == 0 ? "No conflicts left" : "\(conflicts) \(conflicts == 1 ? "file has" : "files have") conflicts")
        return parts.joined(separator: " · ")
    }
}

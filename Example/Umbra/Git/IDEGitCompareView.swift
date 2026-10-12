import GitIntelligence
import SwiftUI

/// Compare with Branch: the commits only on each side and the files that differ between the tips.
/// A file opens in the diff viewer, branch against branch.
struct IDEGitCompareView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let gitStatus: IDEGitStatusModel

    var body: some View {
        if let comparison = gitStatus.comparison {
            VStack(spacing: 0) {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text("\(comparison.left) ↔ \(comparison.right)")
                    Spacer(minLength: 0)
                    Button {
                        gitStatus.clearComparison()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Close the comparison")
                }
                .font(IDEAppearance.Typography.caption)
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .padding(.vertical, IDEAppearance.Spacing.xs)

                SplitPanes(
                    minPrimary: 180, maxPrimary: 900, idealPrimary: 300, minSecondary: 180,
                    storageKey: "umbra.git.compareSplit.files"
                ) {
                    files(comparison)
                } secondary: {
                    SplitPanes(
                        minPrimary: 160, maxPrimary: 900, idealPrimary: 300, minSecondary: 160,
                        storageKey: "umbra.git.compareSplit.commits"
                    ) {
                        commits("Only in \(comparison.left)", comparison.onlyInLeft)
                    } secondary: {
                        commits("Only in \(comparison.right)", comparison.onlyInRight)
                    } divider: {
                        Splitter.rule()
                    }
                } divider: {
                    Splitter.rule()
                }
            }
        } else {
            Text("Choose Compare with Current on a branch to see what differs.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func files(_ comparison: GitComparison) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("\(comparison.files.count) files differ")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(comparison.files) { file in
                        Button {
                            workspace.openBranchDiff(left: comparison.left, right: comparison.right, file: file)
                        } label: {
                            HStack(spacing: IDEAppearance.Spacing.sm) {
                                Text(String(file.status))
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .foregroundStyle(color(for: file.status))
                                    .frame(width: 14)
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .font(IDEAppearance.Typography.caption)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func commits(_ title: String, _ commits: [GitCommit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("\(title) (\(commits.count))")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(commits) { commit in
                        HStack(spacing: IDEAppearance.Spacing.sm) {
                            Text(commit.shortHash)
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                            Text(commit.subject).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(commit.author)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                        }
                        .font(IDEAppearance.Typography.caption)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.sidebarHeader)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func color(for status: Character) -> Color {
        switch status {
        case "A": IDEAppearance.ColorToken.gitAdded
        case "D": IDEAppearance.ColorToken.error
        default: IDEAppearance.ColorToken.gitModified
        }
    }
}

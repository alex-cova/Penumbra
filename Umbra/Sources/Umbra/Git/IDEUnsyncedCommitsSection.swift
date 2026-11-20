import SwiftUI

/// The bottom of the Changes tab: the current branch and its upstream, each with the number of
/// commits not on the other side and the button that sends (Push) or fetches (Pull) them. A row
/// expands to list its commits.
struct IDEUnsyncedCommitsSection: View {
    let gitStatus: IDEGitStatusModel
    @State private var outgoingExpanded = false
    @State private var incomingExpanded = false

    var body: some View {
        let sync = gitStatus.sync
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Sync")
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let sync {
                    let isUpToDate = sync.ahead == 0 && sync.behind == 0
                    if isUpToDate {
                        Text("Up to date")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                    }
                    IDEIconButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        help: "Fast-Forward & Push",
                        isDisabled: gitStatus.isBusy || isUpToDate,
                        action: gitStatus.pullAndPush
                    )
                }
            }

            if let branch = gitStatus.currentBranch {
                IDEUnsyncedRow(
                    name: branch,
                    tint: IDEAppearance.ColorToken.accent,
                    count: sync?.ahead,
                    countHint: "not pushed",
                    directionIcon: "arrow.up",
                    commits: sync?.outgoing ?? [],
                    isExpanded: $outgoingExpanded,
                    buttonTitle: "Push",
                    buttonHelp: sync == nil ? "Publish the branch to origin" : "Push the current branch",
                    isButtonEnabled: !gitStatus.isBusy && (sync == nil || (sync?.ahead ?? 0) > 0),
                    action: { gitStatus.push() }
                )
            }
            if let sync {
                IDEUnsyncedRow(
                    name: sync.upstream,
                    tint: IDEAppearance.ColorToken.muted,
                    count: sync.behind,
                    countHint: "not pulled",
                    directionIcon: "arrow.down",
                    commits: sync.incoming,
                    isExpanded: $incomingExpanded,
                    buttonTitle: "Fast-Forward",
                    compactButtonTitle: "Pull",
                    buttonHelp: "Pull, fast-forward only",
                    isButtonEnabled: !gitStatus.isBusy && sync.behind > 0,
                    action: { gitStatus.pull() }
                )
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.top, IDEAppearance.Spacing.xs)
        .padding(.bottom, IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
    }
}

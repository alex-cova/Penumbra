import GitIntelligence
import SwiftUI

/// The History panel's Stashes sub-tab: the stash list beside the selected stash's files.
struct IDEGitStashPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    let gitStatus: IDEGitStatusModel

    private static let dateStyle = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(gitStatus.stashes.isEmpty ? "No stashes" : "\(gitStatus.stashes.count) stashed")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                Button("Stash Changes…") { gitStatus.requestStashChanges() }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
                Button("Clear All…") { gitStatus.requestClearStashes() }
                    .buttonStyle(.plain)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .disabled(gitStatus.stashes.isEmpty)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.xs)

            SplitPanes(
                minPrimary: 220, maxPrimary: 700, idealPrimary: 380, minSecondary: 200,
                storageKey: "umbra.git.stashSplit"
            ) {
                list
            } secondary: {
                files
            } divider: {
                Splitter.rule()
            }
        }
        .onAppear { gitStatus.loadStashes() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(gitStatus.stashes) { stash in
                    row(stash)
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }

    private func row(_ stash: GitStash) -> some View {
        let isSelected = gitStatus.selectedStashHash == stash.hash
        return Button {
            gitStatus.selectStash(stash.hash)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.title).lineLimit(1).truncationMode(.tail)
                Text([stash.ref, stash.branch, stash.date.formatted(Self.dateStyle)].compactMap { $0 }.joined(separator: " · "))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .font(IDEAppearance.Typography.caption)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") { gitStatus.applyStash(stash) }
            Button("Apply and Restore Staged Changes") { gitStatus.applyStash(stash, reinstateIndex: true) }
            Button("Pop (Apply and Drop)") { gitStatus.applyStash(stash, drop: true) }
            Divider()
            Button("New Branch from Stash…") { gitStatus.requestBranchFromStash(stash) }
            Button("Copy Revision") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stash.hash, forType: .string)
            }
            Divider()
            Button("Drop…", role: .destructive) { gitStatus.requestDropStash(stash) }
        }
    }

    @ViewBuilder
    private var files: some View {
        if let hash = gitStatus.selectedStashHash, let stash = gitStatus.stashes.first(where: { $0.hash == hash }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if gitStatus.stashFiles.isEmpty {
                        Text("Loading…")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .padding(IDEAppearance.Spacing.md)
                    }
                    ForEach(gitStatus.stashFiles) { change in
                        Button {
                            workspace.openStashDiff(stash: stash, change: change)
                        } label: {
                            HStack(spacing: IDEAppearance.Spacing.sm) {
                                Text(change.isUntracked ? "?" : String(change.file.status))
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .foregroundStyle(color(for: change))
                                    .frame(width: 14)
                                Text(change.file.path).lineLimit(1).truncationMode(.middle)
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
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
        } else {
            Text("Select a stash to see its files.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func color(for change: GitStashChange) -> Color {
        if change.isUntracked { return IDEAppearance.ColorToken.gitUntracked }
        switch change.file.status {
        case "A": return IDEAppearance.ColorToken.gitAdded
        case "D": return IDEAppearance.ColorToken.error
        default: return IDEAppearance.ColorToken.gitModified
        }
    }
}

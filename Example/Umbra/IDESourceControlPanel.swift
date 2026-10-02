import AppKit
import GitIntelligence
import SwiftUI

/// The bottom panel's History tab: the commit graph beside a commit's (or one file's) diff. The
/// working tree's changes live in the sidebar (`IDEChangesPanel`).
struct IDESourceControlPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var gitStatus: IDEGitStatusModel

    init(gitStatus: IDEGitStatusModel) {
        self._gitStatus = Bindable(wrappedValue: gitStatus)
    }

    var body: some View {
        historyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(IDEAppearance.ColorToken.editor)
            .clipped()
            .onAppear { gitStatus.loadHistory() }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            if let path = gitStatus.historyFilePath {
                fileHistoryBar(path)
            } else {
                historyFilters
            }
            splitContent(
                list: historyList,
                text: gitStatus.commitDetailText ?? "Select a commit to see its changes.",
                listWidth: 380
            )
        }
    }

    /// Stands in for the branch and author filters while the list is one file's history.
    private func fileHistoryBar(_ path: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("History of \((path as NSString).lastPathComponent)")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Button {
                gitStatus.clearFileHistory()
            } label: {
                Label("All Commits", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Show the history of the whole repository")
            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private var historyFilters: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Menu {
                Button("All Branches") { gitStatus.historyBranch = nil; gitStatus.loadHistory() }
                Divider()
                ForEach(gitStatus.branches, id: \.self) { branch in
                    Button(branch) { gitStatus.historyBranch = branch; gitStatus.loadHistory() }
                }
            } label: {
                Label(gitStatus.historyBranch ?? "All Branches", systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("All Authors") { gitStatus.historyAuthor = nil; gitStatus.loadHistory() }
                Divider()
                ForEach(gitStatus.authors, id: \.self) { author in
                    Button(author) { gitStatus.historyAuthor = author; gitStatus.loadHistory() }
                }
            } label: {
                Label(gitStatus.historyAuthor ?? "All Authors", systemImage: "person")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            HStack(spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                TextField("Search commit messages", text: $gitStatus.historySearch)
                    .textFieldStyle(.plain)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if !gitStatus.historySearch.isEmpty {
                    Button { gitStatus.historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .frame(maxWidth: 260)
            .onChange(of: gitStatus.historySearch) { gitStatus.loadHistory(debounced: true) }

            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    /// List beside the diff. `SplitPanes`, not `HSplitView`: the AppKit-backed split view reports
    /// a minimum size that pushed the whole window layout when hosted in the bottom panel, while
    /// `SplitPanes` only ever takes the space it is given.
    private func splitContent(list: some View, text: String, listWidth: CGFloat = 280) -> some View {
        SplitPanes(
            minPrimary: 180,
            maxPrimary: 560,
            idealPrimary: listWidth,
            minSecondary: 240,
            storageKey: "umbra.sourceControl.listSplit"
        ) {
            list
                .frame(maxHeight: .infinity)
        } secondary: {
            VStack(spacing: 0) {
                if !gitStatus.selectedCommitFiles.isEmpty {
                    commitFiles
                    Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
                }
                IDESourceControlDiffView(
                    text: text,
                    fontName: workspace.preferences.fontName,
                    fontSize: workspace.preferences.fontSize
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } divider: {
            Splitter.rule()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The selected commit's files; a click opens one against the commit's parent in a diff tab.
    private var commitFiles: some View {
        let files = gitStatus.selectedCommitFiles
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    IDECommitFileRow(file: file) { openCommitFile(file, in: files) }
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
        .frame(maxHeight: min(CGFloat(files.count) * 22 + 8, 140))
    }

    private func openCommitFile(_ file: GitChangedFile, in files: [GitChangedFile]) {
        guard let hash = gitStatus.selectedCommitHash else { return }
        let shortHash = gitStatus.commits.first { $0.hash == hash }?.shortHash ?? String(hash.prefix(7))
        workspace.openCommitDiff(hash: hash, shortHash: shortHash, file: file, files: files)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if gitStatus.commits.isEmpty {
                    Text(gitStatus.historyFilePath == nil ? "No commits" : "No commits touched this file")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.top, IDEAppearance.Spacing.sm)
                }
                ForEach(gitStatus.commits) { commit in
                    IDESourceControlCommitRow(
                        commit: commit,
                        isSelected: gitStatus.selectedCommitHash == commit.hash,
                        onSelect: { gitStatus.selectCommit(commit.hash) }
                    )
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }
}

/// The sidebar's Changes tab, top to bottom: the commit message, Commit with an options menu, the
/// collapsible list of changed files (the selected file's diff opens under it), and at the bottom
/// the unsynced commits against the upstream with Pull and Push. Double-clicking a file opens its
/// diff in a tab.
struct IDEChangesPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var gitStatus: IDEGitStatusModel
    @State private var creatingBranch = false
    @State private var newBranchName = ""
    @State private var changedFilesExpanded = true
    @FocusState private var messageFocused: Bool

    init(gitStatus: IDEGitStatusModel) {
        self._gitStatus = Bindable(wrappedValue: gitStatus)
    }

    private var stagedChanges: [IDEGitChange] {
        gitStatus.changes.filter { $0.staged != nil }
    }

    private var unstagedChanges: [IDEGitChange] {
        gitStatus.changes.filter { $0.unstaged != nil }
    }

    private var canCommit: Bool {
        !gitStatus.isBusy
            && !gitStatus.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !stagedChanges.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            messageField
            commitRow
            changedFilesHeader
            if changedFilesExpanded {
                changesArea
            } else {
                Spacer(minLength: 0)
            }
            if !gitStatus.actionStatus.isEmpty {
                Text(gitStatus.actionStatus)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(gitStatus.actionFailed ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
            IDEUnsyncedCommitsSection(gitStatus: gitStatus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IDEAppearance.ColorToken.panel)
        .clipped()
        .alert("New Branch", isPresented: $creatingBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Create") { gitStatus.createBranch(newBranchName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a branch at the current commit and switch to it.")
        }
    }

    private var messageField: some View {
        TextField(
            "Commit message",
            text: $gitStatus.commitMessage,
            prompt: Text("Commit message, press ⌘↩ to commit"),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(IDEAppearance.Typography.body)
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .lineLimit(1...5)
        .focused($messageFocused)
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if canCommit { gitStatus.commit() }
            return .handled
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 6)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                .strokeBorder(
                    messageFocused ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border,
                    lineWidth: 1
                )
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.top, IDEAppearance.Spacing.xs)
        .padding(.bottom, IDEAppearance.Spacing.sm)
        .accessibilityLabel("Commit message")
    }

    private var commitRow: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button("Commit") { gitStatus.commit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canCommit)
                .help(stagedChanges.isEmpty ? "Stage files to commit them" : "Commit the staged files (⌘↩)")

            optionsMenu

            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.sm)
    }

    /// Everything that is not the common path: staging in bulk, revert, refresh and the branch.
    private var optionsMenu: some View {
        Menu {
            Button("Stage All") { gitStatus.stageAll() }
            Button("Unstage All") { gitStatus.unstageAll() }
            Button("Revert All…") {
                workspace.revertChanges(gitStatus.changes.filter { $0.unstaged != nil }.map(\.path))
            }
            .disabled(gitStatus.changes.allSatisfy { $0.unstaged == nil })
            Divider()
            Menu("Switch Branch") {
                ForEach(gitStatus.localBranches, id: \.self) { branch in
                    Button {
                        gitStatus.switchBranch(branch)
                    } label: {
                        if branch == gitStatus.currentBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
            Button("New Branch…") {
                newBranchName = ""
                creatingBranch = true
            }
            Divider()
            Button("Refresh") { gitStatus.refresh() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(gitStatus.isBusy)
        .help("Stage, revert and branch actions")
        .accessibilityLabel("Changes options")
    }

    private var changedFilesHeader: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { changedFilesExpanded.toggle() }
        } label: {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: changedFilesExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 10)
                Text("Changed files")
                    .font(IDEAppearance.Typography.tabLabel.weight(.medium))
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text("\(gitStatus.changes.count)")
                    .font(IDEAppearance.Typography.tabLabel)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .frame(height: 24)
            .background(IDEAppearance.ColorToken.card)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .accessibilityLabel("Changed files, \(gitStatus.changes.count)")
        .accessibilityValue(changedFilesExpanded ? "Expanded" : "Collapsed")
        .focusable(false)
    }

    /// The file list, with the selected file's diff under it. `SplitPanes`, not `VSplitView`: see
    /// `IDESourceControlPanel.splitContent`.
    @ViewBuilder
    private var changesArea: some View {
        if gitStatus.selectedChangePath != nil {
            SplitPanes(
                axis: .vertical,
                minPrimary: 80,
                minSecondary: 90,
                storageKey: "umbra.changes.diffSplit"
            ) {
                changeList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                VStack(spacing: 0) {
                    diffHeader
                    IDESourceControlDiffView(
                        text: gitStatus.diffText ?? "Loading diff…",
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } divider: {
                Splitter.rule()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            changeList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffHeader: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(gitStatus.selectedChangePath.map { ($0 as NSString).lastPathComponent } ?? "")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            IDEExplorerToolbarButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Open in Diff Viewer") {
                openSelectedDiff()
            }
            IDEExplorerToolbarButton(systemImage: "xmark", help: "Close Diff") {
                gitStatus.selectChange(nil)
            }
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.iconButton)
        .background(IDEAppearance.ColorToken.editor)
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                if stagedChanges.isEmpty && unstagedChanges.isEmpty {
                    Text("No changes")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.top, IDEAppearance.Spacing.sm)
                } else {
                    if !stagedChanges.isEmpty {
                        sectionHeader("Staged Changes", count: stagedChanges.count)
                        ForEach(stagedChanges) { change in
                            IDESourceControlChangeRow(
                                change: change,
                                isSelected: gitStatus.selectedChangePaths.contains(change.path),
                                showsStage: false,
                                onSelect: { select(change, in: stagedChanges) },
                                onOpen: { workspace.openChangeDiff(path: change.path, staged: true) },
                                onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                onStage: {},
                                onUnstage: { gitStatus.unstage(path: change.path) },
                                onRevert: { revert(from: change) }
                            )
                        }
                    }
                    if !unstagedChanges.isEmpty {
                        sectionHeader("Changes", count: unstagedChanges.count)
                        ForEach(unstagedChanges) { change in
                            IDESourceControlChangeRow(
                                change: change,
                                isSelected: gitStatus.selectedChangePaths.contains(change.path),
                                showsStage: true,
                                onSelect: { select(change, in: unstagedChanges) },
                                onOpen: { workspace.openChangeDiff(path: change.path, staged: false) },
                                onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                onStage: { gitStatus.stage(path: change.path) },
                                onUnstage: {},
                                onRevert: { revert(from: change) }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.sm)
        }
    }

    /// The selected row's diff in a tab: its unstaged changes when it has any, else its staged ones.
    private func openSelectedDiff() {
        guard let path = gitStatus.selectedChangePath,
              let change = gitStatus.changes.first(where: { $0.path == path }) else { return }
        workspace.openChangeDiff(path: path, staged: change.unstaged == nil)
    }

    /// Plain click selects one row, ⌘-click toggles it, ⇧-click extends from the primary row.
    private func select(_ change: IDEGitChange, in visible: [IDEGitChange]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            gitStatus.toggleChangeSelection(change.path)
        } else if flags.contains(.shift) {
            gitStatus.extendChangeSelection(to: change.path, in: visible.map(\.path))
        } else {
            gitStatus.selectChange(change.path)
        }
    }

    /// The context menu acts on the whole selection when the row is part of it, else on that row.
    private func revert(from change: IDEGitChange) {
        if gitStatus.selectedChangePaths.contains(change.path) {
            let selected = gitStatus.selectedChangePaths
            workspace.revertChanges(gitStatus.changes.map(\.path).filter { selected.contains($0) })
        } else {
            workspace.revertChanges([change.path])
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(IDEAppearance.Typography.sectionHeader)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.top, IDEAppearance.Spacing.xs)
    }
}

/// The bottom of the Changes tab: the current branch and its upstream, each with the number of
/// commits not on the other side and the button that sends (Push) or fetches (Pull) them. A row
/// expands to list its commits.
private struct IDEUnsyncedCommitsSection: View {
    let gitStatus: IDEGitStatusModel
    @State private var outgoingExpanded = false
    @State private var incomingExpanded = false

    var body: some View {
        let sync = gitStatus.sync
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Unsynced commits")
                    .font(IDEAppearance.Typography.tabLabel.weight(.semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                if let sync {
                    Text("↑\(sync.ahead) ↓\(sync.behind)")
                        .font(IDEAppearance.Typography.tabLabel)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let sync {
                    Button("Pull & Push") { gitStatus.pullAndPush() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(gitStatus.isBusy || (sync.ahead == 0 && sync.behind == 0))
                        .help("Pull (fast-forward only), then push")
                }
            }

            if let branch = gitStatus.currentBranch {
                IDEUnsyncedRow(
                    name: branch,
                    tint: .blue,
                    count: sync?.ahead,
                    countHint: "not pushed",
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
                    tint: .purple,
                    count: sync.behind,
                    countHint: "not pulled",
                    commits: sync.incoming,
                    isExpanded: $incomingExpanded,
                    buttonTitle: "Pull",
                    buttonHelp: "Pull, fast-forward only",
                    isButtonEnabled: !gitStatus.isBusy && sync.behind > 0,
                    action: { gitStatus.pull() }
                )
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IDEUnsyncedRow: View {
    let name: String
    let tint: Color
    /// Nil for a branch without an upstream: there is nothing to count against.
    let count: Int?
    let countHint: String
    let commits: [GitCommit]
    @Binding var isExpanded: Bool
    let buttonTitle: String
    let buttonHelp: String
    let isButtonEnabled: Bool
    let action: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var canExpand: Bool { !commits.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Button {
                    if canExpand { withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() } }
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Image(systemName: isExpanded && canExpand ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .opacity(canExpand ? 1 : 0.35)
                            .frame(width: 10)
                        Text(name)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(tint.opacity(0.85), lineWidth: 1)
                            }
                        Text(count.map(String.init) ?? "no upstream")
                            .font(IDEAppearance.Typography.tabLabel)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(count.map { "\($0) \(countHint)" } ?? "This branch has no upstream yet")
                .accessibilityLabel(count.map { "\(name), \($0) \(countHint)" } ?? "\(name), no upstream")

                Spacer(minLength: 0)

                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isButtonEnabled)
                    .help(buttonHelp)
            }

            if isExpanded && canExpand {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject)
                                    .font(IDEAppearance.Typography.tabLabel)
                                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                                    .lineLimit(1)
                                Text("\(commit.shortHash)  \(commit.author) · \(Self.relativeFormatter.localizedString(for: commit.date, relativeTo: Date()))")
                                    .font(IDEAppearance.Typography.caption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                            .padding(.leading, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One file of a commit: its status letter and path. Clicking opens its diff.
private struct IDECommitFileRow: View {
    let file: GitChangedFile
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(String(file.status))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 22)
        .background(isHovering ? IDEAppearance.ColorToken.controlHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help("Show Diff")
    }

    private var statusColor: Color {
        switch file.status {
        case "A": IDEAppearance.ColorToken.gitAdded
        case "D": IDEAppearance.ColorToken.error
        default: IDEAppearance.ColorToken.gitModified
        }
    }
}

private enum IDEGitGraphMetrics {
    static let laneWidth: CGFloat = 12
    static let rowHeight: CGFloat = 38
    static let palette: [Color] = [
        Color(red: 0.25, green: 0.72, blue: 0.55), Color(red: 0.85, green: 0.65, blue: 0.2),
        Color(red: 0.4, green: 0.6, blue: 0.95), Color(red: 0.85, green: 0.4, blue: 0.5),
        Color(red: 0.65, green: 0.5, blue: 0.9), Color(red: 0.3, green: 0.75, blue: 0.85),
    ]

    static func color(_ lane: Int) -> Color { palette[lane % palette.count] }
}

private struct IDEGitGraphView: View {
    let row: GitGraphRow

    private let metrics = IDEGitGraphMetrics.self

    var body: some View {
        let lanes = min(row.laneCount, 8)
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { (CGFloat(min(lane, 7)) + 0.5) * metrics.laneWidth }
            func y(_ anchor: GitGraphAnchor) -> CGFloat {
                switch anchor {
                case .top: return 0
                case .center: return size.height / 2
                case .bottom: return size.height
                }
            }
            for segment in row.segments {
                var path = Path()
                let start = CGPoint(x: x(segment.fromLane), y: y(segment.fromAnchor))
                let end = CGPoint(x: x(segment.toLane), y: y(segment.toAnchor))
                path.move(to: start)
                if segment.fromLane == segment.toLane {
                    path.addLine(to: end)
                } else {
                    let midY = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: midY),
                        control2: CGPoint(x: end.x, y: midY)
                    )
                }
                context.stroke(path, with: .color(metrics.color(segment.colorIndex)), lineWidth: 1.5)
            }
            let mid = size.height / 2
            let dot = CGRect(x: x(row.nodeLane) - 4, y: mid - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(metrics.color(row.colorIndex)))
        }
        .frame(width: CGFloat(max(lanes, 1)) * metrics.laneWidth, height: metrics.rowHeight)
    }
}

private struct IDESourceControlCommitRow: View {
    let commit: IDEGitCommit
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let graph = commit.graph {
                IDEGitGraphView(row: graph)
            }
            VStack(alignment: .leading, spacing: 2) {
                (Text(refsPrefix).foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                    + Text(commit.subject).foregroundStyle(IDEAppearance.ColorToken.foreground))
                    .font(IDEAppearance.Typography.tabLabel)
                    .lineLimit(1)
                Text("\(commit.shortHash)  \(commit.author) · \(commit.relativeDate)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: IDEGitGraphMetrics.rowHeight)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var refsPrefix: String {
        commit.refs.isEmpty ? "" : "[\(commit.refs)] "
    }
}

private struct IDESourceControlChangeRow: View {
    let change: IDEGitChange
    let isSelected: Bool
    let showsStage: Bool
    let onSelect: () -> Void
    /// Double-click: the change in a diff tab.
    let onOpen: () -> Void
    let onOpenFile: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onRevert: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button(action: showsStage ? onStage : onUnstage) {
                Image(systemName: showsStage ? "plus.circle" : "minus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
            }
            .buttonStyle(.plain)
            .help(showsStage ? "Stage File" : "Unstage File")

            Image(systemName: IDEFileIcon.systemName(forFilename: change.relativePath))
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(change.relativePath)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(statusLabel)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Show Diff", action: onOpen)
            Button("Open File", action: onOpenFile)
            Divider()
            Button("Revert…", action: onRevert)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
    }

    private var rowBackground: Color {
        if isSelected {
            return IDEAppearance.ColorToken.selection
        }
        if isHovering {
            return IDEAppearance.ColorToken.controlHover
        }
        return .clear
    }

    private var displayedStatus: IDEGitFileStatus? {
        showsStage ? change.unstaged : change.staged
    }

    private var statusColor: Color {
        switch displayedStatus {
        case .modified: IDEAppearance.ColorToken.gitModified
        case .added, .untracked: IDEAppearance.ColorToken.gitAdded
        case .conflicted: IDEAppearance.ColorToken.gitConflict
        case .ignored: IDEAppearance.ColorToken.gitIgnored
        case .none: IDEAppearance.ColorToken.muted
        }
    }

    private var statusLabel: String {
        switch displayedStatus {
        case .modified: "M"
        case .added: "A"
        case .untracked: "?"
        case .conflicted: "U"
        case .ignored: "!"
        case .none: ""
        }
    }
}

struct IDESourceControlDiffView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = IDEAppearance.NSToken.editor

        let textView = IDEDiffTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.textColor = IDEAppearance.NSToken.foreground
        textView.insertionPointColor = IDEAppearance.NSToken.foreground
        textView.font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.render(text, fontName: fontName, fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.render(text, fontName: fontName, fontSize: fontSize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var textView: IDEDiffTextView?
        private var renderedText = ""
        private var renderedFontName = ""
        private var renderedFontSize = 0.0

        func render(_ text: String, fontName: String, fontSize: Double) {
            guard let textView else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            if renderedText != text || renderedFontName != fontName || renderedFontSize != fontSize {
                let (attributed, bands) = Self.style(text, font: font)
                textView.lineBands = bands
                textView.textStorage?.setAttributedString(attributed)
                textView.needsDisplay = true
                renderedText = text
                renderedFontName = fontName
                renderedFontSize = fontSize
            }
        }

        /// Colours a unified diff: foreground per line kind, plus full-width background bands for
        /// added/removed lines. Hunk state matters so `--- a/file` is not mistaken for a removal.
        private static func style(_ text: String, font: NSFont) -> (NSAttributedString, [IDEDiffTextView.Band]) {
            let result = NSMutableAttributedString()
            var bands: [IDEDiffTextView.Band] = []
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            let base = IDEAppearance.NSToken.foreground
            let muted = NSColor.secondaryLabelColor
            var inHunk = false
            var location = 0

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let string = String(line) + "\n"
                var color = base
                var lineFont = font
                var band: NSColor?
                if line.hasPrefix("diff --git") {
                    inHunk = false
                    color = base
                    lineFont = bold
                    band = NSColor.white.withAlphaComponent(0.06)
                } else if line.hasPrefix("--- ") && line.hasSuffix(" ---") {
                    inHunk = false
                    color = NSColor.systemYellow
                    lineFont = bold
                } else if line.hasPrefix("@@") {
                    inHunk = true
                    color = NSColor.systemCyan
                    band = NSColor.systemCyan.withAlphaComponent(0.08)
                } else if inHunk, line.hasPrefix("+") {
                    color = NSColor.systemGreen
                    band = NSColor.systemGreen.withAlphaComponent(0.14)
                } else if inHunk, line.hasPrefix("-") {
                    color = NSColor.systemRed
                    band = NSColor.systemRed.withAlphaComponent(0.14)
                } else if !inHunk {
                    if line.hasPrefix("commit ") {
                        color = NSColor.systemYellow
                        lineFont = bold
                    } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                        || line.hasPrefix("Author:") || line.hasPrefix("Date:") || line.hasPrefix("similarity")
                        || line.hasPrefix("rename ") {
                        color = muted
                    }
                }
                let length = (string as NSString).length
                result.append(NSAttributedString(string: string, attributes: [.font: lineFont, .foregroundColor: color]))
                if let band { bands.append(.init(range: NSRange(location: location, length: length - 1), color: band)) }
                location += length
            }
            return (result, bands)
        }
    }
}

/// Read-only text view that paints a full-width background behind flagged lines.
final class IDEDiffTextView: NSTextView {
    struct Band {
        let range: NSRange
        let color: NSColor
    }

    var lineBands: [Band] = []

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for band in lineBands {
            let glyphs = layoutManager.glyphRange(forCharacterRange: band.range, actualCharacterRange: nil)
            band.color.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                let fill = NSRect(x: 0, y: lineRect.minY + origin.y, width: max(self.bounds.width, lineRect.maxX), height: lineRect.height)
                if fill.intersects(rect) { fill.fill() }
            }
        }
        _ = textContainer
    }
}

struct IDESourceControlControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        Button(action: { workspace.gitStatus.refresh(); workspace.gitStatus.loadHistory() }) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .help("Refresh")
        .accessibilityLabel("Refresh History")
        .disabled(workspace.gitStatus.isBusy)
    }
}

#Preview {
    IDESourceControlPanel(gitStatus: {
        let model = IDEGitStatusModel()
        return model
    }())
    .environment(IDEWorkspace())
    .frame(width: 720, height: 320)
    .preferredColorScheme(IDEAppearance.preferredColorScheme)
}

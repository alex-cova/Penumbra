import SwiftUI

/// The working tree sidebar, with the commit composer, file list, inline diff, and sync controls.
struct IDEChangesPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var gitStatus: IDEGitStatusModel
    @State private var creatingBranch = false
    @State private var newBranchName = ""
    @State private var changedFilesExpanded = true
    @FocusState private var messageFocused: Bool
    @FocusState private var isListFocused: Bool

    init(gitStatus: IDEGitStatusModel) {
        self._gitStatus = Bindable(wrappedValue: gitStatus)
    }

    private var hasCommitContent: Bool {
        gitStatus.commitOptions.amend || gitStatus.changes.contains { $0.staged != nil && $0.staged != .conflicted }
    }

    private var canCommit: Bool {
        !gitStatus.isBusy
            && !gitStatus.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommitContent
    }

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDEChangesPanel")
        let showsChanges = IDEGitChrome.showsCommitControls(gitStatus.refreshState)
        VStack(spacing: 0) {
            IDEGitOperationBanner(gitStatus: gitStatus)
            if showsChanges {
                commitComposer
            }
            if gitStatus.isNetworkBusy { networkProgressRow }
            if showsChanges {
                changedFilesHeader
                if changedFilesExpanded {
                    changesArea
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                discoveryState
                Spacer(minLength: 0)
            }
            statusLines
            if gitStatus.workspaceSnapshot != nil {
                Rectangle()
                    .fill(IDEAppearance.ColorToken.border)
                    .frame(height: 1)
                IDEUnsyncedCommitsSection(gitStatus: gitStatus)
            }
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
        .ideSidebarFocus(.changes, on: $messageFocused)
        .onChange(of: isListFocused) { _, focused in
            workspace.isChangesListFocused = focused
        }
        .onDisappear {
            workspace.isChangesListFocused = false
        }
    }

    /// A first status that has not produced a snapshot yet: a loading line, or the failure and Refresh.
    @ViewBuilder
    private var discoveryState: some View {
        switch gitStatus.refreshState {
        case .loading:
            HStack(spacing: IDEAppearance.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(IDEGitRefreshCaption.updating)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.top, IDEAppearance.Spacing.md)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(IDEGitRefreshCaption.updating)
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                Text(message)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh") { gitStatus.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Refresh Git status")
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.top, IDEAppearance.Spacing.md)
        case .unavailable, .stale, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        if !gitStatus.actionStatus.isEmpty {
            Text(gitStatus.actionStatus)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(gitStatus.actionFailed ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .accessibilityLabel(gitStatus.actionStatus)
        }
        if gitStatus.workspaceSnapshot != nil, let caption = IDEGitRefreshCaption.updatingLine(gitStatus.refreshState) {
            Text(caption)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .accessibilityLabel(caption)
        }
        if gitStatus.workspaceSnapshot != nil, let refreshError = gitStatus.refreshError {
            Text(refreshError)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Commit message")
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                commitOptionsMenu
            }
            messageField
            commitRow
                .padding(.top, IDEAppearance.Spacing.xs)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.top, IDEAppearance.Spacing.xs)
        .padding(.bottom, IDEAppearance.Spacing.sm)
    }

    private var messageField: some View {
        TextField(
            "Commit message",
            text: $gitStatus.commitMessage,
            prompt: Text("Describe your changes"),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(IDEAppearance.Typography.body)
        .foregroundStyle(IDEAppearance.ColorToken.foreground)
        .lineLimit(2...5)
        .focused($messageFocused)
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if canCommit { gitStatus.commit() }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let rows = IDEGitChangeRows.listed(in: gitStatus.changes)
            guard !rows.isEmpty else { return .ignored }
            if gitStatus.selectedChange == nil {
                gitStatus.moveChangeSelection(by: 1, in: rows)
            }
            isListFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            workspace.focusActiveEditor()
            return .handled
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.snug)
        .background {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                .fill(IDEAppearance.ColorToken.editor)
                .strokeBorder(
                    messageFocused ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border,
                    lineWidth: 1
                )
        }
        .accessibilityLabel("Commit message")
        .accessibilityHint("Press Command-Return to commit staged changes")
    }

    private var commitRow: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button(action: gitStatus.commit) {
                Text(gitStatus.commitOptions.amend ? "Amend" : "Commit")
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(IDEAppearance.ColorToken.accent)
            .help(hasCommitContent ? "Commit the staged files (⌘↩)" : "Stage files to commit them")

            Button(action: commitAndPush) {
                ViewThatFits(in: .horizontal) {
                    Text("Commit & Push…")
                        .fixedSize()
                    Image(systemName: "arrow.up.circle")
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Commit and Push…")
            .help("Commit, then open the push dialog (⌥⌘K)")
            .keyboardShortcut("k", modifiers: [.command, .option])
        }
        .disabled(!canCommit)
    }

    private func commitAndPush() {
        var options = gitStatus.commitOptions
        options.pushAfter = true
        gitStatus.requestCommit(options: options)
    }

    /// Amend, sign-off, hooks, recent messages and the fixup!/squash! prefixes.
    private var commitOptionsMenu: some View {
        IDEIconMenu(
            systemImage: "checklist",
            help: "Commit options: amend, sign off, hooks, recent messages",
            isActive: gitStatus.commitOptions.amend || gitStatus.commitOptions.signoff || gitStatus.commitOptions.skipHooks
        ) {
            Toggle("Amend Last Commit", isOn: Binding(
                get: { gitStatus.commitOptions.amend },
                set: { gitStatus.setAmend($0) }
            ))
            Toggle("Sign Off", isOn: Binding(
                get: { gitStatus.commitOptions.signoff },
                set: { gitStatus.commitOptions.signoff = $0 }
            ))
            Toggle("Skip Hooks (--no-verify)", isOn: Binding(
                get: { gitStatus.commitOptions.skipHooks },
                set: { gitStatus.commitOptions.skipHooks = $0 }
            ))
            Toggle("Analyze Code Before Commit", isOn: Binding(
                get: { gitStatus.analyzesCodeBeforeCommit },
                set: { gitStatus.analyzesCodeBeforeCommit = $0 }
            ))
            .help("Inspect the staged Java files with the active inspection profile and warn about errors and warnings")
            Divider()
            Menu("Recent Messages") {
                ForEach(gitStatus.recentCommitMessages, id: \.self) { message in
                    Button(message.split(separator: "\n").first.map(String.init) ?? message) {
                        gitStatus.commitMessage = message
                    }
                }
            }
            .disabled(gitStatus.recentCommitMessages.isEmpty)
            Menu("Prefix with fixup!, squash! or amend!") {
                ForEach(gitStatus.prefixCandidates) { commit in
                    Menu("\(commit.shortHash) \(commit.subject)") {
                        Button("fixup!") { gitStatus.applyCommitPrefix("fixup", to: commit) }
                        Button("squash!") { gitStatus.applyCommitPrefix("squash", to: commit) }
                        Button("amend!") { gitStatus.applyCommitPrefix("amend", to: commit) }
                    }
                }
            }
            .disabled(gitStatus.prefixCandidates.isEmpty)
        }
        .accessibilityLabel("Commit options")
    }

    /// Everything that is not the common path: staging in bulk, revert, refresh and the branch.
    private var optionsMenu: some View {
        IDEIconMenu(systemImage: "ellipsis", help: "Stage, discard and branch actions") {
            Button("Stage All") { gitStatus.stageAll() }
            Button("Unstage All") { gitStatus.unstageAll() }
            Button("Discard All…") {
                workspace.revertChanges(gitStatus.changes.filter { $0.unstaged != nil }.map(\.path))
            }
            .disabled(gitStatus.changes.allSatisfy { $0.unstaged == nil })
            Divider()
            Button("Stash Changes…") { gitStatus.requestStashChanges() }
            Button("Unstash…") { workspace.showStashes() }
            Divider()
            Button("Fetch") { gitStatus.fetch() }
            Button("Update Project…") { workspace.pullProject() }
            Button("Push…") { workspace.pushProject() }
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
        }
        .disabled(gitStatus.isBusy)
        .accessibilityLabel("Changes options")
    }

    /// What the running fetch, pull or push is doing, with git's percentage when it reports one.
    private var networkProgressRow: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if let fraction = gitStatus.networkProgress?.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 60)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(gitStatus.networkProgress?.phase ?? "Talking to the remote…")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel") { gitStatus.cancelNetworkActions() }
                .buttonStyle(.plain)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Stop the running fetch, update or push")
                .accessibilityLabel("Cancel the running network command")
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.bottom, IDEAppearance.Spacing.xs)
    }

    private var changedFilesHeader: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button {
                IDEAppearance.Motion.animate(IDEAppearance.Motion.quick) { changedFilesExpanded.toggle() }
            } label: {
                HStack(spacing: IDEAppearance.Spacing.snug) {
                    IDEDisclosureChevron(isExpanded: changedFilesExpanded)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    ViewThatFits(in: .horizontal) {
                        Text("Changed files").fixedSize()
                        Text("Files")
                    }
                    .font(IDEAppearance.Typography.sectionHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(gitStatus.changes.count, format: .number)
                        .font(IDEAppearance.Typography.tabLabel.monospacedDigit())
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(minHeight: IDEAppearance.Spacing.iconButton)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Changed files, \(gitStatus.changes.count)")
            .accessibilityValue(changedFilesExpanded ? "Expanded" : "Collapsed")
            .focusable(false)

            optionsMenu
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xxs)
        .background(IDEAppearance.ColorToken.card)
    }

    /// The file list, with the selected file in the diff viewer under it. `SplitPanes`, not
    /// `VSplitView`: see `IDESourceControlPanel.splitContent`. The request is the one Show Diff opens.
    @ViewBuilder
    private var changesArea: some View {
        if let preview = selectedChangePreview {
            SplitPanes(
                axis: .vertical,
                minPrimary: 80,
                minSecondary: 90,
                storageKey: "umbra.changes.diffSplit"
            ) {
                IDEChangesFileList(
                    gitStatus: gitStatus,
                    changes: gitStatus.changes,
                    selectedChanges: gitStatus.selectedChanges,
                    selectedChange: gitStatus.selectedChange,
                    refreshState: gitStatus.refreshState,
                    isBusy: gitStatus.isBusy,
                    listIsFocused: isListFocused,
                    isListFocused: $isListFocused,
                    messageFocused: $messageFocused
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                VStack(spacing: 0) {
                    diffHeader
                    IDEEmbeddedDiffView(
                        workspace: workspace,
                        request: preview.request,
                        siblings: preview.siblings,
                        settingsPrefix: IDEDiffSettings.changesPrefix,
                        defaultLayout: .sideBySide,
                        reloadEpoch: gitStatus.lastAppliedRefreshEpoch,
                        reloadPaths: gitStatus.refreshedRelativePaths,
                        reloadRelativePath: preview.relativePath,
                        onRequestChanged: { request in
                            guard let path = request.filePath else { return }
                            let section: IDEGitChangeSection = request.indexAction == .unstage ? .staged : .unstaged
                            gitStatus.selectChange(row: IDEGitListedChange(section: section, path: path))
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } divider: {
                Splitter.rule()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            IDEChangesFileList(
                gitStatus: gitStatus,
                changes: gitStatus.changes,
                selectedChanges: gitStatus.selectedChanges,
                selectedChange: gitStatus.selectedChange,
                refreshState: gitStatus.refreshState,
                isBusy: gitStatus.isBusy,
                listIsFocused: isListFocused,
                isListFocused: $isListFocused,
                messageFocused: $messageFocused
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selected row's comparison. Nil when nothing is selected or the file left the list
    /// (a branch switch, a commit). The viewer is removed and its session cancelled.
    private var selectedChangePreview: IDEGitChangeDiff.Preview? {
        guard let row = gitStatus.selectedChange else { return nil }
        return IDEGitChangeDiff.preview(of: row.path, section: row.section, in: gitStatus.changes)
    }

    private var diffHeader: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(gitStatus.selectedChangePath.map { ($0 as NSString).lastPathComponent } ?? "")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            IDEIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Open in Diff Viewer") {
                openSelectedDiff()
            }
            IDEIconButton(systemImage: "xmark", help: "Close Diff") {
                gitStatus.selectChange(nil)
            }
        }
        .padding(.leading, IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.iconButton)
        .background(IDEAppearance.ColorToken.editor)
    }

    /// The selected row's diff in a tab. The section chooses which side.
    private func openSelectedDiff() {
        workspace.showSelectedChangeDiff()
    }

}

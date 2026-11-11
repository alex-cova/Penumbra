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

    private enum SubTab: String, CaseIterable, Identifiable {
        case log = "Log"
        case stashes = "Stashes"
        case compare = "Compare"
        case console = "Console"
        var id: String { rawValue }
    }

    @State private var subTab: SubTab = .log
    @State private var typeahead = IDETypeaheadBuffer()
    @State private var fileTypeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCommitFilesFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            subTabBar
            switch subTab {
            case .log:
                historyContent
            case .stashes:
                IDEGitStashPanel(gitStatus: gitStatus)
            case .compare:
                IDEGitCompareView(gitStatus: gitStatus)
            case .console:
                IDEGitConsoleView(repositoryRoot: gitStatus.repositoryRootPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IDEAppearance.ColorToken.editor)
        .clipped()
        .onAppear { gitStatus.loadHistory() }
        .onChange(of: gitStatus.comparison) { _, comparison in
            if comparison != nil { subTab = .compare }
        }
        .onAppear {
            gitStatus.requestShowStashes = { subTab = .stashes }
        }
    }

    /// Compare appears while a comparison is held; Log and Console are always there.
    private var visibleTabs: [SubTab] {
        SubTab.allCases.filter { $0 != .compare || gitStatus.comparison != nil }
    }

    private var subTabBar: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            ForEach(visibleTabs) { tab in
                Button { subTab = tab } label: {
                    Text(tab.rawValue)
                        .font(IDEAppearance.Typography.panelTab)
                        .foregroundStyle(subTab == tab ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            if let lineHistory = gitStatus.lineHistory {
                lineHistoryBar(lineHistory)
                splitContent(
                    list: lineHistoryList(lineHistory),
                    text: lineHistory.entries.first { $0.commit.hash == lineHistory.selectedHash }?.patch
                        ?? (lineHistory.entries.isEmpty || lineHistory.selectedHash != nil ? "Loading…" : nil),
                    listWidth: 380
                )
            } else {
            if let path = gitStatus.historyFilePath {
                fileHistoryBar(path)
            } else {
                historyFilters
            }
            splitContent(
                list: historyList,
                text: gitStatus.commitDetailText ?? (gitStatus.selectedCommitHashes.isEmpty ? nil : "Loading…"),
                listWidth: 380
            )
            }
        }
    }

    // MARK: Line history

    private func lineHistoryBar(_ history: IDEGitLineHistory) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("History of lines \(history.startLine)–\(history.endLine) of \((history.path as NSString).lastPathComponent)")
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                gitStatus.clearLineHistory()
            } label: {
                Label("All Commits", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func lineHistoryList(_ history: IDEGitLineHistory) -> some View {
        let hashes = history.entries.map(\.commit.hash)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let placeholder = IDEGitHistoryPlaceholder.text(
                        hasLoaded: history.hasLoaded,
                        isEmpty: history.entries.isEmpty,
                        fileScoped: false,
                        lineScoped: true
                    ) {
                        Text(placeholder)
                            .font(IDEAppearance.Typography.body)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .padding(IDEAppearance.Spacing.md)
                    }
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.commit.subject)
                                .font(IDEAppearance.Typography.tabLabel)
                                .lineLimit(1)
                            Text("\(entry.commit.shortHash)  \(entry.commit.author)")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(history.selectedHash == entry.commit.hash ? IDEAppearance.ColorToken.selection : Color.clear)
                        .gitRowFocusStroke(isOn: isListFocused && history.selectedHash == entry.commit.hash)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(.isButton)
                        .onTapGesture {
                            isListFocused = true
                            gitStatus.lineHistory?.selectedHash = entry.commit.hash
                        }
                        .id(entry.commit.hash)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleLineHistoryKey(press, hashes: hashes, subjects: history.entries.map(\.commit.subject))
            }
            .onChange(of: history.selectedHash) { _, hash in
                if let hash { proxy.scrollTo(hash) }
            }
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

            Menu {
                Button("Any Date") { gitStatus.setHistoryWindow(since: nil) }
                Divider()
                Button("Last 24 Hours") { gitStatus.setHistoryWindow(since: Date().addingTimeInterval(-86_400)) }
                Button("Last 7 Days") { gitStatus.setHistoryWindow(since: Date().addingTimeInterval(-7 * 86_400)) }
                Button("Last 30 Days") { gitStatus.setHistoryWindow(since: Date().addingTimeInterval(-30 * 86_400)) }
            } label: {
                Label(dateTitle, systemImage: "calendar")
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
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) {
                        isListFocused = true
                        if gitStatus.selectedCommitHash == nil {
                            gitStatus.moveCommitSelection(by: 1, in: gitStatus.commits.map(\.hash))
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if gitStatus.historySearch.isEmpty { return .ignored }
                        gitStatus.historySearch = ""
                        return .handled
                    }
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
    /// The two panes are separate cards with the standard `HandleSplitter` gap between them, the
    /// way Hextech lays out its list/detail panes, rather than one island cut by a 1pt rule.
    ///
    /// A `nil` `text` means nothing is selected: the diff pane shows `IDEGitCommitPlaceholder`
    /// instead of an empty text view.
    private func splitContent(list: some View, text: String?, listWidth: CGFloat = 280) -> some View {
        SplitPanes(
            minPrimary: 180,
            maxPrimary: 560,
            idealPrimary: listWidth,
            minSecondary: 240,
            storageKey: "umbra.sourceControl.listSplit"
        ) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .idePanel(fill: IDEAppearance.ColorToken.editor)
        } secondary: {
            VStack(spacing: 0) {
                if !gitStatus.commitBranches.isEmpty {
                    Text("In branches: \(gitStatus.commitBranches.prefix(8).joined(separator: ", "))\(gitStatus.commitBranches.count > 8 ? " …" : "")")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.vertical, 3)
                }
                if !gitStatus.selectedCommitFiles.isEmpty {
                    commitFiles
                    Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
                }
                if let selection = selectedCommitDiff {
                    // The diff editor for the picked file: chunks, word highlights, and it opens on
                    // the first change.
                    IDEEmbeddedDiffView(
                        workspace: workspace,
                        request: selection.request,
                        siblings: selection.siblings,
                        onRequestChanged: { request in
                            if let index = selection.siblings.firstIndex(where: { $0.id == request.id }),
                               selection.files.indices.contains(index) {
                                gitStatus.selectedCommitFile = selection.files[index].path
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text {
                    IDESourceControlDiffView(
                        text: text,
                        fontName: workspace.preferences.fontName,
                        fontSize: workspace.preferences.fontSize
                    )
                } else {
                    IDEGitCommitPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .idePanel(fill: IDEAppearance.ColorToken.editor)
        }
        .padding(.horizontal, IDEAppearance.Spacing.panelGap)
        .padding(.bottom, IDEAppearance.Spacing.panelGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The selected commit's files; a click opens one against the commit's parent in a diff tab.
    private var commitFiles: some View {
        let files = gitStatus.selectedCommitFiles
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    IDECommitAllChangesRow(
                        isSelected: gitStatus.selectedCommitFile == nil,
                        showsFocus: isCommitFilesFocused && gitStatus.selectedCommitFile == nil
                    ) {
                        isCommitFilesFocused = true
                        gitStatus.selectedCommitFile = nil
                    }
                    .id("all")
                    ForEach(files) { file in
                        IDECommitFileRow(
                            file: file,
                            isSelected: gitStatus.selectedCommitFile == file.path,
                            showsFocus: isCommitFilesFocused && gitStatus.selectedCommitFile == file.path,
                            onSelect: {
                                isCommitFilesFocused = true
                                gitStatus.selectedCommitFile = file.path
                            },
                            onOpenInTab: { openCommitFile(file, in: files) }
                        )
                        .id(file.path)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isCommitFilesFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleCommitFilesKey(press, files: files)
            }
            .onChange(of: gitStatus.selectedCommitFile) { _, path in
                proxy.scrollTo(path ?? "all")
            }
        }
        .frame(maxHeight: min(CGFloat(files.count) * 22 + 8, 140))
    }

    private func handleCommitFilesKey(_ press: KeyPress, files: [GitChangedFile]) -> KeyPress.Result {
        let paths = files.map(\.path)
        switch press.key {
        case .upArrow, .downArrow:
            fileTypeahead.reset()
            gitStatus.moveCommitFileSelection(by: press.key == .downArrow ? 1 : -1, in: paths)
            isCommitFilesFocused = true
            return .handled
        case .return:
            fileTypeahead.reset()
            if let path = gitStatus.selectedCommitFile, let file = files.first(where: { $0.path == path }) {
                openCommitFile(file, in: files)
            }
            return .handled
        case .escape:
            fileTypeahead.reset()
            isListFocused = true
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            let items = [""] + paths
            if let path = IDEListTypeahead.match(
                query: fileTypeahead.typed(character),
                in: items,
                selected: gitStatus.selectedCommitFile ?? "",
                title: { $0.isEmpty ? "All changes" : ($0 as NSString).lastPathComponent }
            ) {
                gitStatus.selectedCommitFile = path.isEmpty ? nil : path
                isCommitFilesFocused = true
            }
            return .handled
        }
    }

    private func openCommitFile(_ file: GitChangedFile, in files: [GitChangedFile]) {
        guard let hash = gitStatus.selectedCommitHash else { return }
        workspace.openCommitDiff(hash: hash, shortHash: shortHash(of: hash), file: file, files: files)
    }

    private func shortHash(of hash: String) -> String {
        gitStatus.commits.first { $0.hash == hash }?.shortHash ?? String(hash.prefix(7))
    }

    /// The request for the file picked under the commit, with the commit's other files as siblings.
    private var selectedCommitDiff: (request: IDEDiffRequest, siblings: [IDEDiffRequest], files: [GitChangedFile])? {
        guard let hash = gitStatus.selectedCommitHash, let path = gitStatus.selectedCommitFile else { return nil }
        let files = gitStatus.selectedCommitFiles
        guard let index = files.firstIndex(where: { $0.path == path }) else { return nil }
        let requests = workspace.commitDiffRequests(hash: hash, shortHash: shortHash(of: hash), files: files)
        guard requests.indices.contains(index) else { return nil }
        return (requests[index], requests, files)
    }

    private var dateTitle: String {
        guard let since = gitStatus.historySince else { return "Any Date" }
        let days = Int((Date().timeIntervalSince(since) / 86_400).rounded())
        return days <= 1 ? "Last 24 Hours" : "Last \(days) Days"
    }

    /// Plain click selects one commit, ⌘-click toggles it, ⇧-click extends from the primary one.
    private func selectCommitRow(_ commit: IDEGitCommit) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            gitStatus.toggleCommitSelection(commit.hash)
        } else if flags.contains(.shift) {
            gitStatus.extendCommitSelection(to: commit.hash)
        } else {
            gitStatus.selectCommit(commit.hash)
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: IDEGitCommit) -> some View {
        let targets = gitStatus.commitsForAction(on: commit.hash)
        let single = targets.count == 1
        let isHead = commit.hash == gitStatus.headCommitHash
        Button("Copy Revision") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.hash).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Checkout Revision") { gitStatus.checkoutCommit(commit.hash) }.disabled(!single)
        Button("Compare with \(gitStatus.currentBranch ?? "Current")") { gitStatus.compare(with: commit.hash) }
            .disabled(!single || gitStatus.currentBranch == nil)
        Divider()
        Button(single ? "Cherry-Pick" : "Cherry-Pick \(targets.count) Commits") { gitStatus.cherryPick(targets.map(\.hash)) }
            .disabled(isHead && single)
        Button(single ? "Revert Commit" : "Revert \(targets.count) Commits") { gitStatus.revertCommits(targets.map(\.hash)) }
        Divider()
        Button("New Branch from Here…") { gitStatus.requestNewBranch(from: commit) }.disabled(!single)
        Button("New Tag Here…") { gitStatus.requestNewTag(at: commit) }.disabled(!single)
        Divider()
        Button("Reset Current Branch to Here…") { gitStatus.requestReset(to: commit) }.disabled(!single)
        Button("Undo Commit") { gitStatus.undoLastCommit() }.disabled(!(isHead && single))
        Button("Edit Commit Message…") { gitStatus.requestEditMessage(of: commit) }.disabled(!single)
        Button("Squash \(targets.count) Commits…") { gitStatus.requestSquash(targets) }.disabled(targets.count < 2)
        Button("Fixup Into Parent") { gitStatus.fixupIntoParent(commit) }
            .disabled(!single || commit.parents.count != 1)
        Button(single ? "Drop Commit…" : "Drop \(targets.count) Commits…", role: .destructive) { gitStatus.requestDrop(targets) }
        Button("Interactively Rebase from Here…") { gitStatus.requestInteractiveRebase(from: commit) }.disabled(!single)
        Divider()
        Button("Push All up to Here…") { gitStatus.requestPush(upTo: commit) }.disabled(!single)
        Button("Open on Web") { workspace.openCommitOnWeb(commit.hash) }.disabled(!single)
        Button("Copy Web Link") { workspace.openCommitOnWeb(commit.hash, copy: true) }.disabled(!single)
        Button("Go to Parent") { gitStatus.goToParent(of: commit) }
            .disabled(!single || !gitStatus.commits.contains { $0.hash == commit.parents.first })
        Button("Go to Child") { gitStatus.goToChild(of: commit) }
            .disabled(!single || !gitStatus.commits.contains { $0.parents.contains(commit.hash) })
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let placeholder = IDEGitHistoryPlaceholder.text(
                        hasLoaded: gitStatus.historyDidLoad,
                        isEmpty: gitStatus.commits.isEmpty,
                        fileScoped: gitStatus.historyFilePath != nil,
                        lineScoped: false
                    ) {
                        Text(placeholder)
                            .font(IDEAppearance.Typography.body)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.top, IDEAppearance.Spacing.sm)
                    }
                    ForEach(gitStatus.commits) { commit in
                        IDESourceControlCommitRow(
                            commit: commit,
                            isSelected: gitStatus.selectedCommitHashes.contains(commit.hash),
                            showsFocus: isListFocused && gitStatus.selectedCommitHashes.contains(commit.hash),
                            onSelect: {
                                isListFocused = true
                                selectCommitRow(commit)
                            }
                        )
                        .id(commit.hash)
                        .contextMenu { commitMenu(commit) }
                    }
                    if gitStatus.hasMoreHistory {
                        Button("Load More…") { gitStatus.loadMoreHistory() }
                            .buttonStyle(.plain)
                            .foregroundStyle(IDEAppearance.ColorToken.accent)
                            .font(IDEAppearance.Typography.caption)
                            .padding(IDEAppearance.Spacing.md)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleHistoryKey(press)
            }
            .onChange(of: gitStatus.selectedCommitHash) { _, hash in
                if let hash { proxy.scrollTo(hash) }
            }
        }
    }

    private func handleHistoryKey(_ press: KeyPress) -> KeyPress.Result {
        let hashes = gitStatus.commits.map(\.hash)
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            guard let next = IDEListNeighbor.move(gitStatus.selectedCommitHash, in: hashes, by: delta) else {
                return .handled
            }
            if press.modifiers.contains(.shift) {
                gitStatus.extendCommitSelection(to: next)
            } else {
                gitStatus.selectCommit(next)
            }
            isListFocused = true
            return .handled
        case .return:
            typeahead.reset()
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
            if let hash = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: hashes,
                selected: gitStatus.selectedCommitHash,
                title: { hash in gitStatus.commits.first { $0.hash == hash }?.subject ?? "" }
            ) {
                gitStatus.selectCommit(hash)
                isListFocused = true
            }
            return .handled
        }
    }

    private func handleLineHistoryKey(_ press: KeyPress, hashes: [String], subjects: [String]) -> KeyPress.Result {
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let next = IDEListNeighbor.move(gitStatus.lineHistory?.selectedHash, in: hashes, by: delta) {
                gitStatus.lineHistory?.selectedHash = next
                isListFocused = true
            }
            return .handled
        case .return:
            typeahead.reset()
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            let titles = Dictionary(uniqueKeysWithValues: zip(hashes, subjects))
            if let hash = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: hashes,
                selected: gitStatus.lineHistory?.selectedHash,
                title: { titles[$0] ?? "" }
            ) {
                gitStatus.lineHistory?.selectedHash = hash
                isListFocused = true
            }
            return .handled
        }
    }
}

/// Conflicts, then staged, then unstaged. The commit field's down arrow uses the same rows as the list.
fileprivate func ideGitVisibleChangePaths(_ changes: [IDEGitChange]) -> [String] {
    IDEGitChangeRows.listed(in: changes).map(\.path)
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
    @FocusState private var isListFocused: Bool

    init(gitStatus: IDEGitStatusModel) {
        self._gitStatus = Bindable(wrappedValue: gitStatus)
    }

    private var canCommit: Bool {
        let hasStaged = gitStatus.changes.contains { $0.staged != nil && $0.staged != .conflicted }
        return !gitStatus.isBusy
            && !gitStatus.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasStaged || gitStatus.commitOptions.amend)
    }

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDEChangesPanel")
        VStack(spacing: 0) {
            IDEGitOperationBanner(gitStatus: gitStatus)
            if IDEGitChrome.showsCommitControls(gitStatus.refreshState) {
                messageField
                commitRow
            }
            if gitStatus.isNetworkBusy { networkProgressRow }
            if IDEGitChrome.showsCommitControls(gitStatus.refreshState) {
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
            Button(gitStatus.commitOptions.amend ? "Amend" : "Commit") { gitStatus.commit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canCommit)
                .help(gitStatus.changes.contains { $0.staged != nil && $0.staged != .conflicted } || gitStatus.commitOptions.amend
                    ? "Commit the staged files (⌘↩)" : "Stage files to commit them")

            Button("Commit and Push…") {
                var options = gitStatus.commitOptions
                options.pushAfter = true
                gitStatus.requestCommit(options: options)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canCommit)
            .help("Commit, then open the push dialog (⌥⌘K)")
            .keyboardShortcut("k", modifiers: [.command, .option])

            commitOptionsMenu

            optionsMenu

            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.sm)
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
        IDEIconMenu(systemImage: "slider.horizontal.3", help: "Stage, discard and branch actions") {
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
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.bottom, IDEAppearance.Spacing.xs)
    }

    private var changedFilesHeader: some View {
        Button {
            IDEAppearance.Motion.animate(IDEAppearance.Motion.quick) { changedFilesExpanded.toggle() }
        } label: {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                IDEDisclosureChevron(isExpanded: changedFilesExpanded)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
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

/// The Changes file list. Its body does not read `commitMessage`. The parent passes the snapshot
/// the list paints, and `EquatableView` skips this body when a commit-field edit leaves that
/// snapshot unchanged.
private struct IDEChangesFileList: View, Equatable {
    @Environment(IDEWorkspace.self) private var workspace
    var gitStatus: IDEGitStatusModel
    /// Sendable snapshot fields. Equality is nonisolated so `EquatableView` can skip this body
    /// without crossing the main actor.
    nonisolated let changes: [IDEGitChange]
    nonisolated let selectedChanges: Set<IDEGitListedChange>
    nonisolated let selectedChange: IDEGitListedChange?
    /// Compared so a refresh-state change updates the list. The rows themselves paint `changes`.
    nonisolated let refreshState: GitRefreshState
    /// Compared so a busy change updates the list. Row actions still call the model directly.
    nonisolated let isBusy: Bool
    nonisolated let listIsFocused: Bool
    var isListFocused: FocusState<Bool>.Binding
    var messageFocused: FocusState<Bool>.Binding

    @State private var typeahead = IDETypeaheadBuffer()
    @State private var scrollToken: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.changes == rhs.changes
            && lhs.selectedChanges == rhs.selectedChanges
            && lhs.selectedChange == rhs.selectedChange
            && lhs.refreshState == rhs.refreshState
            && lhs.isBusy == rhs.isBusy
            && lhs.listIsFocused == rhs.listIsFocused
    }

    var body: some View {
        let conflicted = conflictedChanges
        let staged = stagedChanges
        let unstaged = unstagedChanges
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                    if !conflicted.isEmpty {
                        sectionHeader("Conflicts", count: conflicted.count)
                        ForEach(conflicted) { change in
                            IDEConflictRow(
                                change: change,
                                isSelected: selectedChanges.contains(IDEGitListedChange(section: .conflict, path: change.path)),
                                showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .conflict, path: change.path),
                                onSelect: {
                                    let row = IDEGitListedChange(section: .conflict, path: change.path)
                                    isListFocused.wrappedValue = true
                                    scrollToken = row.scrollID
                                    select(change, section: .conflict, in: conflicted)
                                },
                                onMerge: { workspace.openMergeTool(forPath: change.path) },
                                onTakeYours: { gitStatus.resolve(paths: [change.path], taking: .ours) },
                                onTakeTheirs: { gitStatus.resolve(paths: [change.path], taking: .theirs) },
                                onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } }
                            )
                            .id(IDEGitChangeListIdentity.id(section: .conflict, path: change.path))
                        }
                    }
                    if staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty {
                        Text("No changes")
                            .font(IDEAppearance.Typography.body)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .padding(.horizontal, IDEAppearance.Spacing.md)
                            .padding(.top, IDEAppearance.Spacing.sm)
                    } else {
                        if !staged.isEmpty {
                            sectionHeader("Staged Changes", count: staged.count)
                            ForEach(staged) { change in
                                IDESourceControlChangeRow(
                                    change: change,
                                    section: .staged,
                                    isSelected: selectedChanges.contains(IDEGitListedChange(section: .staged, path: change.path)),
                                    showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .staged, path: change.path),
                                    showsStage: false,
                                    onSelect: {
                                        let row = IDEGitListedChange(section: .staged, path: change.path)
                                        isListFocused.wrappedValue = true
                                        scrollToken = row.scrollID
                                        select(change, section: .staged, in: staged)
                                    },
                                    onOpen: { workspace.openChangeDiff(path: change.path, staged: true) },
                                    onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                    onStage: {},
                                    onUnstage: { gitStatus.unstage(paths: actionPaths(from: change, section: .staged)) },
                                    onRevert: { revert(from: change, section: .staged) }
                                )
                                .id(IDEGitChangeListIdentity.id(section: .staged, path: change.path))
                            }
                        }
                        if !unstaged.isEmpty {
                            sectionHeader("Changes", count: unstaged.count)
                            ForEach(unstaged) { change in
                                IDESourceControlChangeRow(
                                    change: change,
                                    section: .unstaged,
                                    isSelected: selectedChanges.contains(IDEGitListedChange(section: .unstaged, path: change.path)),
                                    showsFocus: listIsFocused && selectedChange == IDEGitListedChange(section: .unstaged, path: change.path),
                                    showsStage: true,
                                    onSelect: {
                                        let row = IDEGitListedChange(section: .unstaged, path: change.path)
                                        isListFocused.wrappedValue = true
                                        scrollToken = row.scrollID
                                        select(change, section: .unstaged, in: unstaged)
                                    },
                                    onOpen: { workspace.openChangeDiff(path: change.path, staged: false) },
                                    onOpenFile: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                    onStage: { gitStatus.stage(paths: actionPaths(from: change, section: .unstaged)) },
                                    onUnstage: {},
                                    onRevert: { revert(from: change, section: .unstaged) }
                                )
                                .id(IDEGitChangeListIdentity.id(section: .unstaged, path: change.path))
                            }
                        }
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.sm)
            }
            .focusable()
            .focused(isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleListKey(press)
            }
            .onChange(of: selectedChange) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.scrollID)
            }
            .onChange(of: scrollToken) { _, token in
                if let token { proxy.scrollTo(token) }
            }
        }
    }

    /// Conflicts, then staged, then unstaged — the order the list paints.
    private var visibleRows: [IDEGitListedChange] {
        IDEGitChangeRows.listed(in: changes)
    }

    private var conflictedChanges: [IDEGitChange] {
        changes.filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
    }

    private var stagedChanges: [IDEGitChange] {
        changes.filter { $0.staged != nil && $0.staged != .conflicted }
    }

    private var unstagedChanges: [IDEGitChange] {
        changes.filter { $0.unstaged != nil && $0.unstaged != .conflicted }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let rows = visibleRows
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            guard let next = IDEListNeighbor.move(gitStatus.selectedChange, in: rows, by: delta) else {
                return .handled
            }
            isListFocused.wrappedValue = true
            scrollToken = next.scrollID
            if press.modifiers.contains(.shift) {
                gitStatus.extendChangeSelection(to: next, in: rows)
            } else {
                gitStatus.selectChange(row: next)
            }
            return .handled
        case .return:
            typeahead.reset()
            activateSelectedChange()
            return .handled
        case .escape:
            typeahead.reset()
            messageFocused.wrappedValue = true
            workspace.isChangesListFocused = false
            return .handled
        default:
            // The Save menu consumes ⌘S before this view when that menu item is installed.
            // This runs only when no menu equivalent takes the key. ⌘U is not a menu key.
            if let action = IDEGitListShortcut.action(characters: press.characters, modifiers: press.modifiers) {
                typeahead.reset()
                switch action {
                case .stage: workspace.stageSelectedChanges()
                case .unstage: workspace.unstageSelectedChanges()
                }
                return .handled
            }
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: rows,
                selected: gitStatus.selectedChange,
                title: { ($0.path as NSString).lastPathComponent }
            ) {
                gitStatus.selectChange(row: row)
                scrollToken = row.scrollID
            }
            return .handled
        }
    }

    private func activateSelectedChange() {
        guard let row = gitStatus.selectedChange,
              let change = changes.first(where: { $0.path == row.path }) else { return }
        if row.section == .conflict || change.unstaged == .conflicted || change.staged == .conflicted {
            workspace.openMergeTool(forPath: row.path)
        } else {
            workspace.openChangeDiff(path: row.path, staged: row.section == .staged)
        }
    }

    /// Plain click selects one row, ⌘-click toggles it, ⇧-click extends inside this section.
    private func select(_ change: IDEGitChange, section: IDEGitChangeSection, in visible: [IDEGitChange]) {
        let row = IDEGitListedChange(section: section, path: change.path)
        let rows = visible.map { IDEGitListedChange(section: section, path: $0.path) }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            gitStatus.toggleChangeSelection(row: row)
        } else if flags.contains(.shift) {
            gitStatus.extendChangeSelection(to: row, in: rows)
        } else {
            gitStatus.selectChange(row: row)
        }
    }

    /// The context menu acts on the whole selection when this row is part of it, else on that row.
    private func actionPaths(from change: IDEGitChange, section: IDEGitChangeSection) -> [String] {
        let row = IDEGitListedChange(section: section, path: change.path)
        guard selectedChanges.contains(row) else { return [change.path] }
        var seen = Set<String>()
        return IDEGitChangeRows.listed(in: changes).compactMap { listed in
            guard selectedChanges.contains(listed), seen.insert(listed.path).inserted else { return nil }
            return listed.path
        }
    }

    private func revert(from change: IDEGitChange, section: IDEGitChangeSection) {
        workspace.revertChanges(actionPaths(from: change, section: section))
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
                    Button("Fast-Forward & Push") { gitStatus.pullAndPush() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(gitStatus.isBusy || (sync.ahead == 0 && sync.behind == 0))
                        .help("Pull (fast-forward only), then push")
                }
            }

            if let branch = gitStatus.currentBranch {
                IDEUnsyncedRow(
                    name: branch,
                    tint: IDEAppearance.ColorToken.accent,
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
                    tint: IDEAppearance.ColorToken.muted,
                    count: sync.behind,
                    countHint: "not pulled",
                    commits: sync.incoming,
                    isExpanded: $incomingExpanded,
                    buttonTitle: "Fast-Forward",
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
                    if canExpand { IDEAppearance.Motion.animate(IDEAppearance.Motion.quick) { isExpanded.toggle() } }
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        IDEDisclosureChevron(isExpanded: isExpanded && canExpand)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .opacity(canExpand ? 1 : 0.35)
                        Text(name)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: IDEAppearance.Radius.selection, style: .continuous)
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

/// Focus indicator for a Git list row. The list's scroll view sits inside a clipped panel, so the
/// system focus ring is clipped over the first and last rows. The ring stays off
/// (`focusEffectDisabled`) and the selected row draws a 1 pt accent stroke while the list is focused.
extension View {
    func gitRowFocusStroke(isOn: Bool) -> some View {
        overlay {
            if isOn {
                Rectangle()
                    .strokeBorder(IDEAppearance.ColorToken.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// One file of a commit: its status letter and path. Clicking opens its diff.
/// The first row of a commit's file list: back to the whole patch with the commit message.
private struct IDECommitAllChangesRow: View {
    let isSelected: Bool
    var showsFocus = false
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "doc.plaintext")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)
            Text("All changes")
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 22)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
        .gitRowFocusStroke(isOn: showsFocus)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help("Show the whole commit")
    }
}

/// A file of the selected commit. A click shows its diff under the list; a double-click or the
/// arrow opens it in a tab.
private struct IDECommitFileRow: View {
    let file: GitChangedFile
    let isSelected: Bool
    var showsFocus = false
    let onSelect: () -> Void
    let onOpenInTab: () -> Void
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
            if isHovering || isSelected {
                IDEIconButton(systemImage: "arrow.up.forward.square", help: "Open in Diff Tab", action: onOpenInTab)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .frame(height: 22)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
        .gitRowFocusStroke(isOn: showsFocus)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture(count: 2, perform: onOpenInTab)
        .onTapGesture(perform: onSelect)
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
    var showsFocus = false
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let graph = commit.graph {
                IDEGitGraphView(row: graph)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(refsPrefix).foregroundStyle(IDEAppearance.ColorToken.gitAdded))\(Text(commit.subject).foregroundStyle(IDEAppearance.ColorToken.foreground))")
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
        .gitRowFocusStroke(isOn: showsFocus)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var refsPrefix: String {
        commit.refs.isEmpty ? "" : "[\(commit.refs)] "
    }
}

private struct IDESourceControlChangeRow: View {
    let change: IDEGitChange
    let section: IDEGitChangeSection
    let isSelected: Bool
    var showsFocus = false
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
        let _ = IDEBodyDiagnostics.note("IDESourceControlChangeRow")
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button(action: showsStage ? onStage : onUnstage) {
                Image(systemName: showsStage ? "plus.circle" : "minus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
            }
            .buttonStyle(.plain)
            .help(showsStage ? "Stage File" : "Unstage File")
            .accessibilityLabel(showsStage ? "Stage File" : "Unstage File")

            Image(systemName: IDEFileIcon.systemName(forFilename: change.relativePath))
                .font(.system(size: 11))
                .foregroundStyle(letterColor)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(presentation.title(path: change.relativePath))
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            Text(presentation.letter)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(letterColor)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(rowBackground)
        .gitRowFocusStroke(isOn: showsFocus)
        .contentShape(Rectangle())
        // Double-tap first: the earlier modifier wins, so a single tap declared before it would
        // consume the click and the double never fired.
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel(path: change.relativePath, section: section))
        .accessibilityAddTraits(.isButton)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            if showsStage {
                Button("Stage", action: onStage)
            } else {
                Button("Unstage", action: onUnstage)
            }
            Button("Show Diff", action: onOpen)
            Button("Open File", action: onOpenFile)
            Divider()
            Button("Discard Changes…", action: onRevert)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
    }

    private var presentation: IDEGitChangePresentation {
        change.presentation(in: section)
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

    private var letterColor: Color {
        switch IDEGitLetterTint.tint(forLetter: presentation.letter) {
        case .added: IDEAppearance.ColorToken.gitAdded
        case .modified: IDEAppearance.ColorToken.gitModified
        case .deleted: IDEAppearance.ColorToken.error
        case .conflict: IDEAppearance.ColorToken.gitConflict
        case .ignored: IDEAppearance.ColorToken.gitIgnored
        case .muted: IDEAppearance.ColorToken.muted
        }
    }
}

struct IDESourceControlDiffView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: Double

    /// The `diff --git` stripe. A blend of the editor background and the foreground, so a light
    /// editor does not get a translucent white wash.
    static var gitHeaderBandColor: NSColor {
        IDEAppearance.NSToken.editor.blended(withFraction: 0.08, of: IDEAppearance.NSToken.foreground)
            ?? IDEAppearance.NSToken.editor
    }

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
            let headerBand = IDESourceControlDiffView.gitHeaderBandColor
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
                    band = headerBand
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
        IDEIconButton(
            systemImage: "arrow.clockwise",
            help: "Refresh",
            isDisabled: workspace.gitStatus.isBusy
        ) {
            workspace.gitStatus.refresh()
            workspace.gitStatus.loadHistory()
        }
        .accessibilityLabel("Refresh History")
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

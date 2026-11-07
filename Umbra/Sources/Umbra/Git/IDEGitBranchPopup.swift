import GitIntelligence
import SwiftUI

/// The branch popup (IntelliJ's branches widget): what to do with the repository as a whole, then
/// local and remote branches and tags with a search field. A row's context menu has the rest.
struct IDEGitBranchPopup: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    private var gitStatus: IDEGitStatusModel { workspace.gitStatus }

    private var keyboardIDs: [String] {
        IDEGitBranchPopupKeyboard.order(
            showingActions: query.isEmpty,
            localIDs: locals.map(\.id),
            remoteIDs: remotes.map(\.id),
            tagNames: tags.map(\.name)
        )
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private var locals: [GitBranch] {
        gitStatus.branchInfos.filter { $0.kind == .local && matches($0.name) }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.lastCommitDate > rhs.lastCommitDate
            }
    }

    private var remotes: [GitBranch] {
        gitStatus.branchInfos.filter { $0.kind == .remote && matches($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var tags: [GitTag] {
        gitStatus.tags.filter { matches($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(IDEAppearance.ColorToken.muted)
                TextField("Search branches and tags", text: $query)
                    .textFieldStyle(.plain)
                    .font(IDEAppearance.Typography.body)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) {
                        isListFocused = true
                        if selectedID == nil { selectedID = keyboardIDs.first }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if query.isEmpty {
                            isPresented = false
                        } else {
                            query = ""
                        }
                        return .handled
                    }
            }
            .padding(IDEAppearance.Spacing.sm)
            Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty { actions }
                        group("Local", locals.map { .branch($0) })
                        group("Remote", remotes.map { .branch($0) })
                        group("Tags", tags.map { .tag($0) })
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleListKey(press)
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(width: 360, height: 440)
        .onAppear {
            isSearchFocused = true
            gitStatus.loadTags()
            gitStatus.loadRemotes()
        }
        .onChange(of: query) { _, _ in
            if let selectedID, !keyboardIDs.contains(selectedID) {
                self.selectedID = keyboardIDs.first
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        ForEach(IDEGitBranchPopupKeyboard.Action.allCases, id: \.id) { action in
            actionRow(action)
        }
        Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1).padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func actionRow(_ action: IDEGitBranchPopupKeyboard.Action) -> some View {
        let isSelected = selectedID == action.id
        return Button {
            selectedID = action.id
            run(action)
        } label: {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: action.systemImage).frame(width: 16).foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(action.title)
                Spacer(minLength: 0)
            }
            .font(IDEAppearance.Typography.body)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(action.id)
    }

    // MARK: Rows

    private enum Item: Identifiable {
        case branch(GitBranch)
        case tag(GitTag)

        var id: String {
            switch self {
            case .branch(let branch): branch.id
            case .tag(let tag): "tag/\(tag.name)"
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.top, IDEAppearance.Spacing.sm)
                .padding(.bottom, IDEAppearance.Spacing.xxs)
            ForEach(items) { item in
                switch item {
                case .branch(let branch): branchRow(branch)
                case .tag(let tag): tagRow(tag)
                }
            }
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        let isSelected = selectedID == branch.id
        return Button {
            selectedID = branch.id
            isPresented = false
            gitStatus.checkout(branch)
        } label: {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(branch.isCurrent ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                Text(branch.name).lineLimit(1).truncationMode(.middle)
                if branch.upstreamIsGone {
                    Text("gone").foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                }
                Spacer(minLength: 0)
                if branch.ahead > 0 { badge("↑\(branch.ahead)") }
                if branch.behind > 0 { badge("↓\(branch.behind)") }
            }
            .font(IDEAppearance.Typography.body)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(branch.id)
        .contextMenu { branchMenu(branch) }
    }

    private func tagRow(_ tag: GitTag) -> some View {
        let id = IDEGitBranchPopupKeyboard.tagID(tag.name)
        let isSelected = selectedID == id
        return Button {
            selectedID = id
            isPresented = false
            gitStatus.checkoutRevision(tag.name)
        } label: {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: "tag").font(.system(size: 11)).frame(width: 16)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(tag.name).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(tag.commit.prefix(7)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .font(IDEAppearance.Typography.body)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
        .contextMenu {
            Button("Checkout") { isPresented = false; gitStatus.checkoutRevision(tag.name) }
            Button("New Branch from Tag…") { promptNewBranch(from: tag.name) }
            Button("Push Tag") { gitStatus.pushTag(tag.name) }
            Divider()
            Button("Delete Tag", role: .destructive) { gitStatus.deleteTag(tag.name) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    @ViewBuilder
    private func branchMenu(_ branch: GitBranch) -> some View {
        if !branch.isCurrent {
            Button("Checkout") { isPresented = false; gitStatus.checkout(branch) }
        }
        Button("New Branch from \(branch.name)…") { promptNewBranch(from: branch.name) }
        if !branch.isCurrent {
            Divider()
            Button("Compare with \(gitStatus.currentBranch ?? "Current")") {
                isPresented = false
                gitStatus.compare(with: branch.name)
            }
            Button("Show Diff with Working Tree") {
                isPresented = false
                workspace.openWorkingTreeDiff(against: .ref(branch.name), title: branch.name)
            }
        }
        if branch.kind == .remote || branch.upstream != nil {
            Button("Open on Web") { workspace.openBranchOnWeb(branch.shortName) }
        }
        if !branch.isCurrent {
            Divider()
            Button("Merge \(branch.name) into \(gitStatus.currentBranch ?? "Current")") {
                isPresented = false
                gitStatus.merge(branch.name)
            }
            Button("Rebase \(gitStatus.currentBranch ?? "Current") onto \(branch.name)") {
                isPresented = false
                gitStatus.rebase(onto: branch.name)
            }
            .disabled(gitStatus.currentBranch == nil)
        }
        if branch.kind == .local {
            Divider()
            Button("Rename…") {
                gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
                    title: "Rename Branch", message: "New name for \(branch.name).", placeholder: "Branch name",
                    initial: branch.name, confirmTitle: "Rename",
                    action: { gitStatus.renameBranch(branch.name, to: $0) }
                )))
            }
            if !branch.isCurrent {
                Button("Delete", role: .destructive) { gitStatus.deleteBranch(branch.name) }
                    .disabled(IDEGitPreferences.isProtected(branch.name))
            }
        } else {
            Divider()
            Button("Delete from \(branch.remoteName ?? "Remote")…", role: .destructive) {
                gitStatus.sheets.present(.confirm(IDEGitConfirmation(
                    title: "Delete Remote Branch?",
                    message: "\(branch.name) will be deleted on the remote for everyone.",
                    confirmTitle: "Delete",
                    isDestructive: true,
                    action: { gitStatus.deleteRemoteBranch(branch) }
                )))
            }
            .disabled(IDEGitPreferences.isProtected(branch.shortName))
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = keyboardIDs
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            if let next = IDEListNeighbor.move(selectedID, in: ids, by: press.key == .downArrow ? 1 : -1) {
                selectedID = next
                isListFocused = true
            }
            return .handled
        case .return:
            typeahead.reset()
            activate(selectedID)
            return .handled
        case .escape:
            typeahead.reset()
            if isSearchFocused {
                isSearchFocused = false
                return .handled
            }
            isPresented = false
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            let titles = titlesByID
            if let id = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: ids,
                selected: selectedID,
                title: { titles[$0] ?? $0 }
            ) {
                selectedID = id
                isListFocused = true
            }
            return .handled
        }
    }

    private var titlesByID: [String: String] {
        var titles: [String: String] = [:]
        for action in IDEGitBranchPopupKeyboard.Action.allCases { titles[action.id] = action.title }
        for branch in locals + remotes { titles[branch.id] = branch.name }
        for tag in tags { titles[IDEGitBranchPopupKeyboard.tagID(tag.name)] = tag.name }
        return titles
    }

    private func activate(_ id: String?) {
        guard let id else { return }
        if let action = IDEGitBranchPopupKeyboard.Action(id: id) {
            run(action)
            return
        }
        if id.hasPrefix("tag/") {
            isPresented = false
            gitStatus.checkoutRevision(String(id.dropFirst(4)))
            return
        }
        if let branch = (locals + remotes).first(where: { $0.id == id }) {
            isPresented = false
            gitStatus.checkout(branch)
        }
    }

    private func run(_ action: IDEGitBranchPopupKeyboard.Action) {
        isPresented = false
        switch action {
        case .update: workspace.pullProject()
        case .fetch: gitStatus.fetch()
        case .push: workspace.pushProject()
        case .newBranch: promptNewBranch(from: gitStatus.currentBranch)
        case .checkoutRevision:
            gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
                title: "Checkout Tag or Revision",
                message: "A tag, a commit id or any revision. HEAD becomes detached.",
                placeholder: "v1.0 or a1b2c3d",
                confirmTitle: "Checkout",
                action: { gitStatus.checkoutRevision($0) }
            )))
        case .deleteMerged: gitStatus.requestDeleteMergedBranches()
        }
    }

    private func promptNewBranch(from base: String?) {
        isPresented = false
        gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Branch",
            message: base.map { "Create a branch from \($0) and switch to it." } ?? "Create a branch at HEAD and switch to it.",
            placeholder: "Branch name",
            confirmTitle: "Create",
            validate: { name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "Enter a branch name." }
                if trimmed.hasPrefix("-") { return "A branch name cannot start with a dash." }
                if trimmed.contains(" ") { return "A branch name cannot contain spaces." }
                if gitStatus.branchInfos.contains(where: { $0.kind == .local && $0.name == trimmed }) {
                    return "A branch named \(trimmed) already exists."
                }
                return nil
            },
            action: { gitStatus.createBranch($0, from: base) }
        )))
    }
}

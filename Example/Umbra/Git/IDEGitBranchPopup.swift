import GitIntelligence
import SwiftUI

/// The branch popup (IntelliJ's branches widget): what to do with the repository as a whole, then
/// local and remote branches and tags with a search field. A row's context menu has the rest.
struct IDEGitBranchPopup: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Binding var isPresented: Bool
    @State private var query = ""

    private var gitStatus: IDEGitStatusModel { workspace.gitStatus }

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
            }
            .padding(IDEAppearance.Spacing.sm)
            Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty { actions }
                    group("Local", locals.map { .branch($0) })
                    group("Remote", remotes.map { .branch($0) })
                    group("Tags", tags.map { .tag($0) })
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
        }
        .frame(width: 360, height: 440)
        .onAppear {
            gitStatus.loadTags()
            gitStatus.loadRemotes()
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        actionRow("Update Project…", systemImage: "arrow.down.circle") { workspace.pullProject() }
        actionRow("Fetch", systemImage: "arrow.triangle.2.circlepath") { gitStatus.fetch() }
        actionRow("Push…", systemImage: "arrow.up.circle") { workspace.pushProject() }
        actionRow("New Branch…", systemImage: "plus") {
            promptNewBranch(from: gitStatus.currentBranch)
        }
        actionRow("Checkout Tag or Revision…", systemImage: "tag") {
            gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
                title: "Checkout Tag or Revision",
                message: "A tag, a commit id or any revision. HEAD becomes detached.",
                placeholder: "v1.0 or a1b2c3d",
                confirmTitle: "Checkout",
                action: { gitStatus.checkoutRevision($0) }
            )))
        }
        actionRow("Delete Merged Branches…", systemImage: "trash") { gitStatus.requestDeleteMergedBranches() }
        Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1).padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: systemImage).frame(width: 16).foregroundStyle(IDEAppearance.ColorToken.muted)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(IDEAppearance.Typography.body)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .padding(.bottom, 2)
            ForEach(items) { item in
                switch item {
                case .branch(let branch): branchRow(branch)
                case .tag(let tag): tagRow(tag)
                }
            }
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        Button {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { branchMenu(branch) }
    }

    private func tagRow(_ tag: GitTag) -> some View {
        Button {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

import GitIntelligence
import SwiftUI

/// Compare with Branch: the commits only on each side and the files that differ between the tips.
/// A file opens in the diff viewer, branch against branch.
struct IDEGitCompareView: View {
    @Environment(IDEWorkspace.self) private var workspace
    let gitStatus: IDEGitStatusModel
    @State private var selectedFile: String?
    @State private var selectedLeft: String?
    @State private var selectedRight: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var focusedPane: Pane?

    private enum Pane: Hashable {
        case files, left, right
    }

    var body: some View {
        if let comparison = gitStatus.comparison {
            VStack(spacing: 0) {
                HStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text("\(comparison.left) ↔ \(comparison.right)")
                    Spacer(minLength: 0)
                    IDEIconButton(systemImage: "xmark.circle.fill", help: "Close the comparison") {
                        gitStatus.clearComparison()
                    }
                }
                .ideIconButtonSize(.compact)
                .font(IDEAppearance.Typography.caption)
                .padding(.horizontal, IDEAppearance.Spacing.md)
                .padding(.vertical, IDEAppearance.Spacing.xs)

                SplitPanes(
                    minPrimary: 180, maxPrimary: 900, idealPrimary: 300, minSecondary: 180,
                    storageKey: "umbra.git.compareSplit.files"
                ) {
                    files(comparison)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .idePanel(fill: IDEAppearance.ColorToken.editor)
                } secondary: {
                    SplitPanes(
                        minPrimary: 160, maxPrimary: 900, idealPrimary: 300, minSecondary: 160,
                        storageKey: "umbra.git.compareSplit.commits"
                    ) {
                        commits("Only in \(comparison.left)", comparison.onlyInLeft, pane: .left)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .idePanel(fill: IDEAppearance.ColorToken.editor)
                    } secondary: {
                        commits("Only in \(comparison.right)", comparison.onlyInRight, pane: .right)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .idePanel(fill: IDEAppearance.ColorToken.editor)
                    }
                }
                .padding(.horizontal, IDEAppearance.Spacing.panelGap)
                .padding(.bottom, IDEAppearance.Spacing.panelGap)
            }
        } else {
            Text("Choose Compare with Current on a branch to see what differs.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func files(_ comparison: GitComparison) -> some View {
        let paths = comparison.files.map(\.path)
        return VStack(alignment: .leading, spacing: 0) {
            header("\(comparison.files.count) files differ")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comparison.files) { file in
                            fileRow(file, comparison: comparison)
                                .id(file.path)
                        }
                    }
                }
                .focusable()
                .focused($focusedPane, equals: .files)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleFileKey(press, paths: paths, comparison: comparison)
                }
                .onChange(of: selectedFile) { _, path in
                    if let path { proxy.scrollTo(path) }
                }
            }
        }
    }

    private func fileRow(_ file: GitChangedFile, comparison: GitComparison) -> some View {
        let isSelected = selectedFile == file.path
        return HStack(spacing: IDEAppearance.Spacing.sm) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture(count: 2) { open(file, comparison: comparison) }
        .onTapGesture {
            focusedPane = .files
            selectedFile = file.path
        }
    }

    private func commits(_ title: String, _ commits: [GitCommit], pane: Pane) -> some View {
        let hashes = commits.map(\.hash)
        let selected = pane == .left ? selectedLeft : selectedRight
        return VStack(alignment: .leading, spacing: 0) {
            header("\(title) (\(commits.count))")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            commitRow(commit, pane: pane, isSelected: selected == commit.hash)
                                .id(commit.hash)
                        }
                    }
                }
                .focusable()
                .focused($focusedPane, equals: pane)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleCommitKey(press, hashes: hashes, commits: commits, pane: pane)
                }
                .onChange(of: selected) { _, hash in
                    if let hash { proxy.scrollTo(hash) }
                }
            }
        }
    }

    private func commitRow(_ commit: GitCommit, pane: Pane, isSelected: Bool) -> some View {
        Button {
            focusedPane = pane
            selectCommit(commit.hash, pane: pane)
        } label: {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func handleFileKey(_ press: KeyPress, paths: [String], comparison: GitComparison) -> KeyPress.Result {
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            if let next = IDEListNeighbor.move(selectedFile, in: paths, by: press.key == .downArrow ? 1 : -1) {
                selectedFile = next
                focusedPane = .files
            }
            return .handled
        case .return:
            typeahead.reset()
            if let path = selectedFile, let file = comparison.files.first(where: { $0.path == path }) {
                open(file, comparison: comparison)
            }
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let path = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: paths,
                selected: selectedFile,
                title: { ($0 as NSString).lastPathComponent }
            ) {
                selectedFile = path
                focusedPane = .files
            }
            return .handled
        }
    }

    private func handleCommitKey(
        _ press: KeyPress, hashes: [String], commits: [GitCommit], pane: Pane
    ) -> KeyPress.Result {
        let selected = pane == .left ? selectedLeft : selectedRight
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            if let next = IDEListNeighbor.move(selected, in: hashes, by: press.key == .downArrow ? 1 : -1) {
                selectCommit(next, pane: pane)
                focusedPane = pane
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
            let subjects = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0.subject) })
            if let hash = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: hashes,
                selected: selected,
                title: { subjects[$0] ?? "" }
            ) {
                selectCommit(hash, pane: pane)
                focusedPane = pane
            }
            return .handled
        }
    }

    private func selectCommit(_ hash: String, pane: Pane) {
        if pane == .left { selectedLeft = hash } else { selectedRight = hash }
    }

    private func open(_ file: GitChangedFile, comparison: GitComparison) {
        workspace.openBranchDiff(left: comparison.left, right: comparison.right, file: file)
    }
}

import EditorIntelligence
import Foundation
import GitIntelligence
import Penumbra

/// Branches, tags and commits as rows of the palette's Symbols results, so Go to Anything finds a
/// branch to check out or a commit to show in the log.
extension IDEWorkspace {
    func gitPaletteItems(matching query: String, limit: Int) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, gitStatus.isRepository else { return [] }
        var items: [PaletteItem] = []

        let branches = gitStatus.branchInfos.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .local }
                return lhs.name.count < rhs.name.count
            }
        for (rank, branch) in branches.prefix(limit).enumerated() {
            items.append(PaletteItem(
                id: "git-branch:\(branch.id)",
                title: branch.name,
                sectionTitle: "Git Branches",
                matchedIndices: CompletionMatcher.match(query, in: branch.name)?.matchedOffsets ?? [],
                score: limit - rank,
                action: { [weak self] in self?.gitStatus.checkout(branch) },
                icon: PaletteIcon(systemName: "arrow.triangle.branch", tint: branch.isCurrent ? .accent : .secondary),
                location: branch.isCurrent ? "current branch" : (branch.kind == .remote ? "remote branch" : nil),
                trailing: nil,
                footer: "Check out \(branch.name)"
            ))
        }

        let tags = gitStatus.tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
        for (rank, tag) in tags.prefix(limit).enumerated() {
            items.append(PaletteItem(
                id: "git-tag:\(tag.name)",
                title: tag.name,
                sectionTitle: "Git Branches",
                matchedIndices: CompletionMatcher.match(query, in: tag.name)?.matchedOffsets ?? [],
                score: limit - rank - branches.count,
                action: { [weak self] in self?.gitStatus.checkoutRevision(tag.name) },
                icon: PaletteIcon(systemName: "tag", tint: .secondary),
                location: "tag",
                trailing: nil,
                footer: "Check out tag \(tag.name) (detached HEAD)"
            ))
        }

        let commits = gitStatus.commits.filter {
            $0.subject.localizedCaseInsensitiveContains(query) || $0.hash.hasPrefix(query.lowercased())
        }
        for (rank, commit) in commits.prefix(limit).enumerated() {
            items.append(PaletteItem(
                id: "git-commit:\(commit.hash)",
                title: commit.subject,
                sectionTitle: "Git Commits",
                matchedIndices: CompletionMatcher.match(query, in: commit.subject)?.matchedOffsets ?? [],
                score: limit - rank,
                action: { [weak self] in
                    guard let self else { return }
                    self.gitStatus.selectCommit(commit.hash)
                    self.showBottomTab(.sourceControl)
                },
                icon: PaletteIcon(systemName: "circle.dotted", tint: .secondary),
                location: commit.shortHash,
                trailing: commit.author,
                footer: "Show in the log"
            ))
        }
        return items
    }
}

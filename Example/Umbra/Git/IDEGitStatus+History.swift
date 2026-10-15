import Foundation
import GitIntelligence

/// What the Log's context menu does with commits: cherry-pick, revert, reset, rewrite, and the
/// filters and line history around it.
extension IDEGitStatusModel {
    /// The commit HEAD points at when it is on a branch (the log's first row when unfiltered).
    var headCommitHash: String? {
        branchInfos.first(where: \.isCurrent)?.hash
    }

    // MARK: - Selection

    /// The commits an action applies to: the selection when `hash` is part of it, else just `hash`,
    /// oldest first (the order cherry-pick and rebase need).
    func commitsForAction(on hash: String) -> [IDEGitCommit] {
        let wanted: Set<String> = selectedCommitHashes.contains(hash) ? selectedCommitHashes : [hash]
        return commits.filter { wanted.contains($0.hash) }.reversed()
    }

    /// ⌘-click adds or removes one commit.
    func toggleCommitSelection(_ hash: String) {
        if selectedCommitHashes.remove(hash) != nil {
            if selectedCommitHash == hash { selectedCommitHash = selectedCommitHashes.first }
        } else {
            selectedCommitHashes.insert(hash)
            selectedCommitHash = hash
        }
    }

    /// ⇧-click selects the rows between the primary commit and `hash`.
    func extendCommitSelection(to hash: String) {
        guard let anchor = selectedCommitHash,
              let from = commits.firstIndex(where: { $0.hash == anchor }),
              let to = commits.firstIndex(where: { $0.hash == hash }) else {
            selectCommit(hash)
            return
        }
        selectedCommitHashes.formUnion(commits[min(from, to)...max(from, to)].map(\.hash))
    }

    // MARK: - Filters

    func setHistoryWindow(since date: Date?) {
        historySince = date
        resetLimitAndReload()
    }

    func setHistoryPath(_ folder: String) {
        historyPathFilter = folder
        resetLimitAndReload()
    }

    func loadMoreHistory() {
        setHistoryLimit(historyLimit + 300)
        loadHistory()
    }

    var hasMoreHistory: Bool { commits.count >= historyLimit }

    private func resetLimitAndReload() {
        setHistoryLimit(300)
        selectCommit(nil)
        loadHistory()
    }

    // MARK: - Commit actions

    func checkoutCommit(_ hash: String) {
        checkoutRevision(hash)
    }

    func cherryPick(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        afterSaving(before: "cherry-picking") { [self] in
            runIntegrationAction("Cherry-pick") { try await $0.cherryPick(hashes) }
        }
    }

    func revertCommits(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        afterSaving(before: "reverting") { [self] in
            // Newest first: each revert applies on top of the one before it.
            runIntegrationAction("Revert") { try await $0.revertCommits(hashes.reversed()) }
        }
    }

    func requestNewBranch(from commit: IDEGitCommit) {
        sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Branch",
            message: "Create a branch at \(commit.shortHash) and switch to it.",
            placeholder: "Branch name",
            confirmTitle: "Create",
            action: { [weak self] in self?.createBranch($0, from: commit.hash) }
        )))
    }

    func requestNewTag(at commit: IDEGitCommit) {
        sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Tag",
            message: "Tag \(commit.shortHash).",
            placeholder: "Tag name",
            confirmTitle: "Create",
            action: { [weak self] in self?.createTag($0, at: commit.hash) }
        )))
    }

    // MARK: - Rewriting history

    /// Remote branches that already hold `hash`, read before a rewrite so the sheet can say it.
    private func publishedBranches(containing hash: String) async -> [String] {
        guard let rootURL,
              let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository)
        else { return [] }
        return await repo.remoteBranchesContaining(hash)
    }

    func requestReset(to commit: IDEGitCommit) {
        Task { [weak self] in
            guard let self else { return }
            // What a reset drops is what is above `commit`: published if the branch tip is.
            let published = await self.publishedBranches(containing: "HEAD")
            self.sheets.present(.reset(IDEGitResetRequest(
                hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject,
                branch: self.currentBranch, publishedOn: commit.hash == self.commits.first?.hash ? [] : published)))
        }
    }

    func reset(to hash: String, mode: GitResetMode) {
        afterSaving(before: "resetting") { [self] in
            runGitAction({ repo in
                _ = try await repo.reset(to: hash, mode: mode)
                return "Reset to \(hash.prefix(7)) (\(mode.rawValue))"
            }, onSuccess: { [weak self] in self?.onWorkingTreeChanged?() })
        }
    }

    func undoLastCommit() {
        runGitAction({ repo in
            try await repo.undoLastCommit()
            return "Last commit undone; its changes are staged"
        })
    }

    func requestEditMessage(of commit: IDEGitCommit) {
        guard let rootURL else { return }
        Task { [weak self] in
            guard let self,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository),
                  let full = try? await repo.commit(hash: commit.hash)
            else { return }
            let isHead = commit.hash == self.commits.first?.hash
            let published = await self.publishedBranches(containing: commit.hash)
            let message = full.body.isEmpty ? commit.subject : full.body
            self.sheets.present(.textPrompt(IDEGitTextPrompt(
                title: "Edit Commit Message",
                message: published.isEmpty ? commit.shortHash
                    : "\(commit.shortHash) is already on \(published.joined(separator: ", ")): changing it needs a force push.",
                placeholder: "Message",
                initial: message,
                confirmTitle: "Change",
                action: { [weak self] new in self?.reword(commit: commit, to: new, isHead: isHead) }
            )))
        }
    }

    private func reword(commit: IDEGitCommit, to message: String, isHead: Bool) {
        if isHead {
            runGitAction({ repo in
                try await repo.amendMessage(message)
                return "Message changed"
            })
            return
        }
        runPlan(startingAt: commit.hash, label: "Reword") { $0.rewording(commit.hash, to: message) }
    }

    func requestSquash(_ selected: [IDEGitCommit]) {
        guard selected.count >= 2, let oldest = selected.first else { return }
        let combined = selected.map(\.subject).joined(separator: "\n")
        sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "Squash \(selected.count) Commits",
            message: "The message of the single commit that replaces them.",
            placeholder: "Message",
            initial: combined,
            confirmTitle: "Squash",
            action: { [weak self] message in
                let hashes = Set(selected.map(\.hash))
                self?.runPlan(startingAt: oldest.hash, label: "Squash") { $0.squashing(hashes, message: message) }
            }
        )))
    }

    /// Melds `commit` into its parent, keeping the parent's message.
    func fixupIntoParent(_ commit: IDEGitCommit) {
        guard let parent = commit.parents.first else { return }
        runPlan(startingAt: parent, label: "Fixup") { $0.fixingUp(commit.hash, into: parent) }
    }

    func requestDrop(_ selected: [IDEGitCommit]) {
        guard let oldest = selected.first else { return }
        let hashes = Set(selected.map(\.hash))
        Task { [weak self] in
            guard let self else { return }
            let published = await self.publishedBranches(containing: oldest.hash)
            let warning = published.isEmpty ? "" : " They are already on \(published.joined(separator: ", ")); a force push will be needed."
            self.sheets.present(.confirm(IDEGitConfirmation(
                title: selected.count == 1 ? "Drop Commit?" : "Drop \(selected.count) Commits?",
                message: "Their changes are removed from the branch.\(warning)",
                confirmTitle: "Drop",
                isDestructive: true,
                action: { [weak self] in
                    self?.runPlan(startingAt: oldest.hash, label: "Drop") { $0.dropping(hashes) }
                }
            )))
        }
    }

    /// Interactively Rebase from Here…: the plan of `commit` and everything above it, to edit.
    func requestInteractiveRebase(from commit: IDEGitCommit) {
        guard let rootURL else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let repo = try await IDEGitSupport.repository(for: rootURL, existing: self.repository)
                let (base, plan) = try await repo.rebasePlan(startingAt: commit.hash)
                let published = await repo.remoteBranchesContaining(commit.hash)
                self.sheets.present(.rebase(IDEGitRebaseRequest(base: base, steps: plan.steps, publishedOn: published)))
            } catch {
                self.fail(IDEGitSupport.describe(error))
            }
        }
    }

    /// Runs a plan built on the commits from `oldest` up to HEAD.
    private func runPlan(startingAt oldest: String, label: String, build: @escaping @Sendable (GitRebasePlan) -> GitRebasePlan) {
        afterSaving(before: "rewriting history") { [self] in
            runIntegrationAction(label) { repo in
                let (base, plan) = try await repo.rebasePlan(startingAt: oldest)
                return try await repo.interactiveRebase(onto: base, plan: build(plan))
            }
        }
    }

    func startInteractiveRebase(base: String, plan: GitRebasePlan) {
        afterSaving(before: "rewriting history") { [self] in
            runIntegrationAction("Rebase") { try await $0.interactiveRebase(onto: base, plan: plan) }
        }
    }

    // MARK: - Push, navigation

    func requestPush(upTo commit: IDEGitCommit) {
        guard isRepository else { return }
        let upstream = branchInfos.first(where: \.isCurrent)?.upstream
        let parts: (String, String)? = upstream.flatMap { name in
            guard let slash = name.firstIndex(of: "/") else { return nil }
            return (String(name[..<slash]), String(name[name.index(after: slash)...]))
        }
        let remote = parts?.0 ?? "origin"
        let target = parts?.1 ?? currentBranch ?? "main"
        let remotes = remoteInfos.map(\.name)
        sheets.present(.push(IDEGitPushRequest(
            branch: commit.hash, remotes: remotes.isEmpty ? [remote] : remotes, remote: remote,
            targetBranch: target, setsUpstream: false)))
    }

    /// Selects the first parent of `commit` in the list, when it is shown.
    func goToParent(of commit: IDEGitCommit) {
        guard let parent = commit.parents.first, commits.contains(where: { $0.hash == parent }) else { return }
        selectCommit(parent)
    }

    func goToChild(of commit: IDEGitCommit) {
        guard let child = commits.first(where: { $0.parents.contains(commit.hash) }) else { return }
        selectCommit(child.hash)
    }

    // MARK: - Line history

    func showLineHistory(path: String, startLine: Int, endLine: Int) {
        guard let relative = repositoryRelativePath(for: path), let rootURL else { return }
        lineHistory = IDEGitLineHistory(path: path, startLine: startLine, endLine: endLine, entries: [], selectedHash: nil)
        let existing = repository
        Task { [weak self] in
            do {
                let repo = try await IDEGitSupport.repository(for: rootURL, existing: existing)
                let entries = try await repo.lineHistory(path: relative, start: startLine, end: endLine)
                guard let self, self.lineHistory?.path == path, self.lineHistory?.startLine == startLine else { return }
                self.lineHistory?.entries = entries
                self.lineHistory?.selectedHash = entries.first?.commit.hash
            } catch {
                self?.lineHistory = nil
                self?.fail(IDEGitSupport.describe(error))
            }
        }
    }

    func clearLineHistory() { lineHistory = nil }

    // MARK: - Plumbing

    /// A merge/rebase-like action: a stop (conflicts, an `edit` step) is reported, not failed.
    private func runIntegrationAction(
        _ name: String, _ operation: @escaping @Sendable (GitRepository) async throws -> GitIntegrationResult
    ) {
        runGitAction({ repo in
            switch try await operation(repo) {
            case .completed(let report):
                let line = IDEGitSupport.statusLine(report)
                return line.isEmpty ? "\(name) finished" : "\(name): \(line)"
            case .stopped:
                let count = (try? await repo.conflictedFiles().count) ?? 0
                return count > 0
                    ? "\(name) stopped: \(count) \(count == 1 ? "file has" : "files have") conflicts"
                    : "\(name) stopped: continue or abort from the banner"
            }
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        }, onFailure: { [weak self] _ in
            self?.onWorkingTreeChanged?()
        })
    }
}

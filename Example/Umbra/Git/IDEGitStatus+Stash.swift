import Foundation
import GitIntelligence

/// The stash: saving, listing, applying and dropping, and the files of the selected stash.
extension IDEGitStatusModel {
    func loadStashes() {
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository)
            else { return }
            let loaded = (try? await repo.stashes()) ?? []
            if loaded != self.stashes { self.stashes = loaded }
            if let selected = self.selectedStashHash, !loaded.contains(where: { $0.hash == selected }) {
                self.selectStash(nil)
            }
        }
    }

    func selectStash(_ hash: String?) {
        selectedStashHash = hash
        stashFiles = []
        guard let hash, let stash = stashes.first(where: { $0.hash == hash }), let rootURL else { return }
        Task { [weak self] in
            guard let self,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository)
            else { return }
            let files = (try? await repo.stashChanges(stash)) ?? []
            guard self.selectedStashHash == hash else { return }
            self.stashFiles = files
        }
    }

    /// Git ▸ Stash Changes…: asks for a message and what to include.
    func requestStashChanges() {
        guard isRepository else { return }
        guard !changes.isEmpty else {
            succeed("No local changes to stash.")
            return
        }
        sheets.present(.stash(IDEGitStashRequest(
            branch: currentBranch,
            hasUntracked: changes.contains { $0.unstaged == .untracked }
        )))
    }

    func stashChanges(message: String, includeUntracked: Bool, keepIndex: Bool) {
        let branch = currentBranch ?? "HEAD"
        let text = message.isEmpty ? "Umbra: changes on \(branch)" : message
        runGitAction({ repo in
            let created = try await repo.stashPush(
                message: text, includeUntracked: includeUntracked, keepIndex: keepIndex)
            return created ? "Changes saved to the stash" : "No local changes to save"
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
            self?.loadStashes()
        })
    }

    func applyStash(_ stash: GitStash, reinstateIndex: Bool = false, drop: Bool = false) {
        guard !refuseUnsaved(before: "applying a stash") else { return }
        runGitAction({ repo in
            if drop {
                _ = try await repo.stashPop(stash, reinstateIndex: reinstateIndex)
                return "Applied and dropped \(stash.ref)"
            }
            _ = try await repo.stashApply(stash, reinstateIndex: reinstateIndex)
            return "Applied \(stash.ref)"
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
            self?.loadStashes()
        }, onFailure: { [weak self] _ in
            // A conflicting apply leaves conflict markers in the tree; the stash is kept.
            self?.onWorkingTreeChanged?()
            self?.loadStashes()
        })
    }

    func requestDropStash(_ stash: GitStash) {
        sheets.present(.confirm(IDEGitConfirmation(
            title: "Drop Stash?",
            message: "\(stash.title) will be deleted. Its changes cannot be recovered afterwards.",
            confirmTitle: "Drop",
            isDestructive: true,
            action: { [weak self] in self?.dropStash(stash) }
        )))
    }

    private func dropStash(_ stash: GitStash) {
        runGitAction({ repo in
            _ = try await repo.stashDrop(stash)
            return "Dropped \(stash.ref)"
        }, onSuccess: { [weak self] in self?.loadStashes() })
    }

    func requestClearStashes() {
        guard !stashes.isEmpty else { return }
        sheets.present(.confirm(IDEGitConfirmation(
            title: "Clear All Stashes?",
            message: "\(stashes.count) \(stashes.count == 1 ? "stash" : "stashes") will be deleted for good.",
            confirmTitle: "Clear All",
            isDestructive: true,
            action: { [weak self] in
                self?.runGitAction({ repo in
                    try await repo.stashClear()
                    return "Cleared the stash"
                }, onSuccess: { self?.loadStashes() })
            }
        )))
    }

    func requestBranchFromStash(_ stash: GitStash) {
        sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Branch from Stash",
            message: "Creates a branch at the commit \(stash.ref) was made on, applies it and drops it.",
            placeholder: "Branch name",
            confirmTitle: "Create",
            action: { [weak self] name in
                self?.runGitAction({ repo in
                    _ = try await repo.stashBranch(name, from: stash)
                    return "Created \(name) from \(stash.ref)"
                }, onSuccess: { self?.onWorkingTreeChanged?(); self?.loadStashes() })
            }
        )))
    }
}

extension IDEWorkspace {
    /// Git ▸ Unstash…: the Stashes tab of the History panel.
    func showStashes() {
        guard gitStatus.isRepository else { return }
        gitStatus.loadStashes()
        gitStatus.requestShowStashes?()
        showBottomTab(.sourceControl)
    }

    /// One file of a stash against the commit the stash was made on.
    func openStashDiff(stash: GitStash, change: GitStashChange) {
        guard let root = gitStatus.repositoryRootPath else { return }
        func request(_ change: GitStashChange) -> IDEDiffRequest {
            IDEDiffRequest.stashFile(
                hash: stash.hash, label: stash.ref, path: change.file.path, oldPath: change.file.oldPath,
                isUntracked: change.isUntracked, repositoryRoot: root)
        }
        openDiff(request(change), siblings: gitStatus.stashFiles.map(request))
    }
}

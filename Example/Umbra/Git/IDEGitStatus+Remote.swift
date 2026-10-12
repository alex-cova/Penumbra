import AppKit
import Foundation
import GitIntelligence

/// Fetch, update, push, checkout (with the smart fallback), branch and tag commands, comparing
/// branches, and the credential prompts git raises while they run.
extension IDEGitStatusModel {
    // MARK: - Credentials

    func registerAskPass(active: Bool) {
        let session = askPassSession
        guard active else {
            IDEGitAskPassServer.shared.unregister(session: session)
            return
        }
        IDEGitAskPassServer.shared.register(session: session) { [weak self] prompt in
            guard let self else { return .cancel }
            return await self.requestCredential(prompt: prompt)
        }
    }

    /// Shows the prompt in this window and waits for the answer.
    func requestCredential(prompt: String) async -> IDEGitAskPassReply {
        await withCheckedContinuation { continuation in
            sheets.present(.credential(IDEGitCredentialRequest(prompt: prompt, continuation: continuation)))
        }
    }

    // MARK: - Fetch, update, push

    /// Fetches in the background every `IDEGitPreferences.fetchIntervalMinutes` (off by default),
    /// while the app is active. It never prompts: a remote that needs a credential is skipped.
    func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            var lastFetch = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let minutes = IDEGitPreferences.fetchIntervalMinutes
                guard minutes > 0, self.isRepository, !self.isNetworkBusy, NSApp.isActive else { continue }
                if Date().timeIntervalSince(lastFetch) >= Double(minutes) * 60 {
                    lastFetch = Date()
                    await self.backgroundFetch()
                }
            }
        }
    }

    private func backgroundFetch() async {
        guard let rootURL,
              let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository)
        else { return }
        // Batch mode: no askpass, so nothing can open a sheet while the user is doing something else.
        _ = try? await repo.withNetwork(.batchMode).fetch()
        noteRefsChanged()
        refresh()
    }

    func fetch() {
        guard isRepository else { return }
        runGitAction({ repo in
            let report = try await repo.fetch()
            let updated = report.split(separator: "\n").filter { $0.contains("->") }.count
            return updated == 0 ? "Already up to date" : "Fetched \(updated) \(updated == 1 ? "update" : "updates")"
        }, network: true)
    }

    /// Update Project: asks merge or rebase unless the user chose not to be asked.
    func requestUpdate() {
        guard isRepository else { return }
        guard !refuseUnsaved(before: "updating") else { return }
        guard sync != nil || currentBranch != nil else { return }
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL else { return }
            let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository)
            let configured = await repo?.config("pull.rebase")
            let strategy = IDEGitPreferences.initialUpdateStrategy(repositoryPullRebase: configured)
            if IDEGitPreferences.asksBeforeUpdate {
                self.sheets.present(.update(IDEGitUpdateRequest(
                    branch: self.currentBranch, upstream: self.sync?.upstream, strategy: strategy)))
            } else {
                self.update(strategy: strategy, autostash: true)
            }
        }
    }

    func update(strategy: GitPullStrategy, autostash: Bool) {
        guard !refuseUnsaved(before: "updating") else { return }
        runGitAction({ repo in
            try await repo.pull(strategy: strategy, autostash: autostash)
        }, network: true, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        })
    }

    func requestPush() {
        guard isRepository else { return }
        let remotes = remoteInfos.map(\.name)
        let current = branchInfos.first(where: \.isCurrent)
        let branch = current?.name ?? currentBranch ?? "HEAD"
        let upstream = current?.upstream
        let remote: String
        let target: String
        if let upstream, let slash = upstream.firstIndex(of: "/") {
            remote = String(upstream[..<slash])
            target = String(upstream[upstream.index(after: slash)...])
        } else {
            remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            target = branch
        }
        sheets.present(.push(IDEGitPushRequest(
            branch: branch, remotes: remotes.isEmpty ? [remote] : remotes, remote: remote,
            targetBranch: target, setsUpstream: upstream == nil)))
        // The remote list may not be loaded yet; the sheet reads it when it appears.
        if remotes.isEmpty { loadRemotes() }
    }

    func push(_ options: GitPushOptions) {
        if options.forceWithLease, let target = options.targetBranch ?? currentBranch,
           IDEGitPreferences.isProtected(target) {
            fail("\(target) is a protected branch: force push is not allowed.")
            return
        }
        runGitAction({ repo in
            IDEGitSupport.pushSummary(try await repo.push(options))
        }, network: true)
    }

    /// The commits `push` would send: those on `source` that `remote/target` does not have.
    func outgoingCommits(source: String, remote: String, target: String) async -> [GitCommit] {
        guard let rootURL else { return [] }
        guard let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository) else { return [] }
        let remoteRef = "\(remote)/\(target)"
        let known = ((try? await repo.branchList()) ?? []).contains { $0.id == "remotes/\(remoteRef)" }
        let range = known ? "\(remoteRef)..\(source)" : "\(source)"
        return (try? await repo.commits(in: range, limit: 200)) ?? []
    }

    // MARK: - Checkout

    func checkout(_ branch: GitBranch) {
        guard !refuseUnsaved(before: "switching branches") else { return }
        switch branch.kind {
        case .local:
            guard !branch.isCurrent else { return }
            switchToLocal(branch.name)
        case .remote:
            if let local = branchInfos.first(where: { $0.kind == .local && $0.name == branch.shortName }) {
                guard !local.isCurrent else { return }
                switchToLocal(local.name)
            } else {
                let name = branch.name
                runGitAction({ try await $0.checkoutRemoteBranch(name) }, onSuccess: { [weak self] in
                    self?.onWorkingTreeChanged?()
                }, onFailure: { [weak self] message in
                    self?.offerSmartCheckout(branch: name, isRemote: true, message: message)
                })
            }
        }
    }

    func switchToLocal(_ name: String) {
        runGitAction({ try await $0.switchBranch(name) }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        }, onFailure: { [weak self] message in
            self?.offerSmartCheckout(branch: name, isRemote: false, message: message)
        })
    }

    /// Git refused because local files are in the way: offer to carry the changes along.
    private func offerSmartCheckout(branch: String, isRemote: Bool, message: String) {
        guard let files = GitSwitchConflictParser.parse(message) else { return }
        sheets.present(.smartCheckout(IDEGitSmartCheckoutRequest(branch: branch, isRemote: isRemote, files: files)))
    }

    func smartCheckout(_ request: IDEGitSmartCheckoutRequest) {
        let name = request.branch
        let isRemote = request.isRemote
        runGitAction({ repo in
            let (report, outcome) = try await repo.preservingLocalChanges {
                isRemote ? try await repo.checkoutRemoteBranch(name) : try await repo.switchBranch(name)
            }
            switch outcome {
            case .completed:
                return report.isEmpty ? "Checked out \(name) with your local changes" : report
            case .restoredWithConflicts:
                return "Checked out \(name); your local changes conflict with it (see Changes)"
            case .keptInStash:
                return "Checked out \(name); your local changes are kept in the stash"
            }
        }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        })
    }

    /// Switches and discards the tracked local changes in the way. The caller confirmed.
    func forceCheckout(branch: String) {
        runGitAction({ try await $0.forceSwitchBranch(branch) }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        })
    }

    func checkoutRevision(_ revision: String) {
        guard !refuseUnsaved(before: "switching") else { return }
        runGitAction({ try await $0.checkout(revision: revision) }, onSuccess: { [weak self] in
            self?.onWorkingTreeChanged?()
        })
    }

    // MARK: - Branches and tags

    func createBranch(_ name: String, from startPoint: String?, checkout: Bool = true) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("Enter a branch name.")
            return
        }
        runGitAction({ repo in
            try await repo.createBranch(trimmed, startPoint: startPoint, checkout: checkout)
        }, onSuccess: { [weak self] in
            if checkout { self?.onWorkingTreeChanged?() }
        })
    }

    func renameBranch(_ name: String, to newName: String) {
        runGitAction({ try await $0.renameBranch(name, to: newName) })
    }

    /// Deletes a local branch. Git refuses an unmerged one; the user is asked whether to force it.
    func deleteBranch(_ name: String, force: Bool = false) {
        runGitAction({ repo in
            _ = try await repo.deleteBranch(name, force: force)
            return "Deleted branch \(name)"
        }, onFailure: { [weak self] message in
            guard !force, message.contains("not fully merged") else { return }
            self?.sheets.present(.confirm(IDEGitConfirmation(
                title: "Delete Unmerged Branch?",
                message: "\(name) has commits that are not merged anywhere else. Deleting it loses them.",
                confirmTitle: "Delete Anyway",
                isDestructive: true,
                action: { self?.deleteBranch(name, force: true) }
            )))
        })
    }

    func deleteRemoteBranch(_ branch: GitBranch) {
        guard let remote = branch.remoteName else { return }
        let name = branch.shortName
        if IDEGitPreferences.isProtected(name) {
            fail("\(name) is a protected branch: it cannot be deleted from \(remote) here.")
            return
        }
        runGitAction({ repo in
            _ = try await repo.deleteRemoteBranch(remote: remote, branch: name)
            return "Deleted \(branch.name)"
        }, network: true)
    }

    func deleteBranches(_ names: [String]) {
        guard !names.isEmpty else { return }
        runGitAction({ repo in
            for name in names { _ = try await repo.deleteBranch(name) }
            return "Deleted \(names.count) \(names.count == 1 ? "branch" : "branches")"
        })
    }

    func createTag(_ name: String, at revision: String? = nil, message: String? = nil) {
        runGitAction({ repo in
            try await repo.createTag(name, at: revision, message: message)
            return "Created tag \(name)"
        }, onSuccess: { [weak self] in self?.loadTags() })
    }

    func deleteTag(_ name: String) {
        runGitAction({ repo in
            try await repo.deleteTag(name)
            return "Deleted tag \(name)"
        }, onSuccess: { [weak self] in self?.loadTags() })
    }

    // MARK: - Lists for the branch popup

    func loadTags() {
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository)
            else { return }
            let loaded = (try? await repo.tags()) ?? []
            if loaded != self.tags { self.setTags(loaded) }
        }
    }

    func loadRemotes() {
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository)
            else { return }
            let loaded = await repo.remoteDetails()
            if loaded != self.remoteInfos { self.setRemotes(loaded) }
        }
    }

    /// Local branches fully merged into the default branch, minus the current and protected ones.
    func requestDeleteMergedBranches() {
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository),
                  let base = await repo.defaultBranchName()
            else {
                self?.fail("There is no default branch to compare against.")
                return
            }
            let merged = (try? await repo.mergedBranches(into: base)) ?? []
            let current = self.currentBranch
            let candidates = merged.filter { $0 != current && !IDEGitPreferences.isProtected($0) }
            if candidates.isEmpty {
                self.succeed("No merged branches to delete.")
            } else {
                self.sheets.present(.deleteMerged(IDEGitDeleteMergedRequest(base: base, candidates: candidates)))
            }
        }
    }

    // MARK: - Compare

    /// Compares `other` with the current branch and shows the result in the Compare tab.
    func compare(with other: String) {
        guard let current = currentBranch ?? repositoryState.branchName else {
            fail("Check out a branch first.")
            return
        }
        Task { [weak self] in
            guard let self, let rootURL = self.rootURL else { return }
            do {
                let repo = try await IDEGitSupport.repository(for: rootURL, existing: self.repository)
                let result = try await repo.compare(current, other)
                self.setComparison(result)
                self.onShowComparison?()
            } catch {
                self.fail(IDEGitSupport.describe(error))
            }
        }
    }

    func clearComparison() { setComparison(nil) }

    /// The files a commit changed, for the push sheet's expandable rows.
    func commitFiles(hash: String) async -> [GitChangedFile] {
        guard let rootURL,
              let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository)
        else { return [] }
        return (try? await repo.commitChanges(hash: hash)) ?? []
    }

    func pushTag(_ name: String) {
        runGitAction({ repo in
            _ = try await repo.pushTag(name)
            return "Pushed tag \(name)"
        }, network: true)
    }
}

extension IDEGitSupport {
    /// The line of a push report that says what moved (`abc..def  main -> main`), or git's own
    /// "Everything up-to-date"; progress lines and the remote's chatter are skipped.
    nonisolated static func pushSummary(_ report: String) -> String {
        let lines = report.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if let moved = lines.first(where: { $0.contains(" -> ") && !$0.hasPrefix("remote:") }) {
            return moved.hasPrefix("*") || moved.hasPrefix("+") || moved.hasPrefix("!") ? moved : "Pushed " + moved
        }
        if lines.contains(where: { $0.hasPrefix("Everything up-to-date") }) { return "Everything up-to-date" }
        return statusLine(report)
    }
}

// MARK: - Prompts the Git menu opens

extension IDEWorkspace {
    func promptNewBranch() {
        let current = gitStatus.currentBranch
        gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Branch",
            message: current.map { "Create a branch from \($0) and switch to it." } ?? "Create a branch at HEAD and switch to it.",
            placeholder: "Branch name",
            confirmTitle: "Create",
            validate: { [weak self] name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "Enter a branch name." }
                if trimmed.hasPrefix("-") { return "A branch name cannot start with a dash." }
                if trimmed.contains(" ") { return "A branch name cannot contain spaces." }
                if self?.gitStatus.branchInfos.contains(where: { $0.kind == .local && $0.name == trimmed }) == true {
                    return "A branch named \(trimmed) already exists."
                }
                return nil
            },
            action: { [weak self] in self?.gitStatus.createBranch($0, from: nil) }
        )))
    }

    func promptCheckoutRevision() {
        gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "Checkout Tag or Revision",
            message: "A tag, a commit id or any revision. HEAD becomes detached.",
            placeholder: "v1.0 or a1b2c3d",
            confirmTitle: "Checkout",
            action: { [weak self] in self?.gitStatus.checkoutRevision($0) }
        )))
    }

    func promptNewTag() {
        gitStatus.sheets.present(.textPrompt(IDEGitTextPrompt(
            title: "New Tag",
            message: "Tag the current commit.",
            placeholder: "Tag name",
            confirmTitle: "Create",
            action: { [weak self] in self?.gitStatus.createTag($0) }
        )))
    }
}

import Foundation
import GitIntelligence

/// Committing: the options, the checks before it, recent messages and the repository's template.
extension IDEGitStatusModel {
    var recentCommitMessages: [String] {
        guard let root = repositoryRootPath else { return [] }
        return IDEGitRecentMessages().messages(for: root)
    }

    /// The subjects of the latest commits, for the fixup!/squash! prefix menu.
    var prefixCandidates: [IDEGitCommit] { Array(commits.prefix(10)) }

    // MARK: - Commit

    func requestCommit(options: IDEGitCommitOptions) {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            fail("Enter a commit message.")
            return
        }
        guard options.amend || changes.contains(where: { $0.staged != nil && $0.staged != .conflicted }) else {
            fail("Nothing staged to commit.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let facts = await self.commitFacts(options: options)
            let findings = IDEGitCommitChecks.evaluate(facts)
            if findings.isEmpty {
                self.performCommit(message: message, options: options)
            } else {
                self.sheets.present(.commitChecks(IDEGitCommitChecksRequest(
                    findings: findings, options: options, message: message)))
            }
        }
    }

    func performCommit(message: String, options: IDEGitCommitOptions) {
        let root = repositoryRootPath
        runGitAction({ repo in
            _ = try await repo.commit(
                message: message, paths: [], untrackedPaths: [], amend: options.amend,
                signoff: options.signoff, skipHooks: options.skipHooks)
            return options.amend ? "Amended the last commit" : "Committed"
        }, credentials: true, onSuccess: { [weak self] in
            if let root { IDEGitRecentMessages().record(message, for: root) }
            self?.resetAfterCommit()
            if options.pushAfter { self?.requestPush() }
        })
    }

    private var analyzeKey: String? {
        repositoryRootPath.map { "umbra.git.analyzeBeforeCommit.\($0)" }
    }

    /// Whether a commit first inspects its staged Java files (IntelliJ's "Analyze code" commit
    /// check). Per repository, off by default.
    var analyzesCodeBeforeCommit: Bool {
        get { analyzeKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false }
        set {
            guard let key = analyzeKey else { return }
            if newValue { UserDefaults.standard.set(true, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func commitFacts(options: IDEGitCommitOptions) async -> IDEGitCommitFacts {
        var facts = IDEGitCommitFacts()
        facts.isAmend = options.amend
        facts.isDetachedHead = repositoryState.isDetached
        facts.unresolvedPaths = conflictedChanges.map(\.relativePath)
        guard let rootURL, let repo = try? await IDEGitSupport.repository(for: rootURL, existing: repository) else {
            return facts
        }
        let name = await repo.config("user.name")
        let email = await repo.config("user.email")
        facts.hasUserName = name != nil
        facts.hasUserEmail = email != nil
        let staged = changes.filter { $0.staged != nil && $0.staged != .conflicted }
        let paths = staged.map(\.relativePath)
        facts.conflictMarkerPaths = Array(Set(await repo.stagedCheckProblems().filter(\.isConflictMarker).map(\.path))).sorted()
        // `true` and `input` convert on add, so a CRLF file reaches the index as LF; anything else
        // (unset, `false`) commits the file as it is.
        let autocrlf = await repo.config("core.autocrlf")?.lowercased()
        if autocrlf != "true", autocrlf != "input" {
            let endings = await repo.indexLineEndings(of: paths)
            facts.crlfPaths = paths.filter { endings[$0] == .crlf || endings[$0] == .mixed }
        }
        let root = rootURL.path
        if analyzesCodeBeforeCommit, let provider = codeAnalysisProvider {
            let javaFiles = staged.filter { $0.relativePath.hasSuffix(".java") }
                .map { URL(fileURLWithPath: (root as NSString).appendingPathComponent($0.relativePath)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !javaFiles.isEmpty { facts.codeAnalysis = await provider(javaFiles) }
        }
        for change in staged where change.staged != nil {
            let absolute = (root as NSString).appendingPathComponent(change.relativePath)
            if let size = (try? FileManager.default.attributesOfItem(atPath: absolute))?[.size] as? Int,
               size >= IDEGitCommitChecks.defaultLargeFileLimit {
                facts.largeFiles.append(.init(path: change.relativePath, bytes: size))
            }
        }
        return facts
    }

    // MARK: - Fixes the checks offer

    func setAuthor(name: String, email: String, then continuation: @escaping @MainActor () -> Void) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        runGitAction({ repo in
            try await repo.setConfig("user.name", to: trimmedName)
            try await repo.setConfig("user.email", to: trimmedEmail)
            return "Author set to \(trimmedName) <\(trimmedEmail)>"
        }, onSuccess: continuation)
    }

    func normalizeLineEndings(paths: [String], then continuation: @escaping @MainActor () -> Void) {
        runGitAction({ repo in
            try await repo.normalizeLineEndings(of: paths)
            return "Converted \(paths.count) \(paths.count == 1 ? "file" : "files") to LF"
        }, onSuccess: continuation)
    }

    // MARK: - Amend, prefixes, template

    func setAmend(_ on: Bool) {
        commitOptions.amend = on
        guard on, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rootURL else { return }
        Task { [weak self] in
            guard let self,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository),
                  let last = await repo.lastCommitMessage()
            else { return }
            if self.commitOptions.amend, self.commitMessage.isEmpty { self.commitMessage = last }
        }
    }

    /// Puts `fixup! <subject>` (or `squash!`, `amend!`) in front of the message.
    func applyCommitPrefix(_ prefix: String, to commit: IDEGitCommit) {
        commitMessage = "\(prefix)! \(commit.subject)"
    }

    /// Offers the repository's `commit.template` once, when the message is empty.
    func offerCommitTemplate() {
        guard !templateOffered, isRepository, let rootURL else { return }
        templateOffered = true
        guard commitMessage.isEmpty else { return }
        Task { [weak self] in
            guard let self,
                  let repo = try? await IDEGitSupport.repository(for: rootURL, existing: self.repository),
                  let path = await repo.config("commit.template")
            else { return }
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : repo.root.appendingPathComponent(expanded)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            // Git strips the template's `#` lines when it opens an editor; with `-m` we must.
            let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if self.commitMessage.isEmpty, !cleaned.isEmpty { self.commitMessage = cleaned }
        }
    }
}

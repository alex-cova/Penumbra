import EditorIntelligence
import Foundation

/// Find and Replace in Files: the parts that need the window's editors and project. What the drawer
/// shows is `IDEFindInFilesModel`.
extension IDEWorkspace {
    public func showFindInFiles() {
        findInFiles.show(hasProject: project.rootURL != nil)
    }

    /// Opens Find in Files with the replacement row showing (⇧⌘R in the IntelliJ keymap).
    public func showReplaceInFiles() {
        findInFiles.isReplaceVisible = true
        showFindInFiles()
    }

    /// What the drawer's mask and scope describe, with this window's open files and git changes.
    var findInFilesFilter: ProjectSearchFilter {
        findInFiles.filter(openFilePaths: openDocumentPaths, changedFilePaths: gitStatus.changes.map(\.path))
    }

    /// Limits Find in Files to `directory` (the Explorer's "Find in Files Here") and opens the drawer.
    func showFindInFiles(in directory: URL) {
        findInFiles.scope = .directory(directory)
        showFindInFiles()
        if !findInFiles.query.isEmpty { runFindInFiles() }
    }

    func hideFindInFiles() {
        findInFiles.isVisible = false
        focusActiveEditor()
    }

    func runFindInFiles() {
        findInFiles.isVisible = true
        let query = findInFiles.query
        guard let root = project.rootURL else {
            findInFiles.fail("Open a folder to search the project")
            return
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findInFiles.fail("Enter a query and press Return")
            return
        }
        guard let intelligenceController = host(for: workbench.activePaneID).intelligenceController else {
            return
        }
        if findInFiles.usesRegex, findInFiles.searchQuery.compiledRegularExpression() == nil {
            findInFiles.fail("Not a valid regular expression")
            return
        }
        if let problem = findInFiles.maskProblem {
            findInFiles.fail(problem)
            return
        }
        findInFiles.resetStaleScope(root: root)
        let filter = findInFilesFilter
        findInFiles.status = "Searching…"
        Task {
            let visible = await IDEGitVisibleFiles.relativePaths(under: root)
            let hits = await intelligenceController.searchProject(
                query,
                in: root,
                isCaseSensitive: findInFiles.isCaseSensitive,
                matchWholeWord: findInFiles.matchesWholeWord,
                useRegularExpression: findInFiles.usesRegex,
                filter: filter,
                visibleRelativePaths: visible
            )
            findInFiles.setResults(hits)
        }
    }

    /// Replaces the search text with the replacement text across the project, after a preview.
    /// Files open in an editor are edited in that editor (left unsaved, one undo step); the rest
    /// are rewritten on disk. Nothing is changed until Apply, and a match whose text has changed
    /// since the search is skipped rather than overwritten.
    func replaceInFiles() {
        findInFiles.isVisible = true
        findInFiles.isReplaceVisible = true
        guard let root = project.rootURL else {
            findInFiles.status = "Open a folder to replace in its files"
            return
        }
        let query = findInFiles.searchQuery
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.useRegularExpression && !query.text.isEmpty else {
            findInFiles.status = "Enter the text to replace and press Replace All"
            return
        }
        guard query.compiledRegularExpression() != nil else {
            findInFiles.status = "Not a valid regular expression"
            return
        }
        if let problem = findInFiles.maskProblem {
            findInFiles.status = problem
            return
        }
        guard let intelligenceController = host(for: workbench.activePaneID).intelligenceController else { return }
        findInFiles.resetStaleScope(root: root)
        // The same filter as the search, so Replace changes exactly the files Find lists.
        let filter = findInFilesFilter
        let replacement = findInFiles.replacement
        findInFiles.status = "Preparing the replacement…"
        Task {
            let visible = await IDEGitVisibleFiles.relativePaths(under: root)
            // The search only picks the files; each is then read as the editor or disk has it now.
            let hits = await intelligenceController.searchProject(
                query.text,
                in: root,
                isCaseSensitive: query.isCaseSensitive,
                matchWholeWord: query.matchWholeWord,
                useRegularExpression: query.useRegularExpression,
                filter: filter,
                visibleRelativePaths: visible
            )
            var urls: [URL] = []
            var seen = Set<String>()
            for hit in hits where seen.insert(hit.url.standardizedFileURL.path).inserted {
                urls.append(hit.url)
            }
            var live: [URL: String] = [:]
            for url in urls {
                if let text = openBufferText(for: url) { live[url] = text }
            }
            // Captured by value: `urls` and `live` are vars, which a detached task must not share.
            let planned = await Task.detached(priority: .userInitiated) { [urls, live, query, replacement] () -> (entries: [WorkspaceEditPlanEntry], unreadable: Int) in
                var entries: [WorkspaceEditPlanEntry] = []
                var unreadable = 0
                for url in urls {
                    guard let text = live[url] ?? (try? String(contentsOf: url, encoding: .utf8)) else {
                        unreadable += 1
                        continue
                    }
                    entries.append(contentsOf: ProjectReplacePlanner.entries(for: query, replacement: replacement, in: text, url: url))
                }
                return (entries, unreadable)
            }.value
            guard !planned.entries.isEmpty else {
                findInFiles.status = "Nothing to replace"
                return
            }
            var warnings: [String] = []
            if hits.count >= 2_000 {
                warnings.append("The search stopped at 2,000 matches, so some files may be missing. Search again after applying.")
            }
            if planned.unreadable > 0 {
                warnings.append("\(planned.unreadable) file\(planned.unreadable == 1 ? "" : "s") couldn't be read as UTF-8 text and \(planned.unreadable == 1 ? "was" : "were") skipped.")
            }
            if !filter.isUnrestricted {
                warnings.append("Limited to \(findInFiles.scopeDescription(for: filter)).")
            }
            if !live.isEmpty {
                warnings.append("Files that are open are changed in their editors and left unsaved.")
            }
            let replacementLabel = replacement.isEmpty ? "nothing" : "“\(replacement)”"
            let plan = WorkspaceEditPlan(
                entries: planned.entries,
                warnings: warnings,
                title: "Replace “\(query.text)” with \(replacementLabel)"
            )
            let files = Set(planned.entries.map(\.url)).count
            findInFiles.status = "\(planned.entries.count) replacement\(planned.entries.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s"): review and apply"
            presentWorkspaceEditPreview(plan, style: .diff) { [weak self = self] edit in
                await self?.applyReplacement(edit, plan: plan) ?? WorkspaceEditApplyResult()
            }
        }
    }

    private func applyReplacement(_ edit: WorkspaceEdit, plan: WorkspaceEditPlan) async -> WorkspaceEditApplyResult {
        var texts: [URL: String] = [:]
        for url in edit.changes.keys {
            texts[url] = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        let outcome = IDEReplaceInFilesGuard.verified(edit, against: plan, texts: texts)
        var result = outcome.edit.changes.isEmpty
            ? WorkspaceEditApplyResult()
            : await historyRecordingApplier(named: "Replace in Files").apply(outcome.edit)
        for (url, count) in outcome.staleCounts {
            let note = "\(count) replacement\(count == 1 ? "" : "s") skipped: the file changed since the search."
            result.failures[url] = result.failures[url].map { "\($0) \(note)" } ?? note
        }
        if result.failures.isEmpty {
            let count = outcome.edit.changes.values.reduce(0) { $0 + $1.count }
            findInFiles.hits = []
            findInFiles.status = "Replaced \(count) occurrence\(count == 1 ? "" : "s") in \(result.appliedFiles.count) file\(result.appliedFiles.count == 1 ? "" : "s")"
        }
        return result
    }

    func openFindInFilesHit(_ hit: ProjectSearchResult) {
        let length = max(0, hit.range.end.utf16Offset - hit.range.start.utf16Offset)
        let range = NSRange(location: hit.range.start.utf16Offset, length: length)
        Task { await openDocument(from: hit.url, selecting: range) }
    }

    func toggleFindInFiles() {
        if findInFiles.isVisible {
            hideFindInFiles()
        } else {
            showFindInFiles()
        }
    }
}

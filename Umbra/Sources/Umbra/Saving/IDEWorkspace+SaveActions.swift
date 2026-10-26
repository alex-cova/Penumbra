import AppKit
import EditorIntelligence
import JavaIntelligence
import Penumbra

/// Settings ▸ Saving ▸ Actions on Save: what a save does to the text before it is written. They run
/// for the user's saves, autosave, saves before a run and git, and a tab being closed, never on the
/// way out of a window or the app. Each step reads the buffer as it is then and is dropped when the
/// buffer changed while it was computed; a step that fails is skipped and the save goes on.
extension IDEWorkspace {
    /// The order is IntelliJ's: fixes, then imports, then layout, then whitespace.
    func runActionsOnSave(for document: WorkbenchDocument, at url: URL, host: IDEEditorPaneHost) async {
        let preferences = self.preferences
        let textView = host.textView
        let controller = host.intelligenceController
        let language = document.languageIdentifier ?? LanguageIdentifier.identifier(for: url)

        if preferences.codeCleanupOnSave {
            await cleanUpCode(at: url, in: textView)
        }
        if preferences.javaOptimizeImportsOnSave {
            await controller?.applyCodeAction(ofKind: CodeAction.organizeImportsKind, timeout: .seconds(2))
        }
        if preferences.reformatOnSave {
            await reformatOnSave(at: url, in: textView, controller: controller, wholeFile: preferences.reformatsWholeFileOnSave)
        }
        let keepsWhitespace = language.map(IDESaveActions.languagesKeepingTrailingWhitespace.contains) ?? false
        let strip = keepsWhitespace ? .off : preferences.stripTrailingWhitespaceOnSave
        if strip != .off || preferences.ensureNewlineAtEndOfFile {
            await tidyWhitespace(at: url, in: textView, strip: strip, keepsCaretLine: preferences.keepsTrailingWhitespaceOnCaretLine,
                                 endsWithNewline: preferences.ensureNewlineAtEndOfFile)
        }
    }

    // MARK: Steps

    /// Applies the active inspection profile's quick fixes to a Java buffer (Code Cleanup).
    private func cleanUpCode(at url: URL, in textView: TextView) async {
        guard url.pathExtension.lowercased() == "java" else { return }
        let text = textView.text
        guard (text as NSString).length <= 400_000 else { return }
        let generation = textView.contentGeneration
        let rules = inspections.activeProfile.enabledRules().filter(\.hasQuickFix)
        guard !rules.isEmpty else { return }
        let result = await JavaBatchFixer.fixAll(
            rules: Set(rules), in: text, url: url, index: javaSupport.javaIndex,
            languageLevel: javaSupport.inspectionLanguageLevel(url)
        )
        guard !result.isEmpty, textView.contentGeneration == generation else { return }
        TextEditApplicator.apply(result.edits, in: textView)
    }

    private func reformatOnSave(
        at url: URL, in textView: TextView, controller: EditorIntelligenceController?, wholeFile: Bool
    ) async {
        guard let controller else { return }
        if wholeFile {
            await controller.formatDocumentForSave()
            return
        }
        let text = textView.text
        let base = await baseTextForChangedLines(at: url)
        // Typed while the base was read: the rows no longer describe the buffer.
        guard textView.text == text else { return }
        let rows = IDESaveActions.changedRows(base: base, current: text)
        guard !rows.isEmpty else { return }
        await controller.formatRangesForSave(IDESaveActions.ranges(ofRows: rows, in: text))
    }

    private func tidyWhitespace(
        at url: URL, in textView: TextView, strip: IDEStripWhitespaceScope, keepsCaretLine: Bool, endsWithNewline: Bool
    ) async {
        let text = textView.text
        let length = (text as NSString).length
        guard length <= IDESaveActions.maximumTextLength else { return }
        var rows: Set<Int>?
        if strip == .modifiedLines {
            let base = await baseTextForChangedLines(at: url)
            guard textView.text == text else { return }
            rows = IDESaveActions.changedRows(base: base, current: text)
        }
        var keeping = Set<Int>()
        if keepsCaretLine {
            let lines = IDEDiffText(text).lines
            for selection in textView.selectedRanges {
                keeping.insert(IDESaveActions.row(containing: selection.location, in: lines))
                keeping.insert(IDESaveActions.row(containing: NSMaxRange(selection), in: lines))
            }
        }
        var replacements: [IDESaveActions.Replacement] = []
        if strip != .off {
            replacements += IDESaveActions.trailingWhitespaceReplacements(in: text, rows: rows, keepingRows: keeping)
        }
        if endsWithNewline, let newline = IDESaveActions.finalNewlineReplacement(in: text) {
            replacements.append(newline)
        }
        guard !replacements.isEmpty else { return }
        TextEditApplicator.apply(replacements: replacements, in: textView)
    }

    /// What "changed lines" are measured against: the file in `HEAD`, or the file on disk before
    /// this save outside a repository. `nil` means a new file, so every line is changed.
    private func baseTextForChangedLines(at url: URL) async -> String? {
        if let root = gitStatus.repositoryRootPath {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(root + "/") {
                let head = await gitStatus.headContents(relativePath: String(path.dropFirst(root.count + 1)))
                if head.found {
                    guard let data = head.data else { return nil }
                    return String(data: data, encoding: .utf8)
                }
            }
        }
        return await Task.detached(priority: .userInitiated) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
    }

    // MARK: Build

    /// Build Project a moment after the user saved. It never asks for trust, never interrupts a
    /// sync or a task (it waits a little for them), and a newer save replaces a build not started.
    func scheduleBuildAfterSave() {
        guard preferences.buildProjectOnSave, project.rootURL != nil else { return }
        buildOnSaveTask?.cancel()
        buildOnSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<30 {
                guard !Task.isCancelled, let self, let system = self.projectSystems.active else { return }
                guard case .synced = system.syncState else { return }
                if !system.isBusy, !self.isRunActive {
                    system.build()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

import AgentKit
import AppKit
import EditorIntelligence
import Foundation

extension IDEWorkspace: IDEAgentHost {
    /// The open project, else (in AI mode only) a scratch folder, so Code can answer without one. The
    /// docked panel and the editor's agent entry points still need a real project.
    var agentProjectRoot: URL? {
        project.rootURL ?? (windowMode == .ai ? Self.agentScratchFolder : nil)
    }

    /// Where Code works when no folder is open: a plain folder in Application Support the agent may use.
    static let agentScratchFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("com.umbra.editor/Scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func toggleAgentPanel() {
        guard hasOpenProject else { return }
        if agent.isPanelVisible {
            hideAgentPage()
        } else {
            agent.showPanel()
        }
    }

    /// A new chat tab (an empty one is reused), with the caret in its message field.
    func newAgentChat() {
        guard hasOpenProject else { return }
        agent.newConversation()
        agent.showPanel()
    }

    func selectAgentChat(_ step: Int) {
        guard hasOpenProject else { return }
        agent.selectNeighbor(step)
        agent.showPanel()
    }

    /// A built-in command from the palette. Chat commands open the panel first. `/rename` without a
    /// name stays a notice; the palette asks for the name instead.
    func runAgentCommand(_ command: IDEAgentBuiltInCommand) {
        guard hasOpenProject else { return }
        switch command {
        case .history:
            showLocalHistory()
        case .rename:
            agent.showPanel()
            promptAgentRename()
        default:
            agent.showPanel()
            agent.runBuiltIn(command)
        }
    }

    func agentShowLocalHistory() {
        showLocalHistory()
    }

    /// The first time `.umbra/settings.local.json` is created. Tests turn session persistence off and
    /// must not stop on a modal; they keep the notice that tells the user to add the line.
    func agentOfferGitignore(_ relativePath: String) -> Bool {
        guard Self.isSessionPersistenceEnabled, let root = project.rootURL else { return false }
        var alert = IDEAlert.confirm(
            "Add to .gitignore",
            detail: "\(relativePath) holds rules for you alone. Add it to .gitignore so it stays out of a shared project.",
            confirm: "Add to .gitignore", cancel: "Not Now")
        guard alert.confirms() else { return false }
        let url = root.appendingPathComponent(".gitignore")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard let updated = IDEAgentPermissionFiles.gitignore(adding: relativePath, to: existing) else { return true }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func promptAgentRename() {
        guard let name = IDEAlert.promptForText(
            "Rename Chat", detail: "Leave it empty to use the first message.",
            initial: agent.selected.title, confirm: "Rename") else { return }
        agent.rename(agent.selected.id, to: name)
    }

    /// Closes the chat page and puts the caret back in the editor.
    func hideAgentPage() {
        guard agent.isPanelVisible else { return }
        agent.isPanelVisible = false
        focusActiveEditor()
    }

    func agentEditorContext() -> String {
        var lines = ["[Editor state, for orientation only]"]
        if let url = workbench.activePane.selectedDocument?.url {
            lines.append("Active file: \(agentRelativePath(url))")
        }
        var seen = Set<String>()
        let open = workbench.allDocuments()
            .compactMap(\.url)
            .map(agentRelativePath)
            .filter { seen.insert($0).inserted }
        if !open.isEmpty {
            lines.append("Open files: " + open.prefix(15).joined(separator: ", ") + (open.count > 15 ? ", …" : ""))
        }
        lines.append("Problems: \(problems.errorCount) errors, \(problems.warningCount) warnings")
        lines.append("[End editor state]")
        return lines.joined(separator: "\n")
    }

    func agentSelection() -> IDEAgentSelection? {
        guard let url = workbench.activePane.selectedDocument?.url else { return nil }
        let textView = host(for: workbench.activePaneID).textView
        let range = textView.selectedRange
        guard range.length > 0, let selected = textView.text(in: range), !selected.isEmpty else { return nil }
        let start = (textView.textLocation(at: range.location)?.lineNumber ?? 0) + 1
        // A selection that ends right after a newline doesn't include the next line.
        let trimmed = selected.hasSuffix("\n") ? String(selected.dropLast()) : selected
        let end = start + trimmed.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return IDEAgentSelection(path: agentRelativePath(url), startLine: start, endLine: end, text: selected)
    }

    func agentOpenText(title: String, text: String) {
        // What the agent hands over is shown in the editor, so AI mode steps aside.
        leaveAIModeForEditor()
        openUntitled(displayName: title, text: text)
    }

    func agentRecordWrite(path: String, before: String?, after: String?, source: IDELocalHistorySource, group: UUID?) {
        localHistory.record(path: path, text: after, source: source, group: group, before: before)
    }

    func agentInsertAtCaret(_ text: String) -> Bool {
        leaveAIModeForEditor()
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .text else { return false }
        let textView = host(for: workbench.activePaneID).textView
        textView.replace(textView.selectedRange, withText: text)
        focusActiveEditor()
        return true
    }

    func agentOpenFilePaths() -> [String] {
        var seen = Set<String>()
        return workbench.allDocuments()
            .filter { $0.contentKind == .text }
            .compactMap(\.url)
            .map(agentRelativePath)
            .filter { seen.insert($0).inserted }
    }

    func agentTerminalTail(lines: Int) -> String? {
        activeTerminalHost()?.recentText(lines: lines)
    }

    func agentFileSuggestions(query: String, limit: Int) -> [String] {
        let index = paletteFileIndex
        let open = workbench.allDocuments().compactMap(\.url)
        return index.search(query, limit: limit, boosts: open).hits.map { index.entry(at: $0.index).relativePath }
    }

    func agentProblems() -> [IDEAgentProblem] {
        problems.files.flatMap { file in
            file.rows.map { row in
                IDEAgentProblem(
                    path: agentRelativePath(file.url),
                    // Diagnostics count lines from 0; the model reads files with 1-based numbers.
                    line: row.diagnostic.range.start.line + 1,
                    severity: String(describing: row.diagnostic.severity),
                    source: row.diagnostic.source,
                    message: row.diagnostic.message)
            }
        }
    }

    // MARK: - Writes

    private func agentURL(_ relativePath: String) throws -> URL {
        guard let root = project.rootURL else { throw AgentWorkspaceError.readOnly }
        return root.appendingPathComponent(relativePath).standardizedFileURL
    }

    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {
        let url = try agentURL(relativePath)
        if workbench.allDocuments().contains(where: {
            $0.url?.standardizedFileURL.path == url.path && $0.contentKind != .text
        }) {
            throw AgentWorkspaceError.notText(relativePath)
        }
        // What the model based its edit on must still be what is in the editor (or on disk).
        let current = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        guard current == expecting else { throw AgentWorkspaceError.changedSinceRead(relativePath) }

        let textEdits = try IDEAgentEditTranslator.textEdits(edits, in: expecting)
        problems.noteAgentEdit(of: url)
        let result = await IDEWorkspaceEditApplier(host: self).apply(WorkspaceEdit(changes: [url: textEdits]))
        if let failure = result.failures[url] { throw AgentWorkspaceError.writeFailed(path: relativePath, reason: failure) }
    }

    func agentCreateFile(relativePath: String, contents: String) async throws {
        let url = try agentURL(relativePath)
        problems.noteAgentEdit(of: url)
        let result = await IDEWorkspaceEditApplier(host: self).apply(WorkspaceEdit(fileCreations: [(url, contents)]))
        if let failure = result.failures[url] { throw AgentWorkspaceError.writeFailed(path: relativePath, reason: failure) }
    }

    func agentTrashFile(relativePath: String) async throws {
        let url = try agentURL(relativePath)
        let result = await IDEWorkspaceEditApplier(host: self).apply(WorkspaceEdit(fileDeletions: [url]))
        if let failure = result.failures[url] { throw AgentWorkspaceError.writeFailed(path: relativePath, reason: failure) }
    }

    func agentShowDiff(relativePath: String, original: String?) {
        guard let url = try? agentURL(relativePath) else { return }
        leaveAIModeForEditor()
        let name = url.lastPathComponent
        openDiff(IDEDiffRequest(
            left: IDEDiffSide(source: .text(original ?? ""), title: original == nil ? "Before (new file)" : "Before the agent"),
            right: IDEDiffSide(source: .workingTree(path: url.path), title: "Now"),
            filePath: url.path,
            title: "\(name) (agent)"))
    }

    // MARK: - Commands and builds

    var agentIsGradleProject: Bool { gradle.isActive }

    func agentProjectTaskNames() -> [String] {
        guard let system = projectSystems.active, system.id != "gradle" else { return [] }
        return system.tasks.map(\.path)
    }

    func agentRunProjectTask(_ name: String) async -> String {
        guard let system = projectSystems.active, system.id != "gradle" else {
            return "This folder has no project tasks. Use gradle for a Gradle build."
        }
        guard system.tasks.contains(where: { $0.path == name }) else {
            let known = system.tasks.map(\.path).joined(separator: ", ")
            return known.isEmpty ? "\(system.displayName) has no tasks." : "Unknown task. Known tasks: \(known)"
        }
        system.runTasks([name])
        return "Started \(system.displayName) task \(name)."
    }

    /// Java tools are offered in a Gradle project or when a Java file is open: elsewhere they would
    /// only add to the tool list a small model has to read.
    func agentJavaNavigator() -> (any IDEAgentNavigating)? {
        guard hasAgentNavigableSource else { return nil }
        return IDEEngineAgentNavigator(engine: navigationEngine)
    }

    private var hasAgentNavigableSource: Bool {
        let extensions = ["java", "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"]
        return gradle.isActive || swiftPM.isActive || xcode.isActive || npm.isActive
            || workbench.allDocuments().contains { extensions.contains($0.url?.pathExtension.lowercased() ?? "") }
    }

    /// The closures hold the window weakly: a running session must not keep it alive.
    func agentSymbolSearch() -> (any IDEAgentSymbolSearching)? {
        guard hasAgentNavigableSource else { return nil }
        return IDEIndexAgentSymbolSearch(
            javaIndex: javaSupport.javaIndex,
            swiftIndex: swiftSupport.index,
            typeScriptIndex: typescriptSupport.index,
            text: { [weak self] url in
                if let open = await MainActor.run(body: { self?.openBufferText(for: url) }) { return open }
                return try? String(contentsOf: url, encoding: .utf8)
            },
            structureProvider: { [weak self] language in
                await MainActor.run { self?.languages.structure(for: language) }
            },
            readiness: { [weak self] in await self?.agentIndexReadiness() ?? .ready })
    }

    /// What is building right now: the activity the language supports report, plus walks that began
    /// outside them and a Java model that is about to replace the (still empty) source index.
    private func agentIndexReadiness() async -> IDEAgentIndexReadiness {
        var pending = indexActivity.active
        if javaSupport.isLoadingJavaModel { pending.insert(.javaSources) }
        if await swiftSupport.index.isBuilding { pending.insert(.swift) }
        if await typescriptSupport.index.isBuilding { pending.insert(.typeScript) }
        return IDEAgentIndexReadiness(pending: pending)
    }

    func agentLineText(url: URL, line: Int) -> String? {
        guard line >= 1, let text = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return nil }
        var number = 1
        for piece in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if number == line { return String(piece) }
            number += 1
        }
        return nil
    }

    func agentCommandEnvironment() async -> [String: String] {
        let javaHome = await javaSupport.jdk.resolveForGradle()?.installation.home
        return AgentCommandEnvironment.make(javaHome: javaHome, extras: IDEAgentSettings.shared.commandEnvironment)
    }

    func agentSaveBuffers(relativePaths: [String]) async {
        for path in relativePaths {
            guard let url = try? agentURL(path) else { continue }
            _ = await saveBuffer(at: url)
        }
    }

    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome {
        agent.isGradleRunActive = true
        defer { agent.isGradleRunActive = false }
        let arguments = options.contains("--no-configuration-cache") ? options : options + ["--no-configuration-cache"]
        return await withCheckedContinuation { continuation in
            gradle.runGradleTasks(tasks, extraArguments: arguments, timeout: .seconds(timeout)) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    func agentCancelGradle() {
        // Only a run the agent started: the user's own build is not Stop's to end.
        guard agent.isGradleRunActive else { return }
        gradle.cancelTasks()
    }

    func agentShowFile(relativePath: String, line: Int?, column: Int?) async throws {
        await openAgentCitedFile(IDEAgentFileLinks.Reference(path: relativePath, line: line, column: column))
    }

    func agentRevealGradle() {
        isProjectSidebarVisible = true
        showGradleOutput()
    }

    func agentShowCommand(id: UUID, title: String, line: String?) {
        showAgentCommand(id: id, title: title, line: line)
    }

    /// One question for all the servers a project's files list, naming each command line, because
    /// what runs is the program, with this user's permissions.
    func agentConfirmMCPServers(_ servers: [MCPServerConfig]) async -> Set<String> {
        guard !servers.isEmpty else { return [] }
        let listing = servers.prefix(8).map { server in
            var line = "• \(server.name): \(server.displayCommand)"
            if !server.env.isEmpty { line += "   (sets \(server.env.keys.sorted().joined(separator: ", ")))" }
            return line
        }.joined(separator: "\n") + (servers.count > 8 ? "\n… and \(servers.count - 8) more" : "")
        var alert = IDEAlert.confirm(
            servers.count == 1
                ? "This project wants to run an MCP server."
                : "This project wants to run \(servers.count) MCP servers.",
            detail: "\(listing)\n\nThese are programs from the project's own files. They run on this Mac with your permissions, and the agent can use what they offer (each use asks first). Allow them only if you trust this project.",
            confirm: "Allow", cancel: "Not Now")
        let allowed = await alert.confirms(in: window)
        return allowed ? Set(servers.map(IDEMCPStore.fingerprint(of:))) : []
    }

    func agentProblemsAfterEdit(relativePaths: [String], timeout: TimeInterval) async -> String? {
        // Only an open file the editor already analyses has anything to report: a file written to disk,
        // or a language with no analysis, would only make this wait out its timeout.
        let open = relativePaths.compactMap { path -> (path: String, url: URL)? in
            guard let url = try? agentURL(path), openBufferText(for: url) != nil, problems.hasEditorReport(for: url) else { return nil }
            return (path, url)
        }
        guard !open.isEmpty else { return nil }
        let settled = await IDEAgentEditProblems.wait(timeout: timeout) {
            open.allSatisfy { self.problems.hasEditorReportSinceAgentEdit(for: $0.url) }
        }
        let errors = open.flatMap { file in
            problems.currentErrors(for: file.url).map {
                IDEAgentEditProblems.Row(path: file.path, line: $0.range.start.line + 1, message: $0.message)
            }
        }
        return IDEAgentEditProblems.note(errors: errors, analysed: settled)
    }

    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems {
        let javaFiles = relativePaths.filter { $0.hasSuffix(".java") }
        guard !javaFiles.isEmpty else { return IDEAgentFreshProblems() }
        guard await javaSupport.compilerDiagnostics.isEnabled else {
            return IDEAgentFreshProblems(unavailable: "no JDK is configured for this project, or it has not finished syncing")
        }

        var result = IDEAgentFreshProblems()
        for path in javaFiles {
            guard let url = try? agentURL(path),
                  let text = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
            else { continue }
            let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
            let document = EditorIntelligence.Document(
                url: url, displayName: url.lastPathComponent,
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)),
                cursor: Cursor(position: start),
                viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
                languageIdentifier: "java")
            guard let diagnostics = await javaSupport.compilerDiagnostics.freshDiagnostics(for: document) else {
                result.unavailable = "javac did not produce a result for \(path)"
                continue
            }
            result.problems += diagnostics.map {
                IDEAgentProblem(
                    path: path, line: $0.range.start.line + 1, severity: String(describing: $0.severity),
                    source: $0.source, message: $0.message)
            }
        }
        return result
    }

    /// Project-relative when the file is inside the project, as the model names files.
    func agentRelativePath(_ url: URL) -> String {
        guard let root = project.rootURL?.standardizedFileURL.path else { return url.path }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// Opens a file the model cited. An already-open file is focused without reloading, so unsaved
    /// edits stay, and the caret is placed from that buffer rather than the copy on disk.
    func openAgentCitedFile(_ reference: IDEAgentFileLinks.Reference) async {
        guard let root = project.rootURL, let url = IDEAgentFileLinks.resolve(reference.path, under: root) else { return }
        // A file is shown in the editor; in AI mode that means leaving it (the editor stays as it was).
        leaveAIModeForEditor()
        host(for: workbench.activePaneID).textView.recordNavigationCheckpoint()
        let range = await citedSelection(reference, in: url)
        if focusOpenDocument(url, selecting: range) { return }
        await openDocument(from: url, selecting: range)
    }

    private func citedSelection(_ reference: IDEAgentFileLinks.Reference, in url: URL) async -> NSRange? {
        guard let line = reference.line else { return nil }
        let column = max(reference.column ?? 1, 1)
        if let live = openBufferText(for: url) {
            return Self.utf16Range(ofLine: line, column: column, in: live)
        }
        return await Task.detached { Self.utf16Range(ofLine: line, column: column, in: url) }.value
    }
}

import AgentKit
import EditorIntelligence
import Foundation

extension IDEWorkspace: IDEAgentHost {
    var agentProjectRoot: URL? { project.rootURL }

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
        // What the model based its edit on must still be what is in the editor (or on disk).
        let current = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        guard current == expecting else { throw AgentWorkspaceError.changedSinceRead(relativePath) }

        let textEdits = try IDEAgentEditTranslator.textEdits(edits, in: expecting)
        let result = await IDEWorkspaceEditApplier(host: self).apply(WorkspaceEdit(changes: [url: textEdits]))
        if let failure = result.failures[url] { throw AgentWorkspaceError.writeFailed(path: relativePath, reason: failure) }
    }

    func agentCreateFile(relativePath: String, contents: String) async throws {
        let url = try agentURL(relativePath)
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
        let name = url.lastPathComponent
        openDiff(IDEDiffRequest(
            left: IDEDiffSide(source: .text(original ?? ""), title: original == nil ? "Before (new file)" : "Before the agent"),
            right: IDEDiffSide(source: .workingTree(path: url.path), title: "Now"),
            filePath: url.path,
            title: "\(name) (agent)"))
    }

    // MARK: - Commands and builds

    var agentIsGradleProject: Bool { javaSupport.isGradleProject }

    /// Java tools are offered in a Gradle project or when a Java file is open: elsewhere they would
    /// only add to the tool list a small model has to read.
    func agentJavaNavigator() -> (any IDEAgentJavaNavigating)? {
        let hasJava = javaSupport.isGradleProject
            || workbench.allDocuments().contains { $0.url?.pathExtension.lowercased() == "java" }
        guard hasJava else { return nil }
        return IDEJavaAgentNavigator(
            definitionProvider: javaSupport.navigationProvider, usageProvider: javaSupport.findUsagesProvider)
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
            javaSupport.runGradleTasks(tasks, extraArguments: arguments, timeout: .seconds(timeout)) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    func agentCancelGradle() {
        // Only a run the agent started: the user's own build is not Stop's to end.
        guard agent.isGradleRunActive else { return }
        javaSupport.cancelGradleTasks()
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
}

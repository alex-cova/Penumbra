import AgentKit
import Foundation

/// A problem as the agent sees it: project-relative, 1-based lines.
struct IDEAgentProblem: Sendable, Equatable {
    var path: String
    var line: Int
    var severity: String
    var source: String
    var message: String
}

/// What the agent needs from a window. `IDEWorkspace` conforms; tests use a fake. Everything is
/// read on the main actor, and tools reach it through weak references only.
@MainActor
protocol IDEAgentHost: AnyObject {
    var agentProjectRoot: URL? { get }
    /// Open files with edits not yet saved, keyed by absolute path.
    func agentUnsavedBuffers() -> [String: String]
    /// A short block describing the editor's state, attached to each user message so the cached
    /// prefix (system prompt, tools) stays untouched.
    func agentEditorContext() -> String
    func agentProblems() -> [IDEAgentProblem]

    // Writes. Paths are project-relative and already checked against the project and protected
    // folders; the host applies them to open buffers or disk and keeps its UI in step.
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws
    func agentCreateFile(relativePath: String, contents: String) async throws
    func agentTrashFile(relativePath: String) async throws
    /// Opens the diff viewer on `original` (empty for a new file) against the file as it is now.
    func agentShowDiff(relativePath: String, original: String?)

    // Commands and builds.
    /// The environment a command runs in (the selected JDK's `JAVA_HOME` and `bin`, the user's extras).
    func agentCommandEnvironment() async -> [String: String]
    /// Saves these open buffers to disk, so a command or build sees the agent's edits.
    func agentSaveBuffers(relativePaths: [String]) async
    var agentIsGradleProject: Bool { get }
    /// Runs Gradle through the window's own runner (console, Problems, Test Results), asking for
    /// the project's trust first. Ends exactly once, whatever happens.
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome
    func agentCancelGradle()
    /// Compiler results for these files' current text, awaited. `unavailable` says why not.
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems

    // Navigation. Both are optional (see the extension below).
    /// Java symbol navigation, or `nil` when the project has no Java to resolve.
    func agentJavaNavigator() -> (any IDEAgentJavaNavigating)?
    /// The text of 1-based `line` of a file, from its open buffer or from disk.
    func agentLineText(url: URL, line: Int) -> String?

    // Mentions. All optional (see the extension below).
    /// The active editor's selection, or `nil` when nothing is selected.
    func agentSelection() -> IDEAgentSelection?
    /// Open files, project-relative, in tab order.
    func agentOpenFilePaths() -> [String]
    /// The last lines of the terminal the user is looking at.
    func agentTerminalTail(lines: Int) -> String?
    /// Project files whose path matches `query`, best first, open files leading.
    func agentFileSuggestions(query: String, limit: Int) -> [String]
    /// An agent wrote a file: `before` is what it held (`nil` if new), `after` what it holds (`nil` if deleted).
    func agentRecordWrite(path: String, before: String?, after: String?, source: IDELocalHistorySource, group: UUID?)
    /// Opens text in a new, unsaved editor tab (a plan to keep and edit).
    func agentOpenText(title: String, text: String)
    /// Puts text at the active editor's caret, replacing the selection. `false` if there is no text editor to put it in.
    func agentInsertAtCaret(_ text: String) -> Bool
    /// Opens the sidebar's History tab on the active file.
    func agentShowLocalHistory()
    /// Offers to add `relativePath` to the project's `.gitignore`. `true` when the line is now in the file.
    func agentOfferGitignore(_ relativePath: String) -> Bool

    // Showing work. All optional (see the extension below). The model asks to open a file; a build
    // or a command reveals the panel it belongs to. None of these run anything by themselves.
    /// Opens `relativePath` in the editor. `line` and `column` are 1-based.
    func agentShowFile(relativePath: String, line: Int?, column: Int?) async throws
    /// Shows the Gradle tool window and the Gradle console.
    func agentRevealGradle()
    /// Appends `line` to the terminal tab for this command, creating and selecting the tab on the
    /// first piece of text. `nil` means the command has finished and later text is ignored.
    func agentShowCommand(id: UUID, title: String, line: String?)
}

extension IDEAgentHost {
    // Optional capabilities: a host without them simply doesn't get the tools that need them.
    func agentJavaNavigator() -> (any IDEAgentJavaNavigating)? { nil }
    func agentLineText(url: URL, line: Int) -> String? { nil }
    func agentSelection() -> IDEAgentSelection? { nil }
    func agentOpenFilePaths() -> [String] { [] }
    func agentTerminalTail(lines: Int) -> String? { nil }
    func agentFileSuggestions(query: String, limit: Int) -> [String] { [] }
    func agentRecordWrite(path: String, before: String?, after: String?, source: IDELocalHistorySource, group: UUID?) {}
    func agentOpenText(title: String, text: String) {}
    func agentInsertAtCaret(_ text: String) -> Bool { false }
    func agentShowLocalHistory() {}
    func agentOfferGitignore(_ relativePath: String) -> Bool { false }
    func agentShowFile(relativePath: String, line: Int?, column: Int?) async throws {}
    func agentRevealGradle() {}
    func agentShowCommand(id: UUID, title: String, line: String?) {}
}

struct IDEAgentFreshProblems: Sendable, Equatable {
    var problems: [IDEAgentProblem] = []
    var unavailable: String?
}

/// Lets `@Sendable` tool closures reach the host without capturing it. Read only inside
/// `MainActor.run`, and weak, so a running session never keeps the window alive.
final class IDEAgentHostBox: @unchecked Sendable {
    private weak var host: (any IDEAgentHost)?

    init(_ host: any IDEAgentHost) { self.host = host }

    func read<T: Sendable>(default fallback: T, _ body: @MainActor (any IDEAgentHost) -> T) async -> T {
        await MainActor.run {
            guard let host else { return fallback }
            return body(host)
        }
    }

    @MainActor
    func replaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {
        guard let host else { throw AgentWorkspaceError.readOnly }
        try await host.agentReplaceText(relativePath: relativePath, expecting: expecting, edits: edits)
    }

    @MainActor
    func createFile(relativePath: String, contents: String) async throws {
        guard let host else { throw AgentWorkspaceError.readOnly }
        try await host.agentCreateFile(relativePath: relativePath, contents: contents)
    }

    func commandEnvironment() async -> [String: String] {
        guard let host else { return AgentCommandEnvironment.make(javaHome: nil) }
        return await host.agentCommandEnvironment()
    }

    @MainActor
    func saveBuffers(relativePaths: [String]) async {
        await host?.agentSaveBuffers(relativePaths: relativePaths)
    }

    @MainActor
    func runGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome {
        guard let host else { return .notStarted("The window is closed.") }
        return await withTaskCancellationHandler {
            await host.agentRunGradle(tasks: tasks, options: options, timeout: timeout)
        } onCancel: {
            // Stop: end the Gradle run the host started on our behalf.
            Task { @MainActor [weak self] in self?.host?.agentCancelGradle() }
        }
    }

    func lineText(url: URL, line: Int) async -> String? {
        await read(default: nil) { $0.agentLineText(url: url, line: line) }
    }

    @MainActor
    func freshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems {
        guard let host else { return IDEAgentFreshProblems(unavailable: "The window is closed.") }
        return await host.agentFreshProblems(relativePaths: relativePaths)
    }

    @MainActor
    func trashFile(relativePath: String) async throws {
        guard let host else { throw AgentWorkspaceError.readOnly }
        try await host.agentTrashFile(relativePath: relativePath)
    }

    @MainActor
    func showFile(relativePath: String, line: Int?, column: Int?) async throws {
        guard let host else { throw AgentWorkspaceError.readOnly }
        try await host.agentShowFile(relativePath: relativePath, line: line, column: column)
    }

    func revealGradle() async {
        await MainActor.run { host?.agentRevealGradle() }
    }

    /// Hops to the main thread and waits, so chunks that arrive from the command's reader stay in
    /// order with the verdict the tool appends after `run` returns.
    func showCommand(id: UUID, title: String, line: String?) {
        let apply = { [weak self] in
            MainActor.assumeIsolated {
                self?.host?.agentShowCommand(id: id, title: title, line: line)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.sync(execute: apply)
        }
    }
}

/// Problems the editor already knows about (open files, the last Gradle build), plus the compiler's
/// answer for the files this run changed, awaited for their exact current text.
struct IDEDiagnosticsTool: AgentTool {
    static let maxRows = 100

    private static let compilerSource = "javac"

    let problems: @Sendable () async -> [IDEAgentProblem]
    /// Compiles these project-relative files now. `nil` for tests that only read the store.
    var fresh: (@Sendable ([String]) async -> IDEAgentFreshProblems)?

    var risk: ToolRisk { .read }
    var verifies: Bool { true }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "diagnostics",
            description: """
            List the compiler errors, warnings and inspections for the project. It covers files open in \
            the editor and the last Gradle build, and compiles the Java files you changed in this run \
            (or the one in `path`) right now, so the answer matches their current text. Run it after \
            editing.
            """,
            parameters: [ToolParameter("path", .string, "Only this project-relative file, compiled now if it is Java.", optional: true)])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = try arguments.optionalString("path")
        var rows = await problems().filter { path == nil || $0.path == path }
        var notes: [String] = []

        if let fresh {
            var targets: [String] = []
            if let path {
                targets = [path]
            } else if let scope = context.checkpoint {
                targets = await scope.log.writtenHashes(in: scope.run).keys.sorted()
            }
            if !targets.isEmpty {
                let result = await fresh(targets)
                if let reason = result.unavailable {
                    notes.append("Note: the compiler could not be run for fresh results (\(reason)); this is only what the editor already knew.")
                } else {
                    // The compiler's answer for the current text replaces its older rows for those files.
                    rows.removeAll { targets.contains($0.path) && $0.source == Self.compilerSource }
                    rows += result.problems
                }
            }
        }

        var seen = Set<String>()
        rows = rows.filter { seen.insert("\($0.path)|\($0.line)|\($0.severity)|\($0.message)").inserted }
        rows.sort { lhs, rhs in
            let (l, r) = (Self.rank(lhs.severity), Self.rank(rhs.severity))
            return (l, lhs.path, lhs.line) < (r, rhs.path, rhs.line)
        }

        guard !rows.isEmpty else {
            return (["No problems reported" + (path.map { " for \($0)" } ?? "")
                + ". This covers open files, the last Gradle build and the files compiled just now."] + notes)
                .joined(separator: "\n")
        }
        var lines = rows.prefix(Self.maxRows).map { "\($0.path):\($0.line): \($0.severity) [\($0.source)]: \($0.message)" }
        if rows.count > Self.maxRows { lines.append("[\(rows.count - Self.maxRows) more problems not shown. Pass a path.]") }
        return (lines + notes).joined(separator: "\n")
    }

    private static func rank(_ severity: String) -> Int {
        switch severity {
        case "error": 0
        case "warning": 1
        default: 2
        }
    }
}

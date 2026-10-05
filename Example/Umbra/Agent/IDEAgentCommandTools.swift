import AgentKit
import Foundation
import JavaIntelligence

/// Which open, unsaved buffers hold the agent's own edits and which hold the user's. The agent's
/// are saved before a command so it runs on what the agent wrote; the user's are never saved
/// silently, only named on the approval card.
nonisolated enum IDEAgentBufferTriage {
    struct Result: Equatable {
        var agentOwned: [String] = []
        var userOwned: [String] = []
    }

    /// - Parameters:
    ///   - unsaved: open buffers with unsaved edits, absolute path to text.
    ///   - written: hash of the last text the agent wrote to each project-relative path this run.
    static func classify(unsaved: [String: String], root: URL, written: [String: UInt64]) -> Result {
        let rootPath = root.standardizedFileURL.path
        var result = Result()
        for (path, text) in unsaved.sorted(by: { $0.key < $1.key }) {
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            // Only a buffer still holding exactly what the agent wrote is the agent's. If the user
            // typed after it, it is theirs.
            if let hash = written[relative], hash == CheckpointLog.hash(of: text) {
                result.agentOwned.append(relative)
            } else {
                result.userOwned.append(relative)
            }
        }
        return result
    }
}

/// Shared by the command tools: triage, notes for the approval card, saving, formatting.
nonisolated struct IDEAgentCommandSupport: Sendable {
    let root: URL
    let box: IDEAgentHostBox

    func triage(_ context: ToolContext) async -> IDEAgentBufferTriage.Result {
        let unsaved = await box.read(default: [:]) { $0.agentUnsavedBuffers() }
        var written: [String: UInt64] = [:]
        if let scope = context.checkpoint { written = await scope.log.writtenHashes(in: scope.run) }
        return IDEAgentBufferTriage.classify(unsaved: unsaved, root: root, written: written)
    }

    func notes(_ triage: IDEAgentBufferTriage.Result) -> [String] {
        var notes: [String] = []
        if !triage.agentOwned.isEmpty {
            notes.append("Saves the files the agent changed first: " + triage.agentOwned.joined(separator: ", "))
        }
        if !triage.userOwned.isEmpty {
            notes.append("You have unsaved changes in " + triage.userOwned.joined(separator: ", ")
                + ". They are not saved, so the command sees the version on disk.")
        }
        return notes
    }

    func saveAgentBuffers(_ context: ToolContext) async {
        let triage = await triage(context)
        guard !triage.agentOwned.isEmpty else { return }
        await box.saveBuffers(relativePaths: triage.agentOwned)
    }

    func timeout(_ arguments: ToolArguments, default fallback: TimeInterval, maximum: TimeInterval) throws -> TimeInterval {
        guard let seconds = try arguments.optionalInt("timeout_seconds") else { return fallback }
        return min(maximum, max(5, TimeInterval(seconds)))
    }
}

struct IDERunCommandTool: AgentTool {
    static let defaultTimeout: TimeInterval = 120
    static let maxTimeout: TimeInterval = 600
    static let maxOutputCharacters = 24_000

    let support: IDEAgentCommandSupport

    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_command",
            description: """
            Run a shell command in the project root (zsh, no login shell, no stdin). The user approves \
            each command first, and it then runs in a new integrated-terminal tab. Use it for what the \
            other tools can't do, such as git and scripts. Not for reading or editing files, and not for \
            a Gradle build or tests (use gradle and run_tests; those open the Gradle tool window). \
            Interactive programs and long-lived servers will not work: anything the command starts is \
            stopped when it ends.
            """,
            parameters: [
                ToolParameter("command", .string, "The shell command."),
                ToolParameter("reason", .string, "One sentence on why you need to run it, shown to the user."),
                ToolParameter("timeout_seconds", .integer, "Default 120, at most 600.", optional: true),
            ])
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let command = try? arguments.string("command") else { return nil }
        let triage = await support.triage(context)
        return ApprovalRequest(
            title: "Run command", command: command, workingDirectory: support.root.path,
            reason: try? arguments.optionalString("reason"), warnings: CommandWarnings.warnings(for: command),
            notes: support.notes(triage), editableArgument: "command")
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let command = try arguments.string("command")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("The command is empty.") }
        let timeout = try support.timeout(arguments, default: Self.defaultTimeout, maximum: Self.maxTimeout)

        await support.saveAgentBuffers(context)
        let environment = await support.box.commandEnvironment()
        let progress = context.progress
        let commandID = UUID()
        let box = support.box
        box.showCommand(id: commandID, title: command, line: "$ \(command)\n")
        let result: AgentCommandResult
        do {
            result = try await AgentCommandRunner.run(
                AgentCommandSpec(command: command, workingDirectory: support.root, environment: environment, timeout: timeout),
                onOutput: { chunk in
                    progress?(chunk)
                    box.showCommand(id: commandID, title: command, line: chunk)
                })
        } catch {
            box.showCommand(id: commandID, title: command, line: error.localizedDescription + "\n")
            box.showCommand(id: commandID, title: command, line: nil)
            throw ToolError(error.localizedDescription)
        }
        let formatted = Self.format(command: command, result: result, timeout: timeout)
        let verdict = formatted.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let separator = result.output.hasSuffix("\n") || result.output.isEmpty ? "" : "\n"
        box.showCommand(id: commandID, title: command, line: separator + verdict + "\n")
        box.showCommand(id: commandID, title: command, line: nil)
        return formatted
    }

    static func format(command: String, result: AgentCommandResult, timeout: TimeInterval) -> String {
        var output = OutputTruncation.headAndTail(result.output, maxCharacters: maxOutputCharacters)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "(no output)" }
        let seconds = String(format: "%.1f", result.duration)
        let verdict: String
        if result.timedOut {
            verdict = "[timed out after \(Int(timeout)) s and was killed, with everything it started]"
        } else if result.cancelled {
            verdict = "[cancelled by the user]"
        } else if let code = result.exitCode {
            verdict = "[exit code \(code) after \(seconds) s]"
        } else {
            verdict = "[killed by signal \(result.signal ?? 0) after \(seconds) s]"
        }
        return "$ \(command)\n\(output)\n\(verdict)"
    }
}

/// Runs Gradle through the window's own runner, so the console, Problems and Test Results show it
/// like any build the user started, and the project's trust prompt applies.
struct IDEGradleTool: AgentTool {
    static let defaultTimeout: TimeInterval = 300
    static let maxTimeout: TimeInterval = 900

    let support: IDEAgentCommandSupport

    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "gradle",
            description: """
            Run Gradle tasks in the project, such as build, classes or a module's task like :app:test. \
            `build` builds the app. The user approves each run, and the Gradle tool window and console \
            open so they can watch it. Gradle build scripts are code. You get a summary: compiler \
            errors, failed tests and the build's verdict, not the full log. To run tests use run_tests.
            """,
            parameters: [
                ToolParameter("tasks", .array(of: .string), "Task names, e.g. [\"classes\"] or [\":app:build\"]."),
                ToolParameter("options", .array(of: .string), "Extra Gradle arguments, e.g. [\"--info\"].", optional: true),
                ToolParameter("reason", .string, "One sentence on why, shown to the user."),
                ToolParameter("timeout_seconds", .integer, "Default 300, at most 900.", optional: true),
            ])
    }

    /// The command line a permission rule such as `Bash(gradle build:*)` matches.
    func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let tasks = try? arguments.stringArray("tasks"), !tasks.isEmpty else { return .none }
        let options = (try? arguments.optionalStringArray("options")) ?? []
        return .command((["gradle"] + tasks + options).joined(separator: " "))
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let tasks = try? arguments.stringArray("tasks"), !tasks.isEmpty else { return nil }
        let options = (try? arguments.optionalStringArray("options")) ?? []
        let triage = await support.triage(context)
        return ApprovalRequest(
            title: "Run Gradle", command: (["gradle"] + tasks + options).joined(separator: " "),
            workingDirectory: support.root.path, reason: try? arguments.optionalString("reason"),
            warnings: [], notes: support.notes(triage))
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let tasks = try arguments.stringArray("tasks")
        let options = try arguments.optionalStringArray("options") ?? []
        guard !tasks.isEmpty else { throw ToolError("Give at least one task.") }
        let timeout = try support.timeout(arguments, default: Self.defaultTimeout, maximum: Self.maxTimeout)
        return try await IDEGradleRunner.run(tasks: tasks, options: options, timeout: timeout, support: support, context: context)
    }
}

struct IDERunTestsTool: AgentTool {
    let support: IDEAgentCommandSupport

    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "run_tests",
            description: """
            Run the project's tests with Gradle and get the failures: test name, message and where it \
            failed. Narrow it with `tests` (a class, Class.method, or a package pattern) and `module`. \
            The user approves each run, and the Gradle tool window and console open for it.
            """,
            parameters: [
                ToolParameter("tests", .array(of: .string), "Filters such as \"com.example.FooTest\" or \"FooTest.bar\". Empty runs everything.", optional: true),
                ToolParameter("module", .string, "Gradle project path such as \":app\". Default: the root project.", optional: true),
                ToolParameter("reason", .string, "One sentence on why, shown to the user."),
                ToolParameter("timeout_seconds", .integer, "Default 300, at most 900.", optional: true),
            ])
    }

    private func command(_ arguments: ToolArguments) throws -> (tasks: [String], options: [String]) {
        let module = (try arguments.optionalString("module")) ?? ""
        let filters = try arguments.optionalStringArray("tests") ?? []
        let task = module.isEmpty ? "test" : (module.hasSuffix(":") ? module : module + ":") + "test"
        return ([task], filters.flatMap { ["--tests", $0] })
    }

    func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let command = try? command(arguments) else { return .none }
        return .command((["gradle"] + command.tasks + command.options).joined(separator: " "))
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let command = try? command(arguments) else { return nil }
        let triage = await support.triage(context)
        return ApprovalRequest(
            title: "Run tests", command: (["gradle"] + command.tasks + command.options).joined(separator: " "),
            workingDirectory: support.root.path, reason: try? arguments.optionalString("reason"),
            warnings: [], notes: support.notes(triage))
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let (tasks, options) = try command(arguments)
        let timeout = try support.timeout(arguments, default: IDEGradleTool.defaultTimeout, maximum: IDEGradleTool.maxTimeout)
        return try await IDEGradleRunner.run(tasks: tasks, options: options, timeout: timeout, support: support, context: context)
    }
}

enum IDEGradleRunner {
    static func run(
        tasks: [String], options: [String], timeout: TimeInterval, support: IDEAgentCommandSupport, context: ToolContext
    ) async throws -> String {
        await support.saveAgentBuffers(context)
        await support.box.revealGradle()
        let started = Date()
        let outcome = await support.box.runGradle(tasks: tasks, options: options, timeout: timeout)
        let commandLine = (["gradle"] + tasks + options).joined(separator: " ")

        var input = IDEGradleSummary.Input(
            commandLine: commandLine, projectRoot: support.root, exitCode: nil, stdout: "", stderr: "",
            duration: Date().timeIntervalSince(started))
        switch outcome {
        case .notStarted(let reason):
            throw ToolError(reason)
        case .failed(let reason):
            throw ToolError(reason)
        case .finished(let result):
            input.exitCode = result.exitCode; input.stdout = result.stdout; input.stderr = result.stderr
        case .timedOut(let partial):
            input.timedOut = true; input.stdout = partial.stdout; input.stderr = partial.stderr
        case .cancelled(let partial):
            input.cancelled = true; input.stdout = partial?.stdout ?? ""; input.stderr = partial?.stderr ?? ""
        }

        let directories = IDEGradleSummary.freshTestReportDirectories(under: support.root, since: started)
        if !directories.isEmpty {
            input.tests = JUnitXMLReportParser.parseReports(in: directories, projectRoot: support.root)
        } else if input.stdout.contains("tests completed") || input.stderr.contains("tests completed") {
            input.tests = JUnitXMLReportParser.parseGradleSummary(input.stdout + "\n" + input.stderr)
        }
        return IDEGradleSummary.make(input)
    }
}

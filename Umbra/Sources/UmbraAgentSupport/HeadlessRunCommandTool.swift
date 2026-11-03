import AgentKit
import Foundation

/// What a host-independent `run_command` needs from its host. The app's
/// `IDERunCommandTool` takes an `IDEAgentCommandSupport` holding a `@MainActor` host box
/// plus JavaIntelligence runners; headless hosts (the CLI, `UmbraACP`) implement this small
/// protocol instead: a project root, a built command environment, and a progress sink.
public protocol UmbraAgentCommandHost: Sendable {
    var projectRoot: URL { get }
    func commandEnvironment() async -> [String: String]
    func showCommand(id: UUID, title: String, line: String?)
}

/// A `run_command` tool with no AppKit, no `@MainActor` box, and no Gradle/Maven runners:
/// every shell command runs through `AgentCommandRunner` in the project root. Permission
/// subjects and approval cards match the app's tool, so the same `Bash(...)` rules cover both.
public struct UmbraAgentRunCommandTool: AgentTool, Sendable {
    public static let defaultTimeout: TimeInterval = 120
    public static let maxTimeout: TimeInterval = 600
    public static let maxOutputCharacters = 24_000

    public let host: any UmbraAgentCommandHost
    public var sandbox: IDEAgentSandboxChoice?

    public init(host: any UmbraAgentCommandHost, sandbox: IDEAgentSandboxChoice? = nil) {
        self.host = host
        self.sandbox = sandbox
    }

    public var risk: ToolRisk { .command }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "run_command",
            description: """
            Run a shell command in the project root (zsh, no stdin). The user approves each one first. \
            Use it for what the other tools can't do, such as git and scripts; not for reading or editing \
            files. Interactive programs and servers will not work: anything it starts stops when it \
            ends. Large output is saved; read the rest with read_tool_output.
            """,
            parameters: [
                ToolParameter("command", .string, "The shell command."),
                ToolParameter("reason", .string, "One sentence on why you need to run it, shown to the user."),
                ToolParameter("timeout_seconds", .integer, "Default 120, at most 600.", optional: true),
            ])
    }

    public func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let command = try? arguments.optionalString("command") else { return .none }
        return .command(command)
    }

    public func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard let command = try? arguments.string("command") else { return nil }
        var notes: [String] = []
        if let sandbox {
            notes.append(sandbox.isConsented
                ? "Runs sandboxed: reads stay out of credentials, writes stay in the project, temp and build caches."
                : "First sandboxed run: the workspace profile keeps reads out of credentials and writes in the project, temp and build caches. Approving runs it sandboxed.")
        }
        return ApprovalRequest(
            title: "Run command", command: command, workingDirectory: host.projectRoot.path,
            reason: try? arguments.optionalString("reason"), warnings: CommandWarnings.warnings(for: command),
            notes: notes, editableArgument: "command")
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let command = try arguments.string("command")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("The command is empty.")
        }
        let timeout = try timeout(arguments)
        let environment = await host.commandEnvironment()
        let progress = context.progress
        let commandID = UUID()
        let host = host
        sandbox?.grant()
        host.showCommand(id: commandID, title: command, line: "$ \(command)\n")
        let result: AgentCommandResult
        do {
            result = try await AgentCommandRunner.run(
                AgentCommandSpec(
                    command: command, workingDirectory: host.projectRoot, environment: environment,
                    timeout: timeout, sandboxProfile: sandbox?.profile),
                onOutput: { chunk in
                    progress?(chunk)
                    host.showCommand(id: commandID, title: command, line: chunk)
                })
        } catch {
            host.showCommand(id: commandID, title: command, line: error.localizedDescription + "\n")
            host.showCommand(id: commandID, title: command, line: nil)
            throw ToolError(error.localizedDescription)
        }
        let formatted = await Self.format(command: command, result: result, timeout: timeout, context: context)
        let verdict = formatted.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let separator = result.output.hasSuffix("\n") || result.output.isEmpty ? "" : "\n"
        host.showCommand(id: commandID, title: command, line: separator + verdict + "\n")
        host.showCommand(id: commandID, title: command, line: nil)
        return formatted
    }

    func timeout(_ arguments: ToolArguments) throws -> TimeInterval {
        guard let seconds = try arguments.optionalInt("timeout_seconds") else { return Self.defaultTimeout }
        return min(Self.maxTimeout, max(5, TimeInterval(seconds)))
    }

    static func format(command: String, result: AgentCommandResult, timeout: TimeInterval) -> String {
        compose(
            command: command, output: OutputTruncation.headAndTail(result.output, maxCharacters: maxOutputCharacters),
            result: result, timeout: timeout)
    }

    static func format(
        command: String, result: AgentCommandResult, timeout: TimeInterval, context: ToolContext
    ) async -> String {
        let output = await OutputTruncation.headAndTailSaving(result.output, maxCharacters: maxOutputCharacters, context: context)
        return compose(command: command, output: output, result: result, timeout: timeout)
    }

    private static func compose(command: String, output shown: String, result: AgentCommandResult, timeout: TimeInterval) -> String {
        var output = shown
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

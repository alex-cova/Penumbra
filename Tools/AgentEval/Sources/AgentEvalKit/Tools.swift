import AgentKit
import Foundation

/// Which tools the model is given. `core` is the shortest list that can still do the job; comparing
/// it with `full` on a small model is how to find out whether a shorter list helps.
public enum Toolset: String, Sendable, CaseIterable {
    case full
    case core

    static let coreNames: Set<String> = ["read_file", "list_dir", "grep", "edit_file", "write_file", "run_tests"]

    /// The model's tools for a task in `sandbox`. `run_tests` is the task's own check and nothing
    /// more general: the agent gets no shell.
    public func tools(runTests: RunTestsTool?) -> [any AgentTool] {
        var tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
        if self == .full { tools.append(TodoTool()) }
        if let runTests { tools.append(runTests) }
        return self == .core ? tools.filter { Self.coreNames.contains($0.name) } : tools
    }
}

/// `run_tests`: runs the task's check command in the sandbox and returns its verdict. The same
/// command decides the trial afterwards, so the model sees exactly what it will be judged on.
public final class RunTestsTool: AgentTool, @unchecked Sendable {
    public static let timeout: TimeInterval = 60
    private let command: String
    private let directory: URL
    private let runs = Atomic(0)

    public init(command: String, directory: URL) {
        self.command = command
        self.directory = directory
    }

    public var callCount: Int { runs.value }

    // A command: it runs code, so it runs alone and never alongside a read.
    public var risk: ToolRisk { .command }
    public var verifies: Bool { true }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "run_tests",
            description: "Run the project's tests and checks and return the result. Run it to see what fails, and again after a change to confirm.")
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        runs.increment()
        let result = await CheckRunner.run(command, in: directory, timeout: Self.timeout)
        var text = OutputTruncation.headAndTail(result.output, maxCharacters: 6_000)
        if text.isEmpty { text = "(no output)" }
        let verdict = result.timedOut ? "timed out after \(Int(Self.timeout)) seconds" : (result.exitCode == 0 ? "passed" : "failed (exit code \(result.exitCode))")
        return "Tests \(verdict).\n\(text)"
    }
}

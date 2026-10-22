import Foundation

/// Hands read-only research to a child session with its own context window (`explore`, `.read`).
/// The child runs in the foreground only: this call waits for it. Its summary, capped and wrapped
/// as untrusted, is the tool's output, and its tokens count against the parent run's budget.
public struct ExploreTool: AgentTool {
    /// Hard iteration cap for the child run.
    public var maxIterations: Int
    /// The summary is cut to this many characters.
    public var summaryMaxCharacters: Int
    /// When set, the child asks this client instead of sharing the parent's. Tests use one scripted
    /// client per side; production shares the parent's client, model and permission rules.
    public var childClient: (any LLMClient)?

    public init(maxIterations: Int = 15, summaryMaxCharacters: Int = 6 * 1024, childClient: (any LLMClient)? = nil) {
        self.maxIterations = maxIterations
        self.summaryMaxCharacters = summaryMaxCharacters
        self.childClient = childClient
    }

    public var risk: ToolRisk { .read }
    /// Bounded by the child's iteration cap and by Stop; the per-tool timeout would only cut off research that is going well.
    public var runsWithoutTimeout: Bool { true }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "explore",
            description: """
            Delegate read-only research to a child session with its own context, such as finding where \
            something is defined or how it works. It can read and search but not change files or run \
            commands. You get back a short summary.
            """,
            parameters: [
                ToolParameter("task", .string, "What to research, with enough context to stand alone."),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let task = try arguments.string("task").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw ToolError("Give the research task as \"task\".") }
        if Task.isCancelled { throw CancellationError() }
        guard let spawn = context.spawnSubagent else {
            throw ToolError("This host does not support subagents.")
        }
        let result = await spawn(SubagentRequest(
            id: context.callID, task: task, maxIterations: maxIterations, client: childClient))
        if Task.isCancelled { throw CancellationError() }
        switch result.ending {
        case .completed:
            break
        case .stopped:
            throw CancellationError()
        case .failed(let message):
            throw ToolError("Explore failed: \(message)")
        default:
            break
        }
        let summary = String(result.summary.prefix(summaryMaxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return UntrustedContent.wrap("Explore finished without findings.", source: "explore")
        }
        return UntrustedContent.wrap(summary, source: "explore")
    }

}

/// What `explore` resolves to one level down: calling it from a child answers with the depth limit
/// instead of starting another session.
struct DepthLimitedExploreTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "explore",
            description: "Delegate read-only research to a child session. Nested explore is not available.",
            parameters: [
                ToolParameter("task", .string, "What to research."),
            ])
    }

    var risk: ToolRisk { .read }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        throw ToolError("Explore cannot start another explore session (depth limit of 1). Summarize with what you have.")
    }
}

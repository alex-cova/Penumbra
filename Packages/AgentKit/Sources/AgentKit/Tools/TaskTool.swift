import Foundation

/// What `task` asks the session to run.
public struct DelegationRequest: Sendable {
    /// The parent's tool-call id, so progress events tie back to the call.
    public var callID: String
    public var agent: AgentDefinition
    /// A few words for the transcript.
    public var description: String
    public var prompt: String
    public var background: Bool
    /// The id of an earlier child to continue, which keeps its conversation.
    public var continuing: String?
    /// When set, the child asks this client instead of sharing the parent's (tests).
    public var client: (any LLMClient)?

    public init(
        callID: String, agent: AgentDefinition, description: String, prompt: String, background: Bool = false,
        continuing: String? = nil, client: (any LLMClient)? = nil
    ) {
        self.callID = callID
        self.agent = agent
        self.description = description
        self.prompt = prompt
        self.background = background
        self.continuing = continuing
        self.client = client
    }
}

public enum DelegationResult: Sendable {
    /// The child ran to the end. `summary` is its last message.
    case finished(sessionID: String, summary: String, ending: RunEnding)
    /// The child runs in the background; its report arrives later as a note.
    case started(sessionID: String)
    /// Not run, for a reason the model can act on.
    case refused(String)
}

/// Hands a self-contained piece of work to a child session with its own context window
/// (`task`). The child can be read-only or change files, depending on the agent; it never asks the
/// user anything and never runs commands. Edits are filed under the parent's run, so Revert Run
/// covers them. A `.edit` tool: plan mode does not offer it, and it runs alone, so at most one
/// foreground child exists at a time.
public struct TaskTool: AgentTool {
    public var catalog: AgentCatalog
    /// When set, the child asks this client instead of sharing the parent's (tests).
    public var childClient: (any LLMClient)?

    public init(catalog: AgentCatalog = .builtIn, childClient: (any LLMClient)? = nil) {
        self.catalog = catalog
        self.childClient = childClient
    }

    public var risk: ToolRisk { .edit }
    public var runsWithoutTimeout: Bool { true }
    public var reportsOwnEdits: Bool { true }

    public var definition: ToolDefinition {
        let agents = catalog.agents.map { "- \($0.name)\($0.editsFiles ? " (can change files)" : " (read-only)"): \($0.description)" }
        return ToolDefinition(
            name: "task",
            description: ([
                "Hand a self-contained task to a subagent with its own context. It knows nothing of this conversation: put everything it needs in the prompt and say what to report. It cannot ask the user or run commands.",
                "Its report is the output, with a session id to pass as `session` to continue it. background=true returns at once and you are told when it finishes: do not poll, sleep or repeat its work, and avoid its files.",
                "Use `explore` for quick read-only research.",
                "",
                "Available agents:",
            ] + agents).joined(separator: "\n"),
            parameters: [
                ToolParameter("agent", .string, "Which agent to use, from the list."),
                ToolParameter("description", .string, "Three to five words naming the task, shown to the user."),
                ToolParameter("prompt", .string, "The full task for the subagent."),
                ToolParameter("background", .boolean, "Run it in the background and return immediately.", optional: true),
                ToolParameter("session", .string, "Continue the subagent with this session id instead of starting a new one.", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let name = try arguments.string("agent").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = try arguments.string("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (try arguments.optionalString("description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ToolError("Give the task as \"prompt\".") }
        guard let agent = catalog.agent(named: name) else {
            throw ToolError("Unknown agent \"\(name)\". Available: \(catalog.agents.map(\.name).joined(separator: ", ")).")
        }
        guard let delegate = context.delegate else { throw ToolError("This host does not support subagents.") }
        if Task.isCancelled { throw CancellationError() }
        let continuing = try arguments.optionalString("session")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await delegate(DelegationRequest(
            callID: context.callID, agent: agent, description: description.isEmpty ? agent.name : String(description.prefix(80)),
            prompt: prompt, background: try arguments.optionalBool("background") ?? false,
            continuing: continuing?.isEmpty == true ? nil : continuing, client: childClient))
        if Task.isCancelled { throw CancellationError() }
        switch result {
        case .refused(let reason):
            throw ToolError(reason)
        case .started(let sessionID):
            return [
                "The subagent is working in the background (session \(sessionID)). You will be notified when it finishes.",
                "Do not sleep, poll for progress, ask it for status, or repeat its work, and avoid the files and topics it is using.",
                "Work on something that does not overlap, or tell the user what you started and end your turn.",
            ].joined(separator: "\n")
        case .finished(let sessionID, let summary, let ending):
            switch ending {
            case .stopped:
                throw CancellationError()
            case .failed(let message):
                throw ToolError("The subagent failed (session \(sessionID)): \(message)")
            default:
                break
            }
            let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let report = text.isEmpty ? "The subagent finished without a report." : text
            let note = ending == .completed ? "" : " It stopped early (\(ending))."
            return "Subagent \(agent.name), session \(sessionID).\(note)\n" + UntrustedContent.wrap(String(report.prefix(8 * 1024)), source: "subagent")
        }
    }
}

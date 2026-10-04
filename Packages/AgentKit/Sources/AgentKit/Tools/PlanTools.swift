import Foundation

/// What the user decided about a plan the model proposed.
public enum PlanDecision: Sendable, Equatable {
    /// Go ahead, in this mode (Accept Edits or Manual).
    case approve(PermissionMode)
    /// Not yet: what to change, in the user's words. May be empty.
    case revise(String)
}

/// `exit_plan_mode`: how a plan ends. In plan mode the model can only look; when it has a plan it
/// submits it here and the run pauses until the user approves it (which switches the session to a mode
/// that can act) or asks for changes. The tool is offered only in plan mode.
public struct ExitPlanModeTool: AgentTool {
    public init() {}
    public var risk: ToolRisk { .read }
    public var waitsForUser: Bool { true }
    public var isExemptFromRepeatGuard: Bool { true }

    public func isOffered(in mode: PermissionMode) -> Bool { mode == .plan }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "exit_plan_mode",
            description: """
            Submit your plan for the user to approve. Use it in plan mode, once you have looked at what you need to. \
            Write the plan in Markdown: what you will change and where (file paths), in order, how you will verify it, \
            and anything you are unsure about. The user approves it, which lets you change files, or asks for changes, \
            in which case revise the plan and submit it again. Do not start changing anything before it is approved.
            """,
            parameters: [ToolParameter("plan", .string, "The plan, in Markdown.")])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let plan = try arguments.string("plan").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else { throw ToolError("The plan is empty. Write what you will change and how you will check it.") }
        guard let propose = context.proposePlan else {
            throw ToolError("A plan cannot be approved here. Describe it in your reply instead.")
        }
        switch await propose(plan) {
        case .approve(let mode):
            return "The user approved the plan. The mode is now \(mode.displayName): you can change files and run commands (anything that needs the user's approval will ask). Carry out the plan, and keep the checklist current."
        case .revise(let feedback):
            let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return "The user did not approve the plan. Ask what they want changed, or revise it and submit it again."
            }
            return "The user wants changes to the plan: \(text)\nRevise the plan and submit it again with exit_plan_mode."
        }
    }
}

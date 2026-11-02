import Foundation

/// One tool call as a hook sees it: the tool's name, what it may touch, and the arguments
/// exactly as the model wrote them. AgentKit never spawns anything for a hook; the host does.
public struct HookCall: Sendable {
    public var toolName: String
    public var risk: ToolRisk
    /// The call's arguments as JSON, exactly as the model wrote them.
    public var argumentsJSON: String

    public init(toolName: String, risk: ToolRisk, argumentsJSON: String) {
        self.toolName = toolName
        self.risk = risk
        self.argumentsJSON = argumentsJSON
    }

    /// The parsed arguments, or `nil` when they are not a JSON object.
    public var arguments: ToolArguments? { try? ToolArguments(json: argumentsJSON) }
}

/// What a before-hook says about a call. `.deny` is final and beats an allow rule; `.ask`
/// forces an approval card even when a rule allows.
public enum HookDecision: Sendable, Equatable {
    case allow
    case deny(String)
    case ask
}

/// User-configured hooks around the agent's tool calls. The host implements this (a shell
/// command, a script); AgentKit only calls it. A method that throws fails open: the call runs
/// as if the hook had allowed it, and an after-hook adds nothing.
///
/// Text returned from `after` reaches the model, so the host must treat it as untrusted
/// content (`UntrustedContent`) before returning it.
public protocol ToolHooks: Sendable {
    func before(_ call: HookCall) async throws -> HookDecision
    func after(_ call: HookCall, output: String) async throws -> String?
}

extension ToolHooks {
    public func before(_ call: HookCall) async throws -> HookDecision { .allow }
    public func after(_ call: HookCall, output: String) async throws -> String? { nil }
}

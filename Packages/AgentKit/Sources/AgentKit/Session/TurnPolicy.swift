import Foundation

/// A decision about the next model turn. Policies are asked only at turn boundaries, so nothing they
/// add can land between a tool call and its output. A policy never touches the conversation; the
/// session applies the decision.
public enum TurnDecision: Sendable, Equatable {
    case proceed
    /// Appended as an editor note. The loop continues.
    case note(String)
    case compact(force: Bool)
    /// One more model turn with no tools, then the run ends with `ending`.
    case finalTurn(note: String, ending: RunEnding)
    case end(RunEnding)
}

/// What a policy may look at. A value, so a policy cannot change the session.
public struct TurnState: Sendable, Equatable {
    public var iteration: Int
    public var maxIterations: Int
    public var usage: TokenUsage
    public var elapsed: TimeInterval
    public var contextWindow: Int?
    public var estimatedTokens: Int
    public var filesEdited: [String]
    public var verifiedSinceEdit: Bool
    public var mode: PermissionMode

    public init(
        iteration: Int, maxIterations: Int, usage: TokenUsage, elapsed: TimeInterval,
        contextWindow: Int?, estimatedTokens: Int, filesEdited: [String], verifiedSinceEdit: Bool,
        mode: PermissionMode
    ) {
        self.iteration = iteration
        self.maxIterations = maxIterations
        self.usage = usage
        self.elapsed = elapsed
        self.contextWindow = contextWindow
        self.estimatedTokens = estimatedTokens
        self.filesEdited = filesEdited
        self.verifiedSinceEdit = verifiedSinceEdit
        self.mode = mode
    }
}

public protocol TurnPolicy: Sendable {
    func beforeTurn(_ state: TurnState) async -> TurnDecision
    /// The model answered without tool calls; the run would end.
    func beforeEnding(_ state: TurnState) async -> TurnDecision
}

extension TurnPolicy {
    public func beforeEnding(_ state: TurnState) async -> TurnDecision { .proceed }
}

/// Stops a run that has spent its token, time or cost budget, or used its iteration cap, and (when
/// asked) gives the model one last turn with no tools to say what was done and what remains.
public struct RunLimitPolicy: TurnPolicy {
    public var maxIterations: Int
    public var maxTokens: Int?
    public var maxSeconds: TimeInterval?
    public var isOverCost: (@Sendable (TokenUsage) -> Bool)?
    public var graceTurn: Bool

    public init(
        maxIterations: Int, maxTokens: Int? = nil, maxSeconds: TimeInterval? = nil,
        isOverCost: (@Sendable (TokenUsage) -> Bool)? = nil, graceTurn: Bool = true
    ) {
        self.maxIterations = maxIterations
        self.maxTokens = maxTokens
        self.maxSeconds = maxSeconds
        self.isOverCost = isOverCost
        self.graceTurn = graceTurn
    }

    public func beforeTurn(_ state: TurnState) async -> TurnDecision {
        let tokens = state.usage.inputTokens + state.usage.outputTokens
        let overTokens = maxTokens.map { tokens >= $0 } ?? false
        let overTime = maxSeconds.map { state.elapsed >= $0 } ?? false
        let overCost = isOverCost?(state.usage) ?? false
        if overTokens || overTime || overCost {
            let why = overTokens ? "token" : (overTime ? "time" : "cost")
            return final("The run's \(why) budget is spent. Do not call tools. Say what was done and what remains.", ending: .budget)
        }
        if state.iteration >= maxIterations {
            return final(
                "The step limit is reached. Do not call tools. Say what was done and what remains.",
                ending: .iterationCap)
        }
        return .proceed
    }

    private func final(_ note: String, ending: RunEnding) -> TurnDecision {
        graceTurn ? .finalTurn(note: note, ending: ending) : .end(ending)
    }
}

/// If the run changed files and nothing that checks them has run since the last edit, ask once
/// before the run ends. Never in plan mode: nothing there can be checked by changing or running.
public final class VerifyBeforeStoppingPolicy: TurnPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    public init() {}

    public func beforeTurn(_ state: TurnState) async -> TurnDecision { .proceed }

    public func beforeEnding(_ state: TurnState) async -> TurnDecision {
        let already = lock.withLock { () -> Bool in
            if asked { return true }
            return false
        }
        guard !already, state.mode != .plan, !state.filesEdited.isEmpty, !state.verifiedSinceEdit else { return .proceed }
        lock.withLock { asked = true }
        return .note(
            "You changed files and have not checked them since the last edit. Call diagnostics, run_tests or gradle if one of them is available, or say why you cannot.")
    }
}

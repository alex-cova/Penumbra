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
    /// Calls to a file-changing tool this run that ran, and how many of them returned an error.
    public var editCalls: Int
    public var failedEditCalls: Int
    /// What the model said on its latest turn, for checks that read it.
    public var lastAssistantText: String

    public init(
        iteration: Int, maxIterations: Int, usage: TokenUsage, elapsed: TimeInterval,
        contextWindow: Int?, estimatedTokens: Int, filesEdited: [String], verifiedSinceEdit: Bool,
        mode: PermissionMode, editCalls: Int = 0, failedEditCalls: Int = 0, lastAssistantText: String = ""
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
        self.editCalls = editCalls
        self.failedEditCalls = failedEditCalls
        self.lastAssistantText = lastAssistantText
    }
}

public protocol TurnPolicy: Sendable {
    func beforeTurn(_ state: TurnState) async -> TurnDecision
    /// The model answered without tool calls; the run would end.
    func beforeEnding(_ state: TurnState) async -> TurnDecision
    /// A new run starts: per-run state (asked-once flags, continuation counts) goes back to zero.
    func reset()
}

extension TurnPolicy {
    public func beforeEnding(_ state: TurnState) async -> TurnDecision { .proceed }
    public func reset() {}
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

    /// A new run asks again.
    public func reset() { lock.withLock { asked = false } }

    public func beforeTurn(_ state: TurnState) async -> TurnDecision { .proceed }

    public func beforeEnding(_ state: TurnState) async -> TurnDecision {
        let already = lock.withLock { asked }
        guard !already, state.mode != .plan, !state.filesEdited.isEmpty, !state.verifiedSinceEdit else { return .proceed }
        lock.withLock { asked = true }
        return .note(
            "You changed files and have not checked them since the last edit. Call diagnostics, run_tests or gradle if one of them is available, or say why you cannot.")
    }
}

/// If the run tried to change files and every attempt failed, say so before the run ends, once: the
/// answer that follows would otherwise claim a change that was never made. A run with at least one
/// applied edit is left alone, and so is plan mode, where nothing is meant to change.
public final class UnappliedEditsPolicy: TurnPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    public init() {}

    /// A new run may be told again.
    public func reset() { lock.withLock { asked = false } }

    public func beforeTurn(_ state: TurnState) async -> TurnDecision { .proceed }

    public func beforeEnding(_ state: TurnState) async -> TurnDecision {
        guard state.mode != .plan, state.editCalls > 0, state.failedEditCalls == state.editCalls,
              state.filesEdited.isEmpty else { return .proceed }
        let already = lock.withLock { () -> Bool in
            defer { asked = true }
            return asked
        }
        guard !already else { return .proceed }
        return .note(
            "Every edit you attempted in this run failed, so no file was changed. Do not tell the user the change was made. "
                + "Fix the error and try again, or say plainly that it did not apply and why.")
    }
}

/// What the host's Stop-gate check sees: which files the run changed, whether anything has checked
/// them since, how many times the gate already continued this run (Codex's `stop_hook_active`), and
/// what the model said last.
public struct StopGateInput: Sendable, Equatable {
    public var filesEdited: [String]
    public var verifiedSinceEdit: Bool
    public var continuations: Int
    public var lastAssistantText: String

    public init(filesEdited: [String], verifiedSinceEdit: Bool, continuations: Int, lastAssistantText: String) {
        self.filesEdited = filesEdited
        self.verifiedSinceEdit = verifiedSinceEdit
        self.continuations = continuations
        self.lastAssistantText = lastAssistantText
    }
}

/// What the host's Stop-gate check says. `.skip` is for "not applicable this time": the run carries
/// on, and no continuation is consumed.
public enum StopGateVerdict: Sendable, Equatable {
    case pass
    case skip
    case block(reason: String)
}

/// A blocking Stop gate: the host's check runs before a run may end `.completed`, and a `.block`
/// continues the run with the reason as an editor note. After `maxContinuations` blocks the run ends
/// anyway, with a final no-tools turn that must say the check did not pass. A check that throws, is
/// cancelled (Stop) or exceeds `timeout` fails open: the run carries on, and the session records why
/// in a `.stopGateChecked` event. Asked only from `beforeEnding`, so stopped, budget, iteration-cap
/// and failed runs skip it; never in plan mode, and never when no file was edited unless
/// `checkWithoutEdits` is set. `VerifyBeforeStoppingPolicy` stays as the soft nudge; a host uses one
/// or the other.
public final class StopGatePolicy: TurnPolicy, @unchecked Sendable {
    public static let defaultMaxContinuations = 3
    public static let defaultTimeout: TimeInterval = 600
    public static let maxReasonCharacters = 4_000

    public var maxContinuations: Int
    public var timeout: TimeInterval
    public var checkWithoutEdits: Bool
    public var check: @Sendable (StopGateInput) async throws -> StopGateVerdict

    private let lock = NSLock()
    private var continuations = 0
    private var lastReason = ""
    private var pending: [AgentEvent] = []

    public init(
        maxContinuations: Int = defaultMaxContinuations,
        timeout: TimeInterval = defaultTimeout,
        checkWithoutEdits: Bool = false,
        check: @escaping @Sendable (StopGateInput) async throws -> StopGateVerdict
    ) {
        self.maxContinuations = maxContinuations
        self.timeout = timeout
        self.checkWithoutEdits = checkWithoutEdits
        self.check = check
    }

    /// A new run blocks again from zero.
    public func reset() {
        lock.withLock {
            continuations = 0
            lastReason = ""
            pending = []
        }
    }

    /// Events since the last drain, for the session to yield after asking.
    func takePendingEvents() -> [AgentEvent] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }

    public func beforeTurn(_ state: TurnState) async -> TurnDecision { .proceed }

    public func beforeEnding(_ state: TurnState) async -> TurnDecision {
        guard state.mode != .plan, checkWithoutEdits || !state.filesEdited.isEmpty else { return .proceed }
        let (count, reason): (Int, String) = lock.withLock { (continuations, lastReason) }
        if count >= maxContinuations {
            emit(passed: false, summary: "The check still fails after \(count) continuations; ending anyway.")
            return .finalTurn(
                note: "The check still fails\(reason.isEmpty ? "" : ": \(reason)") Say so plainly.",
                ending: .completed)
        }
        let input = StopGateInput(
            filesEdited: state.filesEdited, verifiedSinceEdit: state.verifiedSinceEdit,
            continuations: count, lastAssistantText: state.lastAssistantText)
        let (verdict, failOpen): (StopGateVerdict, String?) = await runCheck(input)
        switch verdict {
        case .pass:
            emit(passed: true, summary: failOpen ?? "The check passed.")
            return .proceed
        case .skip:
            emit(passed: true, summary: "The check skipped this run.")
            return .proceed
        case .block(let raw):
            let capped = OutputTruncation.headAndTail(raw, maxCharacters: Self.maxReasonCharacters)
            lock.withLock {
                continuations += 1
                lastReason = capped
            }
            emit(passed: false, summary: capped)
            return .note(capped)
        }
    }

    private func emit(passed: Bool, summary: String) {
        lock.withLock { pending.append(.stopGateChecked(passed: passed, summary: summary)) }
    }

    /// Runs the host check bounded by `timeout`. Anything but a verdict — a throw, Stop, or the
    /// timeout — fails open with the reason, so a broken check never wedges the run.
    private func runCheck(_ input: StopGateInput) async -> (StopGateVerdict, String?) {
        if Task.isCancelled { return (.pass, "The check was cancelled (Stop); failing open.") }
        let check = self.check
        let timeout = self.timeout
        do {
            let verdict = try await withThrowingTaskGroup(of: StopGateVerdict.self) { group in
                group.addTask { try await check(input) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw StopGateCheckError.timedOut(timeout)
                }
                guard let first = try await group.next() else { throw StopGateCheckError.noResult }
                group.cancelAll()
                return first
            }
            if Task.isCancelled, case .block = verdict {
                // Stop landed as the check blocked: the run is ending anyway, so don't continue it.
                return (.pass, "The check was cancelled (Stop); failing open.")
            }
            return (verdict, nil)
        } catch is CancellationError {
            return (.pass, "The check was cancelled (Stop); failing open.")
        } catch let error as StopGateCheckError {
            return (.pass, "\(error.localizedDescription); failing open.")
        } catch {
            return (.pass, "The check threw (\(error.localizedDescription)); failing open.")
        }
    }
}

enum StopGateCheckError: Error, LocalizedError {
    case timedOut(TimeInterval)
    case noResult

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            let seconds = timeout < 1 ? String(format: "%.2f", timeout) : String(Int(timeout))
            return "The check timed out after \(seconds) seconds"
        case .noResult:
            return "The check produced no result"
        }
    }
}

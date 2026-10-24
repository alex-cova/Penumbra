import AgentKit
import Foundation
import FoundationModels

/// Owns one framework session across AgentKit's turns.
///
/// The framework *runs* a tool in the middle of a response and waits for it; AgentKit's loop wants a
/// turn to end with the call, so it can check permissions, ask the user and run the tool itself. The
/// host bridges the two: when the model calls a tool, the call is reported as the end of the turn
/// (`finished(.toolCalls)`) and the framework's call stays suspended. The next request carries the
/// outputs; the host resumes the suspended calls with them and the same response goes on, streaming
/// into the new turn. A request that is not exactly that (compaction, a changed tool list, a note the
/// loop inserted, a stop) starts a new session from the history.
actor AppleSessionHost {
    typealias Sink = AsyncThrowingStream<LLMEvent, Error>.Continuation
    typealias SourceFactory = @Sendable (AppleSourceConfig) -> any AppleResponseSource

    struct Key: Equatable {
        var system: String
        var tools: [ToolDefinition]
    }

    private struct PendingCall {
        var id: String
        var name: String
        var continuation: CheckedContinuation<String, Error>
    }

    private struct Turn {
        var id: UUID
        var sink: Sink
        /// The request's items: with what the model produced, they are what the session has seen.
        var base: [ConversationItem]
        var text = ""
        var calls: [(id: String, name: String, arguments: String)] = []
        var estimatedInput: Int
        var reportedUsage = TokenUsage()
    }

    private let kind: AppleModelKind
    private let makeSource: SourceFactory
    private let settle: Duration

    private var key: Key?
    private var source: (any AppleResponseSource)?
    private var consumed: [ConversationItem] = []
    /// The last response finished, so the session can take another prompt.
    private var isIdle = false
    private var pump: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var pending: [PendingCall] = []
    private var turn: Turn?
    /// Bumped whenever the session is replaced, so a late callback from the old one is ignored.
    private var generation = 0
    /// What the response has said so far, to turn cumulative snapshots into deltas.
    private var emitted = ""
    private var latestUsage: TokenUsage?

    private(set) var lastReuse: Reuse = .none

    enum Reuse: Equatable, Sendable {
        case none
        case rebuilt
        case resumedTools
        case continued
    }

    init(kind: AppleModelKind, settle: Duration = .milliseconds(30), makeSource: @escaping SourceFactory) {
        self.kind = kind
        self.settle = settle
        self.makeSource = makeSource
    }

    // MARK: - Turns

    func begin(_ request: LLMRequest, id: UUID, sink: Sink) {
        if let old = turn {
            old.sink.finish(throwing: CancellationError())
            teardown()
        }
        let newKey = Key(system: request.system, tools: request.tools)
        let estimate = ContextBudget.tokens(system: request.system, tools: request.tools) + ContextBudget.tokens(request.items)
        let disallow = request.toolChoice == .disabled

        if key == newKey, request.items.count > consumed.count, Array(request.items.prefix(consumed.count)) == consumed {
            let suffix = Array(request.items[consumed.count...])
            if !pending.isEmpty, let outputs = Self.outputs(suffix, answering: pending) {
                attach(Turn(id: id, sink: sink, base: request.items, estimatedInput: estimate))
                lastReuse = .resumedTools
                let waiting = pending
                pending = []
                for call in waiting { call.continuation.resume(returning: outputs[call.id] ?? "") }
                return
            }
            if pending.isEmpty, isIdle, suffix.count == 1, case .user(let text) = suffix[0] {
                attach(Turn(id: id, sink: sink, base: request.items, estimatedInput: estimate))
                lastReuse = .continued
                startPump(prompt: text, disallowTools: disallow)
                return
            }
        }

        teardown()
        guard let plan = AppleTranscript.plan(system: request.system, tools: request.tools, items: request.items) else {
            sink.finish(throwing: LLMError.badRequest(status: 0, message: "The conversation must end with a user message or tool results."))
            return
        }
        key = newKey
        source = makeSource(AppleSourceConfig(
            kind: kind, entries: plan.entries, tools: request.tools,
            invoker: { [weak self] name, arguments in
                guard let self else { throw CancellationError() }
                return try await self.toolCalled(name: name, arguments: arguments)
            }))
        attach(Turn(id: id, sink: sink, base: request.items, estimatedInput: estimate))
        lastReuse = .rebuilt
        startPump(prompt: plan.prompt, disallowTools: disallow)
    }

    /// The consumer went away (Stop, or the task was cancelled): the session cannot be trusted any more.
    func cancel(_ id: UUID) {
        guard turn?.id == id else { return }
        turn = nil
        teardown()
    }

    func reset() {
        turn?.sink.finish(throwing: CancellationError())
        turn = nil
        teardown()
    }

    // MARK: - Tool calls

    /// Called by the framework in the middle of a response. Reports the call, then waits for AgentKit's answer.
    func toolCalled(name: String, arguments: String) async throws -> String {
        let id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        if var current = turn {
            current.calls.append((id, name, arguments))
            turn = current
            emit(.toolCallStarted(id: id, name: name))
            emit(.toolCallFinished(id: id, name: name, arguments: arguments))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingCall(id: id, name: name, continuation: continuation))
            scheduleSettle()
        }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        let current = generation
        settleTask = Task { [settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self.settled(current)
        }
    }

    /// No further call arrived together with the last one: the turn ends with the calls made so far.
    private func settled(_ forGeneration: Int) {
        guard forGeneration == generation, var current = turn, !pending.isEmpty else { return }
        emitUsage(&current)
        current.sink.yield(.finished(.toolCalls))
        consumed = produced(by: current)
        isIdle = false
        current.sink.finish()
        turn = nil
    }

    // MARK: - The response

    private func attach(_ newTurn: Turn) {
        turn = newTurn
    }

    private func startPump(prompt: String, disallowTools: Bool) {
        guard let source else { return }
        generation += 1
        let current = generation
        isIdle = false
        emitted = ""
        latestUsage = nil
        let stream = source.respond(to: prompt, disallowTools: disallowTools)
        pump = Task {
            do {
                for try await snapshot in stream { self.received(snapshot, current) }
                self.finished(current, error: nil)
            } catch {
                self.finished(current, error: error)
            }
        }
    }

    private func received(_ snapshot: AppleSnapshot, _ forGeneration: Int) {
        guard forGeneration == generation, var current = turn else { return }
        let text = snapshot.text
        let delta: String
        if text.hasPrefix(emitted) {
            delta = String(text.dropFirst(emitted.count))
        } else if emitted.hasPrefix(text) {
            delta = ""
        } else {
            // The text restarted (a new answer after a tool call), not a revision of the old one.
            delta = text
        }
        emitted = text
        if let usage = snapshot.usage { latestUsage = usage }
        guard !delta.isEmpty else { return }
        current.text += delta
        turn = current
        emit(.textDelta(delta))
    }

    private func finished(_ forGeneration: Int, error: Error?) {
        guard forGeneration == generation else { return }
        pump = nil
        guard var current = turn else {
            // Nobody is listening (the turn ended on its tool calls and the response failed, or was stopped).
            if error != nil { teardown() } else { isIdle = true }
            return
        }
        guard let error else {
            emitUsage(&current)
            current.sink.yield(.finished(.completed))
            consumed = produced(by: current)
            isIdle = true
            current.sink.finish()
            turn = nil
            return
        }
        turn = nil
        let hadOutput = !current.text.isEmpty || !current.calls.isEmpty
        teardown()
        if error is CancellationError {
            current.sink.finish(throwing: error)
            return
        }
        switch AppleErrorMapping.classify(error, hadOutput: hadOutput) {
        case .finish(let reason):
            current.sink.yield(.finished(reason))
            current.sink.finish()
        case .fail(let failure):
            current.sink.finish(throwing: failure)
        }
    }

    // MARK: - Helpers

    private func emit(_ event: LLMEvent) {
        guard let current = turn else { return }
        if case .terminated = current.sink.yield(event) {
            turn = nil
            teardown()
        }
    }

    private func emitUsage(_ current: inout Turn) {
        let output = ContextBudget.tokens(current.text) + current.calls.reduce(0) { $0 + ContextBudget.tokens($1.arguments) + 8 }
        var usage: TokenUsage
        if let latestUsage {
            usage = TokenUsage(
                inputTokens: latestUsage.inputTokens, outputTokens: max(0, latestUsage.outputTokens - current.reportedUsage.outputTokens),
                cachedInputTokens: latestUsage.cachedInputTokens, reasoningTokens: latestUsage.reasoningTokens)
            current.reportedUsage = latestUsage
        } else {
            usage = TokenUsage(inputTokens: current.estimatedInput, outputTokens: output)
        }
        current.sink.yield(.usage(usage))
    }

    /// What the session has seen once this turn is over: the request, then the answer text, then the calls.
    private func produced(by turn: Turn) -> [ConversationItem] {
        var items = turn.base
        if !turn.text.isEmpty { items.append(.assistant(turn.text)) }
        items += turn.calls.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
        return items
    }

    /// The outputs for exactly the calls that are waiting, by call id; `nil` if the items are anything else.
    private static func outputs(_ items: [ConversationItem], answering pending: [PendingCall]) -> [String: String]? {
        var result: [String: String] = [:]
        for item in items {
            guard case .toolOutput(let callID, let output) = item else { return nil }
            result[callID] = output
        }
        guard result.count == items.count, Set(result.keys) == Set(pending.map(\.id)) else { return nil }
        return result
    }

    /// Drops the session: stops the response and fails every call it is waiting on.
    private func teardown() {
        generation += 1
        pump?.cancel()
        pump = nil
        settleTask?.cancel()
        settleTask = nil
        let waiting = pending
        pending = []
        for call in waiting { call.continuation.resume(throwing: CancellationError()) }
        source = nil
        key = nil
        consumed = []
        isIdle = false
        emitted = ""
        latestUsage = nil
    }
}

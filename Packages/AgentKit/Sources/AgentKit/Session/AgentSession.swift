import Foundation

/// One conversation: its history, and the loop that turns a user message into model turns and tool
/// calls until a turn ends without tool calls, the user stops it, or a guardrail does.
///
/// Invariants: every tool call in `items` has exactly one output, whatever happened to it (denied,
/// failed, timed out, cancelled), because both APIs reject a history with an unanswered call; and a
/// failed or stopped turn leaves nothing half-written, so the session stays usable.
public actor AgentSession {
    public private(set) var items: [ConversationItem]
    /// Names this conversation in a `SessionStore`; kept when it is restored.
    public let sessionID: UUID
    public private(set) var totalUsage: TokenUsage
    /// Input tokens the provider reported for the latest turn: the best measure of context in use.
    public private(set) var lastInputTokens = 0
    /// How many `items` the request that reported `lastInputTokens` covered.
    private var itemsAtLastReport = 0
    /// After a summary request failed, don't ask again until the conversation has grown by a few items.
    private var summaryBackoffUntilItems = 0
    public private(set) var isRunning = false

    private let client: any LLMClient
    private let tools: [any AgentTool]
    private let toolsByName: [String: any AgentTool]
    private let workspace: any AgentWorkspace
    private let configuration: AgentConfiguration
    private let ledger = ReadLedger()
    /// Per-run checkpoints of every file the agent changed, for the changed-files summary and Revert.
    public let checkpoints = CheckpointLog()
    private var runTask: Task<Void, Never>?
    private var currentRun: RunID?
    private var pendingApprovals: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var pendingQuestions: [String: CheckedContinuation<String?, Never>] = [:]
    /// The model's checklist; rebuilt from the history of a resumed conversation.
    public let todoList: TodoList

    public init(
        client: any LLMClient,
        tools: [any AgentTool],
        workspace: any AgentWorkspace,
        configuration: AgentConfiguration,
        history: [ConversationItem] = [],
        totalUsage: TokenUsage = TokenUsage(),
        sessionID: UUID = UUID()
    ) {
        self.sessionID = sessionID
        self.totalUsage = totalUsage
        self.client = client
        self.tools = tools
        self.toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.workspace = workspace
        self.configuration = configuration
        self.items = history
        self.todoList = TodoList(TodoList.latest(in: history))
    }

    /// Starts a run. The stream ends with exactly one `.runEnded`. Dropping the stream stops the run.
    public func send(_ text: String) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        guard !isRunning else {
            continuation.yield(.runEnded(.failed("A run is already in progress.")))
            continuation.finish()
            return stream
        }
        isRunning = true
        items.append(.user(text))
        let task = Task { await self.run(label: text, continuation) }
        runTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Cancels the stream and running tools. The run still ends normally, with `.stopped`.
    public func stop() {
        runTask?.cancel()
    }

    /// Answers an `.approvalRequested` event. A call with no pending request is ignored, so a late
    /// or repeated answer from the UI is harmless.
    public func resolveApproval(callID: String, decision: ApprovalDecision) {
        pendingApprovals.removeValue(forKey: callID)?.resume(returning: decision)
    }

    public var awaitingApproval: [String] { Array(pendingApprovals.keys) }

    /// Answers an `.questionAsked` event; `nil` means the user dismissed it. A call with no pending
    /// question is ignored.
    public func answerQuestion(callID: String, answer: String?) {
        pendingQuestions.removeValue(forKey: callID)?.resume(returning: answer)
    }

    public var awaitingAnswer: [String] { Array(pendingQuestions.keys) }

    private func waitForAnswer(callID: String) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingQuestions[callID] = continuation
                if Task.isCancelled { answerQuestion(callID: callID, answer: nil) }
            }
        } onCancel: {
            Task { await self.answerQuestion(callID: callID, answer: nil) }
        }
    }

    /// Replaces the checklist, for a host that restores it from its own storage.
    public func setTodos(_ items: [TodoItem]) async {
        await todoList.replace(with: items)
    }

    private func waitForApproval(callID: String) async -> ApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApprovals[callID] = continuation
                // Stop may have landed before the request was registered.
                if Task.isCancelled { resolveApproval(callID: callID, decision: .deny(note: "Cancelled by user.")) }
            }
        } onCancel: {
            Task { await self.resolveApproval(callID: callID, decision: .deny(note: "Cancelled by user.")) }
        }
    }

    public enum RevertError: Error, Equatable, LocalizedError {
        case runInProgress

        public var errorDescription: String? { "Wait for the current run to finish, or stop it, before reverting." }
    }

    /// Puts a finished run's files back: see `CheckpointLog.revert`. Never while a run is going,
    /// since the agent could be changing the same files.
    public func revertRun(_ id: RunID) async throws -> RevertReport {
        guard !isRunning else { throw RevertError.runInProgress }
        return await checkpoints.revert(id, using: workspace, ledger: ledger)
    }

    // MARK: - Run

    private func run(label: String, _ out: AsyncStream<AgentEvent>.Continuation) async {
        let runID = await checkpoints.beginRun(label: label)
        currentRun = runID
        out.yield(.runStarted(runID))
        let ending = await loop(out)
        isRunning = false
        runTask = nil
        currentRun = nil
        out.yield(.stateChanged(.idle))
        out.yield(.runEnded(ending))
        out.finish()
    }

    private func loop(_ out: AsyncStream<AgentEvent>.Continuation) async -> RunEnding {
        var callCounts: [String: Int] = [:]
        var compactedAfterOverflow = false
        var unreadableCalls = 0

        for _ in 0..<configuration.maxIterations {
            if Task.isCancelled { return .stopped }
            await compactIfNeeded(force: false, out)
            if Task.isCancelled { return .stopped }
            out.yield(.stateChanged(.streaming))

            let itemsAtRequest = items.count
            let turn: Turn
            do {
                turn = try await streamTurn(out)
            } catch is CancellationError {
                return .stopped
            } catch LLMError.contextLengthExceeded where !compactedAfterOverflow {
                // The estimate was too low. Shorten hard, once, and try the turn again.
                compactedAfterOverflow = true
                if await compactIfNeeded(force: true, out) { continue }
                return .failed(LLMError.contextLengthExceeded.localizedDescription)
            } catch {
                return .failed(error.localizedDescription)
            }
            if Task.isCancelled { return .stopped }
            guard let finish = turn.finish else { return .failed("The model's response ended unexpectedly.") }

            totalUsage = totalUsage + turn.usage
            if turn.usage.inputTokens > 0 {
                lastInputTokens = turn.usage.inputTokens
                itemsAtLastReport = itemsAtRequest
            }
            out.yield(.usage(turn.usage))

            items += turn.items
            items += turn.calls.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
            if !turn.text.isEmpty { out.yield(.assistantMessage(turn.text)) }

            // A turn cut off or filtered may hold half-written calls: answer them without running.
            if finish == .length || finish == .contentFilter {
                let reason = finish == .length ? "the response hit the length limit" : "the response was blocked by a content filter"
                for call in turn.calls {
                    items.append(.toolOutput(callID: call.id, output: "Not run: \(reason)."))
                }
                return finish == .length ? .lengthLimit : .contentFiltered
            }
            // A call the model wrote but nobody could read: say so and let it try again, a few times.
            // (Ending the run here would throw away the work done so far for a typo in JSON.)
            if !turn.unreadable.isEmpty {
                unreadableCalls += turn.unreadable.count
                if unreadableCalls > Self.maxUnreadableCalls {
                    for call in turn.calls { items.append(.toolOutput(callID: call.id, output: "Not run: the run was stopped.")) }
                    return .failed("The model kept writing tool calls that could not be read (\(turn.unreadable[0].detail)).")
                }
            }
            if turn.calls.isEmpty, turn.unreadable.isEmpty { return .completed }

            if !turn.calls.isEmpty {
                switch await execute(turn.calls, counts: &callCounts, out) {
                case .continue: break
                case .stopped: return .stopped
                case .repeated(let name): return .repeatedCall(name)
                }
            }
            if Task.isCancelled { return .stopped }
            if !turn.unreadable.isEmpty {
                items.append(.user(Self.unreadableCallNote(turn.unreadable)))
            }
        }
        return .iterationCap
    }

    static let maxUnreadableCalls = 3

    /// What the model is told when a call it wrote could not be read.
    static func unreadableCallNote(_ calls: [(detail: String, raw: String)]) -> String {
        let first = calls[0]
        let started = first.raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        return """
        [Note from the editor, not from the user] A tool call you wrote could not be read, so it was not run (\(first.detail)). \
        \(started.isEmpty ? "" : "It began: \(started)\n")Make the call again as one valid call. The arguments must be a JSON object; \
        inside a string write a newline as \\n and a double quote as \\\", and keep long text short by editing in small steps.
        """
    }

    // MARK: - Context

    /// Tokens the next request will carry, as best it can be known: what the provider reported for the
    /// last one plus an estimate of what was added since, but never less than an estimate of the
    /// whole thing. (Ollama counts only the tokens it evaluated, not those it served from its own
    /// cache, so the reported figure alone would run low.)
    /// The tools the model is told about. In plan mode that is only the ones that look.
    private var offeredTools: [any AgentTool] { tools.filter { configuration.mode.offers($0.risk) } }

    func estimatedContextTokens() -> Int {
        let fixed = ContextBudget.tokens(system: configuration.systemPrompt, tools: offeredTools.map(\.definition))
        let whole = fixed + ContextBudget.tokens(items)
        guard lastInputTokens > 0, itemsAtLastReport <= items.count else { return whole }
        return max(whole, lastInputTokens + ContextBudget.tokens(items[itemsAtLastReport...]))
    }

    /// Shortens the conversation when it passes the threshold (or at once if `force`). Returns
    /// whether it changed anything. Stage one replaces old tool outputs with stubs; if that is not
    /// enough, stage two summarizes the oldest part with one model request.
    @discardableResult
    private func compactIfNeeded(force: Bool, _ out: AsyncStream<AgentEvent>.Continuation) async -> Bool {
        guard let window = configuration.contextWindow, window > 0 else { return false }
        let before = estimatedContextTokens()
        let limit = Int(Double(window) * configuration.compactionThreshold)
        guard force || before > limit else { return false }

        var policy = CompactionPolicy(contextWindow: window, threshold: configuration.compactionThreshold)
        if force {
            policy.target = 0.35
            policy.keepRecentToolOutputs = 2
        }
        var report = CompactionReport()
        report.estimatedTokensBefore = before

        // After a provider overflow the estimate is known to be too low, so treat the window as full.
        let stubs = ToolOutputStubs.apply(to: items, policy: policy, estimatedTokens: force ? max(before, window) : before)
        if stubs.stubbed > 0 {
            items = stubs.items
            report.stubbedOutputs = stubs.stubbed
        }

        let afterStubs = ContextBudget.tokens(system: configuration.systemPrompt, tools: offeredTools.map(\.definition)) + ContextBudget.tokens(items)
        if afterStubs > (force ? Int(Double(window) * policy.target) : limit),
           items.count >= summaryBackoffUntilItems,
           let cut = ConversationSummary.cutIndex(in: items, keepTurns: policy.keepRecentTurns) {
            if let summary = await summarize(Array(items[..<cut]), window: window) {
                report.summarizedItems = cut
                items = ConversationSummary.replacing(items, upTo: cut, with: summary)
            } else {
                report.summaryFailed = !Task.isCancelled
                summaryBackoffUntilItems = items.count + 6
            }
        }

        guard report.changedAnything || report.summaryFailed else { return false }
        // Nothing the provider reported applies to the shortened conversation any more.
        lastInputTokens = 0
        itemsAtLastReport = 0
        report.estimatedTokensAfter = estimatedContextTokens()
        out.yield(.compacted(report))
        return report.changedAnything
    }

    /// One request to the same model, asking it to condense the older part of the conversation.
    private func summarize(_ older: [ConversationItem], window: Int) async -> String? {
        let budgetCharacters = max(2_000, Int(Double(window) * 0.5) * 3)
        let transcript = ConversationSummary.transcript(of: older, maximumCharacters: budgetCharacters)
        let request = LLMRequest(
            model: configuration.model, system: ConversationSummary.systemPrompt,
            items: [.user(transcript + "\n\nWrite the summary now.")], tools: [],
            reasoningEffort: nil, maxOutputTokens: 1_500, cacheKey: nil)
        var text = ""
        do {
            for try await event in client.stream(request) {
                switch event {
                case .textDelta(let delta): text += delta
                case .retrying: text = ""
                default: break
                }
            }
        } catch {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - One model turn

    private struct PendingCall: Sendable {
        let id: String
        let name: String
        var arguments: String
    }

    private struct Turn {
        var items: [ConversationItem] = []
        var calls: [PendingCall] = []
        var text = ""
        var usage = TokenUsage()
        var finish: FinishReason?
        /// Notes for the model about calls it wrote that could not be read.
        var unreadable: [(detail: String, raw: String)] = []
    }

    private func streamTurn(_ out: AsyncStream<AgentEvent>.Continuation) async throws -> Turn {
        let request = LLMRequest(
            model: configuration.model,
            system: configuration.systemPrompt,
            items: items,
            tools: offeredTools.map(\.definition),
            reasoningEffort: configuration.reasoningEffort,
            maxOutputTokens: configuration.maxOutputTokens,
            cacheKey: configuration.cacheKey)

        var turn = Turn()
        var textFlushed = false

        func flushText(_ turn: inout Turn) {
            guard !textFlushed, !turn.text.isEmpty else { return }
            textFlushed = true
            turn.items.append(.assistant(turn.text))
        }

        for try await event in client.stream(request) {
            switch event {
            case .textDelta(let delta):
                turn.text += delta
                out.yield(.textDelta(delta))
            case .reasoningDelta(let delta):
                out.yield(.reasoningDelta(delta))
            case .toolCallStarted(let id, let name):
                flushText(&turn)
                if !turn.calls.contains(where: { $0.id == id }) { turn.calls.append(PendingCall(id: id, name: name, arguments: "")) }
                out.yield(.toolCallStarted(id: id, name: name))
            case .toolCallArgumentsDelta(let id, let delta):
                if let index = turn.calls.firstIndex(where: { $0.id == id }) { turn.calls[index].arguments += delta }
            case .toolCallFinished(let id, let name, let arguments):
                if let index = turn.calls.firstIndex(where: { $0.id == id }) {
                    turn.calls[index].arguments = arguments
                } else {
                    flushText(&turn)
                    turn.calls.append(PendingCall(id: id, name: name, arguments: arguments))
                }
                out.yield(.toolCallArguments(id: id, name: name, arguments: arguments))
            case .opaqueItem(let item):
                turn.items.append(.opaque(item))
            case .unreadableToolCall(let detail, let raw):
                turn.unreadable.append((detail, raw))
                out.yield(.unreadableToolCall(detail: detail))
            case .usage(let usage):
                turn.usage = usage
            case .finished(let reason):
                turn.finish = reason
            case .retrying:
                turn = Turn()
                textFlushed = false
                out.yield(.turnRestarted)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        flushText(&turn)
        return turn
    }

    // MARK: - Tool execution

    private enum ExecutionResult {
        case `continue`
        case stopped
        case repeated(String)
    }

    private enum Plan {
        /// Settled without running: an unknown tool, bad arguments, a repeat warning.
        case answered(ToolOutput)
        /// `note` is put in front of the output, for what the model must know (the user edited the command).
        case run(any AgentTool, arguments: String, note: String?)

        var isConcurrent: Bool {
            switch self {
            case .answered: true
            case .run(let tool, _, _): tool.risk == .read && !tool.waitsForUser
            }
        }
    }

    private func execute(
        _ calls: [PendingCall],
        counts: inout [String: Int],
        _ out: AsyncStream<AgentEvent>.Continuation
    ) async -> ExecutionResult {
        // The same call a third time gets a warning instead of a run; a fourth stops the run.
        var plans: [Plan] = []
        var repeated: String?
        for call in calls {
            let key = call.name + "\u{0}" + Self.canonical(call.arguments)
            // Bookkeeping such as a checklist is meant to be sent again unchanged; the iteration cap bounds it.
            let exempt = toolsByName[call.name]?.isExemptFromRepeatGuard ?? false
            if !exempt { counts[key, default: 0] += 1 }
            if !exempt, counts[key]! >= 4 {
                repeated = repeated ?? call.name
                plans.append(.answered(.error("Stopped: this exact call was made four times in one run.")))
            } else if !exempt, counts[key]! == 3 {
                plans.append(.answered(.error("You have already made this exact call twice. Try a different approach instead of repeating it.")))
            } else if let tool = toolsByName[call.name], !configuration.mode.offers(tool.risk) {
                plans.append(.answered(.error("\(call.name) is not available: this session is in plan mode, so nothing can be changed or run. Describe the change in your plan instead.")))
            } else if let tool = toolsByName[call.name] {
                plans.append(.run(tool, arguments: call.arguments, note: nil))
            } else {
                plans.append(.answered(.error("Unknown tool \"\(call.name)\". Available tools: \(offeredTools.map(\.name).joined(separator: ", "))")))
            }
        }
        if let repeated {
            for (call, plan) in zip(calls, plans) {
                var output = ToolOutput.error("Not run: the run was stopped for repeating a call.")
                if case .answered(let settled) = plan { output = settled }
                items.append(.toolOutput(callID: call.id, output: output.text))
                out.yield(.toolCallFinished(id: call.id, name: call.name, output: output))
            }
            return .repeated(repeated)
        }

        // Consecutive read-only calls run together; edits and commands run alone, in the order sent,
        // so a read after an edit sees it. Outputs go back in call order.
        var outputs = [ToolOutput?](repeating: nil, count: calls.count)
        var start = 0
        while start < calls.count, !Task.isCancelled {
            var end = start + 1
            if plans[start].isConcurrent {
                while end < calls.count, plans[end].isConcurrent { end += 1 }
            }
            // Commands ask first, one call at a time (they never share a batch).
            if !plans[start].isConcurrent {
                plans[start] = await approved(plans[start], call: calls[start], out)
                if Task.isCancelled { break }
            }
            let names = (start..<end).compactMap { index -> String? in
                if case .run = plans[index] { calls[index].name } else { nil }
            }
            if !names.isEmpty { out.yield(.stateChanged(.runningTools(names))) }

            let batch = await runBatch(Array(start..<end), calls: calls, plans: plans, out)
            if Task.isCancelled { break }
            var changedFiles = false
            for (index, output) in batch {
                outputs[index] = output
                out.yield(.toolCallFinished(id: calls[index].id, name: calls[index].name, output: output))
                if !output.isError, case .run(let tool, _, _) = plans[index], tool.risk == .edit { changedFiles = true }
            }
            // Running the tests again after an edit is the normal loop, not a stuck one: only identical
            // calls with nothing changed in between count towards the repeat guard.
            if changedFiles { counts.removeAll() }
            if let changed = await todoList.takeChange() { out.yield(.todosUpdated(changed)) }
            start = end
        }

        let cancelled = Task.isCancelled
        for (index, call) in calls.enumerated() {
            let output = outputs[index] ?? .error("Cancelled by user.")
            if outputs[index] == nil { out.yield(.toolCallFinished(id: call.id, name: call.name, output: output)) }
            items.append(.toolOutput(callID: call.id, output: output.text))
        }
        return cancelled ? .stopped : .continue
    }

    /// Asks the user about a command-risk call and returns the plan to follow: unchanged, with the
    /// user's edit, or settled as a denial. Nothing a tool returns can approve a call; only
    /// `resolveApproval` does.
    private func approved(_ plan: Plan, call: PendingCall, _ out: AsyncStream<AgentEvent>.Continuation) async -> Plan {
        guard case .run(let tool, let arguments, _) = plan, configuration.approval == .askForCommands,
              let parsed = try? ToolArguments(json: arguments)
        else { return plan }

        let context = ToolContext(
            workspace: workspace, ledger: ledger, callID: call.id,
            checkpoint: currentRun.map { CheckpointScope(log: checkpoints, run: $0) })

        var request: ApprovalRequest
        let isEdit = tool.risk == .edit
        switch tool.risk {
        case .command:
            guard let asked = await tool.approvalRequest(for: parsed, context: context) else { return plan }
            request = asked
        case .edit where configuration.mode == .approveEachEdit:
            // A call that can't be previewed (stale file, bad arguments) is left to fail on its own.
            guard let preview = await tool.editPreview(for: parsed, context: context) else { return plan }
            request = ApprovalRequest(title: "Apply edit", command: preview.summary, diff: preview.diff)
        default:
            return plan
        }
        request.callID = call.id
        request.toolName = call.name

        out.yield(.approvalRequested(request))
        out.yield(.stateChanged(.awaitingApproval(callID: call.id)))
        switch await waitForApproval(callID: call.id) {
        case .approve:
            return plan
        case .approveEditing(let edited):
            guard let key = request.editableArgument,
                  var object = (try? JSONValue(parsing: arguments))?.objectValue
            else { return plan }
            object[key] = .string(edited)
            guard let rewritten = try? JSONValue.object(object).serialized() else { return plan }
            return .run(tool, arguments: rewritten, note: "[The user edited the command before approving it. This ran: \(edited)]")
        case .deny(let note):
            let reason = (note?.isEmpty == false) ? " Their note: \(note!)" : ""
            if isEdit {
                return .answered(.error("The user rejected this edit; nothing was changed.\(reason) Do not apply it again as is; ask what they want or propose something else."))
            }
            return .answered(.error("The user denied this command.\(reason) Do not retry it as is; adjust or ask what they want."))
        }
    }

    private func runBatch(
        _ indices: [Int], calls: [PendingCall], plans: [Plan], _ out: AsyncStream<AgentEvent>.Continuation
    ) async -> [(Int, ToolOutput)] {
        let workspace = workspace
        let ledger = ledger
        let todoList = todoList
        let scope = currentRun.map { CheckpointScope(log: checkpoints, run: $0) }
        let timeout = configuration.toolTimeout
        return await withTaskGroup(of: (Int, ToolOutput).self) { group in
            for index in indices {
                let call = calls[index]
                switch plans[index] {
                case .answered(let output):
                    group.addTask { (index, output) }
                case .run(let tool, let arguments, let note):
                    group.addTask {
                        let context = ToolContext(
                            workspace: workspace, ledger: ledger, callID: call.id, checkpoint: scope,
                            progress: { out.yield(.toolCallOutput(id: call.id, chunk: $0)) },
                            ask: { question in
                                out.yield(.questionAsked(question))
                                out.yield(.stateChanged(.awaitingAnswer(callID: question.callID)))
                                return await self.waitForAnswer(callID: question.callID)
                            },
                            todos: todoList)
                        let output = await Self.run(tool, arguments: arguments, context: context, timeout: timeout)
                        guard let note else { return (index, output) }
                        return (index, ToolOutput(note + "\n" + output.text, isError: output.isError))
                    }
                }
            }
            var results: [(Int, ToolOutput)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
    }

    /// Races the tool against its timeout. A tool that ignores cancellation delays the result past
    /// the timeout, which is why `AgentTool` documents that tools must honor it.
    private static func run(_ tool: any AgentTool, arguments: String, context: ToolContext, timeout: TimeInterval) async -> ToolOutput {
        // A person's answer takes as long as it takes; Stop is what ends the wait.
        if tool.waitsForUser { return await tool.execute(argumentsJSON: arguments, context: context) }
        return await withTaskGroup(of: ToolOutput?.self) { group in
            group.addTask { await tool.execute(argumentsJSON: arguments, context: context) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if Task.isCancelled { return .error("Cancelled by user.") }
            let seconds = timeout < 1 ? String(format: "%.2f", timeout) : String(Int(timeout))
            return first ?? .error("\(tool.name) timed out after \(seconds) seconds.")
        }
    }

    /// Argument text with keys sorted, so `{"a":1,"b":2}` and `{"b":2,"a":1}` count as one call.
    private static func canonical(_ arguments: String) -> String {
        (try? JSONValue(parsing: arguments).serialized()) ?? arguments
    }
}

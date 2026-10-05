import Foundation
import Testing
@testable import AgentKit

/// Records when probe tools start and finish, and how many ran at once.
actor Probe {
    private(set) var log: [String] = []
    private(set) var running = 0
    private(set) var maxRunning = 0

    func begin(_ name: String) {
        log.append("start:\(name)")
        running += 1
        maxRunning = max(maxRunning, running)
    }

    func end(_ name: String) {
        log.append("end:\(name)")
        running -= 1
    }

    var startedCount: Int { log.filter { $0.hasPrefix("start:") }.count }

    func waitUntilStarted(_ count: Int = 1) async {
        while startedCount < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

struct ProbeTool: AgentTool {
    let name: String
    var risk: ToolRisk = .read
    var delay: Duration = .zero
    var result = "ok"
    var fails = false
    let probe: Probe

    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "probe", parameters: [ToolParameter("n", .integer, "n", optional: true)])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        await probe.begin(name)
        defer { Task { await probe.end(name) } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw ToolError("\(name) failed on purpose") }
        return "\(result):\(name)"
    }
}

/// The invariant the loop exists to keep.
func expectEveryCallAnswered(_ items: [ConversationItem], sourceLocation: SourceLocation = #_sourceLocation) {
    var calls: [String] = []
    var outputs: [String] = []
    for item in items {
        if case .toolCall(let id, _, _) = item { calls.append(id) }
        if case .toolOutput(let id, _) = item { outputs.append(id) }
    }
    #expect(calls.sorted() == outputs.sorted(), "every tool call needs exactly one output", sourceLocation: sourceLocation)
}

func toolOutputs(_ items: [ConversationItem]) -> [String: String] {
    var result: [String: String] = [:]
    for case .toolOutput(let id, let text) in items { result[id] = text }
    return result
}

private func makeSession(
    _ client: MockLLMClient, tools: [any AgentTool], configuration: AgentConfiguration = AgentConfiguration(model: "m")
) throws -> AgentSession {
    AgentSession(client: client, tools: tools, workspace: try TempProject().workspace, configuration: configuration)
}

private func runToEnd(_ session: AgentSession, _ text: String = "go") async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await session.send(text) { events.append(event) }
    return events
}

private func ending(_ events: [AgentEvent]) -> RunEnding? {
    for case .runEnded(let ending) in events { return ending }
    return nil
}

@Suite struct AgentSessionTests {
    @Test func runsAToolThenAnswersFromItsOutput() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            MockTurn([
                .textDelta("Let me look."), .toolCallStarted(id: "c1", name: "look"),
                .toolCallFinished(id: "c1", name: "look", arguments: "{}"),
                .usage(TokenUsage(inputTokens: 100, outputTokens: 10)), .finished(.toolCalls),
            ]),
            MockTurn([.textDelta("Found it."), .usage(TokenUsage(inputTokens: 150, outputTokens: 5)), .finished(.completed)]),
        ])
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        let events = await runToEnd(session, "find it")

        #expect(ending(events) == .completed)
        #expect(events.last == .runEnded(.completed))
        #expect(events.contains(.toolCallFinished(id: "c1", name: "look", output: ToolOutput("ok:look"))))
        #expect(events.contains(.assistantMessage("Let me look.")))
        #expect(events.contains(.assistantMessage("Found it.")))
        #expect(await session.items == [
            .user("find it"), .assistant("Let me look."),
            .toolCall(id: "c1", name: "look", arguments: "{}"), .toolOutput(callID: "c1", output: "ok:look"),
            .assistant("Found it."),
        ])
        // The second request carried the tool output back.
        #expect(client.requests.count == 2)
        #expect(client.requests[1].items.contains(.toolOutput(callID: "c1", output: "ok:look")))
        #expect(await session.totalUsage == TokenUsage(inputTokens: 250, outputTokens: 15))
        #expect(await session.lastInputTokens == 150)
        #expect(await !session.isRunning)
    }

    @Test func requestsCarryTheToolsInOrderAndTheConfiguration() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [.text("hi")])
        let configuration = AgentConfiguration(
            model: "gpt-x", systemPrompt: "sys", reasoningEffort: "low", maxOutputTokens: 99, cacheKey: "k")
        let session = try makeSession(
            client, tools: [ProbeTool(name: "b", probe: probe), ProbeTool(name: "a", probe: probe)], configuration: configuration)
        _ = await runToEnd(session)
        let request = try #require(client.requests.first)
        #expect(request.tools.map(\.name) == ["b", "a"])
        #expect(request.model == "gpt-x" && request.system == "sys" && request.reasoningEffort == "low")
        #expect(request.maxOutputTokens == 99 && request.cacheKey == "k")
    }

    @Test func everyCallGetsAnOutputWhateverWentWrong() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            .toolCalls(
                (id: "ok", name: "look", arguments: "{}"),
                (id: "boom", name: "explode", arguments: "{}"),
                (id: "ghost", name: "nonexistent", arguments: "{}")),
            .text("done"),
        ])
        let session = try makeSession(client, tools: [
            ProbeTool(name: "look", probe: probe), ProbeTool(name: "explode", fails: true, probe: probe),
        ])
        let events = await runToEnd(session)
        #expect(ending(events) == .completed)
        let items = await session.items
        expectEveryCallAnswered(items)
        let outputs = toolOutputs(items)
        #expect(outputs["ok"] == "ok:look")
        #expect(outputs["boom"] == "Error: explode failed on purpose")
        #expect(outputs["ghost"] == "Error: Unknown tool \"nonexistent\". Available tools: look, explode")
    }

    @Test func invalidArgumentsAreAnOutputNotAFailure() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [.toolCalls((id: "c", name: "look", arguments: "{oops")), .text("ok")])
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        #expect(ending(await runToEnd(session)) == .completed)
        #expect(toolOutputs(await session.items)["c"] == "Error: The arguments were not a valid JSON object.")
        #expect(await probe.startedCount == 0)
    }

    @Test func readOnlyCallsRunTogetherAndEditsRunAloneInOrder() async throws {
        let probe = Probe()
        let slow = Duration.milliseconds(60)
        let client = MockLLMClient(turns: [
            .toolCalls(
                (id: "r1", name: "read1", arguments: "{}"), (id: "r2", name: "read2", arguments: "{}"),
                (id: "e", name: "edit", arguments: "{}"), (id: "r3", name: "read3", arguments: "{}")),
            .text("done"),
        ])
        let session = try makeSession(client, tools: [
            ProbeTool(name: "read1", delay: slow, probe: probe), ProbeTool(name: "read2", delay: slow, probe: probe),
            ProbeTool(name: "edit", risk: .edit, delay: slow, probe: probe), ProbeTool(name: "read3", delay: slow, probe: probe),
        ])
        _ = await runToEnd(session)
        #expect(await probe.maxRunning == 2, "the two leading reads overlap, nothing else does")
        let log = await probe.log
        let editStart = try #require(log.firstIndex(of: "start:edit"))
        #expect(log.firstIndex(of: "end:read1")! < editStart && log.firstIndex(of: "end:read2")! < editStart)
        #expect(log.firstIndex(of: "start:read3")! > log.firstIndex(of: "end:edit")!, "a read after an edit sees it")

        // Outputs return in the order the calls were made.
        let outputIDs = await session.items.compactMap { item -> String? in
            if case .toolOutput(let id, _) = item { id } else { nil }
        }
        #expect(outputIDs == ["r1", "r2", "e", "r3"])
    }

    @Test func aToolTimeoutBecomesAnOutput() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [.toolCalls((id: "c", name: "slow", arguments: "{}")), .text("done")])
        let session = try makeSession(
            client, tools: [ProbeTool(name: "slow", delay: .seconds(30), probe: probe)],
            configuration: AgentConfiguration(model: "m", toolTimeout: 0.05))
        let events = await runToEnd(session)
        #expect(ending(events) == .completed)
        #expect(toolOutputs(await session.items)["c"] == "Error: slow timed out after 0.05 seconds.")
    }

    @Test func iterationCapPausesInsteadOfFailing() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: (0..<5).map {
            .toolCalls((id: "c\($0)", name: "look", arguments: "{\"n\":\($0)}"))
        })
        let session = try makeSession(
            client, tools: [ProbeTool(name: "look", probe: probe)],
            configuration: AgentConfiguration(model: "m", maxIterations: 3, graceTurnAtCap: false))
        #expect(ending(await runToEnd(session)) == .iterationCap)
        #expect(client.requests.count == 3)
        expectEveryCallAnswered(await session.items)
    }

    @Test func theSameCallThriceGetsAWarningAndAFourthStopsTheRun() async throws {
        let probe = Probe()
        let same = (id: "x", name: "look", arguments: "{\"n\":1}")
        let client = MockLLMClient(turns: (1...4).map { MockTurn.toolCalls((id: "c\($0)", name: same.name, arguments: same.arguments)) })
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        let events = await runToEnd(session)
        #expect(ending(events) == .repeatedCall("look"))
        let outputs = toolOutputs(await session.items)
        #expect(outputs["c1"] == "ok:look" && outputs["c2"] == "ok:look")
        #expect(outputs["c3"]?.contains("already made this exact call twice") == true)
        #expect(outputs["c4"]?.contains("four times") == true)
        #expect(await probe.startedCount == 2, "the warned and stopped calls never ran")
        expectEveryCallAnswered(await session.items)
    }

    @Test func argumentKeyOrderDoesNotHideARepeat() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "a", name: "look", arguments: #"{"a":1,"b":2}"#)),
            .toolCalls((id: "b", name: "look", arguments: #"{"b":2,"a":1}"#)),
            .toolCalls((id: "c", name: "look", arguments: #"{"a":1, "b":2}"#)),
            .text("done"),
        ])
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        _ = await runToEnd(session)
        #expect(toolOutputs(await session.items)["c"]?.contains("already made") == true)
    }

    @Test func aRetryDropsTheStreamedPartOfTheTurn() async throws {
        let client = MockLLMClient(turns: [
            MockTurn([
                .textDelta("par"), .toolCallStarted(id: "gone", name: "look"),
                .retrying(attempt: 1, after: 0), .textDelta("full answer"), .finished(.completed),
            ])
        ])
        let session = try makeSession(client, tools: [])
        let events = await runToEnd(session)
        #expect(events.contains(.turnRestarted))
        #expect(events.contains(.assistantMessage("full answer")))
        #expect(await session.items == [.user("go"), .assistant("full answer")])
    }

    @Test func aTurnCutOffByTheLengthLimitAnswersItsCallsWithoutRunningThem() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            MockTurn([
                .toolCallStarted(id: "c", name: "look"), .toolCallArgumentsDelta(id: "c", delta: "{\"n\":"), .finished(.length),
            ])
        ])
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        #expect(ending(await runToEnd(session)) == .lengthLimit)
        #expect(toolOutputs(await session.items)["c"] == "Not run: the response hit the length limit.")
        #expect(await probe.startedCount == 0)
        expectEveryCallAnswered(await session.items)
    }

    @Test func aContentFilterEndsTheRun() async throws {
        let client = MockLLMClient(turns: [MockTurn([.finished(.contentFilter)])])
        #expect(ending(await runToEnd(try makeSession(client, tools: []))) == .contentFiltered)
    }

    @Test func opaqueItemsAreKeptInOrderBeforeTheTextAndCalls() async throws {
        let probe = Probe()
        let reasoning = OpaqueItem(provider: "mock", payload: ["type": "reasoning"])
        let client = MockLLMClient(turns: [
            MockTurn([
                .opaqueItem(reasoning), .textDelta("hm"), .toolCallStarted(id: "c", name: "look"),
                .toolCallFinished(id: "c", name: "look", arguments: "{}"), .finished(.toolCalls),
            ]),
            .text("done"),
        ])
        let session = try makeSession(client, tools: [ProbeTool(name: "look", probe: probe)])
        _ = await runToEnd(session)
        let items = await session.items
        #expect(Array(items.prefix(4)) == [
            .user("go"), .opaque(reasoning), .assistant("hm"), .toolCall(id: "c", name: "look", arguments: "{}"),
        ])
    }

    @Test func retryRunsTheSameMessageAgainWithoutAddingASecondCopy() async throws {
        let client = MockLLMClient(turns: [
            MockTurn([.textDelta("par")], failure: .unreachable("Could not connect to localhost.")),
            .text("full"),
        ])
        let session = try makeSession(client, tools: [])
        #expect(ending(await runToEnd(session, "hello")) == .failed("Could not connect to localhost."))
        #expect(await session.items == [.user("hello")])

        var retried: [AgentEvent] = []
        for await event in await session.retry() { retried.append(event) }
        #expect(ending(retried) == .completed)
        #expect(await session.items == [.user("hello"), .assistant("full")])
        #expect(client.requests.count == 2)
        #expect(client.requests[0].items == [.user("hello")])
        #expect(client.requests[1].items == [.user("hello")])
    }

    @Test func aFailedTurnLeavesNothingHalfWrittenAndTheSessionUsable() async throws {
        let client = MockLLMClient(turns: [
            MockTurn([.textDelta("par")], failure: .unauthorized), .text("recovered"),
        ])
        let session = try makeSession(client, tools: [])
        let first = await runToEnd(session, "one")
        #expect(ending(first) == .failed(LLMError.unauthorized.localizedDescription))
        #expect(await session.items == [.user("one")])
        #expect(ending(await runToEnd(session, "two")) == .completed)
        #expect(await session.items.last == .assistant("recovered"))
    }

    @Test func aSecondSendWhileRunningIsRefused() async throws {
        let client = MockLLMClient(turns: [MockTurn([.textDelta("a"), .textDelta("b"), .finished(.completed)], delayPerEvent: .milliseconds(50))])
        let session = try makeSession(client, tools: [])
        let first = await session.send("one")
        var refused: [AgentEvent] = []
        for await event in await session.send("two") { refused.append(event) }
        #expect(ending(refused) == .failed("A run is already in progress."))
        for await _ in first {}
        #expect(await session.items.filter { if case .user = $0 { true } else { false } }.count == 1)
    }

    @Test func historyContinuesAcrossRuns() async throws {
        let client = MockLLMClient(turns: [.text("first"), .text("second")])
        let session = try makeSession(client, tools: [])
        _ = await runToEnd(session, "q1")
        _ = await runToEnd(session, "q2")
        #expect(client.requests[1].items == [.user("q1"), .assistant("first"), .user("q2")])
    }
}

@Suite struct AgentSessionStopTests {
    @Test func stopMidToolAnswersEveryCallAndLeavesTheSessionUsable() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "slow", name: "slow", arguments: "{}"), (id: "later", name: "edit", arguments: "{}")),
            .text("resumed"),
        ])
        let session = try makeSession(client, tools: [
            ProbeTool(name: "slow", delay: .seconds(30), probe: probe), ProbeTool(name: "edit", risk: .edit, probe: probe),
        ])
        let stream = await session.send("go")
        let collector = Task { () -> [AgentEvent] in
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await probe.waitUntilStarted()
        await session.stop()
        let events = await collector.value

        #expect(ending(events) == .stopped)
        let items = await session.items
        expectEveryCallAnswered(items)
        #expect(toolOutputs(items)["slow"] == "Error: Cancelled by user.")
        #expect(toolOutputs(items)["later"] == "Error: Cancelled by user.")
        #expect(await probe.log.contains("start:edit") == false, "the edit after the cancelled read never started")

        // The next message continues the same conversation.
        #expect(ending(await runToEnd(session, "again")) == .completed)
        #expect(client.requests[1].items.count == items.count + 1)
    }

    @Test func stopMidStreamDiscardsTheHalfTurn() async throws {
        let events = (0..<50).map { LLMEvent.textDelta("w\($0) ") } + [.finished(.completed)]
        let client = MockLLMClient(turns: [MockTurn(events, delayPerEvent: .milliseconds(20))])
        let session = try makeSession(client, tools: [])
        let stream = await session.send("go")
        let collector = Task { () -> [AgentEvent] in
            var received: [AgentEvent] = []
            for await event in stream {
                received.append(event)
                if case .textDelta = event { await session.stop() }
            }
            return received
        }
        let received = await collector.value
        #expect(ending(received) == .stopped)
        #expect(await session.items == [.user("go")])
        #expect(received.filter { if case .textDelta = $0 { true } else { false } }.count < 50)
    }

    @Test func droppingTheEventStreamStopsTheRun() async throws {
        let events = (0..<200).map { LLMEvent.textDelta("w\($0)") } + [.finished(.completed)]
        let client = MockLLMClient(turns: [MockTurn(events, delayPerEvent: .milliseconds(20))])
        let session = try makeSession(client, tools: [])
        do {
            let stream = await session.send("go")
            for await _ in stream { break }
        }
        // The run winds down on its own; the session becomes idle without anyone calling stop().
        for _ in 0..<200 where await session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await !session.isRunning)
        #expect(await session.items == [.user("go")])
    }
}

import Foundation
import Testing
@testable import AgentKit

private let liveOutputLimitProjects = Locked<[TempProject]>([])

private func session(
    _ client: MockLLMClient, probe: Probe, configuration: AgentConfiguration = AgentConfiguration(model: "m")
) throws -> AgentSession {
    let project = try TempProject()
    liveOutputLimitProjects.value.append(project)
    return AgentSession(
        client: client, tools: [ProbeTool(name: "look", probe: probe)], workspace: project.workspace,
        configuration: configuration)
}

private func run(_ session: AgentSession) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await session.send("go") { events.append(event) }
    return events
}

private func ending(_ events: [AgentEvent]) -> RunEnding? {
    for case .runEnded(let ending) in events { return ending }
    return nil
}

private func continuations(_ events: [AgentEvent], _ reason: ContinuationReason) -> [Int] {
    events.compactMap { event in
        if case .continuing(let found, let attempt) = event, found == reason { attempt } else { nil }
    }
}

private func editorNotes(_ items: [ConversationItem]) -> [String] {
    items.compactMap { item in
        if case .user(let text) = item, text.hasPrefix("[Note from the editor, not from the user]") { text } else { nil }
    }
}

@Suite struct OutputLimitContinuationTests {
    @Test func aCutOffAnswerIsContinuedWithANoteAndTheRunCompletes() async throws {
        let client = MockLLMClient(turns: [
            MockTurn([.textDelta("part"), .finished(.length)]), .text("rest"),
        ])
        let session = try session(client, probe: Probe())
        let events = await run(session)

        #expect(ending(events) == .completed)
        #expect(continuations(events, .outputLimit) == [1])
        let items = await session.items
        #expect(items.count == 4)
        #expect(items[0] == .user("go") && items[1] == .assistant("part") && items[3] == .assistant("rest"))
        let notes = editorNotes(items)
        #expect(notes.count == 1 && notes[0].contains("output token limit") && notes[0].contains("smaller pieces"))
    }

    @Test func aCallThatArrivedWholeRunsAndACutOffOneIsAnsweredWithoutANote() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            MockTurn([
                .toolCallStarted(id: "a", name: "look"), .toolCallFinished(id: "a", name: "look", arguments: "{}"),
                .toolCallStarted(id: "b", name: "look"), .toolCallArgumentsDelta(id: "b", delta: #"{"n":"#),
                .finished(.length),
            ]),
            .text("done"),
        ])
        let session = try session(client, probe: probe)
        let events = await run(session)

        #expect(ending(events) == .completed)
        #expect(await probe.startedCount == 1)
        let items = await session.items
        expectEveryCallAnswered(items)
        let outputs = toolOutputs(items)
        #expect(outputs["a"] == "ok:look")
        #expect(outputs["b"]?.hasPrefix("Not run: the output token limit was reached") == true)
        #expect(outputs["b"]?.contains("smaller calls") == true)
        #expect(editorNotes(items).isEmpty, "the cut-off call's output already says what to do")
        #expect(continuations(events, .outputLimit) == [1])
    }

    @Test func aCallWhoseArgumentsFinishedButDoNotParseIsNotRun() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            MockTurn([
                .toolCallStarted(id: "a", name: "look"), .toolCallFinished(id: "a", name: "look", arguments: #"{"n":"#),
                .finished(.length),
            ]),
            .text("done"),
        ])
        let session = try session(client, probe: probe)
        _ = await run(session)
        #expect(await probe.startedCount == 0)
        #expect(toolOutputs(await session.items)["a"]?.hasPrefix("Not run: the output token limit") == true)
    }

    @Test func threeCutOffsInARowEndTheRunAfterTwoContinuations() async throws {
        let cut = MockTurn([.textDelta("part"), .finished(.length)])
        let client = MockLLMClient(turns: [cut, cut, cut])
        let session = try session(client, probe: Probe())
        let events = await run(session)

        #expect(ending(events) == .lengthLimit)
        #expect(client.requests.count == 3)
        #expect(continuations(events, .outputLimit) == [1, 2])
    }

    @Test func aCutOffThatIsNotFollowedByAnotherStartsTheCountAgain() async throws {
        let cut = MockTurn([.textDelta("part"), .finished(.length)])
        let client = MockLLMClient(turns: [
            cut, MockTurn.toolCalls((id: "t1", name: "look", arguments: "{}")),
            cut, MockTurn.toolCalls((id: "t2", name: "look", arguments: "{}")),
            cut, .text("finished"),
        ])
        let session = try session(client, probe: Probe())
        let events = await run(session)

        #expect(ending(events) == .completed)
        #expect(continuations(events, .outputLimit) == [1, 1, 1])
    }

    @Test func continuationsCanBeTurnedOff() async throws {
        let client = MockLLMClient(turns: [MockTurn([.textDelta("part"), .finished(.length)]), .text("never asked")])
        let session = try session(
            client, probe: Probe(), configuration: AgentConfiguration(model: "m", maxLengthContinuations: 0))
        #expect(ending(await run(session)) == .lengthLimit)
        #expect(client.requests.count == 1)
    }

    @Test func aCutOffClosingTurnStillEndsTheRunAtTheLimit() async throws {
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "c1", name: "look", arguments: "{}")),
            MockTurn([.textDelta("summary so f"), .finished(.length)]),
        ])
        let session = try session(
            client, probe: Probe(), configuration: AgentConfiguration(model: "m", maxIterations: 1))
        let events = await run(session)
        #expect(ending(events) == .lengthLimit)
        #expect(continuations(events, .outputLimit).isEmpty)
        #expect(client.requests.count == 2)
    }
}

@Suite struct InterruptedStreamTests {
    private static let dropped = LLMError.interruptedAfterOutput("the network went away")

    @Test func aDropAfterTextKeepsTheTextAndAsksTheModelToCarryOn() async throws {
        let client = MockLLMClient(turns: [
            MockTurn([.textDelta("Half an")], failure: Self.dropped), .text("answer"),
        ])
        let session = try session(client, probe: Probe())
        let events = await run(session)

        #expect(ending(events) == .completed)
        #expect(continuations(events, .interrupted) == [1])
        let items = await session.items
        #expect(items.count == 4)
        #expect(items[1] == .assistant("Half an"))
        #expect(editorNotes(items).count == 1 && editorNotes(items)[0].contains("interrupted"))
        // The second request carries the partial text, so the model continues from it.
        #expect(client.requests[1].items.contains(.assistant("Half an")))
    }

    @Test func aDropKeepsCallsThatArrivedWholeAndAnswersTheOthers() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [
            MockTurn([
                .toolCallStarted(id: "a", name: "look"), .toolCallFinished(id: "a", name: "look", arguments: "{}"),
                .toolCallStarted(id: "b", name: "look"), .toolCallArgumentsDelta(id: "b", delta: #"{"n""#),
            ], failure: Self.dropped),
            .text("done"),
        ])
        let session = try session(client, probe: probe)
        let events = await run(session)

        #expect(ending(events) == .completed)
        #expect(await probe.startedCount == 1)
        let items = await session.items
        expectEveryCallAnswered(items)
        #expect(toolOutputs(items)["a"] == "ok:look")
        #expect(toolOutputs(items)["b"]?.hasPrefix("Not run: the connection dropped") == true)
        // The note comes after every output, never between a call and its answer.
        let lastOutput = try #require(items.lastIndex { if case .toolOutput = $0 { true } else { false } })
        let note = try #require(items.firstIndex { if case .user(let text) = $0 { text.contains("interrupted") } else { false } })
        #expect(note > lastOutput)
    }

    @Test func threeDropsInARowFailTheRunAndLeaveAValidHistory() async throws {
        let drop = MockTurn([
            .textDelta("x"), .toolCallStarted(id: "c", name: "look"),
        ], failure: Self.dropped)
        let client = MockLLMClient(turns: [drop, drop, drop])
        let session = try session(client, probe: Probe())
        let events = await run(session)

        guard case .failed(let message) = ending(events) else {
            Issue.record("expected a failed run, got \(String(describing: ending(events)))"); return
        }
        #expect(message.contains("dropped repeatedly"))
        #expect(client.requests.count == 3)
        let items = await session.items
        expectEveryCallAnswered(items)
        #expect({ if case .user = items.last { true } else { false } }(), "Continue needs a request that ends on a user item")
    }

    @Test func aDropOnTheClosingTurnKeepsWhatArrivedAsTheSummary() async throws {
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "c1", name: "look", arguments: "{}")),
            MockTurn([.textDelta("Done so far: the")], failure: Self.dropped),
        ])
        let session = try session(
            client, probe: Probe(), configuration: AgentConfiguration(model: "m", maxIterations: 1))
        let events = await run(session)
        #expect(ending(events) == .iterationCap)
        #expect(events.contains(.assistantMessage("Done so far: the")))
        #expect(client.requests.count == 2)
    }
}

@Suite struct OutputBudgetTests {
    @Test func withoutAWindowTheRequestIsLeftAlone() {
        #expect(OutputBudget.maxOutputTokens(requested: nil, window: nil, measured: 0, estimated: 10_000) == nil)
        #expect(OutputBudget.maxOutputTokens(requested: 4_000, window: nil, measured: 0, estimated: 10_000) == 4_000)
        #expect(OutputBudget.maxOutputTokens(requested: nil, window: 0, measured: 0, estimated: 10_000) == nil)
    }

    @Test func plentyOfRoomLeavesAnUnsetLimitUnset() {
        #expect(OutputBudget.maxOutputTokens(requested: nil, window: 200_000, measured: 10_000, estimated: 500) == nil)
        #expect(OutputBudget.maxOutputTokens(requested: 4_000, window: 200_000, measured: 10_000, estimated: 500) == 4_000)
    }

    @Test func aTightWindowFitsTheLimitToTheRoomWithAMarginOnTheEstimateOnly() {
        // 8,000 - 5,000 measured - 1,150 (1,000 estimated + 15%) = 1,850
        #expect(OutputBudget.maxOutputTokens(requested: nil, window: 8_000, measured: 5_000, estimated: 1_000) == 1_850)
        #expect(OutputBudget.maxOutputTokens(requested: 10_000, window: 8_000, measured: 5_000, estimated: 1_000) == 1_850)
    }

    @Test func theLimitNeverDropsBelowTheMinimumOrRisesAboveTheRequest() {
        #expect(OutputBudget.maxOutputTokens(requested: nil, window: 8_000, measured: 7_900, estimated: 500) == OutputBudget.minimumTokens)
        #expect(OutputBudget.maxOutputTokens(requested: 500, window: 8_000, measured: 7_900, estimated: 500) == 500)
    }

    @Test func theSessionSendsTheFittedLimitOnlyWhenTheWindowIsTight() async throws {
        let tight = MockLLMClient(turns: [.text("ok")])
        let tightSession = try session(tight, probe: Probe(), configuration: AgentConfiguration(model: "m", contextWindow: 4_000))
        _ = await run(tightSession)
        let fitted = try #require(tight.requests.first?.maxOutputTokens)
        #expect(fitted >= OutputBudget.minimumTokens && fitted < 4_000)

        let roomy = MockLLMClient(turns: [.text("ok")])
        let roomySession = try session(roomy, probe: Probe(), configuration: AgentConfiguration(model: "m", contextWindow: 200_000))
        _ = await run(roomySession)
        #expect(roomy.requests.first?.maxOutputTokens == nil)
    }
}

@Suite struct ClosingTurnToolChoiceTests {
    private func closingRequest(supports: Bool) async throws -> LLMRequest {
        let client = MockLLMClient(supportsDisabledToolChoice: supports, turns: [
            MockTurn.toolCalls((id: "c1", name: "look", arguments: "{}")), .text("summary"),
        ])
        let session = try session(
            client, probe: Probe(), configuration: AgentConfiguration(model: "m", maxIterations: 1))
        _ = await run(session)
        #expect(client.requests.count == 2)
        return client.requests[1]
    }

    @Test func aClientThatCanSwitchToolsOffKeepsTheToolListOnTheClosingTurn() async throws {
        let first = try await closingRequest(supports: true)
        #expect(first.toolChoice == .disabled)
        #expect(!first.tools.isEmpty)
    }

    @Test func aClientThatCannotGetsNoToolsOnTheClosingTurn() async throws {
        let closing = try await closingRequest(supports: false)
        #expect(closing.toolChoice == nil)
        #expect(closing.tools.isEmpty)
    }

    @Test func encodersSendToolChoiceNoneNextToTheToolListAndOtherwiseNothing() throws {
        let tool = ToolDefinition(name: "look", description: "d", parameters: [])
        func body(_ data: Data) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        var request = LLMRequest(model: "m", items: [.user("hi")], tools: [tool])

        let plain = [
            try body(AnthropicRequestEncoder.body(for: request)),
            try body(ResponsesRequestEncoder.body(for: request)),
            try body(ChatCompletionsRequestEncoder.body(for: request, capabilities: .openAI)),
        ]
        for json in plain { #expect(json["tool_choice"] == nil) }

        request.toolChoice = .disabled
        let anthropic = try body(AnthropicRequestEncoder.body(for: request))
        #expect((anthropic["tool_choice"] as? [String: String]) == ["type": "none"])
        #expect((anthropic["tools"] as? [Any])?.count == 1)
        #expect(try body(ResponsesRequestEncoder.body(for: request))["tool_choice"] as? String == "none")
        #expect(try body(ChatCompletionsRequestEncoder.body(for: request, capabilities: .openAI))["tool_choice"] as? String == "none")

        // Without tools there is nothing to switch off.
        request.tools = []
        #expect(try body(AnthropicRequestEncoder.body(for: request))["tool_choice"] == nil)
    }

    @Test func theClosingRequestMatchesTheEarlierOneApartFromToolChoice() throws {
        let tool = ToolDefinition(name: "look", description: "d", parameters: [])
        let earlier = LLMRequest(model: "m", system: "s", items: [.user("hi")], tools: [tool], cacheKey: "k")
        var closing = earlier
        closing.toolChoice = .disabled
        func stripped(_ data: Data) throws -> NSDictionary {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["tool_choice"] = nil
            return json as NSDictionary
        }
        #expect(try stripped(AnthropicRequestEncoder.body(for: earlier)) == stripped(AnthropicRequestEncoder.body(for: closing)))
        #expect(try stripped(ResponsesRequestEncoder.body(for: earlier)) == stripped(ResponsesRequestEncoder.body(for: closing)))
    }
}

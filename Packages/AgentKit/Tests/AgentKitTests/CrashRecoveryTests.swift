import Foundation
import Testing
@testable import AgentKit

private func call(_ id: String, _ name: String = "look") -> ConversationItem {
    .toolCall(id: id, name: name, arguments: "{}")
}

@Suite struct AnsweringUnansweredCallsTests {
    @Test func aHistoryWithNoOpenCallIsReturnedAsItIs() {
        let items: [ConversationItem] = [.user("go"), call("a"), .toolOutput(callID: "a", output: "ok"), .assistant("done")]
        #expect(ConversationItem.answeringUnansweredCalls(items) == items)
        #expect(ConversationItem.answeringUnansweredCalls([]) == [])
    }

    @Test func aCallLeftOpenAtTheEndGetsAnOutputThatSaysItMayHavePartlyRun() throws {
        let fixed = ConversationItem.answeringUnansweredCalls([.user("go"), .assistant("Looking"), call("a", "edit_file")])
        #expect(fixed.count == 4)
        guard case .toolOutput(let id, let text) = fixed[3] else { Issue.record("expected an output"); return }
        #expect(id == "a")
        #expect(text.hasPrefix("Tool execution interrupted: edit_file.") && text.contains("may have partly run"))
        expectEveryCallAnswered(fixed)
    }

    @Test func onlyTheOpenCallsOfAGroupAreAnsweredAndAfterTheOnesThatAre() {
        let fixed = ConversationItem.answeringUnansweredCalls([
            .user("go"), call("a"), call("b"), call("c"), .toolOutput(callID: "b", output: "ok"),
        ])
        let outputIDs = fixed.compactMap { item -> String? in
            if case .toolOutput(let id, _) = item { id } else { nil }
        }
        #expect(outputIDs == ["b", "a", "c"])
        expectEveryCallAnswered(fixed)
    }

    @Test func theOutputGoesBeforeWhateverFollowsItsGroup() {
        let fixed = ConversationItem.answeringUnansweredCalls([.user("go"), call("a"), .user("a note"), .assistant("later")])
        guard case .toolOutput = fixed[2], fixed[3] == .user("a note") else {
            Issue.record("the output should sit right after the call, ahead of the note: \(fixed)"); return
        }
    }

    @Test func repairingTwiceChangesNothingMore() {
        let once = ConversationItem.answeringUnansweredCalls([.user("go"), call("a"), call("b")])
        #expect(ConversationItem.answeringUnansweredCalls(once) == once)
    }
}

private func session(
    _ client: MockLLMClient, history: [ConversationItem] = [], probe: Probe = Probe(),
    configuration: AgentConfiguration = AgentConfiguration(model: "m")
) throws -> AgentSession {
    AgentSession(
        client: client, tools: [ProbeTool(name: "look", probe: probe)], workspace: try TempProject().workspace,
        configuration: configuration, history: history)
}

private func run(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Suite struct ResumeAfterAnInterruptionTests {
    @Test func aSessionBuiltFromADanglingHistorySendsAValidRequest() async throws {
        let client = MockLLMClient(turns: [.text("ok")])
        let session = try session(client, history: [.user("go"), .assistant("Looking"), call("a")])
        _ = await run(await session.send("and now?"))
        expectEveryCallAnswered(client.requests[0].items)
        expectEveryCallAnswered(await session.items)
    }

    @Test func resumeAddsANoteNotAUserMessageAndCarriesOn() async throws {
        let saved: [ConversationItem] = [.user("go"), call("a"), .toolOutput(callID: "a", output: "ok:look")]
        let client = MockLLMClient(turns: [.text("finished the job")])
        let session = try session(client, history: saved)
        let events = await run(await session.resume())

        #expect(events.last == .runEnded(.completed))
        let sent = client.requests[0].items
        #expect(Array(sent.prefix(3)) == saved)
        #expect(sent.count == 4)
        guard case .user(let note) = sent[3] else { Issue.record("expected the note"); return }
        #expect(note.hasPrefix("[Note from the editor, not from the user]") && note.contains("app was closed"))
        #expect(await session.items.last == .assistant("finished the job"))
    }

    @Test func resumeRepairsTheCallsTheInterruptionLeftOpen() async throws {
        let client = MockLLMClient(turns: [.text("checked")])
        let session = try session(client, history: [.user("go"), call("a", "edit_file")])
        _ = await run(await session.resume())
        expectEveryCallAnswered(client.requests[0].items)
        #expect(toolOutputs(client.requests[0].items)["a"]?.contains("Tool execution interrupted: edit_file") == true)
    }

    @Test func resumeDuringARunIsRefusedLikeASend() async throws {
        let client = MockLLMClient(turns: [MockTurn([.textDelta("x"), .finished(.completed)], delayPerEvent: .milliseconds(200))])
        let session = try session(client)
        let first = await session.send("go")
        let refused = await run(await session.resume())
        #expect(refused == [.runEnded(.failed("A run is already in progress."))])
        _ = await run(first)
    }
}

@Suite struct StepFinishedTests {
    @Test func itFollowsEachStepThatRanToolsWithEveryCallAnswered() async throws {
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "a", name: "look", arguments: "{}"), (id: "b", name: "look", arguments: #"{"n":1}"#)),
            MockTurn.toolCalls((id: "c", name: "look", arguments: #"{"n":2}"#)),
            .text("done"),
        ])
        let session = try session(client)
        let events = await run(await session.send("go"))

        let steps = events.compactMap { event -> [ConversationItem]? in
            if case .stepFinished(let items) = event { items } else { nil }
        }
        #expect(steps.count == 2, "one per step that ran tools; the run's end is .runEnded")
        for items in steps { expectEveryCallAnswered(items) }
        #expect(steps[0].count == 5 && steps[1].count == 7)
        let final = await session.items
        #expect(Array(final.prefix(steps[1].count)) == steps[1])
        // The event comes after the step's outputs and before the next request.
        let stepIndex = try #require(events.firstIndex { if case .stepFinished = $0 { true } else { false } })
        let finishedA = try #require(events.firstIndex(of: .toolCallFinished(id: "b", name: "look", output: ToolOutput("ok:look"))))
        #expect(stepIndex > finishedA)
    }

    @Test func aContinuedOutputLimitStepAlsoReportsOne() async throws {
        let client = MockLLMClient(turns: [MockTurn([.textDelta("part"), .finished(.length)]), .text("rest")])
        let session = try session(client)
        let events = await run(await session.send("go"))
        #expect(events.filter { if case .stepFinished = $0 { true } else { false } }.count == 1)
    }

    @Test func aRunWithNoToolsReportsNone() async throws {
        let client = MockLLMClient(turns: [.text("hi")])
        let events = await run(await (try session(client)).send("go"))
        #expect(!events.contains { if case .stepFinished = $0 { true } else { false } })
    }
}

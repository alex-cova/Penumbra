import Foundation
import Testing
@testable import AgentKit

private let liveProjects = Locked<[TempProject]>([])

private func session(_ turns: [MockTurn], toolTimeout: TimeInterval = 120, mode: PermissionMode = .acceptEdits, history: [ConversationItem] = [])
    throws -> (AgentSession, MockLLMClient)
{
    let project = try TempProject(files: ["A.txt": "a\n"])
    // The folder is deleted when the project is released; keep it for the test run.
    liveProjects.value.append(project)
    let client = MockLLMClient(turns: turns)
    let agent = AgentSession(
        client: client, tools: ReadOnlyTools.all() + EditingTools.all() + [TodoTool(), AskUserTool()], workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", toolTimeout: toolTimeout, mode: mode), history: history)
    return (agent, client)
}

private func ask(_ id: String = "q", _ question: String = "Which one?", options: String = "") -> MockTurn {
    let extra = options.isEmpty ? "" : #","options":\#(options)"#
    return .toolCalls((id: id, name: "ask_user", arguments: #"{"question":"\#(question)"\#(extra)}"#))
}

@Suite struct TodoTests {
    @Test func linesParseWithMarkersBulletsAndNoCheckboxAtAll() {
        #expect(TodoItem.parse("[ ] read") == TodoItem("read", .pending))
        #expect(TodoItem.parse("[~] edit") == TodoItem("edit", .inProgress))
        #expect(TodoItem.parse("[x] test") == TodoItem("test", .completed))
        #expect(TodoItem.parse("- [X] bulleted") == TodoItem("bulleted", .completed))
        #expect(TodoItem.parse("  * [>]  indented ") == TodoItem("indented", .inProgress))
        #expect(TodoItem.parse("plain step") == TodoItem("plain step", .pending))
        #expect(TodoItem.parse("[ ]   ") == nil, "an empty item is dropped")
        #expect(TodoItem.parse("[] not a box")?.content == "[] not a box")
        #expect(TodoItem("x", .inProgress).line == "[~] x")
    }

    @Test func theToolReplacesTheListAndEmitsOneUpdatePerChange() async throws {
        let (agent, _) = try session([
            .toolCalls((id: "t1", name: "todo", arguments: #"{"items":["[~] find the bug","[ ] fix it","[ ] run tests"]}"#)),
            .toolCalls((id: "t2", name: "todo", arguments: #"{"items":["[x] find the bug","[~] fix it","[ ] run tests"]}"#)),
            .toolCalls((id: "t3", name: "todo", arguments: #"{"items":["[x] find the bug","[~] fix it","[ ] run tests"]}"#)),
            .text("done"),
        ])
        var updates: [[TodoItem]] = []
        for await event in await agent.send("go") { if case .todosUpdated(let items) = event { updates.append(items) } }
        #expect(updates.count == 2, "the repeated, identical list is not a change")
        #expect(updates[0].map(\.status) == [.inProgress, .pending, .pending])
        #expect(updates[1].map(\.status) == [.completed, .inProgress, .pending])
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["t1"]?.hasPrefix("Checklist updated (0 of 3 done)") == true)
        #expect(outputs["t2"]?.hasPrefix("Checklist updated (1 of 3 done)") == true)
        #expect(await agent.todoList.items.count == 3)
    }

    @Test func resendingTheSameListIsNotALoopAndTellsTheModelNothingChanged() async throws {
        let ids = ["t1", "t2", "t3", "t4", "t5"]
        let turns = ids.map { id in MockTurn.toolCalls((id: id, name: "todo", arguments: #"{"items":["[ ] a","[ ] b"]}"#)) } + [.text("done")]
        let (agent, _) = try session(turns)
        var ending: RunEnding?
        for await event in await agent.send("go") { if case .runEnded(let value) = event { ending = value } }
        #expect(ending == .completed, "five identical checklist calls must not trip the repeat guard")
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["t1"]?.hasPrefix("Checklist updated") == true)
        #expect(outputs["t2"]?.hasPrefix("Checklist unchanged (0 of 2 done). Mark items [x]") == true)
        #expect(outputs["t5"]?.hasPrefix("Checklist unchanged") == true)
    }

    @Test func otherToolsStillTripTheRepeatGuard() async throws {
        let call = #"{"path":"A.txt"}"#
        let turns = (1...5).map { MockTurn.toolCalls((id: "r\($0)", name: "read_file", arguments: call)) } + [.text("done")]
        let (agent, _) = try session(turns)
        var ending: RunEnding?
        for await event in await agent.send("go") { if case .runEnded(let value) = event { ending = value } }
        #expect(ending == .repeatedCall("read_file"))
    }

    @Test func tooManyItemsAndBadArgumentsAreErrorsTheModelCanActOn() async throws {
        let many = (1...31).map { "\"[ ] \($0)\"" }.joined(separator: ",")
        let (agent, _) = try session([
            .toolCalls((id: "a", name: "todo", arguments: #"{"items":[\#(many)]}"#), (id: "b", name: "todo", arguments: #"{"items":"not a list"}"#)),
            .text("ok"),
        ])
        for await _ in await agent.send("go") {}
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["a"]?.contains("at most 30 items") == true)
        #expect(outputs["b"]?.hasPrefix("Error:") == true)
        #expect(await agent.todoList.items.isEmpty)
    }

    @Test func aResumedConversationGetsItsChecklistBackFromTheHistory() async throws {
        let history: [ConversationItem] = [
            .user("go"),
            .toolCall(id: "1", name: "todo", arguments: #"{"items":["[x] one","[ ] two"]}"#), .toolOutput(callID: "1", output: "ok"),
            .toolCall(id: "2", name: "todo", arguments: #"{"items":["[x] one","[x] two","[ ] three"]}"#), .toolOutput(callID: "2", output: "ok"),
            .assistant("working"),
        ]
        let (agent, _) = try session([], history: history)
        #expect(await agent.todoList.items.map(\.content) == ["one", "two", "three"], "the last call wins")
        #expect(TodoList.latest(in: [.user("hi")]).isEmpty)
        await agent.setTodos([TodoItem("restored", .inProgress)])
        #expect(await agent.todoList.items == [TodoItem("restored", .inProgress)])
    }

    @Test func theChecklistIsAvailableInPlanMode() async throws {
        let (agent, client) = try session([.toolCalls((id: "t", name: "todo", arguments: #"{"items":["[ ] plan"]}"#)), .text("planned")], mode: .plan)
        for await _ in await agent.send("plan it") {}
        #expect(client.requests[0].tools.map(\.name).contains("todo"))
        #expect(toolOutputs(await agent.items)["t"]?.hasPrefix("Checklist updated") == true)
    }
}

@Suite(.serialized) struct AskUserTests {
    /// Drives a run, answering every question with `decide`.
    private func drive(_ agent: AgentSession, decide: @escaping @Sendable (UserQuestion) async -> String?) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in await agent.send("go") {
            events.append(event)
            if case .questionAsked(let question) = event {
                let answer = await decide(question)
                await agent.answerQuestion(callID: question.callID, answer: answer)
            }
        }
        return events
    }

    @Test func theRunPausesForTheAnswerAndTheModelGetsIt() async throws {
        let (agent, client) = try session([ask("q", "Tabs or spaces?", options: #"["tabs","spaces"]"#), .text("Using spaces.")])
        let asked = Locked<UserQuestion?>(nil)
        let events = await drive(agent) { question in asked.value = question; return "spaces" }

        #expect(asked.value == UserQuestion(callID: "q", question: "Tabs or spaces?", options: ["tabs", "spaces"]))
        #expect(events.contains(.stateChanged(.awaitingAnswer(callID: "q"))))
        #expect(events.last == .runEnded(.completed))
        #expect(toolOutputs(await agent.items)["q"] == "The user answered: spaces")
        #expect(client.requests.count == 2)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func aSkippedQuestionTellsTheModelToUseItsJudgment() async throws {
        let (agent, _) = try session([ask(), .text("assuming the first")])
        _ = await drive(agent) { _ in nil }
        let output = try #require(toolOutputs(await agent.items)["q"])
        #expect(output.hasPrefix("The user did not answer.") && output.contains("best judgment"))
        let blank = try session([ask(), .text("ok")])
        _ = await drive(blank.0) { _ in "   " }
        #expect(toolOutputs(await blank.0.items)["q"] == "The user gave an empty answer.")
    }

    @Test func waitingIsNotCutOffByTheToolTimeout() async throws {
        let (agent, _) = try session([ask(), .text("thanks")], toolTimeout: 0.05)
        let events = await drive(agent) { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return "yes"
        }
        #expect(toolOutputs(await agent.items)["q"] == "The user answered: yes", "a 50 ms timeout must not apply to a person")
        #expect(events.last == .runEnded(.completed))
    }

    @Test func stopEndsTheWaitAndLeavesEveryCallAnswered() async throws {
        let (agent, _) = try session([ask(), .text("never")])
        var events: [AgentEvent] = []
        for await event in await agent.send("go") {
            events.append(event)
            if case .questionAsked = event { await agent.stop() }
        }
        #expect(events.last == .runEnded(.stopped))
        #expect(await agent.awaitingAnswer.isEmpty)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func twoQuestionsInOneTurnAreAskedOneAtATime() async throws {
        let (agent, _) = try session([
            .toolCalls((id: "q1", name: "ask_user", arguments: #"{"question":"First?"}"#), (id: "q2", name: "ask_user", arguments: #"{"question":"Second?"}"#)),
            .text("done"),
        ])
        let order = Locked<[String]>([])
        let pending = Locked<Int>(0)
        let overlap = Locked<Bool>(false)
        _ = await drive(agent) { question in
            if pending.value > 0 { overlap.value = true }
            pending.value += 1
            order.value.append(question.question)
            try? await Task.sleep(for: .milliseconds(30))
            pending.value -= 1
            return "ok"
        }
        #expect(order.value == ["First?", "Second?"])
        #expect(!overlap.value, "the second question waits for the first answer")
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["q1"] == "The user answered: ok" && outputs["q2"] == "The user answered: ok")
    }

    @Test func aStaleAnswerAndAnEmptyQuestionAreHarmless() async throws {
        let (agent, _) = try session([.toolCalls((id: "q", name: "ask_user", arguments: #"{"question":"  "}"#)), .text("ok")])
        await agent.answerQuestion(callID: "nothing-pending", answer: "x")
        _ = await drive(agent) { _ in "never asked" }
        #expect(toolOutputs(await agent.items)["q"] == "Error: The question is empty.")
    }

    @Test func withoutAWayToAskTheToolSaysSoInsteadOfHanging() async throws {
        let project = try TempProject(files: [:])
        let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "q")
        let output = await AskUserTool().execute(argumentsJSON: #"{"question":"Hello?"}"#, context: context)
        #expect(output.isError && output.text.contains("cannot be asked"))
    }

    @Test func optionsAreCappedInCountAndLength() async throws {
        let many = (1...10).map { "\"\(String(repeating: "x", count: 300))\($0)\"" }.joined(separator: ",")
        let (agent, _) = try session([ask(options: "[\(many)]"), .text("ok")])
        let seen = Locked<UserQuestion?>(nil)
        _ = await drive(agent) { question in seen.value = question; return "a" }
        #expect(seen.value?.options.count == 6)
        #expect(seen.value?.options.allSatisfy { $0.count <= 120 } == true)
    }
}

/// A tiny lock-protected box for state shared with a `@Sendable` closure in these tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}


@Suite struct RepeatGuardAfterEditsTests {
    private func edit(_ id: String, from: String, to: String) -> MockTurn {
        .toolCalls((id: id, name: "edit_file", arguments: #"{"path":"A.txt","old_string":"\#(from)","new_string":"\#(to)"}"#))
    }

    private let read = #"{"path":"A.txt"}"#

    @Test func theSameReadBetweenEditsIsTheNormalLoopAndNeverTripsTheGuard() async throws {
        // read, edit, read, edit, ... six identical reads, each after a change.
        var turns: [MockTurn] = []
        let words = ["a", "b", "c", "d", "e", "f", "g"]
        for index in 0..<6 {
            turns.append(.toolCalls((id: "r\(index)", name: "read_file", arguments: read)))
            turns.append(edit("e\(index)", from: words[index], to: words[index + 1]))
        }
        turns.append(.text("done"))
        let (agent, _) = try session(turns)
        var ending: RunEnding?
        for await event in await agent.send("go") { if case .runEnded(let value) = event { ending = value } }
        #expect(ending == .completed)
        let outputs = toolOutputs(await agent.items)
        #expect(outputs.values.allSatisfy { !$0.contains("already made this exact call") })
    }

    @Test func aFailedEditChangesNothingSoTheRepeatsStillAddUp() async throws {
        var turns: [MockTurn] = [.toolCalls((id: "r0", name: "read_file", arguments: read))]
        for index in 1...4 {
            turns.append(edit("bad\(index)", from: "text that is not there", to: "x"))
            turns.append(.toolCalls((id: "r\(index)", name: "read_file", arguments: read)))
        }
        turns.append(.text("done"))
        let (agent, _) = try session(turns)
        var ending: RunEnding?
        for await event in await agent.send("go") { if case .runEnded(let value) = event { ending = value } }
        #expect(ending == .repeatedCall("read_file"), "edits that did not apply do not reset the count")
    }
}

import Foundation
import Testing
@testable import AgentKit

private let liveEmptyTurnProjects = Locked<[TempProject]>([])

private func agent(_ turns: [MockTurn]) throws -> (AgentSession, MockLLMClient) {
    let project = try TempProject(files: ["A.txt": "a\n"])
    liveEmptyTurnProjects.value.append(project)
    let client = MockLLMClient(turns: turns)
    return (AgentSession(
        client: client, tools: ReadOnlyTools.all(), workspace: project.workspace,
        configuration: AgentConfiguration(model: "m")), client)
}

@Suite struct EmptyTurnTests {
    @Test func anEmptyTurnIsRetriedOnceWithANote() async throws {
        let (session, client) = try agent([MockTurn([.finished(.completed)]), .text("Here you go.")])
        var events: [AgentEvent] = []
        for await event in await session.send("go") { events.append(event) }

        #expect(events.last == .runEnded(.completed))
        #expect(client.requests.count == 2)
        guard case .user(let note) = try #require(client.requests[1].items.last) else {
            Issue.record("the note should be a user item"); return
        }
        #expect(note.hasPrefix("[Note from the editor, not from the user]") && note.contains("empty"))
    }

    @Test func aSecondEmptyTurnFailsTheRunInsteadOfCompleting() async throws {
        let (session, client) = try agent([
            MockTurn([.finished(.completed)]), MockTurn([.textDelta("  \n"), .finished(.completed)]),
        ])
        var events: [AgentEvent] = []
        for await event in await session.send("go") { events.append(event) }

        #expect(events.last == .runEnded(.failed("The model produced no output.")))
        #expect(client.requests.count == 2)
    }

    @Test func aTurnWithAnAnswerOrACallIsNotEmpty() async throws {
        let (session, client) = try agent([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .text("Done."),
        ])
        var events: [AgentEvent] = []
        for await event in await session.send("go") { events.append(event) }
        #expect(events.last == .runEnded(.completed))
        #expect(client.requests.count == 2)
    }
}

@Suite struct UnappliedEditsTests {
    private func state(edits: Int, failed: Int, files: [String] = [], mode: PermissionMode = .acceptEdits) -> TurnState {
        TurnState(
            iteration: 0, maxIterations: 8, usage: TokenUsage(), elapsed: 0, contextWindow: nil, estimatedTokens: 0,
            filesEdited: files, verifiedSinceEdit: false, mode: mode, editCalls: edits, failedEditCalls: failed)
    }

    @Test func tellsTheModelOnceWhenEveryEditFailed() async {
        let policy = UnappliedEditsPolicy()
        if case .note(let text) = await policy.beforeEnding(state(edits: 2, failed: 2)) {
            #expect(text.contains("no file was changed"))
        } else {
            Issue.record("a run whose edits all failed should be told")
        }
        #expect(await policy.beforeEnding(state(edits: 2, failed: 2)) == .proceed, "once per run")
        policy.reset()
        if case .note = await policy.beforeEnding(state(edits: 1, failed: 1)) {} else { Issue.record("a new run is told again") }
    }

    @Test func staysQuietWhenNothingWasAttemptedSomethingAppliedOrInPlanMode() async {
        let policy = UnappliedEditsPolicy()
        #expect(await policy.beforeEnding(state(edits: 0, failed: 0)) == .proceed)
        #expect(await policy.beforeEnding(state(edits: 2, failed: 1, files: ["a.txt"])) == .proceed)
        #expect(await policy.beforeEnding(state(edits: 1, failed: 1, mode: .plan)) == .proceed)
    }

    @Test func aRefusedWriteInARunGetsTheNoteBeforeTheClaim() async throws {
        let project = try TempProject(files: ["A.txt": "a\n"])
        liveEmptyTurnProjects.value.append(project)
        let client = MockLLMClient(turns: [
            .toolCalls((id: "w", name: "write_file", arguments: #"{"path":"A.txt","content":"b\n"}"#)),
            .text("Implemented the form."),
            .text("The edit did not apply: A.txt was not read first."),
        ])
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        var events: [AgentEvent] = []
        for await event in await session.send("make it a form") { events.append(event) }

        #expect(events.last == .runEnded(.completed))
        #expect(client.requests.count == 3, "the claim was challenged once")
        let items = await session.items
        #expect(items.contains { item in
            if case .user(let text) = item { return text.contains("no file was changed") }
            return false
        })
    }
}

@Suite struct VerifyPolicyPerRunTests {
    @Test func everyRunIsAskedAgainNotJustTheFirstOfTheSession() async throws {
        let probe = Probe()
        var tool = ProbeTool(name: "edit", probe: probe)
        tool.risk = .edit
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "e1", name: "edit", arguments: #"{"path":"a.txt"}"#)), .text("done"), .text("cannot check"),
            MockTurn.toolCalls((id: "e2", name: "edit", arguments: #"{"path":"a.txt"}"#)), .text("done"), .text("cannot check"),
        ])
        let session = try AgentSession(
            client: client, tools: [tool], workspace: TempProject().workspace,
            configuration: AgentConfiguration(model: "m", verifyBeforeStopping: true))
        for _ in 0..<2 { for await _ in await session.send("go") {} }
        #expect(client.requests.count == 6, "each run asked once before ending")
    }
}

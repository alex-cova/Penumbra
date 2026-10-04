import Foundation
import Testing
@testable import AgentKit

private func unreadable(_ raw: String = #"<tool_call>{"name": "edit_file", "arguments": {"new_string": "a "b" c"#, detail: String = "malformed_syntax: the payload could not be parsed") -> MockTurn {
    MockTurn([.unreadableToolCall(detail: detail, raw: raw), .finished(.completed)])
}

private func agent(_ turns: [MockTurn]) throws -> (AgentSession, MockLLMClient) {
    let project = try TempProject(files: ["A.txt": "a\n"])
    liveUnreadableProjects.value.append(project)
    let client = MockLLMClient(turns: turns)
    return (AgentSession(
        client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
        configuration: AgentConfiguration(model: "m")), client)
}

private let liveUnreadableProjects = Locked<[TempProject]>([])

@Suite struct UnreadableToolCallTests {
    @Test func theModelIsToldAndTriesAgainInsteadOfTheRunEnding() async throws {
        let (session, client) = try agent([
            unreadable(),
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .text("Done."),
        ])
        var events: [AgentEvent] = []
        for await event in await session.send("go") { events.append(event) }

        #expect(events.last == .runEnded(.completed))
        #expect(events.contains(.unreadableToolCall(detail: "malformed_syntax: the payload could not be parsed")))
        #expect(client.requests.count == 3)

        // The second request carries the note, after the user's message, saying what to do.
        let second = client.requests[1].items
        guard case .user(let note) = try #require(second.last) else { Issue.record("the note should be a user item"); return }
        #expect(note.hasPrefix("[Note from the editor, not from the user]"))
        #expect(note.contains("could not be read") && note.contains("malformed_syntax") && note.contains("It began: <tool_call>"))
        #expect(note.contains(#"\n"#) && note.contains(#"\""#), "it says how to write newlines and quotes")
        expectEveryCallAnswered(await session.items)
    }

    @Test func validCallsInTheSameTurnStillRunAndTheNoteComesAfterTheirOutputs() async throws {
        let (session, _) = try agent([
            MockTurn([
                .toolCallStarted(id: "r", name: "read_file"),
                .toolCallFinished(id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#),
                .unreadableToolCall(detail: "broken", raw: "<tool_call>{"),
                .finished(.toolCalls),
            ]),
            .text("ok"),
        ])
        for await _ in await session.send("go") {}
        let items = await session.items
        let kinds = items.map { item -> String in
            switch item {
            case .user: "user"
            case .assistant: "assistant"
            case .toolCall: "call"
            case .toolOutput: "output"
            case .opaque: "opaque"
            }
        }
        #expect(kinds == ["user", "call", "output", "user", "assistant"], "\(kinds)")
        #expect(toolOutputs(items)["r"]?.contains("lines 1") == true, "the readable call ran")
    }

    @Test func aFourthUnreadableCallEndsTheRunWithTheReason() async throws {
        let (session, client) = try agent([unreadable(), unreadable(), unreadable(), unreadable(detail: "broken syntax"), .text("never")])
        var ending: RunEnding?
        for await event in await session.send("go") { if case .runEnded(let value) = event { ending = value } }
        guard case .failed(let message)? = ending else { Issue.record("expected a failure, got \(String(describing: ending))"); return }
        #expect(message.contains("kept writing tool calls that could not be read") && message.contains("broken syntax"))
        #expect(client.requests.count == 4, "three retries were allowed")
    }

    @Test func aRunThatRecoversOnceDoesNotUseUpTheNextRunsAllowance() async throws {
        let (session, _) = try agent([unreadable(), .text("first done"), unreadable(), unreadable(), unreadable(), .text("second done")])
        var endings: [RunEnding] = []
        for await event in await session.send("one") { if case .runEnded(let value) = event { endings.append(value) } }
        for await event in await session.send("two") { if case .runEnded(let value) = event { endings.append(value) } }
        #expect(endings == [.completed, .completed], "the allowance is per run")
    }
}

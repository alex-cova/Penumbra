import Foundation
import Testing
@testable import AgentKit

private func snapshot(_ text: String?, name: String = "AGENTS.md") -> InstructionSnapshot {
    InstructionSnapshot(name: name, text: text)
}

@Suite struct InstructionStateTests {
    @Test func staysQuietWhileTheFileIsWhatThePromptSaid() async {
        let state = InstructionState(initial: "Use tabs.\n")
        #expect(await state.observe(snapshot("Use tabs.\n"), itemCount: 3) == nil)
    }

    @Test func anEditBecomesANoteWithTheDiffAndTheSameChangeIsNotReportedTwice() async throws {
        let state = InstructionState(initial: "Use tabs.\nRun swift test.\n")
        let note = try #require(await state.observe(snapshot("Use spaces.\nRun swift test.\n"), itemCount: 3))
        #expect(note.hasPrefix("AGENTS.md changed on disk."))
        #expect(note.contains("```diff\n--- a/AGENTS.md"))
        #expect(note.contains("-Use tabs.") && note.contains("+Use spaces."))
        #expect(note.contains("do not override the rules above"), "the notes keep the system prompt's framing")
        #expect(note.hasSuffix("```"))
        #expect(await state.observe(snapshot("Use spaces.\nRun swift test.\n"), itemCount: 5) == nil)

        // The next edit is a diff against the version the model was last told, not against the prompt's.
        let second = try #require(await state.observe(snapshot("Use spaces.\nRun swift test -c release.\n"), itemCount: 7))
        #expect(second.contains("-Run swift test.\n") && second.contains("+Run swift test -c release."))
        #expect(!second.contains("Use tabs"))
    }

    @Test func aLargeChangeSaysTheWholeFileInsteadOfADiff() async throws {
        let big = (0..<400).map { "Rule number \($0): keep it simple and readable." }.joined(separator: "\n")
        let state = InstructionState(initial: "Short.\n")
        let note = try #require(await state.observe(snapshot(big), itemCount: 1))
        #expect(note.hasPrefix("AGENTS.md now reads as follows."))
        #expect(!note.contains("```diff"))
        #expect(note.contains("Rule number 399"))
    }

    @Test func aDeletedFileAndANewFileAreBothAnnounced() async throws {
        let state = InstructionState(initial: "Use tabs.\n")
        let deleted = try #require(await state.observe(snapshot(nil), itemCount: 1))
        #expect(deleted.contains("was deleted") && deleted.contains("no longer apply"))
        #expect(await state.observe(snapshot(nil), itemCount: 2) == nil)
        let created = try #require(await state.observe(snapshot("Fresh.\n", name: "CLAUDE.md"), itemCount: 3))
        #expect(created.hasPrefix("CLAUDE.md now reads as follows.") && created.contains("Fresh."))
    }

    @Test func aChangeTheModelMadeItselfNeedsNoNote() async {
        let state = InstructionState(initial: "Use tabs.\n")
        await state.accept(snapshot("Use tabs.\nAlso this.\n"), itemCount: 4)
        #expect(await state.observe(snapshot("Use tabs.\nAlso this.\n"), itemCount: 5) == nil)
        #expect(await state.observe(snapshot("Different.\n"), itemCount: 6) != nil, "a later change still shows")
    }

    @Test func aRewindPastANoteMakesTheNextObservationAnnounceItAgain() async throws {
        let state = InstructionState(initial: "Old.\n")
        let first = try #require(await state.observe(snapshot("New.\n"), itemCount: 5))

        await state.rewound(toBeforeItem: 6)
        #expect(await state.observe(snapshot("New.\n"), itemCount: 6) == nil, "the note at 5 is still in the history")

        await state.rewound(toBeforeItem: 5)
        #expect(await state.observe(snapshot("New.\n"), itemCount: 5) == first)
    }

    @Test func aSummaryOverANoteBringsTheFileBackInFull() async throws {
        let state = InstructionState(initial: "Old.\n")
        #expect(await state.summarized(itemCount: 3) == nil, "the model only ever saw the prompt's version")

        _ = await state.observe(snapshot("New.\n"), itemCount: 5)
        let note = try #require(await state.summarized(itemCount: 4))
        #expect(note.hasPrefix("AGENTS.md now reads as follows.") && note.contains("New."))
        #expect(await state.observe(snapshot("New.\n"), itemCount: 5) == nil)

        // Rewinding past the re-announcement goes back to the prompt's version.
        await state.rewound(toBeforeItem: 4)
        #expect(await state.observe(snapshot("New.\n"), itemCount: 4) != nil)
    }
}

/// Changes the instruction text when a turn calls it, so the edit lands between two model turns.
private struct EditInstructionsTool: AgentTool {
    let name = "edit_instructions"
    let box: Locked<String?>
    let newText: String?
    var risk: ToolRisk { .read }
    var definition: ToolDefinition { ToolDefinition(name: name, description: "test", parameters: []) }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        box.value = newText
        return "edited"
    }
}

private func notes(in items: [ConversationItem]) -> [String] {
    items.compactMap { item in
        if case .user(let text) = item, text.hasPrefix("[Note from the editor, not from the user]") { text } else { nil }
    }
}

@Suite struct InstructionDriftSessionTests {
    private func session(
        _ client: MockLLMClient, box: Locked<String?>, tools: [any AgentTool], project: TempProject,
        baseline: String? = "Use tabs.\n"
    ) -> AgentSession {
        AgentSession(
            client: client, tools: tools, workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m", systemPrompt: "SYSTEM",
                currentInstructions: { InstructionSnapshot(name: "AGENTS.md", text: box.value) },
                instructionsBaseline: baseline))
    }

    private func run(_ session: AgentSession, _ text: String = "go") async {
        for await _ in await session.send(text) {}
    }

    @Test func anEditMadeBetweenTurnsReachesTheModelAfterTheToolOutputAndTheSystemPromptStaysPut() async throws {
        let box = Locked<String?>("Use tabs.\n")
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "e", name: "edit_instructions", arguments: "{}")), .text("ok"),
        ])
        let project = try TempProject()
        let session = session(client, box: box, tools: [EditInstructionsTool(box: box, newText: "Use spaces.\n")], project: project)
        await run(session)

        #expect(client.requests.count == 2)
        #expect(notes(in: client.requests[0].items).isEmpty)
        let second = client.requests[1].items
        let note = try #require(notes(in: second).first)
        #expect(note.contains("-Use tabs.") && note.contains("+Use spaces."))
        // After the call's output, never between a call and its output.
        guard case .user = try #require(second.last), case .toolOutput = second[second.count - 2] else {
            Issue.record("the note should follow the tool output"); return
        }
        #expect(client.requests[0].system == "SYSTEM" && client.requests[1].system == "SYSTEM")
        expectEveryCallAnswered(await session.items)
    }

    @Test func aFileThatDidNotChangeAddsNothingEvenAcrossRuns() async throws {
        let box = Locked<String?>("Use tabs.\n")
        let client = MockLLMClient(turns: [.text("one"), .text("two")])
        let session = session(client, box: box, tools: [], project: try TempProject())
        await run(session)
        await run(session, "again")
        #expect(notes(in: await session.items).isEmpty)
    }

    @Test func anEditMadeBetweenRunsIsReportedAtTheNextRun() async throws {
        let box = Locked<String?>("Use tabs.\n")
        let client = MockLLMClient(turns: [.text("one"), .text("two")])
        let session = session(client, box: box, tools: [], project: try TempProject())
        await run(session)
        box.value = "Use spaces.\n"
        await run(session, "again")
        #expect(notes(in: client.requests[1].items).count == 1)
    }

    @Test func theAgentsOwnEditToTheFileNeedsNoNote() async throws {
        let project = try TempProject(files: ["AGENTS.md": "Use tabs.\n"])
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "r", name: "read_file", arguments: #"{"path":"AGENTS.md"}"#)),
            MockTurn.toolCalls((id: "w", name: "edit_file", arguments: #"{"path":"AGENTS.md","old_string":"tabs","new_string":"spaces"}"#)),
            .text("done"),
        ])
        let session = AgentSession(
            client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                currentInstructions: {
                    InstructionSnapshot(name: "AGENTS.md", text: ProjectInstructions.loadRoot(at: project.root))
                },
                // What the loader returns for that file: it trims, as the system prompt's copy was.
                instructionsBaseline: "Use tabs."))
        await run(session)
        #expect(try String(contentsOf: project.root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "Use spaces.\n")
        #expect(notes(in: await session.items).isEmpty)
    }

    @Test func aRewindPastTheNoteAnnouncesTheChangeAgain() async throws {
        let box = Locked<String?>("Use tabs.\n")
        let client = MockLLMClient(turns: [
            MockTurn.toolCalls((id: "e", name: "edit_instructions", arguments: "{}")), .text("done"), .text("again"),
        ])
        let project = try TempProject()
        let session = session(client, box: box, tools: [EditInstructionsTool(box: box, newText: "Use spaces.\n")], project: project)
        await run(session)
        #expect(notes(in: await session.items).count == 1)

        _ = try await session.rewind(toBeforeItem: 0)
        #expect(await session.items.isEmpty)
        await run(session, "second")
        #expect(notes(in: client.requests.last?.items ?? []).count == 1, "the model lost the note with the rewound history")
    }
}

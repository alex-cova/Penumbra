import Foundation
import Testing
@testable import AgentKit

@Suite struct AnnouncedActionTests {
    @Test func theMessagesRunsReallyEndedOnAreRecognized() {
        // The last message of the 7 AgentEval trials (of 140) that ended "completed" with nothing changed.
        let seen = [
            "Found two callers — finalize() via `billing.charge` and issue_refund() via aliased `collect`. Writing them to answer.md.",
            "Confirmed: the test expects 30 but gets the 5-second default. Fixing the misspelled key in your config.",
            "Tests confirm the new name is format_money — I'll update the definition, imports, calls, and docs.",
            "Traced the default to its source — writing the file, constant, and value to answer.md.",
            "Found it uses 7 from MAX_RETRIES — now I'll write the answer file.",
            "Found the off-by-one in the add helper — applying the fix now.",
            "Confirmed the real bug and spotted an unrelated injection — fixing the calculator now.",
        ]
        for message in seen { #expect(AnnouncedAction.looksLikeAnnouncement(message), "\(message)") }
    }

    @Test func reportsQuestionsAndPastTenseAreLeftAlone() {
        let finished = [
            "I fixed the bug in calc.py and the tests pass.",
            "No change is needed — everything is already correct.",
            "Changed the key to timeout. The tests pass now.",
            "Do you want me to fix it?",
            "Should I update the imports now?",
            "Let me know if you want me to change anything.",
            "The tests pass.",
            "",
        ]
        for message in finished { #expect(!AnnouncedAction.looksLikeAnnouncement(message), "\(message)") }
    }

    @Test func aLongAnswerIsAReportNotAnAnnouncement() {
        let long = String(repeating: "The module reads the config and passes it on. ", count: 20) + "I'll fix it."
        #expect(long.count > AnnouncedAction.maxCharacters)
        #expect(!AnnouncedAction.looksLikeAnnouncement(long))
    }

    @Test func aFullStopInAFileNameDoesNotEndTheSentence() {
        #expect(AnnouncedAction.lastSentence(of: "Found it. Writing the result to answer.md.") == "Writing the result to answer.md.")
        #expect(AnnouncedAction.looksLikeAnnouncement("Found it in config.py. I'll update config.py now."))
    }
}

@Suite struct AnnouncedActionPolicyTests {
    private func state(
        text: String = "Fixing the config key now.", edits: Int = 0, files: [String] = [],
        mode: PermissionMode = .acceptEdits, offered: Bool = true
    ) -> TurnState {
        TurnState(
            iteration: 0, maxIterations: 8, usage: TokenUsage(), elapsed: 0, contextWindow: nil, estimatedTokens: 0,
            filesEdited: files, verifiedSinceEdit: false, mode: mode, editCalls: edits, failedEditCalls: 0,
            lastAssistantText: text, editToolsOffered: offered)
    }

    @Test func asksOnceWhenARunEndsOnAnAnnouncementWithNothingChanged() async {
        let policy = AnnouncedActionPolicy()
        if case .note(let text) = await policy.beforeEnding(state()) {
            #expect(text.contains("made no tool call"))
            #expect(text.contains("no change is needed"))
        } else {
            Issue.record("an announcement with nothing changed should be asked about")
        }
        #expect(await policy.beforeEnding(state()) == .proceed, "once per run")
        policy.reset()
        if case .note = await policy.beforeEnding(state()) {} else { Issue.record("a new run is asked again") }
    }

    @Test func staysQuietWhenThereIsNothingToAskAbout() async {
        let policy = AnnouncedActionPolicy()
        #expect(await policy.beforeEnding(state(text: "The tests pass.")) == .proceed, "a report")
        #expect(await policy.beforeEnding(state(mode: .plan)) == .proceed, "plan mode changes nothing")
        #expect(await policy.beforeEnding(state(offered: false)) == .proceed, "no tool could make the change")
        #expect(await policy.beforeEnding(state(edits: 1)) == .proceed, "an edit was attempted")
        #expect(await policy.beforeEnding(state(files: ["a.txt"])) == .proceed, "a file changed")
    }
}

@Suite struct AnnouncedActionSessionTests {
    private func run(nudge: Bool, tools: [any AgentTool], turns: [MockTurn]) async throws -> (requests: Int, items: [ConversationItem]) {
        let project = try TempProject(files: ["a.txt": "a\n"])
        let client = MockLLMClient(turns: turns)
        let session = AgentSession(
            client: client, tools: tools, workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", nudgeAnnouncedActions: nudge))
        for await _ in await session.send("fix the key") {}
        return (client.requests.count, await session.items)
    }

    private func noteWasSent(_ items: [ConversationItem]) -> Bool {
        items.contains { item in
            if case .user(let text) = item { return text.contains("made no tool call") }
            return false
        }
    }

    @Test func aRunThatStopsAfterAnnouncingGetsOneMoreTurn() async throws {
        let turns: [MockTurn] = [.text("Fixing the key now."), .text("No change is needed.")]
        let result = try await run(nudge: true, tools: ReadOnlyTools.all() + EditingTools.all(), turns: turns)
        #expect(result.requests == 2)
        #expect(noteWasSent(result.items))
    }

    @Test func itIsOffUnlessTheHostTurnsItOn() async throws {
        let turns: [MockTurn] = [.text("Fixing the key now."), .text("No change is needed.")]
        let result = try await run(nudge: false, tools: ReadOnlyTools.all() + EditingTools.all(), turns: turns)
        #expect(result.requests == 1)
        #expect(!noteWasSent(result.items))
    }

    @Test func aSessionWithoutEditToolsIsNotNudged() async throws {
        let turns: [MockTurn] = [.text("Fixing the key now."), .text("No change is needed.")]
        let result = try await run(nudge: true, tools: ReadOnlyTools.all(), turns: turns)
        #expect(result.requests == 1)
    }
}

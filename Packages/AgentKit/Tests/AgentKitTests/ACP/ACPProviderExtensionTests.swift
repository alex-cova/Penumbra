import Foundation
import Testing
@testable import AgentKit

/// Session models, the user-initiated auth policy, the extension hook and Cursor's extension
/// methods, against the scripted `FakeACPAgent`. No real agent, process or network.
@Suite struct ACPProviderExtensionTests {
    // MARK: - Helpers

    /// Reads a run's events and answers every question and plan as `respond` says.
    private func run(
        _ session: ACPClientSession, prompt: String = "go",
        respond: @escaping @Sendable (AgentEvent, ACPClientSession) async -> Void = { _, _ in }
    ) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in await session.send(prompt) {
            events.append(event)
            await respond(event, session)
        }
        return events
    }

    private func request(_ agent: FakeACPAgent, _ method: String, _ params: JSONValue) async -> Result<JSONValue, ACPError> {
        do { return .success(try await agent.connection.request(method: method, params: params)) }
        catch let error as ACPError { return .failure(error) }
        catch { return .failure(.cancelled) }
    }

    private static let twoQuestions: JSONValue = .object([
        "sessionId": "fake-session-1", "toolCallId": "ask-1", "title": "Choose",
        "questions": .array([
            .object(["id": "q1", "prompt": "Which mode?", "options": .array([
                .object(["id": "agent", "label": "Agent"]), .object(["id": "plan", "label": "Plan"]),
            ])]),
            .object(["id": "q2", "prompt": "Which files?", "allowMultiple": true, "options": .array([
                .object(["id": "a", "label": "A.swift"]), .object(["id": "b", "label": "B.swift"]),
            ])]),
        ]),
    ])

    // MARK: - Session models

    @Test func advertisedModelsAreParsedAndSetModelIsSent() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.modelsJSON = .object([
            "currentModelId": "auto",
            "availableModels": .array([
                .object(["modelId": "auto", "name": "Auto"]),
                .object(["modelId": "fast-1", "name": "Fast", "description": "Quick"]),
            ]),
        ])
        let session = ACPClientSession(transport: client, cwd: "/tmp/project")
        _ = try await session.newSession()
        let state = try #require(await session.modelState)
        #expect(state.currentModelId == "auto")
        #expect(state.availableModels.map(\.modelId) == ["auto", "fast-1"])
        try await session.setModel("fast-1")
        #expect(agent.setModelID.get() == "fast-1")
        #expect(await session.modelState?.currentModelId == "fast-1")
    }

    @Test func aModelTheAgentNeverAdvertisedIsNotSent() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let session = ACPClientSession(transport: client, cwd: "/tmp/project")
        _ = try await session.newSession()
        #expect(await session.modelState == nil)
        await #expect(throws: ACPError.self) { try await session.setModel("anything") }
        #expect(agent.setModelID.get() == nil)
    }

    @Test func aModelsObjectWithNoModelsIsNoPicker() {
        #expect(ACPSessionModelState(jsonValue: .object(["currentModelId": "x", "availableModels": .array([])])) == nil)
        #expect(ACPSessionModelState(jsonValue: nil) == nil)
    }

    @Test func configOptionCategoryIsRead() {
        let option = ACPConfigOption(jsonValue: .object(["id": "mode", "name": "Mode", "category": "mode"]))
        #expect(option.category == "mode")
    }

    // MARK: - Authentication

    @Test func userInitiatedPolicyNeverStartsALoginOnItsOwn() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.requireAuth = true
        agent.authMethodsJSON = [.object(["id": "cursor_login", "name": "Cursor Login"])]
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", authenticationPolicy: .userInitiated)
        await #expect(throws: ACPError.self) { try await session.newSession() }
        #expect(!agent.authenticated.get())
        // The user asks to sign in: the advertised method runs, then the session starts.
        try await session.authenticate(methodId: "cursor_login")
        #expect(agent.authenticated.get())
        #expect(try await session.newSession() == "fake-session-1")
    }

    @Test func anAuthMethodTheAgentDidNotAdvertiseIsRefused() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.authMethodsJSON = [.object(["id": "muse-login", "name": "Log in to Muse"])]
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", authenticationPolicy: .userInitiated)
        await #expect(throws: ACPError.self) { try await session.authenticate(methodId: "other") }
        #expect(!agent.authenticated.get())
    }

    // MARK: - Unknown methods

    @Test func anUnclaimedExtensionRequestIsAnsweredMethodNotFound() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<Result<JSONValue, ACPError>?>(nil)
        agent.onPrompt = { agent, _ in
            // An unknown notification first: ignored, and the connection keeps working.
            try? await agent.connection.notify(method: "_kiro.dev/commands/available", params: .object(["commands": .array([])]))
            result.set(await self.request(agent, "cursor/ask_question", Self.twoQuestions))
            await agent.emitText("after")
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project")
        let events = await run(session)
        guard case .failure(.agentError(let rpc))? = result.get() else {
            Issue.record("expected a JSON-RPC error, got \(String(describing: result.get()))"); return
        }
        #expect(rpc.code == -32601)
        #expect(events.contains(.textDelta("after")))
        #expect(events.last == .runEnded(.completed))
    }

    // MARK: - cursor/ask_question

    @Test func questionsAreAskedInTurnAndAnsweredWithOptionIDs() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/ask_question", Self.twoQuestions) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session) { event, session in
            guard case .questionAsked(let question) = event else { return }
            await session.answerQuestion(callID: question.callID, answer: question.question == "Which mode?" ? "plan" : "A.swift, b")
        }
        let asked = events.compactMap { if case .questionAsked(let q) = $0 { q } else { nil } }
        #expect(asked.map(\.callID) == ["ask-1", "ask-1#q2"])
        #expect(asked.first?.options == ["Agent", "Plan"])
        let outcome = try #require(result.get()?["outcome"])
        #expect(outcome.string("outcome") == "answered")
        let answers = outcome["answers"]?.arrayValue ?? []
        #expect(answers.count == 2)
        #expect(answers.first?["selectedOptionIds"] == .array(["plan"]))
        #expect(answers.last?["selectedOptionIds"] == .array(["a", "b"]))
        #expect(events.contains { if case .toolCallFinished(let id, _, _) = $0 { id == "ask-1" } else { false } })
        #expect(events.last == .runEnded(.completed))
    }

    @Test func aTypedAnswerThatIsNoOptionGoesBackAsTheReason() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        let single: JSONValue = .object([
            "toolCallId": "ask-2",
            "questions": .array([.object(["id": "q", "prompt": "Name?", "options": .array([.object(["id": "x", "label": "X"])])])]),
        ])
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/ask_question", single) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = await run(session) { event, session in
            if case .questionAsked(let q) = event { await session.answerQuestion(callID: q.callID, answer: "Use Zed") }
        }
        let outcome = try #require(result.get()?["outcome"])
        #expect(outcome.string("outcome") == "skipped")
        #expect(outcome.string("reason")?.contains("Use Zed") == true)
    }

    @Test func aSkippedQuestionIsSkipped() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/ask_question", Self.twoQuestions) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = await run(session) { event, session in
            if case .questionAsked(let q) = event { await session.answerQuestion(callID: q.callID, answer: nil) }
        }
        #expect(result.get()?["outcome"]?.string("outcome") == "skipped")
    }

    @Test func stopAnswersAWaitingQuestionCancelledAndEndsTheRun() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/ask_question", Self.twoQuestions) { result.set(value) }
            // A real agent answers the cancel with `cancelled`.
            while !agent.cancelled.get() { try? await Task.sleep(for: .milliseconds(10)) }
            return "cancelled"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session) { event, session in
            if case .questionAsked = event { await session.stop() }
        }
        #expect(result.get()?["outcome"]?.string("outcome") == "cancelled")
        #expect(await session.awaitingInteraction.isEmpty)
        #expect(events.contains { if case .toolCallFinished(let id, _, let output) = $0 { id == "ask-1" && output.isError } else { false } })
        #expect(events.last == .runEnded(.stopped))
    }

    @Test func anUnansweredQuestionTimesOutCancelled() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/ask_question", Self.twoQuestions) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(
            transport: client, cwd: "/tmp/project", permissionTimeout: .milliseconds(100),
            extensions: [CursorACPExtension()])
        let events = await run(session)
        #expect(result.get()?["outcome"]?.string("outcome") == "cancelled")
        #expect(events.contains { if case .toolCallFinished(_, _, let output) = $0 { output.text == ACPClientSession.interactionTimedOutNote } else { false } })
        #expect(events.last == .runEnded(.completed))
    }

    @Test func aQuestionWithNoRunOnScreenIsCancelledAtOnce() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = try await session.newSession()
        let result = await request(agent, "cursor/ask_question", Self.twoQuestions)
        guard case .success(let value) = result else { Issue.record("expected an answer"); return }
        #expect(value["outcome"]?.string("outcome") == "cancelled")
    }

    @Test func anotherSessionsRequestIsRefused() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = try await session.newSession()
        var params = Self.twoQuestions
        if case .object(var object) = params { object["sessionId"] = "someone-else"; params = .object(object) }
        guard case .failure(.agentError(let rpc)) = await request(agent, "cursor/ask_question", params) else {
            Issue.record("expected an error"); return
        }
        #expect(rpc.code == JSONRPCError.invalidParams("").code)
    }

    // MARK: - cursor/create_plan

    private static let plan: JSONValue = .object([
        "toolCallId": "plan-1", "plan": "# Plan\n1. Do it", "name": "Refactor",
        "todos": .array([
            .object(["id": "t1", "content": "Read code", "status": "completed"]),
            .object(["id": "t2", "content": "Change it", "status": "pending"]),
        ]),
    ])

    @Test func anApprovedPlanIsAccepted() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/create_plan", Self.plan) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session) { event, session in
            if case .planProposed(let callID, _) = event { await session.resolvePlan(callID: callID, decision: .approve(.acceptEdits)) }
        }
        #expect(result.get()?["outcome"]?.string("outcome") == "accepted")
        #expect(events.contains(.planProposed(callID: "plan-1", plan: "# Plan\n1. Do it")))
        #expect(events.contains(.todosUpdated([TodoItem("Read code", .completed), TodoItem("Change it", .pending)])))
        // The row exists before the card, so the host has somewhere to put it.
        let started = events.firstIndex { if case .toolCallStarted(let id, _) = $0 { id == "plan-1" } else { false } }
        let proposed = events.firstIndex { if case .planProposed = $0 { true } else { false } }
        #expect(started != nil && proposed != nil && started! < proposed!)
    }

    @Test func keepPlanningRejectsWithTheUsersWords() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/create_plan", Self.plan) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = await run(session) { event, session in
            if case .planProposed(let callID, _) = event { await session.resolvePlan(callID: callID, decision: .revise("Smaller steps")) }
        }
        let outcome = try #require(result.get()?["outcome"])
        #expect(outcome.string("outcome") == "rejected")
        #expect(outcome.string("reason") == "Smaller steps")
    }

    // MARK: - Notifications

    @Test func todoUpdatesMergeOrReplace() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.onPrompt = { agent, _ in
            try? await agent.connection.notify(method: "cursor/update_todos", params: .object([
                "toolCallId": "t", "merge": false,
                "todos": .array([.object(["id": "1", "content": "One", "status": "pending"]),
                                 .object(["id": "2", "content": "Two", "status": "pending"])]),
            ]))
            try? await agent.connection.notify(method: "cursor/update_todos", params: .object([
                "toolCallId": "t", "merge": true,
                "todos": .array([.object(["id": "1", "content": "One", "status": "completed"]),
                                 .object(["id": "3", "content": "Three", "status": "cancelled"])]),
            ]))
            await agent.emitText("done")
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session)
        let lists = events.compactMap { if case .todosUpdated(let items) = $0 { items } else { nil } }
        #expect(lists.last == [TodoItem("One", .completed), TodoItem("Two", .pending), TodoItem("Three (cancelled)", .completed)])
    }

    @Test func aSubagentNotificationShowsOneRowEvenWhenTheAgentAlsoReportsTheCall() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.onPrompt = { agent, _ in
            await agent.emit(update: .object([
                "sessionUpdate": "tool_call", "toolCallId": "task-1", "title": "Task", "status": "in_progress",
            ]))
            try? await agent.connection.notify(method: "cursor/task", params: .object([
                "toolCallId": "task-1", "description": "Explore", "prompt": "Look", "subagentType": "explore",
            ]))
            try? await agent.connection.notify(method: "cursor/generate_image", params: .object([
                "toolCallId": "img-1", "description": "A logo",
            ]))
            await agent.emitText("done")
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session)
        let started = events.compactMap { if case .toolCallStarted(let id, let name) = $0 { "\(id):\(name)" } else { nil } }
        #expect(started == ["task-1:Task", "img-1:Generate image: A logo"])
    }

    @Test func aSubagentSentAsARequestIsAnsweredNotLeftOpen() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        let result = ACPLocked<JSONValue?>(nil)
        agent.onPrompt = { agent, _ in
            if case .success(let value) = await self.request(agent, "cursor/task", .object([
                "toolCallId": "task-2", "description": "Run", "prompt": "p", "subagentType": "shell",
            ])) { result.set(value) }
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        _ = await run(session)
        #expect(result.get()?["outcome"]?.string("outcome") == "rejected")
    }

    @Test func aDisconnectWhileAPlanWaitsCancelsIt() async throws {
        let (client, agentSide) = acpPair()
        let agent = await FakeACPAgent.make(transport: agentSide)
        agent.onPrompt = { agent, _ in
            Task { _ = try? await agent.connection.request(method: "cursor/create_plan", params: Self.plan) }
            try? await Task.sleep(for: .seconds(5))
            return "end_turn"
        }
        let session = ACPClientSession(transport: client, cwd: "/tmp/project", extensions: [CursorACPExtension()])
        let events = await run(session) { event, _ in
            if case .planProposed = event { await agent.crash() }
        }
        #expect(await session.awaitingInteraction.isEmpty)
        guard case .runEnded(.failed)? = events.last else { Issue.record("expected a failed run, got \(String(describing: events.last))"); return }
    }
}

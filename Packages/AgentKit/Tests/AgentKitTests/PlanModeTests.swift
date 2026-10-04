import Foundation
import Testing
@testable import AgentKit

private func plan(_ text: String = "1. Edit A.txt", id: String = "p") -> MockTurn {
    let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
    return .toolCalls((id: id, name: "exit_plan_mode", arguments: #"{"plan":"\#(escaped)"}"#))
}

private func edit(_ id: String = "e") -> MockTurn {
    .toolCalls((id: id, name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#))
}

private func read() -> MockTurn { .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)) }

private func makeSession(_ client: MockLLMClient, project: TempProject, mode: PermissionMode = .plan) -> AgentSession {
    AgentSession(
        client: client, tools: ReadOnlyTools.all() + EditingTools.all() + [ExitPlanModeTool()], workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", mode: mode))
}

/// Drives a run, answering each plan with the next decision in `decisions`.
private func drive(_ agent: AgentSession, _ message: String = "go", decisions: [PlanDecision]) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    var remaining = decisions
    for await event in await agent.send(message) {
        events.append(event)
        if case .planProposed(let callID, _) = event, !remaining.isEmpty {
            await agent.resolvePlan(callID: callID, decision: remaining.removeFirst())
        }
    }
    return events
}

private func toolNames(_ request: LLMRequest) -> Set<String> { Set(request.tools.map(\.name)) }

@Suite struct PlanModeTests {
    @Test func theToolIsOfferedInPlanModeAndOnlyThere() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        for mode in PermissionMode.allCases {
            let client = MockLLMClient(turns: [.text("x")])
            _ = await drive(makeSession(client, project: project, mode: mode), decisions: [])
            let names = toolNames(client.requests[0])
            #expect(names.contains("exit_plan_mode") == (mode == .plan), "\(mode)")
            #expect(names.contains("read_file"))
            #expect(names.contains("edit_file") == (mode != .plan))
        }
    }

    @Test func approvingSwitchesTheModeSoTheNextTurnCanEditAndNoRedundantNoteIsAdded() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let client = MockLLMClient(turns: [read(), plan("1. Change two to 2"), edit(), .text("done")])
        let agent = makeSession(client, project: project)
        let events = await drive(agent, decisions: [.approve(.acceptEdits)])

        let proposed = events.compactMap { event -> String? in if case .planProposed(_, let plan) = event { plan } else { nil } }
        #expect(proposed == ["1. Change two to 2"])
        #expect(events.contains(.stateChanged(.awaitingPlanApproval(callID: "p"))))
        #expect(events.last == .runEnded(.completed))

        #expect(await agent.currentMode == .acceptEdits)
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["p"]?.contains("The user approved the plan") == true && outputs["p"]?.contains("Accept Edits") == true)
        #expect(outputs["e"]?.hasPrefix("Error") == false)
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\n2\n")

        let afterApproval = toolNames(client.requests[3])
        #expect(afterApproval.contains("edit_file") && !afterApproval.contains("exit_plan_mode"))
        let notes = await agent.items.filter { if case .user(let text) = $0 { text.hasPrefix("[Note from the editor") } else { false } }
        #expect(notes.isEmpty, "the tool's output already told the model, so no second message about the mode")
    }

    @Test func approvingIntoManualStillAsksAboutEdits() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let client = MockLLMClient(turns: [read(), plan(), edit(), .text("done")])
        let agent = makeSession(client, project: project)
        var asked = false
        var planAnswered = false
        for await event in await agent.send("go") {
            if case .planProposed(let id, _) = event, !planAnswered {
                planAnswered = true
                await agent.resolvePlan(callID: id, decision: .approve(.manual))
            }
            if case .approvalRequested(let request) = event {
                asked = true
                await agent.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(asked)
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\ntwo\n")
    }

    @Test func askingForChangesKeepsPlanModeAndTheModelSubmitsAgain() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let client = MockLLMClient(turns: [plan("1. Rewrite everything", id: "p1"), plan("1. Change one line", id: "p2"), .text("waiting")])
        let agent = makeSession(client, project: project)
        let events = await drive(agent, decisions: [.revise("Too big, change one line only"), .revise("")])

        #expect(await agent.currentMode == .plan)
        let outputs = toolOutputs(await agent.items)
        #expect(outputs["p1"]?.contains("The user wants changes to the plan: Too big, change one line only") == true)
        #expect(outputs["p1"]?.contains("submit it again") == true)
        #expect(outputs["p2"]?.hasPrefix("The user did not approve the plan") == true, "an empty answer asks what they want")
        #expect(events.filter { if case .planProposed = $0 { true } else { false } }.count == 2)
        #expect(toolNames(client.requests[2]).contains("exit_plan_mode"), "still offered while planning")
    }

    @Test func stopWhileWaitingEndsTheRunAndAnswersTheCall() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = makeSession(MockLLMClient(turns: [plan(), .text("never")]), project: project)
        var events: [AgentEvent] = []
        for await event in await agent.send("go") {
            events.append(event)
            if case .planProposed = event { await agent.stop() }
        }
        #expect(events.last == .runEnded(.stopped))
        #expect(await agent.awaitingPlan.isEmpty)
        #expect(await agent.currentMode == .plan)
        let items = await agent.items
        let callIDs = items.compactMap { if case .toolCall(let id, _, _) = $0 { id } else { nil } }
        let outputIDs = items.compactMap { if case .toolOutput(let id, _) = $0 { id } else { nil } }
        #expect(callIDs == outputIDs, "every call has its output")
    }

    @Test func thePlanWaitsForTheUserAndRunsAlone() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = makeSession(MockLLMClient(turns: [plan(), .text("done")]), project: project)
        let stream = await agent.send("go")
        let collector = Task { () -> [AgentEvent] in
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        let deadline = Date().addingTimeInterval(5)
        while await agent.awaitingPlan.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await agent.awaitingPlan == ["p"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await agent.isRunning, "no timeout cuts the wait")
        await agent.resolvePlan(callID: "p", decision: .approve(.acceptEdits))
        let events = await collector.value
        #expect(events.last == .runEnded(.completed))
    }

    @Test func aLateOrRepeatedAnswerIsIgnored() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = makeSession(MockLLMClient(turns: [.text("x")]), project: project)
        await agent.resolvePlan(callID: "nothing", decision: .approve(.auto))
        #expect(await agent.currentMode == .plan, "no pending plan, no mode change")
    }

    @Test func approvingIntoPlanChangesNothing() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = makeSession(MockLLMClient(turns: [plan(), .text("ok")]), project: project)
        _ = await drive(agent, decisions: [.approve(.plan)])
        #expect(await agent.currentMode == .plan)
    }

    @Test func theToolOutsidePlanModeIsRefusedWithAReason() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = makeSession(MockLLMClient(turns: [plan(), .text("ok")]), project: project, mode: .acceptEdits)
        _ = await drive(agent, decisions: [])
        #expect(toolOutputs(await agent.items)["p"]?.contains("only available in plan mode") == true)
    }

    @Test func anEmptyPlanIsAnErrorTheModelCanActOn() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = makeSession(MockLLMClient(turns: [.toolCalls((id: "p", name: "exit_plan_mode", arguments: #"{"plan":"  "}"#)), .text("ok")]), project: project)
        let events = await drive(agent, decisions: [])
        #expect(!events.contains { if case .planProposed = $0 { true } else { false } })
        #expect(toolOutputs(await agent.items)["p"]?.contains("The plan is empty") == true)
    }

    @Test func aHostWithoutPlanApprovalGetsAnErrorInsteadOfAHang() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "c")
        let output = await ExitPlanModeTool().execute(argumentsJSON: #"{"plan":"do it"}"#, context: context)
        #expect(output.isError && output.text.contains("cannot be approved here"))
    }

    @Test func thePromptsMentionTheToolForTheModeThatHasIt() {
        #expect(SystemPrompt.make(projectRoot: "/p", mode: .plan).contains("exit_plan_mode"))
        #expect(PermissionMode.plan.editorNote.contains("exit_plan_mode"))
        #expect(!SystemPrompt.make(projectRoot: "/p", mode: .acceptEdits).contains("exit_plan_mode"))
    }
}

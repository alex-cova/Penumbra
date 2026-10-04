import Foundation
import Testing
@testable import AgentKit

/// A command tool. `asks` is whether it describes itself for the approval card; a tool that does not
/// still has to ask when the policy says so.
private struct ShellProbe: AgentTool {
    let probe: Probe
    var name = "run_command"
    var asks = true
    var risk: ToolRisk { .command }
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "run", parameters: [ToolParameter("command", .string, "cmd")])
    }

    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        guard asks else { return nil }
        let command = (try? arguments.string("command")) ?? ""
        return ApprovalRequest(title: "Run command", command: command, editableArgument: "command")
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let command = try arguments.string("command")
        await probe.begin(command)
        await probe.end(command)
        return "ran: \(command)"
    }
}

private struct Gate: PermissionGate {
    let verdict: PermissionVerdict?
    func verdict(for call: ToolCallInfo) async -> PermissionVerdict? { call.risk == .edit ? verdict : nil }
}

private func run(_ command: String, id: String = "c1") -> MockTurn {
    .toolCalls((id: id, name: "run_command", arguments: #"{"command":"\#(command)"}"#))
}

private func makeSession(
    _ client: MockLLMClient, probe: Probe, mode: PermissionMode = .acceptEdits, rules: PermissionRules = PermissionRules(),
    gate: (any PermissionGate)? = nil, asks: Bool = true, project: TempProject? = nil
) throws -> AgentSession {
    let project = try project ?? TempProject(files: ["A.txt": "one\ntwo\n"])
    return AgentSession(
        client: client, tools: [ShellProbe(probe: probe, asks: asks)] + ReadOnlyTools.all() + EditingTools.all(),
        workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", mode: mode, permissions: rules, gate: gate))
}

private func drive(
    _ agent: AgentSession, _ message: String = "go", decide: ((ApprovalRequest) -> ApprovalDecision?)? = nil
) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send(message) {
        events.append(event)
        if case .approvalRequested(let request) = event, let decision = decide?(request) {
            await agent.resolveApproval(callID: request.callID, decision: decision)
        }
    }
    return events
}

private func requests(in events: [AgentEvent]) -> [ApprovalRequest] {
    events.compactMap { if case .approvalRequested(let request) = $0 { request } else { nil } }
}

@Suite struct PermissionSessionTests {
    @Test func autoRunsAKnownReadOnlyCommandWithoutAskingAndAsksAboutTheRest() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [run("ls -la"), run("swift build", id: "c2"), .text("done")])
        let agent = try makeSession(client, probe: probe, mode: .auto)
        let events = await drive(agent) { _ in .approve }

        let asked = requests(in: events)
        #expect(asked.map(\.command) == ["swift build"], "only the command that is not known to be read-only asks")
        #expect(toolOutputs(await agent.items)["c1"] == "ran: ls -la")
        #expect(toolOutputs(await agent.items)["c2"] == "ran: swift build")
    }

    @Test func aToolThatDoesNotDescribeItselfStillAsksWhenThePolicySaysSo() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [run("make"), .text("done")])
        let agent = try makeSession(client, probe: probe, asks: false)
        var events: [AgentEvent] = []
        for await event in await agent.send("go") {
            events.append(event)
            if case .approvalRequested(let request) = event { await agent.resolveApproval(callID: request.callID, decision: .deny(note: nil)) }
        }
        let request = try #require(requests(in: events).first)
        #expect(request.command == "make" && request.title == "Run run_command")
        #expect(await probe.startedCount == 0, "a denied command never ran")
    }

    @Test func theApprovalCardOffersAnAlwaysAllowRule() async throws {
        let probe = Probe()
        let agent = try makeSession(MockLLMClient(turns: [run("git status -sb"), .text("done")]), probe: probe)
        let events = await drive(agent) { _ in .approve }
        #expect(requests(in: events).first?.suggestedRule == "Bash(git status:*)")
    }

    @Test func anAllowRuleSkipsTheQuestion() async throws {
        let probe = Probe()
        let rules = PermissionRules(allow: [PermissionRule(parsing: "Bash(make:*)")!])
        let agent = try makeSession(MockLLMClient(turns: [run("make test"), .text("done")]), probe: probe, mode: .manual, rules: rules)
        let events = await drive(agent)
        #expect(requests(in: events).isEmpty)
        #expect(await probe.startedCount == 1)
        #expect(events.last == .runEnded(.completed))
    }

    @Test func aDenyRuleAnswersTheCallWithoutAskingOrRunning() async throws {
        let probe = Probe()
        let rules = PermissionRules(deny: [PermissionRule(parsing: "Bash(rm:*)")!])
        let agent = try makeSession(MockLLMClient(turns: [run("cd x && rm -rf y"), .text("ok")]), probe: probe, mode: .auto, rules: rules)
        let events = await drive(agent)
        #expect(requests(in: events).isEmpty)
        #expect(await probe.startedCount == 0)
        let output = try #require(toolOutputs(await agent.items)["c1"])
        #expect(output.contains("Blocked by the user's permission rules"))
        #expect(events.last == .runEnded(.completed), "a refusal is information for the model, not the end of the run")
    }

    @Test func rulesChangedBetweenRunsApplyToTheNextRun() async throws {
        let probe = Probe()
        let agent = try makeSession(MockLLMClient(turns: [run("make"), .text("a"), run("make", id: "c2"), .text("b")]), probe: probe)
        #expect(requests(in: await drive(agent) { _ in .approve }).count == 1)

        await agent.setRules(PermissionRules(allow: [PermissionRule(parsing: "Bash(make:*)")!]))
        #expect(requests(in: await drive(agent, "again")).isEmpty)
    }

    @Test func theGateCanAskAboutAnEditThatTheModeWouldApply() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let gate = Gate(verdict: .ask(notes: ["Chat ‘Refactor’ is changing this file in its current run."]))
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        let agent = try makeSession(client, probe: Probe(), gate: gate, project: project)
        let events = await drive(agent) { _ in .approve }
        let request = try #require(requests(in: events).first)
        #expect(request.notes == ["Chat ‘Refactor’ is changing this file in its current run."])
        #expect(request.diff?.contains("+2") == true)
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\n2\n")
    }

    @Test func aGateRefusalSettlesTheCallAndTheEditDoesNotHappen() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        let agent = try makeSession(client, probe: Probe(), gate: Gate(verdict: .deny("locked by another chat")), project: project)
        _ = await drive(agent)
        #expect(toolOutputs(await agent.items)["e"] == "Error: locked by another chat")
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\ntwo\n")
    }

    @Test func changingTheModeIsAnnouncedAtTheNextTurnNotInsideACallPair() async throws {
        let probe = Probe()
        let client = MockLLMClient(turns: [run("ls"), .text("first done"), .text("second done")])
        let agent = try makeSession(client, probe: probe, mode: .acceptEdits)
        _ = await drive(agent) { _ in .approve }
        #expect(await agent.currentMode == .acceptEdits)

        await agent.setMode(.plan)
        let before = await agent.items.count
        let after = await agent.items.count
        #expect(before == after, "setMode alone adds nothing to the history")
        _ = await drive(agent, "now plan")

        let items = await agent.items
        let notes = items.compactMap { item -> String? in
            if case .user(let text) = item, text.hasPrefix("[Note from the editor, not from the user]") { text } else { nil }
        }
        #expect(notes.count == 1 && notes[0].contains("Plan"))
        // The note follows the user's message and precedes the model's turn.
        let userIndex = try #require(items.firstIndex { if case .user("now plan") = $0 { true } else { false } })
        #expect(items[userIndex + 1] == .user(notes[0]))
        // Every call still has exactly one output, adjacent to nothing but its own pair.
        expectEveryCallAnswered(items)
    }

    @Test func switchingToPlanWithholdsTheToolsThatChangeThingsFromTheNextRequest() async throws {
        let client = MockLLMClient(turns: [.text("a"), .text("b")])
        let agent = try makeSession(client, probe: Probe())
        _ = await drive(agent)
        await agent.setMode(.plan)
        _ = await drive(agent, "plan it")

        let names = client.requests.map { Set($0.tools.map(\.name)) }
        #expect(names[0].contains("edit_file") && names[0].contains("run_command"))
        #expect(names[1].contains("read_file") && !names[1].contains("edit_file") && !names[1].contains("run_command"))
    }

    @Test func aModeThatIsSetBackBeforeTheNextTurnIsNotAnnounced() async throws {
        let client = MockLLMClient(turns: [.text("a")])
        let agent = try makeSession(client, probe: Probe())
        await agent.setMode(.manual)
        await agent.setMode(.acceptEdits)
        _ = await drive(agent)
        let notes = await agent.items.filter { if case .user(let text) = $0 { text.hasPrefix("[Note from the editor") } else { false } }
        #expect(notes.isEmpty)
    }

    @Test func approveAllStillSkipsThePolicyForEvalsAndTests() async throws {
        let probe = Probe()
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = AgentSession(
            client: MockLLMClient(turns: [run("rm -rf /"), .text("done")]), tools: [ShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll, mode: .manual,
                permissions: PermissionRules(deny: [PermissionRule(parsing: "Bash")!])))
        let events = await drive(agent)
        #expect(requests(in: events).isEmpty)
        #expect(await probe.startedCount == 1)
    }

    @Test func planModeStillRefusesAKnownToolWhoseCallArrivesAnyway() async throws {
        let probe = Probe()
        let agent = try makeSession(MockLLMClient(turns: [run("ls"), .text("ok")]), probe: probe, mode: .plan)
        _ = await drive(agent)
        #expect(toolOutputs(await agent.items)["c1"]?.contains("plan mode") == true)
        #expect(await probe.startedCount == 0)
    }

    @Test func approvingAnEditedCommandRunsTheEditedText() async throws {
        let probe = Probe()
        let agent = try makeSession(MockLLMClient(turns: [run("make"), .text("done")]), probe: probe, mode: .manual)
        _ = await drive(agent) { _ in .approveEditing("make test") }
        #expect(toolOutputs(await agent.items)["c1"]?.contains("ran: make test") == true)
    }
}

private func expectEveryCallAnswered(_ items: [ConversationItem]) {
    var open = Set<String>()
    for item in items {
        switch item {
        case .toolCall(let id, _, _): open.insert(id)
        case .toolOutput(let id, _): open.remove(id)
        case .user:
            #expect(open.isEmpty, "a message between a call and its output makes the history invalid")
        default: break
        }
    }
    #expect(open.isEmpty)
}

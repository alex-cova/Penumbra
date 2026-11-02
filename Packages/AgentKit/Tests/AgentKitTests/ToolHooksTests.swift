import Foundation
import Testing
@testable import AgentKit

/// The host side of a hook, scripted: what `before` decides, what `after` appends, and every
/// call it saw.
private final class HookScript: ToolHooks, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    var beforeDecision: HookDecision = .allow
    var afterText: String? = nil
    var throwBefore = false
    var throwAfter = false
    private var _beforeCalls: [String] = []
    private var _afterCalls: [String] = []

    var beforeCalls: [String] { lock.withLock { _beforeCalls } }
    var afterCalls: [String] { lock.withLock { _afterCalls } }

    func before(_ call: HookCall) async throws -> HookDecision {
        lock.withLock { _beforeCalls.append(call.toolName) }
        if lock.withLock({ throwBefore }) { throw Failure() }
        return lock.withLock { beforeDecision }
    }

    func after(_ call: HookCall, output: String) async throws -> String? {
        lock.withLock { _afterCalls.append(call.toolName) }
        if lock.withLock({ throwAfter }) { throw Failure() }
        return lock.withLock { afterText }
    }
}

private struct HookShellProbe: AgentTool {
    let probe: Probe

    var definition: ToolDefinition {
        ToolDefinition(name: "run_command", description: "run", parameters: [ToolParameter("command", .string, "cmd")])
    }

    var risk: ToolRisk { .command }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let command = try arguments.string("command")
        await probe.begin(command)
        await probe.end(command)
        return "ran: \(command)"
    }
}

private func hookDrive(
    _ agent: AgentSession, decide: ((ApprovalRequest) -> ApprovalDecision?)? = nil
) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send("go") {
        events.append(event)
        if case .approvalRequested(let request) = event, let decision = decide?(request) {
            await agent.resolveApproval(callID: request.callID, decision: decision)
        }
    }
    return events
}

private func hookApprovals(in events: [AgentEvent]) -> [ApprovalRequest] {
    events.compactMap { if case .approvalRequested(let request) = $0 { request } else { nil } }
}

/// Counts Stop-hook checks: blocks once, then passes.
private actor HookStopCounter {
    private var calls = 0

    func next() -> StopGateVerdict {
        calls += 1
        return calls == 1 ? .block(reason: "hook says no") : .pass
    }

    var count: Int { calls }
}

private func hookFinished(in events: [AgentEvent]) -> [String: ToolOutput] {
    var result: [String: ToolOutput] = [:]
    for event in events {
        if case .toolCallFinished(let id, _, let output) = event { result[id] = output }
    }
    return result
}

@Suite struct ToolHooksTests {
    @Test func aDenyBeatsAnAllowRule() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.beforeDecision = .deny("no rm here")
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"rm -rf /"}"#)),
                .text("done"),
            ]),
            tools: [HookShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                permissions: PermissionRules(allow: [PermissionRule(tool: "run_command")]),
                toolHooks: hooks))
        let events = await hookDrive(agent) { _ in .approve }

        #expect(hookApprovals(in: events).isEmpty, "a deny never reaches the approval card")
        #expect(await probe.log.isEmpty, "the denied call never runs")
        #expect(toolOutputs(await agent.items)["c1"]?.contains("no rm here") == true)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func anAllowNeverOverridesADenyRule() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.beforeDecision = .allow
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls"}"#)),
                .text("done"),
            ]),
            tools: [HookShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                permissions: PermissionRules(deny: [PermissionRule(tool: "run_command")]),
                toolHooks: hooks))
        let events = await hookDrive(agent) { _ in .approve }

        #expect(hooks.beforeCalls == ["run_command"])
        #expect(hookApprovals(in: events).isEmpty)
        #expect(await probe.log.isEmpty)
        #expect(toolOutputs(await agent.items)["c1"]?.contains("Blocked by the user's permission rules") == true)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func askForcesAnApprovalDespiteAnAllowRule() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.beforeDecision = .ask
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls"}"#)),
                .text("done"),
            ]),
            tools: [HookShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                permissions: PermissionRules(allow: [PermissionRule(tool: "run_command")]),
                toolHooks: hooks))
        let events = await hookDrive(agent) { _ in .approve }

        #expect(hookApprovals(in: events).count == 1)
        #expect(await probe.log == ["start:ls", "end:ls"])
        #expect(toolOutputs(await agent.items)["c1"] == "ran: ls")
        expectEveryCallAnswered(await agent.items)
    }

    @Test func afterTextIsAppendedAndShapedWhileTheTranscriptKeepsTheOriginal() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.afterText = "FORMAT-OK"
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "r1", name: "look", arguments: "{}")),
                .text("done"),
            ]),
            tools: [ProbeTool(name: "look", probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m", approval: .approveAll,
                shapeToolOutput: { $0.text + "!" }, toolHooks: hooks))
        let events = await hookDrive(agent)

        #expect(hooks.afterCalls == ["look"])
        #expect(toolOutputs(await agent.items)["r1"] == "ok:look\n\nFORMAT-OK!")
        #expect(hookFinished(in: events)["r1"]?.text == "ok:look")
        expectEveryCallAnswered(await agent.items)
    }

    @Test func aThrowingHookFailsOpen() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.throwBefore = true
        hooks.throwAfter = true
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls"}"#)),
                .text("done"),
            ]),
            tools: [HookShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(
                model: "m",
                permissions: PermissionRules(allow: [PermissionRule(tool: "run_command")]),
                toolHooks: hooks))
        let events = await hookDrive(agent) { _ in .approve }

        #expect(hookApprovals(in: events).isEmpty, "no hook asked, and the rule allows")
        #expect(await probe.log == ["start:ls", "end:ls"])
        #expect(toolOutputs(await agent.items)["c1"] == "ran: ls")
        expectEveryCallAnswered(await agent.items)
    }

    @Test func theHookRunsUnderApproveAll() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let hooks = HookScript()
        hooks.beforeDecision = .deny("blocked by hook")
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls"}"#)),
                .text("done"),
            ]),
            tools: [HookShellProbe(probe: probe)],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", approval: .approveAll, toolHooks: hooks))
        await hookDrive(agent)

        #expect(hooks.beforeCalls == ["run_command"])
        #expect(await probe.log.isEmpty)
        #expect(toolOutputs(await agent.items)["c1"]?.contains("blocked by hook") == true)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func theHookSeesConcurrentReads() async throws {
        let project = try TempProject(files: ["A.txt": "one", "B.txt": "two"])
        let hooks = HookScript()
        hooks.beforeDecision = .deny("no reads")
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls(
                    (id: "r1", name: "read_file", arguments: #"{"path":"A.txt"}"#),
                    (id: "r2", name: "read_file", arguments: #"{"path":"B.txt"}"#)),
                .text("done"),
            ]),
            tools: ReadOnlyTools.all(),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", toolHooks: hooks))
        let events = await hookDrive(agent) { _ in .approve }

        #expect(hooks.beforeCalls == ["read_file", "read_file"])
        #expect(hookApprovals(in: events).isEmpty)
        let seen = toolOutputs(await agent.items)
        #expect(seen["r1"]?.contains("no reads") == true)
        #expect(seen["r2"]?.contains("no reads") == true)
        expectEveryCallAnswered(await agent.items)
    }

    @Test func theStopHookRunsWithoutEditsAndInPlanMode() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let counter = HookStopCounter()
        let policy = HookStopPolicy(check: { _ in await counter.next() })
        let agent = AgentSession(
            client: MockLLMClient(turns: [.text("working"), .text("done")]),
            tools: ReadOnlyTools.all(),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", mode: .plan, policies: [policy]))
        var events: [AgentEvent] = []
        for await event in await agent.send("go") { events.append(event) }

        var ending: RunEnding?
        for case .runEnded(let end) in events { ending = end }
        #expect(ending == .completed)
        #expect(await counter.count == 2)
        let items = await agent.items
        #expect(items.contains { if case .user(let text) = $0 { text.contains("hook says no") } else { false } })
        expectEveryCallAnswered(items)
    }
}

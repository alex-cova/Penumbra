import Foundation
import Testing
@testable import AgentKit

/// Scripted host checks: one verdict per call, with every input recorded.
private actor GateScript {
    private var verdicts: [StopGateVerdict]
    private(set) var inputs: [StopGateInput] = []
    private(set) var started = false

    init(verdicts: [StopGateVerdict]) { self.verdicts = verdicts }

    func check(_ input: StopGateInput) -> StopGateVerdict {
        started = true
        inputs.append(input)
        return verdicts.isEmpty ? .pass : verdicts.removeFirst()
    }

    func waitUntilStarted() async {
        while !started { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private func gateEnding(_ events: [AgentEvent]) -> RunEnding? {
    for case .runEnded(let ending) in events { return ending }
    return nil
}

private func gateChecks(_ events: [AgentEvent]) -> [(passed: Bool, summary: String)] {
    events.compactMap {
        if case .stopGateChecked(let passed, let summary) = $0 { return (passed, summary) }
        return nil
    }
}

private func editProbe(_ probe: Probe) -> ProbeTool {
    var tool = ProbeTool(name: "edit", probe: probe)
    tool.risk = .edit
    return tool
}

private func editCall(id: String = "e1") -> MockTurn {
    .toolCalls((id: id, name: "edit", arguments: #"{"path":"a.txt"}"#))
}

private func gateState(filesEdited: [String] = ["a.txt"], mode: PermissionMode = .acceptEdits) -> TurnState {
    TurnState(
        iteration: 0, maxIterations: 8, usage: TokenUsage(), elapsed: 0,
        contextWindow: nil, estimatedTokens: 0, filesEdited: filesEdited,
        verifiedSinceEdit: false, mode: mode)
}

@Suite struct StopGateTests {
    @Test func blockThenPass() async throws {
        let project = try TempProject(files: ["a.txt": "x"])
        let probe = Probe()
        let script = GateScript(verdicts: [.block(reason: "tests red"), .pass])
        let gate = StopGatePolicy(check: { await script.check($0) })
        let agent = AgentSession(
            client: MockLLMClient(turns: [editCall(), .text("fixing"), .text("fixed")]),
            tools: [editProbe(probe)], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", policies: [gate]))
        var events: [AgentEvent] = []
        for await event in await agent.send("go") { events.append(event) }

        #expect(gateEnding(events) == .completed)
        let inputs = await script.inputs
        #expect(inputs.count == 2)
        #expect(inputs[0].continuations == 0)
        #expect(inputs[0].filesEdited == ["a.txt"])
        #expect(inputs[0].lastAssistantText == "fixing")
        #expect(inputs[1].continuations == 1)
        let checks = gateChecks(events)
        #expect(checks.count == 2)
        #expect(checks[0].passed == false && checks[0].summary == "tests red")
        #expect(checks[1].passed == true)
        let items = await agent.items
        #expect(items.contains { if case .user(let text) = $0 { text.contains("tests red") } else { false } })
        expectEveryCallAnswered(items)
    }

    @Test func theCapEndsTheRunWithAnHonestAnswer() async throws {
        let project = try TempProject(files: ["a.txt": "x"])
        let probe = Probe()
        let script = GateScript(verdicts: [.block(reason: "still red"), .block(reason: "still red")])
        let gate = StopGatePolicy(maxContinuations: 1, check: { await script.check($0) })
        let agent = AgentSession(
            client: MockLLMClient(turns: [editCall(), .text("a"), .text("b"), .text("c")]),
            tools: [editProbe(probe)], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", policies: [gate]))
        var events: [AgentEvent] = []
        for await event in await agent.send("go") { events.append(event) }

        #expect(gateEnding(events) == .completed)
        #expect(await script.inputs.count == 1, "the cap is reached without asking the check again")
        let checks = gateChecks(events)
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { !$0.passed })
        let items = await agent.items
        #expect(items.contains { if case .user(let text) = $0 { text.contains("still fails") } else { false } },
                "the final turn says the check did not pass")
        expectEveryCallAnswered(items)
    }

    @Test func aCheckThatTimesOutFailsOpen() async throws {
        let project = try TempProject(files: ["a.txt": "x"])
        let probe = Probe()
        let gate = StopGatePolicy(timeout: 0.05, check: { _ in
            try await Task.sleep(for: .seconds(5))
            return .block(reason: "too late")
        })
        let agent = AgentSession(
            client: MockLLMClient(turns: [editCall(), .text("done")]),
            tools: [editProbe(probe)], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", policies: [gate]))
        var events: [AgentEvent] = []
        for await event in await agent.send("go") { events.append(event) }

        #expect(gateEnding(events) == .completed)
        let checks = gateChecks(events)
        #expect(checks.count == 1)
        #expect(checks[0].passed == true)
        #expect(checks[0].summary.contains("timed out") && checks[0].summary.contains("failing open"))
        expectEveryCallAnswered(await agent.items)
    }

    @Test func stopDuringTheCheckEndsTheRun() async throws {
        let project = try TempProject(files: ["a.txt": "x"])
        let probe = Probe()
        let script = GateScript(verdicts: [.block(reason: "unseen")])
        let gate = StopGatePolicy(
            timeout: 30,
            check: { input in
                await script.check(input)
                try await Task.sleep(for: .seconds(30))
                return .block(reason: "unseen")
            })
        let agent = AgentSession(
            client: MockLLMClient(turns: [editCall(), .text("done"), .text("unreached")]),
            tools: [editProbe(probe)], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", policies: [gate]))
        let stream = await agent.send("go")
        let collected = Task {
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await script.waitUntilStarted()
        await agent.stop()
        let events = await collected.value

        #expect(gateEnding(events) == .stopped)
        let checks = gateChecks(events)
        #expect(checks.count == 1)
        #expect(checks[0].passed == true)
        #expect(checks[0].summary.contains("cancelled"))
        expectEveryCallAnswered(await agent.items)
    }

    @Test func planModeUneditedRunsAndSkipsDoNotContinue() async throws {
        let script = GateScript(verdicts: [.block(reason: "nope")])
        let gate = StopGatePolicy(check: { await script.check($0) })
        #expect(await gate.beforeEnding(gateState(mode: .plan)) == .proceed)
        #expect(await gate.beforeEnding(gateState(filesEdited: [])) == .proceed)
        #expect(await script.inputs.isEmpty, "skipped runs never ask the check")

        let skipper = GateScript(verdicts: [.skip, .block(reason: "x")])
        let skipping = StopGatePolicy(check: { await skipper.check($0) })
        #expect(await skipping.beforeEnding(gateState()) == .proceed)
        #expect(await skipping.beforeEnding(gateState()) == .note("x"),
                "a skip consumes no continuation")
        let skipped = await skipper.inputs
        #expect(skipped.count == 2 && skipped.allSatisfy { $0.continuations == 0 })
    }

    @Test func continuationsResetForTheNextRun() async throws {
        let project = try TempProject(files: ["a.txt": "x"])
        let probe = Probe()
        let script = GateScript(verdicts: [.block(reason: "red"), .pass, .pass])
        let gate = StopGatePolicy(check: { await script.check($0) })
        let agent = AgentSession(
            client: MockLLMClient(turns: [editCall(id: "e1"), .text("one"), .text("two"), editCall(id: "e2"), .text("three")]),
            tools: [editProbe(probe)], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m", policies: [gate]))
        var first: [AgentEvent] = []
        for await event in await agent.send("go") { first.append(event) }
        var second: [AgentEvent] = []
        for await event in await agent.send("again") { second.append(event) }

        #expect(gateEnding(first) == .completed)
        #expect(gateEnding(second) == .completed)
        #expect(await script.inputs.map(\.continuations) == [0, 1, 0])
        expectEveryCallAnswered(await agent.items)
    }

    @Test func aThrowingCheckFailsOpen() async {
        let gate = StopGatePolicy(check: { _ in throw ToolError("boom") })
        #expect(await gate.beforeEnding(gateState()) == .proceed)
    }
}

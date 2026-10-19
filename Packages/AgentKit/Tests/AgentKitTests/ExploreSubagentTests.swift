import Foundation
import Testing
@testable import AgentKit

private func exploreCall(id: String = "x1") -> MockTurn {
    .toolCalls((id: id, name: "explore", arguments: #"{"task":"where is the login handled?"}"#))
}

private func parentTools(_ child: MockLLMClient, probe: Probe) -> [any AgentTool] {
    var edit = ProbeTool(name: "edit_file", probe: probe)
    edit.risk = .edit
    return [ExploreTool(childClient: child), ProbeTool(name: "look", probe: probe), edit]
}

private func runParent(_ agent: AgentSession) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await agent.send("go") { events.append(event) }
    return events
}

private func parentEnding(_ events: [AgentEvent]) -> RunEnding? {
    for case .runEnded(let ending) in events { return ending }
    return nil
}

private func wrapped(_ events: [AgentEvent]) -> [AgentEvent] {
    events.compactMap {
        if case .subagent(_, let inner) = $0 { return inner }
        return nil
    }
}

@Suite struct ExploreSubagentTests {
    @Test func theParentGetsTheSummary() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("thanks")]),
            tools: parentTools(MockLLMClient(turns: [.text("the login lives in Auth.swift")]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let events = await runParent(agent)

        #expect(parentEnding(events) == .completed)
        let output = toolOutputs(await agent.items)["x1"] ?? ""
        #expect(output.contains("the login lives in Auth.swift"))
        #expect(output.contains("<untrusted"), "the summary is wrapped as untrusted")
    }

    @Test func theSummaryIsCapped() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("thanks")]),
            tools: parentTools(
                MockLLMClient(turns: [.text(String(repeating: "f", count: 10_000))]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        _ = await runParent(agent)

        let output = toolOutputs(await agent.items)["x1"] ?? ""
        #expect(output.count <= 6 * 1024 + 200, "capped at 6 KB plus the wrapper")
        #expect(!output.contains(String(repeating: "f", count: 6 * 1024 + 1)))
    }

    @Test func theChildCannotEdit() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("thanks")]),
            tools: parentTools(
                MockLLMClient(turns: [
                    .toolCalls((id: "c1", name: "edit_file", arguments: #"{"path":"A.txt"}"#)),
                    .text("could not edit, here is what I read"),
                ]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let events = await runParent(agent)

        #expect(parentEnding(events) == .completed)
        let refusals = wrapped(events).compactMap { event -> String? in
            if case .toolCallFinished(let id, _, let output) = event, id == "c1" { return output.text }
            return nil
        }
        #expect(refusals.count == 1 && refusals[0].contains("not available"))
        #expect(try String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8) == "x")
    }

    @Test func everyCallIsAnsweredOnBothSides() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("thanks")]),
            tools: parentTools(
                MockLLMClient(turns: [
                    .toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#)),
                    .text("saw it"),
                ]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let events = await runParent(agent)

        expectEveryCallAnswered(await agent.items)
        var started: [String] = []
        var finished: [String] = []
        for inner in wrapped(events) {
            if case .toolCallStarted(let id, _) = inner { started.append(id) }
            if case .toolCallFinished(let id, _, _) = inner { finished.append(id) }
        }
        #expect(started.sorted() == finished.sorted() && !started.isEmpty)
    }

    @Test func nestedExploreHitsTheDepthLimit() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("thanks")]),
            tools: parentTools(
                MockLLMClient(turns: [
                    .toolCalls((id: "c1", name: "explore", arguments: #"{"task":"deeper"}"#)),
                    .text("went one level"),
                ]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let events = await runParent(agent)

        #expect(parentEnding(events) == .completed)
        let nested = wrapped(events).compactMap { event -> String? in
            if case .toolCallFinished(let id, _, let output) = event, id == "c1" { return output.text }
            return nil
        }
        #expect(nested.count == 1 && nested[0].contains("depth"))
    }

    @Test func stopMidChildEndsBothWithOneRunEnded() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        var look = ProbeTool(name: "look", probe: probe)
        look.delay = .milliseconds(500)
        var edit = ProbeTool(name: "edit_file", probe: probe)
        edit.risk = .edit
        let agent = AgentSession(
            client: MockLLMClient(turns: [exploreCall(), .text("unreached")]),
            tools: [ExploreTool(childClient: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#)),
                .text("unreached"),
            ])), look, edit],
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let stream = await agent.send("go")
        let collected = Task {
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await probe.waitUntilStarted()
        await agent.stop()
        let events = await collected.value

        let endings = events.compactMap { event -> RunEnding? in
            if case .runEnded(let ending) = event { return ending }
            return nil
        }
        #expect(endings == [.stopped], "one top-level ending, for the parent run")
        // The child ends with the parent: nothing keeps running after Stop.
        let deadline = Date().addingTimeInterval(5)
        while await probe.running != 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.running == 0)
        #expect(await probe.startedCount == 1)
    }

    @Test func usageAddsUp() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let probe = Probe()
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                MockTurn([
                    .toolCallStarted(id: "x1", name: "explore"),
                    .toolCallFinished(id: "x1", name: "explore", arguments: #"{"task":"t"}"#),
                    .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
                    .finished(.toolCalls),
                ]),
                MockTurn([
                    .usage(TokenUsage(inputTokens: 1, outputTokens: 1)),
                    .textDelta("thanks"),
                    .finished(.completed),
                ]),
            ]),
            tools: parentTools(
                MockLLMClient(turns: [
                    MockTurn([
                        .usage(TokenUsage(inputTokens: 100, outputTokens: 50)),
                        .textDelta("found it"),
                        .finished(.completed),
                    ]),
                ]), probe: probe),
            workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
        let events = await runParent(agent)

        #expect(parentEnding(events) == .completed)
        let total = await agent.totalUsage
        #expect(total.inputTokens == 111 && total.outputTokens == 56,
                "parent turns plus the child's run, got \(total)")
    }

    @Test func theChildHasAHardIterationCap() {
        #expect(ExploreTool().maxIterations == 15)
    }
}

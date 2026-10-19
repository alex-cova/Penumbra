import Foundation
import Testing
@testable import AgentKit

private func shapingFinished(_ events: [AgentEvent], id: String) -> ToolOutput? {
    for event in events {
        if case .toolCallFinished(let finishedID, _, let output) = event, finishedID == id { return output }
    }
    return nil
}

@Suite struct ToolOutputShapingTests {
    private func session(
        _ client: MockLLMClient, tool: ProbeTool,
        shaper: (@Sendable (ToolOutputShapingInput) async throws -> String)? = nil
    ) throws -> AgentSession {
        AgentSession(
            client: client, tools: [tool], workspace: try TempProject().workspace,
            configuration: AgentConfiguration(model: "m", shapeToolOutput: shaper))
    }

    private func run(_ agent: AgentSession, _ text: String = "go") async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in await agent.send(text) { events.append(event) }
        return events
    }

    @Test func theShapedTextIsInItemsAndTheEventHasTheOriginal() async throws {
        let probe = Probe()
        let agent = try session(
            MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#)), .text("done"),
            ]),
            tool: ProbeTool(name: "look", probe: probe),
            shaper: { "\($0.toolName):\($0.risk):\($0.text)" })
        let events = await run(agent)

        #expect(toolOutputs(await agent.items)["c1"] == "look:read:ok:look")
        #expect(shapingFinished(events, id: "c1")?.text == "ok:look",
                "the live transcript keeps the original")
    }

    @Test func aCancelStubIsUntouched() async throws {
        let probe = Probe()
        var tool = ProbeTool(name: "look", probe: probe)
        tool.delay = .milliseconds(300)
        let agent = try session(
            MockLLMClient(turns: [.toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#))]),
            tool: tool,
            shaper: { "SHAPED " + $0.text })
        let stream = await agent.send("go")
        let collected = Task {
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await probe.waitUntilStarted()
        await agent.stop()
        let events = await collected.value

        var stopped = false
        for case .runEnded(.stopped) in events { stopped = true }
        #expect(stopped)
        #expect(toolOutputs(await agent.items)["c1"] == "Error: Cancelled by user.",
                "the cancel stub keeps its original text, unshaped")
    }

    @Test func aThrowingShaperFallsBack() async throws {
        struct Boom: Error {}
        let probe = Probe()
        let agent = try session(
            MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#)), .text("done"),
            ]),
            tool: ProbeTool(name: "look", probe: probe),
            shaper: { _ in throw Boom() })
        let events = await run(agent)

        var completed = false
        for case .runEnded(.completed) in events { completed = true }
        #expect(completed)
        #expect(toolOutputs(await agent.items)["c1"] == "ok:look")
    }

    @Test func errorsFallBackToTheOriginal() async throws {
        let probe = Probe()
        var tool = ProbeTool(name: "look", probe: probe)
        tool.fails = true
        let agent = try session(
            MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "look", arguments: #"{"n":1}"#)), .text("done"),
            ]),
            tool: tool,
            shaper: { "SHAPED " + $0.text })
        await run(agent)

        #expect(toolOutputs(await agent.items)["c1"] == "Error: look failed on purpose")
    }
}

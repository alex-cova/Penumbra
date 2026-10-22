import Foundation
import Testing
@testable import AgentKit

/// A command-risk tool standing in for an MCP server's tool.
private struct Stub: AgentTool {
    let name: String
    let log: Log
    var risk: ToolRisk { .command }
    var definition: ToolDefinition { ToolDefinition(name: name, description: "stub") }
    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        await log.add(name)
        return "ran \(name)"
    }
}

private actor Log {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

private func disk(_ project: TempProject, _ path: String) -> String? {
    try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
}

private func outputs(_ session: AgentSession) async -> [String: String] {
    var result: [String: String] = [:]
    for case .toolOutput(let id, let text) in await session.items { result[id] = text }
    return result
}

private func builtIn(_ turns: [MockTurn], files: [String: String] = ["note.txt": "Tangerine\n"]) throws -> (AgentSession, TempProject) {
    let project = try TempProject(files: files)
    let agent = AgentSession(
        client: MockLLMClient(turns: turns), tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", approval: .approveAll))
    return (agent, project)
}

private func read(_ path: String, id: String = "r1") -> (id: String, name: String, arguments: String) {
    (id: id, name: "read_file", arguments: #"{"path":"\#(path)"}"#)
}

private func write(_ path: String, _ content: String, id: String = "w1") -> (id: String, name: String, arguments: String) {
    (id: id, name: "write_file", arguments: #"{"path":"\#(path)","content":"\#(content)"}"#)
}

@Suite struct EmptyWriteTests {
    @Test func anEmptyWriteBesideAReadIsNotRunAndTheModelWritesAgainWithTheResult() async throws {
        let (agent, project) = try builtIn([
            .toolCalls(read("note.txt"), write("reply.txt", "")),
            .toolCalls(write("reply.txt", "Tangerine", id: "w2")),
            .text("done"),
        ])
        for await _ in await agent.send("go") {}
        let seen = await outputs(agent)
        #expect(seen["w1"]?.contains(AgentSession.emptyWriteMessage) == true)
        #expect(seen["r1"]?.contains("Tangerine") == true, "the read still ran")
        #expect(disk(project, "reply.txt") == "Tangerine", "only the second write happened")
    }

    @Test func theRefusalIsAnErrorOutputSoTheRunGoesOnAndNothingWasWritten() async throws {
        let (agent, project) = try builtIn([.toolCalls(read("note.txt"), write("reply.txt", "")), .text("ok")])
        var refused: ToolOutput?
        for await event in await agent.send("go") {
            if case .toolCallFinished(let id, _, let out) = event, id == "w1" { refused = out }
        }
        #expect(refused?.isError == true)
        #expect(disk(project, "reply.txt") == nil)
    }

    @Test func aCommandRiskReadAndWriteFromAServerAreCaughtToo() async throws {
        let log = Log()
        let project = try TempProject()
        let agent = AgentSession(
            client: MockLLMClient(turns: [
                .toolCalls(
                    (id: "r", name: "mcp__files__read_text_file", arguments: #"{"path":"/a"}"#),
                    (id: "w", name: "mcp__files__write_file", arguments: #"{"path":"/b","content":""}"#)),
                .text("ok"),
            ]),
            tools: [Stub(name: "mcp__files__read_text_file", log: log), Stub(name: "mcp__files__write_file", log: log)],
            workspace: project.workspace, configuration: AgentConfiguration(model: "m", approval: .approveAll))
        for await _ in await agent.send("go") {}
        #expect(await log.names == ["mcp__files__read_text_file"], "the write did not run")
        #expect(await outputs(agent)["w"]?.contains("empty content") == true)
    }

    @Test func aWriteWithContentRunsBesideARead() async throws {
        let (agent, project) = try builtIn([.toolCalls(read("note.txt"), write("other.txt", "unrelated text")), .text("ok")])
        for await _ in await agent.send("go") {}
        #expect(disk(project, "other.txt") == "unrelated text")
    }

    @Test func anEmptyWriteOnItsOwnCreatesTheEmptyFile() async throws {
        let (agent, project) = try builtIn([.toolCalls(write("empty.txt", "")), .text("ok")])
        for await _ in await agent.send("go") {}
        #expect(disk(project, "empty.txt") == "")
    }

    @Test func anEmptyWriteBesideAnotherWriteRuns() async throws {
        let (agent, project) = try builtIn([.toolCalls(write("a.txt", "x"), write("empty.txt", "", id: "w2")), .text("ok")])
        for await _ in await agent.send("go") {}
        #expect(disk(project, "empty.txt") == "")
        #expect(disk(project, "a.txt") == "x")
    }
}

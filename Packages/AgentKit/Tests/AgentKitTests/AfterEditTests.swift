import Foundation
import Testing
@testable import AgentKit

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[String]] = []
    func add(_ paths: [String]) { lock.withLock { all.append(paths) } }
    var value: [[String]] { lock.withLock { all } }
}

private func write(_ path: String, id: String) -> (id: String, name: String, arguments: String) {
    (id: id, name: "write_file", arguments: #"{"path":"\#(path)","content":"x"}"#)
}

private func session(
    turns: [MockTurn], project: TempProject, timeout: TimeInterval = 3,
    afterEdit: (@Sendable ([String]) async -> String?)?
) -> AgentSession {
    AgentSession(
        client: MockLLMClient(turns: turns), tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", approval: .approveAll, afterEdit: afterEdit, afterEditTimeout: timeout))
}

private func outputs(_ session: AgentSession) async -> [String: String] {
    var result: [String: String] = [:]
    for case .toolOutput(let id, let text) in await session.items { result[id] = text }
    return result
}

private func run(_ session: AgentSession) async {
    for await _ in await session.send("go") {}
}

@Suite struct AfterEditTests {
    @Test func theHostsNoteIsAddedToTheEditsOutput() async throws {
        let project = try TempProject()
        let calls = Calls()
        let agent = session(turns: [.toolCalls(write("A.txt", id: "w1")), .text("ok")], project: project) { paths in
            calls.add(paths)
            return "Problems after this edit: A.txt:1 broken"
        }
        await run(agent)
        #expect(calls.value == [["A.txt"]])
        let text = try #require(await outputs(agent)["w1"])
        #expect(text.hasSuffix("Problems after this edit: A.txt:1 broken"))
        #expect(text.contains("A.txt"), "the edit's own result is still there")
    }

    @Test func oneAskPerTurnWithEveryFileAndTheNoteOnTheLastEdit() async throws {
        let project = try TempProject()
        let calls = Calls()
        let agent = session(
            turns: [.toolCalls(write("A.txt", id: "w1"), write("B.txt", id: "w2")), .text("ok")], project: project
        ) { paths in
            calls.add(paths)
            return "NOTE"
        }
        await run(agent)
        #expect(calls.value == [["A.txt", "B.txt"]])
        let seen = await outputs(agent)
        #expect(seen["w1"]?.contains("NOTE") == false)
        #expect(seen["w2"]?.hasSuffix("NOTE") == true)
    }

    @Test func aTurnThatChangedNothingDoesNotAsk() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let calls = Calls()
        let agent = session(
            turns: [.toolCalls((id: "r1", name: "read_file", arguments: #"{"path":"A.txt"}"#)), .text("ok")], project: project
        ) { paths in
            calls.add(paths)
            return "NOTE"
        }
        await run(agent)
        #expect(calls.value.isEmpty)
    }

    @Test func aFailedEditDoesNotAsk() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let calls = Calls()
        // Not read first, so edit_file refuses.
        let agent = session(
            turns: [.toolCalls((id: "e1", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"x","new_string":"y"}"#)), .text("ok")],
            project: project
        ) { paths in
            calls.add(paths)
            return "NOTE"
        }
        await run(agent)
        #expect(calls.value.isEmpty)
        #expect(await outputs(agent)["e1"]?.contains("NOTE") == false)
    }

    @Test func nothingBackLeavesTheOutputAsItWas() async throws {
        let project = try TempProject()
        let plain = session(turns: [.toolCalls(write("A.txt", id: "w1")), .text("ok")], project: project, afterEdit: nil)
        await run(plain)
        let expected = try #require(await outputs(plain)["w1"])

        let project2 = try TempProject()
        let silent = session(turns: [.toolCalls(write("A.txt", id: "w1")), .text("ok")], project: project2) { _ in nil }
        await run(silent)
        #expect(await outputs(silent)["w1"] == expected)
        let empty = session(turns: [.toolCalls(write("A.txt", id: "w1")), .text("ok")], project: try TempProject()) { _ in "" }
        await run(empty)
        #expect(await outputs(empty)["w1"] == expected)
    }

    @Test func aSlowHostIsLeftBehind() async throws {
        let project = try TempProject()
        let agent = session(turns: [.toolCalls(write("A.txt", id: "w1")), .text("ok")], project: project, timeout: 0.2) { _ in
            try? await Task.sleep(for: .seconds(10))
            return "too late"
        }
        let started = Date()
        await run(agent)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await outputs(agent)["w1"]?.contains("too late") == false)
    }
}

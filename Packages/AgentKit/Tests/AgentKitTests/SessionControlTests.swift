import Foundation
import Testing
@testable import AgentKit

@Suite struct RecordReadTests {
    private func edit() -> MockTurn {
        .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#))
    }

    private func session(_ project: TempProject, _ client: MockLLMClient) -> AgentSession {
        AgentSession(client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace, configuration: AgentConfiguration(model: "m"))
    }

    private func run(_ agent: AgentSession) async {
        for await _ in await agent.send("go") {}
    }

    @Test func aFileTheHostShowedTheModelCanBeEditedWithoutReadingItAgain() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = session(project, MockLLMClient(turns: [edit(), .text("done")]))
        await agent.recordRead(path: "A.txt", text: "one\ntwo\n")
        await run(agent)
        #expect(toolOutputs(await agent.items)["e"]?.hasPrefix("Error") == false)
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\n2\n")
    }

    @Test func withoutItTheEditIsRefusedUntilTheFileIsRead() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = session(project, MockLLMClient(turns: [edit(), .text("done")]))
        await run(agent)
        #expect(toolOutputs(await agent.items)["e"]?.hasPrefix("Error") == true)
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\ntwo\n")
    }

    @Test func textThatIsNotWhatIsOnDiskDoesNotCountAsARead() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = session(project, MockLLMClient(turns: [edit(), .text("done")]))
        await agent.recordRead(path: "A.txt", text: "something the file never said")
        await run(agent)
        #expect(toolOutputs(await agent.items)["e"]?.hasPrefix("Error") == true, "the model was shown a different text")
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\ntwo\n")
    }

    @Test func aFileThatChangedAfterItWasShownMustBeReadAgain() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let agent = session(project, MockLLMClient(turns: [edit(), .text("done")]))
        await agent.recordRead(path: "A.txt", text: "one\ntwo\n")
        try "one\ntwo\nthree\n".write(to: project.root.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        await run(agent)
        #expect(toolOutputs(await agent.items)["e"]?.hasPrefix("Error") == true)
    }
}

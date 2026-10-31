import Foundation
import Testing
@testable import AgentKit

@Suite struct ReadFileLineNumbersTests {
    private func context(_ project: TempProject) async -> ToolContext {
        let log = CheckpointLog()
        let run = await log.beginRun(label: "test")
        return ToolContext(
            workspace: project.workspace, ledger: ReadLedger(), callID: "c",
            checkpoint: CheckpointScope(log: log, run: run))
    }

    @Test func numbersAreOnByDefault() async throws {
        let project = try TempProject(files: ["a.txt": "alpha\nbeta\n"])
        let read = await ReadFileTool().execute(argumentsJSON: #"{"path":"a.txt"}"#, context: await context(project))
        #expect(read.text == "[a.txt: lines 1–2 of 2]\n     1\talpha\n     2\tbeta\n")
    }

    @Test func withoutNumbersTheTextComesBackAsItIs() async throws {
        let project = try TempProject(files: ["a.txt": "alpha\n  beta\n"])
        let read = await ReadFileTool(lineNumbers: false).execute(argumentsJSON: #"{"path":"a.txt"}"#, context: await context(project))
        #expect(read.text == "[a.txt: lines 1–2 of 2]\nalpha\n  beta\n")
    }

    @Test func pagingStillWorksFromTheHeaderAndTheFooter() async throws {
        let project = try TempProject(files: ["a.txt": (1...5).map { "line\($0)" }.joined(separator: "\n") + "\n"])
        let read = await ReadFileTool(lineNumbers: false).execute(
            argumentsJSON: #"{"path":"a.txt","offset":3,"limit":2}"#, context: await context(project))
        #expect(read.text.hasPrefix("[a.txt: lines 3–4 of 5]\nline3\nline4\n"))
        #expect(read.text.contains("Use offset=5 to continue."))
    }

    @Test func anEditStillMatchesOnContentAfterAReadWithoutNumbers() async throws {
        let project = try TempProject(files: ["a.txt": "alpha\nbeta\ngamma\n"])
        let context = await context(project)
        _ = await ReadFileTool(lineNumbers: false).execute(argumentsJSON: #"{"path":"a.txt"}"#, context: context)
        let edited = await EditFileTool().execute(
            argumentsJSON: #"{"path":"a.txt","old_string":"beta","new_string":"BETA"}"#, context: context)
        #expect(!edited.isError)
        let disk = try String(contentsOf: project.root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(disk == "alpha\nBETA\ngamma\n")
    }

    @Test func theDescriptionOnlyPromisesNumbersWhenThereAreSome() {
        #expect(ReadFileTool().definition.description.contains("numbered lines"))
        #expect(!ReadFileTool(lineNumbers: false).definition.description.contains("numbered"))
        let tools = ReadOnlyTools.all(lineNumbers: false)
        #expect(tools.first { $0.name == "read_file" }?.definition.description.contains("numbered") == false)
    }
}

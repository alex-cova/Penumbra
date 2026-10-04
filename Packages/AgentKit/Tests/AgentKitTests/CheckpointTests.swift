import Foundation
import Testing
@testable import AgentKit

private func session(
    _ client: MockLLMClient, project: TempProject, tools: [any AgentTool] = ReadOnlyTools.all() + EditingTools.all()
) -> AgentSession {
    AgentSession(client: client, tools: tools, workspace: project.workspace, configuration: AgentConfiguration(model: "m"))
}

private func runToEnd(_ session: AgentSession, _ text: String = "go") async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await session.send(text) { events.append(event) }
    return events
}

private func runID(_ events: [AgentEvent]) -> RunID? {
    for case .runStarted(let id) in events { return id }
    return nil
}

private func disk(_ project: TempProject, _ path: String) -> String? {
    try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
}

@Suite struct CheckpointLogTests {
    @Test func revertingRestoresEditedAndRemovesCreatedFiles() async throws {
        let project = try TempProject(files: ["A.txt": "orig A\n", "B.txt": "orig B\n"])
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        let workspace = project.workspace

        await log.willChange(run: run, path: "A.txt", original: "orig A\n")
        try await workspace.replaceText(path: "A.txt", expecting: "orig A\n", edits: [AgentTextEdit(location: 0, length: 4, replacement: "edit")])
        await log.didChange(run: run, path: "A.txt", written: "edit A\n")

        await log.willChange(run: run, path: "New.txt", original: nil)
        try await workspace.createFile(path: "New.txt", contents: "new\n")
        await log.didChange(run: run, path: "New.txt", written: "new\n")

        let report = await log.revert(run, using: workspace)
        #expect(report.isComplete)
        #expect(Set(report.reverted) == ["A.txt", "New.txt"])
        #expect(disk(project, "A.txt") == "orig A\n")
        #expect(disk(project, "New.txt") == nil, "a created file goes to the Trash")
        #expect(disk(project, "B.txt") == "orig B\n")
        #expect(await log.run(run)?.isReverted == true)
    }

    @Test func aFileTheUserChangedAfterwardsIsNeverOverwritten() async throws {
        let project = try TempProject(files: ["A.txt": "orig\n", "B.txt": "orig B\n"])
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        for (path, original, written) in [("A.txt", "orig\n", "agent A\n"), ("B.txt", "orig B\n", "agent B\n")] {
            await log.willChange(run: run, path: path, original: original)
            try project.write(path, written)
            await log.didChange(run: run, path: path, written: written)
        }
        try project.write("A.txt", "the user kept typing\n")

        let report = await log.revert(run, using: project.workspace)
        #expect(report.reverted == ["B.txt"])
        #expect(report.conflicts == [RevertConflict(path: "A.txt", original: "orig\n", current: "the user kept typing\n")])
        #expect(disk(project, "A.txt") == "the user kept typing\n", "the user's text survives")
        #expect(disk(project, "B.txt") == "orig B\n")
        #expect(await log.run(run)?.isReverted == false, "a partial revert leaves the run open")
    }

    @Test func aDeletedFileIsAConflictAndANeverCreatedOneIsFine() async throws {
        let project = try TempProject(files: ["A.txt": "orig\n"])
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        await log.willChange(run: run, path: "A.txt", original: "orig\n")
        await log.didChange(run: run, path: "A.txt", written: "agent\n")
        try FileManager.default.removeItem(at: project.root.appendingPathComponent("A.txt"))
        // A creation whose write failed: nothing exists, and there is nothing to undo.
        await log.willChange(run: run, path: "Never.txt", original: nil)

        let report = await log.revert(run, using: project.workspace)
        #expect(report.conflicts == [RevertConflict(path: "A.txt", original: "orig\n", current: nil)])
        #expect(report.reverted == ["Never.txt"])
    }

    @Test func revertingTwiceAndRetryingAfterAPartialRevertAreSafe() async throws {
        let project = try TempProject(files: ["A.txt": "orig\n", "B.txt": "orig B\n"])
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        for (path, original, written) in [("A.txt", "orig\n", "agent\n"), ("B.txt", "orig B\n", "agent B\n")] {
            await log.willChange(run: run, path: path, original: original)
            try project.write(path, written)
            await log.didChange(run: run, path: path, written: written)
        }
        try project.write("A.txt", "user text\n")
        let first = await log.revert(run, using: project.workspace)
        #expect(first.conflicts.count == 1)

        // The user puts the agent's text back (or undoes their edit); the retry finishes the job.
        try project.write("A.txt", "agent\n")
        let retry = await log.revert(run, using: project.workspace)
        #expect(retry.isComplete)
        #expect(Set(retry.reverted) == ["A.txt", "B.txt"], "B.txt is already at its original and counts as done")
        #expect(disk(project, "A.txt") == "orig\n")

        let again = await log.revert(run, using: project.workspace)
        #expect(again == RevertReport(), "a reverted run is a no-op")
    }

    @Test func eachRunKeepsItsOwnOriginalAndAnOlderRunConflictsWhenANewerOneTouchedTheFile() async throws {
        let project = try TempProject(files: ["A.txt": "v0\n"])
        let log = CheckpointLog()
        let run1 = await log.beginRun(label: "one")
        await log.willChange(run: run1, path: "A.txt", original: "v0\n")
        try project.write("A.txt", "v1\n")
        await log.didChange(run: run1, path: "A.txt", written: "v1\n")

        let run2 = await log.beginRun(label: "two")
        await log.willChange(run: run2, path: "A.txt", original: "v1\n")
        try project.write("A.txt", "v2\n")
        await log.didChange(run: run2, path: "A.txt", written: "v2\n")

        let early = await log.revert(run1, using: project.workspace)
        #expect(early.conflicts.map(\.path) == ["A.txt"], "run 2 changed the file after run 1")
        #expect(disk(project, "A.txt") == "v2\n")

        #expect(await log.revert(run2, using: project.workspace).isComplete)
        #expect(disk(project, "A.txt") == "v1\n")
        #expect(await log.revert(run1, using: project.workspace).isComplete)
        #expect(disk(project, "A.txt") == "v0\n")
    }

    @Test func aRunWithoutChangesLeavesNoRecord() async throws {
        let log = CheckpointLog()
        let run = await log.beginRun(label: "just reading")
        #expect(await log.run(run) == nil)
        #expect(await log.runs.isEmpty)
    }

    @Test func theOldestRunsLoseRevertFirstAndTheNewestAlwaysStays() async throws {
        let log = CheckpointLog(maxBytes: 100)
        var ids: [RunID] = []
        for index in 0..<4 {
            let run = await log.beginRun(label: "run \(index)")
            await log.willChange(run: run, path: "f\(index).txt", original: String(repeating: "x", count: 60))
            ids.append(run)
        }
        let kept = await log.runs.map(\.id)
        #expect(kept == [ids[3]], "only the newest fits")
        #expect(await log.run(ids[0]) == nil)

        let huge = await log.beginRun(label: "huge")
        await log.willChange(run: huge, path: "big.txt", original: String(repeating: "x", count: 500))
        #expect(await log.runs.map(\.id) == [huge], "the current run stays even when it alone exceeds the cap")
    }
}

@Suite struct EditingSessionTests {
    @Test func aRunThatEditsFilesCanBeRevertedAsAWhole() async throws {
        let project = try TempProject(files: ["src/A.java": "class A {\n  int x = 1;\n}\n", "src/B.java": "class B {}\n"])
        let client = MockLLMClient(turns: [
            .toolCalls(
                (id: "r1", name: "read_file", arguments: #"{"path":"src/A.java"}"#),
                (id: "r2", name: "read_file", arguments: #"{"path":"src/B.java"}"#)),
            .toolCalls(
                (id: "e1", name: "edit_file", arguments: #"{"path":"src/A.java","old_string":"int x = 1;","new_string":"int x = 2;"}"#),
                (id: "e2", name: "edit_file", arguments: #"{"path":"src/B.java","old_string":"class B {}","new_string":"class B { int y; }"}"#),
                (id: "w", name: "write_file", arguments: #"{"path":"src/C.java","content":"class C {}\n"}"#)),
            .text("Done."),
        ])
        let agent = session(client, project: project)
        let events = await runToEnd(agent, "change things")
        let id = try #require(runID(events))

        #expect(events.last == .runEnded(.completed))
        #expect(disk(project, "src/A.java") == "class A {\n  int x = 2;\n}\n")
        #expect(disk(project, "src/C.java") == "class C {}\n")
        let changes = await agent.checkpoints.changes(in: id)
        #expect(changes.map(\.path) == ["src/A.java", "src/B.java", "src/C.java"])
        #expect(changes.map(\.isCreation) == [false, false, true])

        let report = try await agent.revertRun(id)
        #expect(report.isComplete && report.reverted.count == 3)
        #expect(disk(project, "src/A.java") == "class A {\n  int x = 1;\n}\n")
        #expect(disk(project, "src/B.java") == "class B {}\n")
        #expect(disk(project, "src/C.java") == nil)
    }

    @Test func aRunThatOnlyReadsLeavesNothingToRevert() async throws {
        let project = try TempProject(files: ["A.txt": "x\n"])
        let client = MockLLMClient(turns: [.toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)), .text("ok")])
        let agent = session(client, project: project)
        let id = try #require(runID(await runToEnd(agent)))
        #expect(await agent.checkpoints.changes(in: id).isEmpty)
    }

    @Test func aFailedEditLeavesNoPhantomChange() async throws {
        let project = try TempProject(files: ["A.txt": "x\n"])
        let client = MockLLMClient(turns: [
            .toolCalls(
                (id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"nope","new_string":"y"}"#)),
            .text("could not"),
        ])
        let agent = session(client, project: project)
        let id = try #require(runID(await runToEnd(agent)))
        #expect(await agent.checkpoints.changes(in: id).isEmpty)
        #expect(disk(project, "A.txt") == "x\n")
    }

    @Test func revertingWhileARunIsInProgressIsRefused() async throws {
        let project = try TempProject()
        let events = (0..<100).map { LLMEvent.textDelta("w\($0)") } + [.finished(.completed)]
        let client = MockLLMClient(turns: [MockTurn(events, delayPerEvent: .milliseconds(20))])
        let agent = session(client, project: project)
        let stream = await agent.send("go")
        await #expect(throws: AgentSession.RevertError.runInProgress) { _ = try await agent.revertRun(RunID()) }
        await agent.stop()
        for await _ in stream {}
    }

    @Test func stopMidEditStillLeavesAValidCheckpoint() async throws {
        let project = try TempProject(files: ["A.txt": "one\n"])
        let slow = SlowEditTool(project: project)
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "s", name: "slow_edit", arguments: "{}")),
            .text("never reached"),
        ])
        let agent = session(client, project: project, tools: ReadOnlyTools.all() + [slow])
        let stream = await agent.send("go")
        let collector = Task { () -> [AgentEvent] in
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await slow.started.wait()
        await agent.stop()
        let events = await collector.value
        #expect(events.last == .runEnded(.stopped))

        // The checkpoint was taken before the change began, so the original is recoverable.
        let id = try #require(runID(events))
        let changes = await agent.checkpoints.changes(in: id)
        #expect(changes.first?.original == "one\n")
    }
}

/// An edit tool that checkpoints, then hangs until cancelled: Stop lands between "will change" and "did change".
private struct SlowEditTool: AgentTool {
    let project: TempProject
    let started = Signal()
    var risk: ToolRisk { .edit }
    var definition: ToolDefinition { ToolDefinition(name: "slow_edit", description: "slow") }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        await context.checkpoint?.willChange(path: "A.txt", original: "one\n")
        await started.fire()
        try await Task.sleep(for: .seconds(30))
        return "unreachable"
    }
}

private actor Signal {
    private var fired = false
    func fire() { fired = true }
    func wait() async { while !fired { try? await Task.sleep(for: .milliseconds(5)) } }
}

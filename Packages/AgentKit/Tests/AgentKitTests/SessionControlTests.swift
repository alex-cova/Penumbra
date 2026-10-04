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

private final class MemoryBlobs: CheckpointBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String] = [:]

    private func key(_ run: RunID, _ path: String) -> String { "\(run)/\(path)" }

    func put(_ text: String, run: RunID, path: String) { lock.withLock { texts[key(run, path)] = text } }
    func get(run: RunID, path: String) -> String? { lock.withLock { texts[key(run, path)] } }
    func remove(run: RunID, path: String) { lock.withLock { _ = texts.removeValue(forKey: key(run, path)) } }
    var count: Int { lock.withLock { texts.count } }
}

@Suite struct CheckpointPersistenceTests {
    private func disk(_ project: TempProject, _ path: String) -> String? {
        try? String(contentsOf: project.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func originalsAreWrittenToTheStoreAsTheyAreRecordedAndCreationsAreNot() async throws {
        let blobs = MemoryBlobs()
        let log = CheckpointLog(blobs: blobs)
        let run = await log.beginRun(label: "go")
        await log.willChange(run: run, path: "A.txt", original: "before")
        await log.willChange(run: run, path: "New.txt", original: nil)
        await log.willChange(run: run, path: "A.txt", original: "ignored: not the first change")
        #expect(blobs.get(run: run, path: "A.txt") == "before")
        #expect(blobs.get(run: run, path: "New.txt") == nil)
        #expect(blobs.count == 1)
    }

    @Test func aRunCanBeRevertedAfterARelaunch() async throws {
        let project = try TempProject(files: ["A.txt": "original\n", "Keep.txt": "same\n"])
        let blobs = MemoryBlobs()
        let first = CheckpointLog(blobs: blobs)
        let run = await first.beginRun(label: "edit A")
        await first.willChange(run: run, path: "A.txt", original: "original\n")
        try "changed\n".write(to: project.root.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        await first.didChange(run: run, path: "A.txt", written: "changed\n")
        await first.willChange(run: run, path: "New.txt", original: nil)
        try "created\n".write(to: project.root.appendingPathComponent("New.txt"), atomically: true, encoding: .utf8)
        await first.didChange(run: run, path: "New.txt", written: "created\n")

        // The window is closed: only the snapshot (kept with the conversation) and the blobs survive.
        let saved = try JSONEncoder().encode(await first.snapshot())
        let second = CheckpointLog(blobs: blobs)
        let restored = await second.restore(try JSONDecoder().decode([RunSnapshot].self, from: saved))
        #expect(restored == [run])
        #expect(await second.changes(in: run).map(\.path) == ["A.txt", "New.txt"])

        let report = await second.revert(run, using: project.workspace)
        #expect(report.isComplete)
        #expect(Set(report.reverted) == ["A.txt", "New.txt"])
        #expect(disk(project, "A.txt") == "original\n")
        #expect(disk(project, "New.txt") == nil, "a file the run created goes away")
        #expect(disk(project, "Keep.txt") == "same\n")
    }

    @Test func aFileTheUserEditedSinceStillCountsAsAConflictAfterARelaunch() async throws {
        let project = try TempProject(files: ["A.txt": "original\n"])
        let blobs = MemoryBlobs()
        let first = CheckpointLog(blobs: blobs)
        let run = await first.beginRun(label: "edit")
        await first.willChange(run: run, path: "A.txt", original: "original\n")
        try "agent wrote\n".write(to: project.root.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        await first.didChange(run: run, path: "A.txt", written: "agent wrote\n")
        let snapshot = await first.snapshot()

        try "the user typed this\n".write(to: project.root.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        let second = CheckpointLog(blobs: blobs)
        await second.restore(snapshot)
        let report = await second.revert(run, using: project.workspace)
        #expect(report.conflicts.map(\.path) == ["A.txt"])
        #expect(disk(project, "A.txt") == "the user typed this\n", "the user's text is never overwritten")
    }

    @Test func aFileWhoseOriginalIsGoneIsLeftOutAndAnEmptyRunIsDropped() async throws {
        let blobs = MemoryBlobs()
        let first = CheckpointLog(blobs: blobs)
        let kept = await first.beginRun(label: "kept")
        await first.willChange(run: kept, path: "A.txt", original: "a")
        await first.willChange(run: kept, path: "B.txt", original: "b")
        let lost = await first.beginRun(label: "lost")
        await first.willChange(run: lost, path: "C.txt", original: "c")
        let snapshot = await first.snapshot()

        blobs.remove(run: kept, path: "B.txt")
        blobs.remove(run: lost, path: "C.txt")
        let second = CheckpointLog(blobs: blobs)
        let restored = await second.restore(snapshot)
        #expect(restored == [kept])
        #expect(await second.changes(in: kept).map(\.path) == ["A.txt"])
        #expect(await second.run(lost) == nil)
    }

    @Test func aRestoreDoesNotReplaceARunThatIsAlreadyKnown() async throws {
        let blobs = MemoryBlobs()
        let log = CheckpointLog(blobs: blobs)
        let run = await log.beginRun(label: "live")
        await log.willChange(run: run, path: "A.txt", original: "a")
        let snapshot = await log.snapshot()
        let restored = await log.restore(snapshot)
        #expect(restored.isEmpty)
        #expect(await log.runs.count == 1)
    }

    @Test func theRevertedFlagAndTheLabelSurvive() async throws {
        let project = try TempProject(files: ["A.txt": "x\n"])
        let blobs = MemoryBlobs()
        let first = CheckpointLog(blobs: blobs)
        let run = await first.beginRun(label: "tidy up")
        await first.willChange(run: run, path: "A.txt", original: "x\n")
        await first.didChange(run: run, path: "A.txt", written: "x\n")
        _ = await first.revert(run, using: project.workspace)

        let second = CheckpointLog(blobs: blobs)
        await second.restore(await first.snapshot())
        let record = try #require(await second.run(run))
        #expect(record.isReverted && record.label == "tidy up")
        #expect(await second.revert(run, using: project.workspace) == RevertReport(), "a run reverted before the relaunch is not reverted twice")
    }

    @Test func theRestoredRunsStayWithinTheMemoryBudgetKeepingTheNewest() async throws {
        let blobs = MemoryBlobs()
        let first = CheckpointLog(blobs: blobs)
        var ids: [RunID] = []
        for index in 0..<5 {
            let run = await first.beginRun(label: "run \(index)")
            await first.willChange(run: run, path: "f.txt", original: String(repeating: "x", count: 100))
            ids.append(run)
        }
        let second = CheckpointLog(maxBytes: 250, blobs: blobs)
        await second.restore(await first.snapshot())
        let kept = await second.runs.map(\.id)
        #expect(kept == Array(ids.suffix(2)), "two 100-byte originals fit in 250 bytes; the older runs lose Revert first")
    }

    @Test func aSessionTakesALogItCanRestoreInto() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let blobs = MemoryBlobs()
        let log = CheckpointLog(blobs: blobs)
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        let agent = AgentSession(
            client: client, tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"), checkpoints: log)
        var runID: RunID?
        for await event in await agent.send("go") { if case .runStarted(let id) = event { runID = id } }
        let run = try #require(runID)
        #expect(blobs.get(run: run, path: "A.txt") == "one\ntwo\n", "the session's edit wrote its original through")

        let snapshot = await log.snapshot()
        let relaunched = CheckpointLog(blobs: blobs)
        await relaunched.restore(snapshot)
        let second = AgentSession(
            client: MockLLMClient(turns: []), tools: ReadOnlyTools.all() + EditingTools.all(), workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"), history: await agent.items, checkpoints: relaunched)
        let report = try await second.revertRun(run)
        #expect(report.isComplete)
        #expect(disk(project, "A.txt") == "one\ntwo\n")
    }
}

@Suite struct RewindTests {
    private func session(_ client: MockLLMClient, project: TempProject) -> AgentSession {
        AgentSession(
            client: client, tools: ReadOnlyTools.all() + EditingTools.all() + [TodoTool()], workspace: project.workspace,
            configuration: AgentConfiguration(model: "m"))
    }

    private func run(_ agent: AgentSession, _ text: String) async {
        for await _ in await agent.send(text) {}
    }

    private func userIndex(_ agent: AgentSession, _ text: String) async -> Int? {
        await agent.items.firstIndex { if case .user(let value) = $0 { value == text } else { false } }
    }

    @Test func theConversationIsCutBeforeTheChosenMessageAndWhatWasCutIsReturned() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = session(MockLLMClient(turns: [.text("a1"), .text("a2"), .text("a3")]), project: project)
        await run(agent, "first")
        await run(agent, "second")
        await run(agent, "third")
        let index = try #require(await userIndex(agent, "second"))

        let removed = try await agent.rewind(toBeforeItem: index)
        #expect(await agent.items == [.user("first"), .assistant("a1")])
        #expect(removed == [.user("second"), .assistant("a2"), .user("third"), .assistant("a3")])
    }

    @Test func theNextMessageContinuesFromWhatIsLeft() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let client = MockLLMClient(turns: [.text("a1"), .text("a2"), .text("again")])
        let agent = session(client, project: project)
        await run(agent, "first")
        await run(agent, "second")
        try await agent.rewind(toBeforeItem: try #require(await userIndex(agent, "second")))
        await run(agent, "a different second")
        #expect(client.requests.last?.items == [.user("first"), .assistant("a1"), .user("a different second")])
    }

    @Test func theChecklistGoesBackToWhatItWasThen() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let client = MockLLMClient(turns: [
            .toolCalls((id: "t1", name: "todo", arguments: #"{"items":["[ ] one"]}"#)), .text("a1"),
            .toolCalls((id: "t2", name: "todo", arguments: #"{"items":["[x] one","[ ] two"]}"#)), .text("a2"),
        ])
        let agent = session(client, project: project)
        await run(agent, "first")
        await run(agent, "second")
        #expect(await agent.todoList.items.count == 2)
        try await agent.rewind(toBeforeItem: try #require(await userIndex(agent, "second")))
        #expect(await agent.todoList.items.map(\.content) == ["one"])
        try await agent.rewind(toBeforeItem: try #require(await userIndex(agent, "first")))
        #expect(await agent.todoList.items.isEmpty)
    }

    @Test func afterARewindTheModelMustReadAFileAgainBeforeEditingIt() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\n"])
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)), .text("read it"),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)), .text("tried"),
        ])
        let agent = session(client, project: project)
        await run(agent, "read")
        try await agent.rewind(toBeforeItem: 0)
        await run(agent, "edit without reading")
        #expect(toolOutputs(await agent.items)["e"]?.hasPrefix("Error") == true, "what it read before the rewind is forgotten")
    }

    @Test func itRefusesAMidTurnItemAnOutOfRangeIndexAndARunInProgress() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = session(
            MockLLMClient(turns: [.toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)), .text("done"), MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(300))]),
            project: project)
        await run(agent, "go")
        await #expect(throws: AgentSession.RewindError.notAUserMessage) { try await agent.rewind(toBeforeItem: 1) }
        await #expect(throws: AgentSession.RewindError.notAUserMessage) { try await agent.rewind(toBeforeItem: 99) }
        await #expect(throws: AgentSession.RewindError.notAUserMessage) { try await agent.rewind(toBeforeItem: -1) }

        let stream = await agent.send("slow one")
        await #expect(throws: AgentSession.RewindError.runInProgress) { try await agent.rewind(toBeforeItem: 0) }
        for await _ in stream {}
    }

    @Test func severalRunsAreRevertedNewestFirstSoTheOldestStateWins() async throws {
        let project = try TempProject(files: ["A.txt": "one\ntwo\nthree\n"])
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r1", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e1", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)), .text("first done"),
            .toolCalls((id: "e2", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"three","new_string":"3"}"#)), .text("second done"),
        ])
        let agent = session(client, project: project)
        var runs: [RunID] = []
        for message in ["first", "second"] {
            for await event in await agent.send(message) { if case .runStarted(let id) = event { runs.append(id) } }
        }
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\n2\n3\n")

        let report = try await agent.revertRuns(runs)
        #expect(report.isComplete)
        #expect(report.reverted == ["A.txt", "A.txt"], "once per run")
        #expect((try? String(contentsOf: project.root.appendingPathComponent("A.txt"), encoding: .utf8)) == "one\ntwo\nthree\n")
    }

    @Test func revertingNoRunsOrUnknownRunsChangesNothing() async throws {
        let project = try TempProject(files: ["A.txt": "x"])
        let agent = session(MockLLMClient(turns: []), project: project)
        #expect(try await agent.revertRuns([]) == RevertReport())
        #expect(try await agent.revertRuns([UUID()]) == RevertReport())
    }
}

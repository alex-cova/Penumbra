import AgentKit
import EditorIntelligence
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDELocalHistoryIntegrationTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var historyDirectory: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("local-history-it-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        historyDirectory = base.appendingPathComponent("history")
        storeDirectory = base.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "class B {}\n".write(to: project.appendingPathComponent("src/B.java"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.localHistory.enable(baseDirectory: historyDirectory)
        workspace.project.setRoot(project)
        workspace.localHistory.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private var recorder: IDELocalHistoryRecorder { workspace.localHistory }

    private func write(_ text: String, _ path: String) throws {
        try text.write(to: project.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    private func waitFor(_ message: String, _ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    private func events(_ path: String) async -> [IDELocalHistoryEvent] { await recorder.store?.events(forPath: path) ?? [] }

    private func texts(_ path: String) async -> [String] {
        guard let store = recorder.store else { return [] }
        var result: [String] = []
        for event in await store.events(forPath: path) { result.append(await store.text(of: event) ?? "<missing>") }
        return result
    }

    // MARK: - Recording

    func testAnOpenedThenSavedFileHasItsStartAndItsChange() async throws {
        let url = project.appendingPathComponent("A.txt")
        recorder.recordBaseline(url)
        await waitFor("the baseline") { await self.events("A.txt").count == 1 }
        try write("one\n2\nthree\n", "A.txt")
        recorder.recordSaved(url)
        await waitFor("the save") { await self.events("A.txt").count == 2 }

        let list = await events("A.txt")
        XCTAssertEqual(list.map(\.source), [.save, .baseline])
        let store = try XCTUnwrap(recorder.store)
        let beforeText = await store.text(of: list[0], before: true)
        XCTAssertEqual(beforeText, "one\ntwo\nthree\n", "the save knows what the file was when it was opened")
        let latest = await texts("A.txt")
        XCTAssertEqual(latest, ["one\n2\nthree\n", "one\ntwo\nthree\n"])
    }

    func testSavingAnUnchangedFileAddsNothingAndAnOutsideFileIsIgnored() async throws {
        let url = project.appendingPathComponent("A.txt")
        recorder.recordBaseline(url)
        await waitFor("the baseline") { await self.events("A.txt").count == 1 }
        recorder.recordSaved(url)
        recorder.recordSaved(base.appendingPathComponent("outside.txt"))
        try write("outside", "../outside.txt")
        recorder.recordSaved(base.appendingPathComponent("outside.txt"))
        try await Task.sleep(for: .milliseconds(150))
        let all = await recorder.store?.recentEvents() ?? []
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(recorder.relativePath(of: base.appendingPathComponent("outside.txt")))
    }

    func testThePathIsProjectRelative() async throws {
        recorder.recordBaseline(project.appendingPathComponent("src/B.java"))
        await waitFor("baseline") { await self.events("src/B.java").count == 1 }
        XCTAssertEqual(recorder.relativePath(of: project.appendingPathComponent("src/B.java")), "src/B.java")
    }

    func testAnExternalChangeToAFileWithHistoryIsRecordedAndOneToAnUnknownFileIsNot() async throws {
        let known = project.appendingPathComponent("A.txt")
        recorder.recordBaseline(known)
        await waitFor("baseline") { await self.events("A.txt").count == 1 }
        try write("one\nchanged by git\nthree\n", "A.txt")
        try write("brand new build output", "src/Generated.java")

        recorder.recordExternalChanges([known.path, project.appendingPathComponent("src/Generated.java").path, base.appendingPathComponent("elsewhere.txt").path])
        await waitFor("the external change") { await self.events("A.txt").count == 2 }
        let list = await events("A.txt")
        XCTAssertEqual(list[0].source, .external)
        try await Task.sleep(for: .milliseconds(100))
        let generated = await events("src/Generated.java")
        XCTAssertTrue(generated.isEmpty, "a file with no history is not read")
    }

    func testAnExternalChangeThatOurOwnSaveCausedIsNotRecordedTwice() async throws {
        let url = project.appendingPathComponent("A.txt")
        recorder.recordBaseline(url)
        await waitFor("baseline") { await self.events("A.txt").count == 1 }
        try write("saved text\n", "A.txt")
        recorder.recordSaved(url)
        await waitFor("the save") { await self.events("A.txt").count == 2 }
        recorder.recordExternalChanges([url.path])
        try await Task.sleep(for: .milliseconds(150))
        let count = await events("A.txt").count
        XCTAssertEqual(count, 2, "the watcher reports our own write too; the same text is not news")
    }

    func testARefactoringThatRewritesClosedFilesKeepsWhatTheyWereAsOneAction() async throws {
        try write("class A { void run() {} }\n", "src/A.java")
        let a = project.appendingPathComponent("src/A.java")
        let b = project.appendingPathComponent("src/B.java")
        let edit = WorkspaceEdit(changes: [
            a: [TextEdit(range: TextRange(start: TextPosition(line: 0, column: 6, utf16Offset: 6), end: TextPosition(line: 0, column: 7, utf16Offset: 7)), replacement: "Renamed")],
            b: [TextEdit(range: TextRange(start: TextPosition(line: 0, column: 6, utf16Offset: 6), end: TextPosition(line: 0, column: 7, utf16Offset: 7)), replacement: "Other")],
        ])
        let result = await workspace.historyRecordingApplier(named: "Rename Class").apply(edit)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(disk("src/A.java"), "class Renamed { void run() {} }\n")

        await waitFor("both files recorded") {
            let first = await self.events("src/A.java").count
            let second = await self.events("src/B.java").count
            return first == 2 && second == 2
        }
        let events = await events("src/A.java")
        XCTAssertEqual(events[0].source, .refactor("Rename Class"))
        let store = try XCTUnwrap(recorder.store)
        let before = await store.text(of: events[0], before: true)
        XCTAssertEqual(before, "class A { void run() {} }\n", "what the file was before the refactoring")
        let other = await self.events("src/B.java")
        XCTAssertEqual(events[0].group, other[0].group, "one refactoring, one action")
        XCTAssertNotNil(events[0].group)
    }

    func testAnOrdinaryApplyRecordsNothingByItself() async throws {
        let a = project.appendingPathComponent("A.txt")
        let edit = WorkspaceEdit(changes: [
            a: [TextEdit(range: TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0), end: TextPosition(line: 0, column: 3, utf16Offset: 3)), replacement: "ONE")]
        ])
        _ = await IDEWorkspaceEditApplier(host: workspace).apply(edit)
        try await Task.sleep(for: .milliseconds(100))
        let all = await recorder.store?.recentEvents() ?? []
        XCTAssertTrue(all.isEmpty, "agent writes and restores record themselves, with their own source")
    }

    func testABinaryOrMissingFileIsNotARevision() async throws {
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: project.appendingPathComponent("blob.bin"))
        recorder.recordBaseline(project.appendingPathComponent("blob.bin"))
        recorder.recordBaseline(project.appendingPathComponent("missing.txt"))
        try await Task.sleep(for: .milliseconds(150))
        let all = await recorder.store?.recentEvents() ?? []
        XCTAssertTrue(all.isEmpty)
    }

    func testAWindowWithPersistenceOffRecordsNothing() async throws {
        let off = IDEWorkspace()
        defer { off.teardown() }
        off.project.setRoot(project)
        off.localHistory.setRoot(project)
        XCTAssertNil(off.localHistory.store)
        XCTAssertFalse(off.localHistory.isEnabled)
        off.localHistory.recordBaseline(project.appendingPathComponent("A.txt"))
    }

    func testTwoProjectsKeepSeparateHistories() async throws {
        let other = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x".write(to: other.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        recorder.recordBaseline(project.appendingPathComponent("A.txt"))
        await waitFor("first project") { await self.events("A.txt").count == 1 }

        recorder.setRoot(other)
        let none = await events("A.txt")
        XCTAssertTrue(none.isEmpty, "the other project has its own history")
        recorder.setRoot(project)
        let back = await events("A.txt")
        XCTAssertEqual(back.count, 1, "and the first one comes back from disk")
    }

    // MARK: - Agent writes

    private func makeController(_ turns: [MockTurn]) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return controller
    }

    private func say(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        for _ in 0..<800 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAnAgentEditIsARevisionThatNamesTheChatAndTheMessageAndKeepsWhatWasThereBefore() async throws {
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .toolCalls((id: "w", name: "write_file", arguments: #"{"path":"New.txt","content":"fresh\n"}"#)),
            .text("done"),
        ])
        controller.selected.rename("Number work")
        await say(controller, "change two to 2 and add a file")
        await waitFor("both writes recorded") {
            let edited = await self.events("A.txt").count
            let created = await self.events("New.txt").count
            return edited == 2 && created == 1
        }

        let a = await events("A.txt")
        XCTAssertEqual(a.map(\.source), [.agent(tab: "Number work", prompt: "change two to 2 and add a file"), .baseline])
        let store = try XCTUnwrap(recorder.store)
        let before = await store.text(of: a[0], before: true)
        XCTAssertEqual(before, "one\ntwo\nthree\n", "a file nobody opened still has a left side")
        let after = await store.text(of: a[0])
        XCTAssertEqual(after, "one\n2\nthree\n")
        let created = await events("New.txt")
        XCTAssertNil(created[0].before, "a created file has no before")
        XCTAssertEqual(created[0].group, a[0].group, "one run, one action")
        XCTAssertNotNil(a[0].group)
    }

    func testRevertingARunIsRecordedAsARevertNotAsAnAgentEdit() async throws {
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        await say(controller, "edit it")
        await waitFor("the edit recorded") { await self.events("A.txt").count == 2 }
        let card = try XCTUnwrap(controller.entries.first { $0.kind == .changes })

        controller.revert(entryID: card.id)
        await waitFor("the revert recorded") { await self.events("A.txt").count == 3 }
        let list = await events("A.txt")
        XCTAssertEqual(list[0].source, .revert)
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n")
        XCTAssertEqual(list.filter(\.source.isAgent).count, 1, "only the real edit counts as the agent's")
    }

    // MARK: - Restoring

    private func seededHistory() async throws -> (v1: IDELocalHistoryEvent, v2: IDELocalHistoryEvent) {
        let store = try XCTUnwrap(recorder.store)
        let v1 = await store.record(path: "A.txt", text: "version one\n", source: .save, at: Date(timeIntervalSince1970: 1_000))
        let v2 = await store.record(path: "A.txt", text: "version two\n", source: .save, at: Date(timeIntervalSince1970: 2_000))
        try write("version two\n", "A.txt")
        return (try XCTUnwrap(v1), try XCTUnwrap(v2))
    }

    func testRevertingToARevisionPutsTheTextBackAndNotesIt() async throws {
        let (v1, _) = try await seededHistory()
        let done = await workspace.localHistoryRevert(toRevision: v1)
        XCTAssertTrue(done)
        XCTAssertEqual(disk("A.txt"), "version one\n")
        await waitFor("the revert noted") { await self.events("A.txt").first?.source == .revert }
        let texts = await texts("A.txt")
        XCTAssertEqual(texts.first, "version one\n")
    }

    func testRevertingToWhatTheFileAlreadyHoldsChangesNothing() async throws {
        let (_, v2) = try await seededHistory()
        let done = await workspace.localHistoryRevert(toRevision: v2)
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(100))
        let count = await events("A.txt").count
        XCTAssertEqual(count, 2)
    }

    func testUndoingOneChangeRestoresWhatCameBeforeIt() async throws {
        let (_, v2) = try await seededHistory()
        let done = await workspace.localHistoryUndo(v2)
        XCTAssertTrue(done)
        XCTAssertEqual(disk("A.txt"), "version one\n")
    }

    func testUndoingTheChangeThatCreatedAFileRemovesIt() async throws {
        let store = try XCTUnwrap(recorder.store)
        try write("brand new\n", "Created.txt")
        let created = await store.record(path: "Created.txt", text: "brand new\n", source: .agent(tab: "t", prompt: "p"))
        let done = await workspace.localHistoryUndo(try XCTUnwrap(created))
        XCTAssertTrue(done)
        XCTAssertNil(disk("Created.txt"))
    }

    func testRestoringADeletedFileBringsItBack() async throws {
        let store = try XCTUnwrap(recorder.store)
        await store.record(path: "Gone.txt", text: "was here\n", source: .save, at: Date(timeIntervalSince1970: 1))
        let deleted = await store.record(path: "Gone.txt", text: nil, source: .external, at: Date(timeIntervalSince1970: 2))
        XCTAssertNil(disk("Gone.txt"))
        let done = await workspace.localHistoryUndo(try XCTUnwrap(deleted))
        XCTAssertTrue(done)
        XCTAssertEqual(disk("Gone.txt"), "was here\n")
    }

    func testUndoingAnActionPutsEveryFileItTouchedBack() async throws {
        let store = try XCTUnwrap(recorder.store)
        let run = UUID()
        await store.record(path: "A.txt", text: "a original\n", source: .save, at: Date(timeIntervalSince1970: 1))
        await store.record(path: "src/B.java", text: "b original\n", source: .save, at: Date(timeIntervalSince1970: 1))
        await store.record(path: "A.txt", text: "a first\n", source: .agent(tab: "t", prompt: "p"), group: run, at: Date(timeIntervalSince1970: 10))
        await store.record(path: "src/B.java", text: "b new\n", source: .agent(tab: "t", prompt: "p"), group: run, at: Date(timeIntervalSince1970: 11))
        await store.record(path: "A.txt", text: "a second\n", source: .agent(tab: "t", prompt: "p"), group: run, at: Date(timeIntervalSince1970: 12))
        try write("a second\n", "A.txt")
        try write("b new\n", "src/B.java")

        let groups = IDELocalHistoryPresentation.groups(await store.recentEvents())
        let action = try XCTUnwrap(groups.first { $0.id == run })
        XCTAssertEqual(action.events.count, 3)
        let restored = await workspace.localHistoryUndo(group: action)
        XCTAssertEqual(restored, 3)
        XCTAssertEqual(disk("A.txt"), "a original\n", "a file changed twice goes back to before the first change")
        XCTAssertEqual(disk("src/B.java"), "b original\n")
    }

    func testAnUnavailableRevisionIsReportedNotSilentlyIgnored() async throws {
        let (v1, _) = try await seededHistory()
        let hash = try XCTUnwrap(v1.after)
        try FileManager.default.removeItem(at: historyDirectory.appendingPathComponent("\(try XCTUnwrap(workspaceHistoryFolder()))/objects/\(hash)"))
        let before = workspace.notifications.items.count
        let done = await workspace.localHistoryRevert(toRevision: v1)
        XCTAssertFalse(done)
        XCTAssertEqual(workspace.notifications.items.count, before + 1)
        XCTAssertEqual(disk("A.txt"), "version two\n", "nothing was changed")
    }

    private func workspaceHistoryFolder() -> String? {
        try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path).first
    }
}

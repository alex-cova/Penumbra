import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// AI mode's Changes / Plan / Browser panel: what it lists, how it diffs, which addresses it opens,
/// and that it is saved with the window.
@MainActor
final class IDEAIInspectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    // MARK: - Changed files

    private func card(
        _ changes: [(String, String?)], reverted: Bool = false, conflicts: [String] = []
    ) -> IDEAgentEntry {
        var entry = IDEAgentEntry(kind: .changes, text: "")
        entry.run = UUID()
        entry.fileChanges = changes.map { IDEAgentFileChange(path: $0.0, original: $0.1) }
        entry.isReverted = reverted
        entry.conflicts = conflicts.map { IDEAgentFileChange(path: $0, original: "") }
        return entry
    }

    func testTwoRunsOnOneFileKeepTheOriginalFromBeforeTheChat() {
        let first = card([("A.txt", "v0")])
        let second = card([("A.txt", "v1"), ("B.txt", nil)])
        let files = IDEAIChangedFiles.summarize([first, IDEAgentEntry(kind: .assistant, text: "x"), second])

        XCTAssertEqual(files.map(\.path), ["A.txt", "B.txt"], "both were last touched by the second run, which listed A first")
        let a = files.first { $0.path == "A.txt" }
        XCTAssertEqual(a?.original, "v0", "compared with the file before this chat, not before the last run")
        XCTAssertEqual(a?.entryIDs, [second.id, first.id], "newest run first")
        XCTAssertEqual(files.first { $0.path == "B.txt" }?.isCreation, true)
    }

    func testTheFileTouchedMostRecentlyComesFirst() {
        let first = card([("Old.txt", "o")])
        let second = card([("New.txt", "n")])
        XCTAssertEqual(IDEAIChangedFiles.summarize([first, second]).map(\.path), ["New.txt", "Old.txt"])
    }

    func testARevertedRunDoesNotProvideTheOriginal() {
        // Run 1 changed the file and was reverted; run 2 changed it again from the restored text.
        let first = card([("A.txt", "v0")], reverted: true)
        let second = card([("A.txt", "v0")])
        let files = IDEAIChangedFiles.summarize([first, second])
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].isReverted, "a live run still touches it")
        XCTAssertEqual(files[0].original, "v0")

        // A file created by a reverted run and then created again is a creation of the second.
        let created = card([("N.txt", nil)], reverted: true)
        let recreated = card([("N.txt", nil)])
        XCTAssertEqual(IDEAIChangedFiles.summarize([created, recreated]).first?.isCreation, true)
    }

    func testAFileWhoseRunsWereAllRevertedIsMarkedReverted() {
        let only = card([("A.txt", "v0")], reverted: true)
        let files = IDEAIChangedFiles.summarize([only])
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isReverted)
        XCTAssertEqual(files[0].original, "v0")
    }

    func testAConflictOnACardMarksItsFile() {
        let entry = card([("A.txt", "v0"), ("B.txt", "b")], conflicts: ["A.txt"])
        let files = IDEAIChangedFiles.summarize([entry])
        XCTAssertTrue(files.first { $0.path == "A.txt" }?.hasConflict == true)
        XCTAssertTrue(files.first { $0.path == "B.txt" }?.hasConflict == false)
    }

    func testFilesInTheRunningTurnAreListedBeforeTheirCardExists() {
        func call(_ name: String, _ path: String, output: ToolOutput?) -> IDEAgentEntry {
            var entry = IDEAgentEntry(kind: .toolCall(name: name), text: #"{"path":"\#(path)"}"#)
            entry.output = output
            return entry
        }
        let older = card([("Old.txt", "o")])
        let entries = [
            older,
            IDEAgentEntry(kind: .user, text: "go"),
            call("read_file", "Read.txt", output: ToolOutput("x")),
            call("edit_file", "A.txt", output: ToolOutput("ok")),
            call("write_file", "B.txt", output: ToolOutput("ok")),
            call("edit_file", "A.txt", output: ToolOutput("ok")),
            call("edit_file", "Failed.txt", output: .error("no")),
            call("edit_file", "Waiting.txt", output: nil),
        ]
        XCTAssertEqual(IDEAIChangedFiles.pendingPaths(in: entries, isRunning: true), ["A.txt", "B.txt"])
        XCTAssertEqual(IDEAIChangedFiles.pendingPaths(in: entries, isRunning: false), [], "a finished run has its card")
    }

    // MARK: - Unified diff

    func testADiffHasHunksWithContext() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 10\n", with: "ten\n")
        let diff = IDEAIUnifiedDiff.make(original: before, current: after)
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.text, """
        @@ -7,7 +7,7 @@
         line 7
         line 8
         line 9
        -line 10
        +ten
         line 11
         line 12
         line 13
        """)
    }

    func testChangesCloseTogetherShareAHunk() {
        let before = (1...30).map { "l\($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...30).map { "l\($0)" }
        lines[9] = "X"
        lines[13] = "Y"
        lines[27] = "Z"
        let diff = IDEAIUnifiedDiff.make(original: before, current: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(diff.text.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count, 2, "10 and 14 share one, 28 has its own")
        XCTAssertEqual(diff.added, 3)
        XCTAssertEqual(diff.removed, 3)
    }

    func testACreatedFileIsAllAdditionsAndADeletedOneAllRemovals() {
        let created = IDEAIUnifiedDiff.make(original: nil, current: "a\nb\n")
        XCTAssertEqual(created.added, 2)
        XCTAssertEqual(created.removed, 0)
        XCTAssertEqual(created.text, "@@ -0,0 +1,2 @@\n+a\n+b")

        let deleted = IDEAIUnifiedDiff.make(original: "a\nb\n", current: nil)
        XCTAssertEqual(deleted.added, 0)
        XCTAssertEqual(deleted.removed, 2)
        XCTAssertEqual(deleted.text, "@@ -1,2 +0,0 @@\n-a\n-b")
    }

    func testNoChangeAndALineBreakAtTheEndAreNotDiffs() {
        XCTAssertTrue(IDEAIUnifiedDiff.make(original: "a\n", current: "a\n").isEmpty)
        XCTAssertTrue(IDEAIUnifiedDiff.make(original: "", current: "").isEmpty)
        XCTAssertTrue(IDEAIUnifiedDiff.make(original: "a", current: "a\n").isEmpty, "only the final line break was added")
    }

    func testAHugeRewriteIsCutAtTheOutputLimit() {
        let before = (1...5_000).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let after = (1...5_000).map { "new \($0)" }.joined(separator: "\n") + "\n"
        let diff = IDEAIUnifiedDiff.make(original: before, current: after)
        XCTAssertEqual(diff.added, 5_000)
        XCTAssertEqual(diff.removed, 5_000)
        let lines = diff.text.components(separatedBy: "\n")
        XCTAssertLessThanOrEqual(lines.count, IDEAIUnifiedDiff.maximumOutputLines + 1, "the cut hunk plus the notice")
        XCTAssertTrue(lines.first?.hasPrefix("@@") == true, "the one hunk is cut, not dropped")
        XCTAssertTrue(lines.last?.contains("truncated") == true)
    }

    // MARK: - The model reads the files as they are now

    func testTheModelDiffsAgainstTheDiskAndPrefersAnUnsavedBuffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\n2\nthree\n".write(to: root.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "kept\n".write(to: root.appendingPathComponent("B.txt"), atomically: true, encoding: .utf8)

        func file(_ path: String, _ original: String?) -> IDEAIChangedFile {
            IDEAIChangedFile(path: path, original: original, entryIDs: [UUID()], isReverted: false, hasConflict: false)
        }
        let model = IDEAIChangesModel()
        let unsaved = [root.appendingPathComponent("B.txt").path: "typed\n"]
        await model.update(
            files: [file("A.txt", "one\ntwo\nthree\n"), file("B.txt", "kept\n"), file("Gone.txt", "was\n"), file("New.txt", nil)],
            root: root, unsaved: unsaved)

        XCTAssertEqual(model.results["A.txt"]?.diff?.added, 1)
        XCTAssertEqual(model.results["A.txt"]?.diff?.removed, 1)
        XCTAssertEqual(model.results["B.txt"]?.diff?.added, 1, "the open buffer wins over the disk")
        XCTAssertEqual(model.results["Gone.txt"]?.diff?.removed, 1, "a file that is gone shows as removed")
        XCTAssertEqual(model.results["Gone.txt"]?.note, nil)
        XCTAssertEqual(model.results["New.txt"]?.note, "Deleted.", "created, then gone: nothing either side")
        XCTAssertEqual(model.totals.added, 2)
    }

    // MARK: - Browser addresses

    func testAddressesGetTheRightSchemeAndOnlyTheWebIsOpened() {
        func url(_ text: String) -> String? {
            if case .url(let url) = IDEAIBrowserAddress.normalize(text) { return url.absoluteString }
            return nil
        }
        XCTAssertEqual(url("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("127.0.0.1:8080/app"), "http://127.0.0.1:8080/app")
        XCTAssertEqual(url("  example.com/docs  "), "https://example.com/docs")
        XCTAssertEqual(url("http://example.com"), "http://example.com")
        XCTAssertEqual(url("https://localhost:8443"), "https://localhost:8443")
        XCTAssertEqual(url("mac.local:5000"), "http://mac.local:5000")
        XCTAssertEqual(url("about:blank"), "about:blank")

        for refused in ["", "   ", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "hello world", "intranet"] {
            XCTAssertNil(url(refused), "\(refused) must not open")
        }
        if case .rejected(let reason) = IDEAIBrowserAddress.normalize("file:///etc/passwd") {
            XCTAssertTrue(reason.contains("http"))
        } else {
            XCTFail("file: must be refused")
        }
    }

    func testTheNavigationPolicyStaysOnTheWeb() {
        XCTAssertTrue(IDEAIBrowserNavigationPolicy.allows(URL(string: "https://example.com")))
        XCTAssertTrue(IDEAIBrowserNavigationPolicy.allows(URL(string: "http://localhost:3000/x")))
        XCTAssertTrue(IDEAIBrowserNavigationPolicy.allows(URL(string: "about:blank")))
        XCTAssertFalse(IDEAIBrowserNavigationPolicy.allows(URL(string: "file:///etc/hosts")))
        XCTAssertFalse(IDEAIBrowserNavigationPolicy.allows(URL(string: "mailto:a@b.c")))
        XCTAssertFalse(IDEAIBrowserNavigationPolicy.allows(URL(string: "slack://open")))
        XCTAssertFalse(IDEAIBrowserNavigationPolicy.allows(nil))
    }

    func testLocalServersAreFoundInToolOutputNewestFirst() {
        func command(_ output: String, live: String = "") -> IDEAgentEntry {
            var entry = IDEAgentEntry(kind: .toolCall(name: "run_command"), text: #"{"command":"npm run dev"}"#)
            entry.output = ToolOutput(output)
            entry.liveOutput = live
            return entry
        }
        let entries = [
            command("ready - started server on 0.0.0.0:3000, url: http://localhost:3000"),
            IDEAgentEntry(kind: .assistant, text: "see http://localhost:9999 for docs"),
            command("Listening on http://127.0.0.1:5173/."),
            command("again http://localhost:3000, nothing else; and http://0.0.0.0:4000/path)."),
        ]
        let servers = IDEAIBrowserAddress.localServers(in: entries).map(\.absoluteString)
        XCTAssertEqual(servers, ["http://localhost:4000/path", "http://localhost:3000", "http://127.0.0.1:5173/"])
        XCTAssertFalse(servers.contains("http://localhost:9999"), "only tool output counts, not the model's prose")
        XCTAssertEqual(IDEAIBrowserAddress.localServers(in: entries, limit: 1).count, 1)
    }

    // MARK: - Window state

    func testThePanelStateIsSavedWithTheWindowAndOlderFilesLackIt() throws {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        XCTAssertFalse(workspace.showsAIInspector)
        workspace.showsAIInspector = true
        workspace.aiInspectorTab = .browser
        workspace.aiInspectorWidth = 444

        let session = workspace.makeSession()
        XCTAssertEqual(session.isAIInspectorVisible, true)
        XCTAssertEqual(session.aiInspectorTab, .browser)
        XCTAssertEqual(session.aiInspectorWidth, 444)

        let decoded = try JSONDecoder().decode(IDEWindowSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.isAIInspectorVisible, true)
        XCTAssertEqual(decoded.aiInspectorTab, .browser)
        XCTAssertEqual(decoded.aiInspectorWidth, 444)

        let old = try JSONDecoder().decode(IDEWindowSession.self, from: Data("{}".utf8))
        XCTAssertNil(old.isAIInspectorVisible)
        XCTAssertNil(old.aiInspectorTab)
        XCTAssertNil(old.aiInspectorWidth)
    }

    func testTheToggleOpensCodeFirstAndAskingForTheShownTabHidesIt() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }

        workspace.toggleAIInspector(tab: .plan)
        XCTAssertTrue(workspace.isAIMode)
        XCTAssertEqual(workspace.aiTab, .code, "the panel is Code's")
        XCTAssertTrue(workspace.showsAIInspector)
        XCTAssertEqual(workspace.aiInspectorTab, .plan)

        workspace.toggleAIInspector(tab: .browser)
        XCTAssertTrue(workspace.showsAIInspector, "another tab switches to it")
        XCTAssertEqual(workspace.aiInspectorTab, .browser)

        workspace.toggleAIInspector(tab: .browser)
        XCTAssertFalse(workspace.showsAIInspector, "the tab already showing hides the panel")
    }

    func testTheBrowserIsMadeOnceAndDoesNotKeepTheWindowAlive() async {
        weak var weakWorkspace: IDEWorkspace?
        weak var weakBrowser: IDEAIBrowserModel?
        do {
            let workspace = IDEWorkspace()
            weakWorkspace = workspace
            let browser = workspace.ensureAIBrowser()
            XCTAssertNotNil(browser)
            XCTAssertTrue(workspace.ensureAIBrowser() === browser, "one page per window")
            XCTAssertFalse(browser?.hasStarted ?? true, "nothing loads until an address is entered")
            weakBrowser = browser
            workspace.teardown()
            XCTAssertNil(workspace.aiBrowser)
            XCTAssertNil(workspace.ensureAIBrowser(), "no page is made for a closing window")
        }
        for _ in 0..<500 where weakWorkspace != nil || weakBrowser != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakWorkspace)
        XCTAssertNil(weakBrowser)
    }

    func testARefusedAddressLoadsNothingAndSaysWhy() {
        let browser = IDEAIBrowserModel()
        XCTAssertFalse(browser.go(to: "file:///etc/passwd"))
        XCTAssertFalse(browser.hasStarted)
        XCTAssertNotNil(browser.rejection)
        XCTAssertTrue(browser.go(to: "about:blank"))
        XCTAssertTrue(browser.hasStarted)
        XCTAssertNil(browser.rejection)
        browser.teardown()
    }
}

/// Revert All over several runs of one chat, with a real session and real files.
@MainActor
final class IDEAIInspectorRevertTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-revert-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    func testRevertAllPutsTheFileBackAsItWasBeforeTheFirstRunAndMarksBothCards() async throws {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r1", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e1", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"), .text("checked"),
            .toolCalls((id: "r2", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e2", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"three","new_string":"3"}"#)),
            .text("done"), .text("checked"),
        ])
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()

        for message in ["first", "second"] {
            controller.draft = message
            controller.submit()
            await waitFor("\(message) run ends") { !controller.isRunning && controller.entries.filter { $0.kind == .changes }.count == (message == "first" ? 1 : 2) }
        }
        XCTAssertEqual(disk("A.txt"), "one\n2\n3\n")

        let files = IDEAIChangedFiles.summarize(controller.entries)
        XCTAssertEqual(files.map(\.path), ["A.txt"])
        XCTAssertEqual(files.first?.original, "one\ntwo\nthree\n", "the row compares with the file before the chat")
        XCTAssertEqual(files.first?.entryIDs.count, 2)

        controller.selected.revertRuns(entryIDs: files.flatMap(\.entryIDs))
        await waitFor("both cards reverted") { controller.entries.filter { $0.kind == .changes }.allSatisfy(\.isReverted) }
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n", "newest run first, so the file ends as it was before the oldest")

        XCTAssertTrue(IDEAIChangedFiles.summarize(controller.entries).allSatisfy(\.isReverted))
        controller.selected.revertRuns(entryIDs: files.flatMap(\.entryIDs))
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n", "reverting again does nothing")
    }
}

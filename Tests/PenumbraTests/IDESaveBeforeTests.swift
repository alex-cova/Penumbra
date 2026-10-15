import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Unsaved buffers reach the disk before something reads it: a run, a git operation, the end of a
/// tab, a window or the app.
@MainActor
final class IDESaveBeforeTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("savebefore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func open(_ url: URL) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await eventually("the editor never showed the file") { host.textView.text == (try? String(contentsOf: url, encoding: .utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        return (document, host)
    }

    private func edit(_ document: WorkbenchDocument, in host: IDEEditorPaneHost, to text: String) {
        host.textView.text = text
        document.isDirty = true
    }

    private func eventually(_ message: String = "condition never held", seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: Run

    func testARunSessionStartsFromWhatIsOnScreen() async throws {
        let url = try write("Run.txt", "old\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "new\n")
        var seenByTheProgram: String?
        let request = IDERunRequest(
            id: UUID(), title: "Run", providerID: "test", payload: nil, allowsMultipleInstances: false,
            prepare: { [directory] _ in
                seenByTheProgram = try? String(contentsOf: directory!.appendingPathComponent("Run.txt"), encoding: .utf8)
            }
        )

        _ = workspace.runs.start(request)

        await eventually("the run never started") { seenByTheProgram != nil }
        XCTAssertEqual(seenByTheProgram, "new\n")
        XCTAssertFalse(document.isDirty)
    }

    func testAFileThatCannotBeSavedDoesNotStopTheRun() async throws {
        let url = try write("Held.txt", "base\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        var started = false
        let request = IDERunRequest(
            id: UUID(), title: "Run", providerID: "test", payload: nil, allowsMultipleInstances: false,
            prepare: { _ in started = true }
        )

        _ = workspace.runs.start(request)

        await eventually("the run never started") { started }
        XCTAssertEqual(try read(url), "theirs\n", "a newer file on disk must not be overwritten by a run")
        XCTAssertTrue(document.isDirty)
    }

    func testAfterSavingUnsavedRunsAtOnceWhenThereIsNothingToSave() {
        var ran = false
        workspace.afterSavingUnsaved { ran = true }
        XCTAssertTrue(ran)
    }

    // MARK: Git

    func testAGitOperationSavesFirstAndThenRuns() async {
        let model = IDEGitStatusModel()
        var unsaved = true
        var order: [String] = []
        model.hasUnsavedEditors = { unsaved }
        model.saveUnsavedEditors = {
            order.append("save")
            unsaved = false
            return []
        }

        model.afterSaving(before: "pulling") { order.append("pull") }

        await eventually { order == ["save", "pull"] }
        XCTAssertEqual(order, ["save", "pull"])
    }

    func testAGitOperationStopsWhenAFileCannotBeSaved() async {
        let model = IDEGitStatusModel()
        var ran = false
        model.hasUnsavedEditors = { true }
        model.saveUnsavedEditors = { ["Main.java"] }

        model.afterSaving(before: "pulling") { ran = true }

        await eventually { model.actionFailed }
        XCTAssertFalse(ran)
        XCTAssertEqual(model.actionStatus, "Couldn't save Main.java before pulling.")
    }

    func testAGitOperationWithNothingUnsavedRunsAtOnce() {
        let model = IDEGitStatusModel()
        model.hasUnsavedEditors = { false }
        var ran = false
        model.afterSaving(before: "pulling") { ran = true }
        XCTAssertTrue(ran)
    }

    func testWithoutASaverAGitOperationStillRefuses() {
        let model = IDEGitStatusModel()
        model.hasUnsavedEditors = { true }
        var ran = false
        model.afterSaving(before: "merging") { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(model.actionStatus, "Save unsaved changes before merging.")
    }

    // MARK: Closing a tab

    func testClosingADirtyTabSavesItFirst() async throws {
        let url = try write("Close.txt", "old\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "edited\n")
        workspace.closePromptResolver = { _, _ in
            XCTFail("a file that can be saved must not be asked about")
            return .cancel
        }

        workspace.requestCloseTab(document.id, in: workspace.workbench.activePaneID)

        await eventually("the tab never closed") { !self.workspace.workbench.allDocuments().contains { $0.id == document.id } }
        XCTAssertEqual(try read(url), "edited\n")
    }

    func testClosingACleanTabClosesAtOnce() async throws {
        let url = try write("Clean.txt", "same\n")
        let (document, _) = try await open(url)

        workspace.requestCloseTab(document.id, in: workspace.workbench.activePaneID)

        XCTAssertFalse(workspace.workbench.allDocuments().contains { $0.id == document.id })
    }

    func testClosingATabWhoseFileChangedOnDiskAsksAndCancelKeepsIt() async throws {
        let url = try write("Newer.txt", "base\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        var asked: IDEClosePrompt?
        workspace.closePromptResolver = { _, prompt in
            asked = prompt
            return .cancel
        }

        workspace.requestCloseTab(document.id, in: workspace.workbench.activePaneID)

        await eventually("it never asked") { asked != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(workspace.workbench.allDocuments().contains { $0.id == document.id })
        XCTAssertEqual(try read(url), "theirs\n")
        XCTAssertTrue(document.isDirty)
    }

    func testCloseAnywayDropsTheEditsOfAFileThatCouldNotBeSaved() async throws {
        let url = try write("Drop.txt", "base\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.closePromptResolver = { _, _ in .discard }

        workspace.requestCloseTab(document.id, in: workspace.workbench.activePaneID)

        await eventually("the tab never closed") { !self.workspace.workbench.allDocuments().contains { $0.id == document.id } }
        XCTAssertEqual(try read(url), "theirs\n")
    }

    func testClosingAnUntitledBufferAsksAndDontSaveCloses() async throws {
        workspace.newFile()
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        document.isDirty = true
        var asked: IDEClosePrompt?
        workspace.closePromptResolver = { _, prompt in
            asked = prompt
            return .discard
        }

        workspace.requestCloseTab(document.id, in: workspace.workbench.activePaneID)

        await eventually("the tab never closed") { !self.workspace.workbench.allDocuments().contains { $0.id == document.id } }
        XCTAssertEqual(asked, .untitled)
    }

    // MARK: Closing the window

    func testClosingTheWindowSavesBeforeAnyQuestion() async throws {
        let url = try write("Window.txt", "old\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "edited\n")

        let mayClose = await workspace.confirmCloseWindow()

        XCTAssertTrue(mayClose)
        XCTAssertEqual(try read(url), "edited\n")
        XCTAssertFalse(document.isDirty)
    }
}

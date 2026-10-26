import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Save All and the shared save path: tabs in the background are written from their captured
/// state, untitled buffers are listed instead of prompting, and a save that may not ask raises the
/// banner for a file that changed on disk.
@MainActor
final class IDESaveAllTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var savedPolicy: IDEExternalChangePolicy = .always

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        savedPolicy = IDEPreferences.shared.externalChangePolicy
        IDEPreferences.shared.externalChangePolicy = .always
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("saveall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEPreferences.shared.externalChangePolicy = savedPolicy
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

    /// Opens `url` in the active pane and waits until the editor shows it and its baseline is read.
    private func open(_ url: URL) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await eventually("the editor never showed the file") { host.textView.text == (try? String(contentsOf: url, encoding: .utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        return (document, host)
    }

    private func eventually(_ message: String = "condition never held", seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    private func edit(_ document: WorkbenchDocument, in host: IDEEditorPaneHost, to text: String) {
        host.textView.text = text
        document.isDirty = true
    }

    // MARK: Save All

    func testSaveAllWritesTheLiveTabAndTheOneInTheBackground() async throws {
        let first = try write("a.txt", "a\n")
        let second = try write("b.txt", "b\n")
        let (firstDocument, host) = try await open(first)
        edit(firstDocument, in: host, to: "a edited\n")
        // Opening another file puts the first one in the background, with its edits captured.
        let (secondDocument, _) = try await open(second)
        edit(secondDocument, in: workspace.host(for: workspace.workbench.activePaneID), to: "b edited\n")
        XCTAssertTrue(firstDocument.isDirty)
        XCTAssertNotEqual(firstDocument.id, secondDocument.id)

        let report = await workspace.saveAll()

        XCTAssertEqual(report.saved, 2)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(try read(first), "a edited\n")
        XCTAssertEqual(try read(second), "b edited\n")
        XCTAssertFalse(firstDocument.isDirty)
        XCTAssertFalse(secondDocument.isDirty)
    }

    func testSaveAllWithNothingUnsavedDoesNothing() async throws {
        let url = try write("clean.txt", "same\n")
        _ = try await open(url)

        let report = await workspace.saveAll()

        XCTAssertEqual(report, IDESaveAllReport())
        XCTAssertEqual(try read(url), "same\n")
    }

    func testSaveAllListsAnUntitledBufferInsteadOfAskingForAName() async throws {
        workspace.newFile()
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertNil(document.url)
        document.isDirty = true

        let outcome = await workspace.saveDocument(document, reason: .saveAll)
        XCTAssertEqual(outcome, .skippedUntitled)

        let report = await workspace.saveAll()
        XCTAssertEqual(report.untitled, [document.displayName])
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(document.isDirty)
    }

    func testASaveThatMayNotAskRefusesANewerFileAndRaisesTheBanner() async throws {
        let url = try write("conflict.txt", "base\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.saveConflictResolver = { _ in
            XCTFail("an agent save must not ask")
            return .overwrite
        }

        let outcome = await workspace.saveDocument(document, reason: .agent)

        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(try read(url), "theirs\n")
        XCTAssertEqual(workspace.externalChangeState(of: document), .changedOnDisk)
        XCTAssertTrue(document.isDirty)
    }

    func testSaveAllAsksAboutANewerFileLikeSave() async throws {
        let url = try write("ask.txt", "base\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        var asked = 0
        workspace.saveConflictResolver = { _ in
            asked += 1
            return .overwrite
        }

        let report = await workspace.saveAll()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(report.saved, 1)
        XCTAssertEqual(try read(url), "mine\n")
    }

    func testAnExplicitSaveStillReturnsWhetherTheFileWasWritten() async throws {
        let url = try write("explicit.txt", "one\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "two\n")

        let saved = await workspace.saveActiveDocument()

        XCTAssertTrue(saved)
        XCTAssertEqual(try read(url), "two\n")
        XCTAssertFalse(document.isDirty)
    }

    // MARK: Mark modified

    func testUnsavedPathsFollowTheDirtyBuffers() async throws {
        let url = try write("marked.txt", "x\n")
        let (document, host) = try await open(url)
        XCTAssertTrue(workspace.unsavedPaths.isEmpty)

        edit(document, in: host, to: "y\n")
        workspace.refreshPresentation()
        XCTAssertEqual(workspace.unsavedPaths, [url.standardizedFileURL.path])

        _ = await workspace.saveAll()
        XCTAssertTrue(workspace.unsavedPaths.isEmpty)
    }

    // MARK: Reload

    func testReloadAllReloadsACleanTabEvenWhenThePolicyIsNever() async throws {
        IDEPreferences.shared.externalChangePolicy = .never
        let url = try write("reload.txt", "old\n")
        let (_, host) = try await open(url)
        try "new\n".write(to: url, atomically: true, encoding: .utf8)

        await workspace.reloadAllFromDisk()

        await eventually("the clean tab did not reload") { host.textView.text == "new\n" }
    }

    func testReloadAllRaisesTheBannerForATabWithUnsavedEdits() async throws {
        let url = try write("dirty.txt", "old\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)

        await workspace.reloadAllFromDisk()

        XCTAssertEqual(host.textView.text, "mine\n")
        XCTAssertEqual(workspace.externalChangeState(of: document), .changedOnDisk)
    }
}

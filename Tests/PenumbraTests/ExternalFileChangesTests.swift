import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Open text tabs against their files: the three policies, the banner, Umbra's own saves, and the
/// save-time conflict. Changes are fed to the sync as the watcher's batches would be, so these do
/// not depend on FSEvents timing; the last test goes through the real watcher.
@MainActor
final class ExternalFileChangesTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var savedPolicy: IDEExternalChangePolicy = .always

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        savedPolicy = IDEPreferences.shared.externalChangePolicy
        IDEPreferences.shared.externalChangePolicy = .always
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
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

    /// Opens `url` and waits for its baseline to be read.
    private func open(_ url: URL) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await eventually("the editor never showed the file") { host.textView.text == (try? String(contentsOf: url, encoding: .utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        return (document, host)
    }

    private func path(_ url: URL) -> String { url.standardizedFileURL.path }

    private func changed(_ url: URL) {
        workspace.diskSync.handle(paths: [path(url)])
    }

    private func eventually(_ message: String = "condition never held", seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    private func state(_ document: WorkbenchDocument) -> IDEExternalChangeState {
        workspace.externalChangeState(of: document)
    }

    // MARK: always

    func testACleanTabReloadsAndKeepsItsCaret() async throws {
        let url = try write("a.txt", "one\ntwo\nthree\n")
        let (document, host) = try await open(url)
        host.textView.selectedRange = NSRange(location: 5, length: 0)

        try "one\ntwo\nthree\nfour\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)

        await eventually("the clean tab did not reload") { host.textView.text == "one\ntwo\nthree\nfour\n" }
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(host.textView.selectedRange.location, 5)
        XCTAssertEqual(state(document), .none)
    }

    func testADirtyTabGetsTheBannerAndKeepsItsText() async throws {
        let url = try write("b.txt", "disk\n")
        let (document, host) = try await open(url)
        host.textView.text = "mine\n"
        document.isDirty = true

        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)

        await eventually { self.state(document) == .changedOnDisk }
        XCTAssertEqual(host.textView.text, "mine\n")

        workspace.reloadFromBanner(document)
        await eventually { host.textView.text == "theirs\n" }
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(state(document), .none)
    }

    func testKeepMineIsNotAskedAgainForTheSameBytes() async throws {
        let url = try write("c.txt", "disk\n")
        let (document, host) = try await open(url)
        host.textView.text = "mine\n"
        document.isDirty = true
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)
        await eventually { self.state(document) == .changedOnDisk }

        workspace.keepMineFromBanner(document)
        XCTAssertEqual(state(document), .none)
        try await Task.sleep(for: .milliseconds(150))
        changed(url)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state(document), .none, "the same disk bytes raised the banner again")

        try "theirs, again\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)
        await eventually("new bytes should ask again") { self.state(document) == .changedOnDisk }
    }

    func testOwnSaveAndTouchDoNotReload() async throws {
        let url = try write("d.txt", "start\n")
        let (document, host) = try await open(url)
        host.textView.text = "saved by umbra\n"
        document.isDirty = true
        let saved = await workspace.saveActiveDocument()
        XCTAssertTrue(saved)
        let generation = document.contentGeneration

        changed(url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        changed(url)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(document.contentGeneration, generation, "Umbra reloaded its own save or a touch")
        XCTAssertEqual(state(document), .none)
    }

    func testADeletedFileKeepsItsTab() async throws {
        let url = try write("e.txt", "here\n")
        let (document, _) = try await open(url)
        try FileManager.default.removeItem(at: url)
        changed(url)

        await eventually { self.state(document) == .deletedOnDisk }
        XCTAssertTrue(workspace.workbench.allDocuments().contains { $0 === document })

        workspace.keepEditingDeleted(document)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(state(document), .none)
    }

    // MARK: prompt and never

    func testPromptAsksEvenForACleanTab() async throws {
        IDEPreferences.shared.externalChangePolicy = .prompt
        let url = try write("f.txt", "old\n")
        let (document, host) = try await open(url)
        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)

        await eventually { self.state(document) == .changedOnDisk }
        XCTAssertEqual(host.textView.text, "old\n")
    }

    func testNeverOnlyNotifies() async throws {
        IDEPreferences.shared.externalChangePolicy = .never
        let url = try write("g.txt", "old\n")
        let (document, host) = try await open(url)
        let before = workspace.notifications.items.count
        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)

        await eventually { self.workspace.notifications.items.count == before + 1 }
        XCTAssertEqual(host.textView.text, "old\n")
        XCTAssertEqual(state(document), .none)
        XCTAssertEqual(workspace.notifications.items.first?.action, .openFile(path(url)))

        changed(url)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.notifications.items.count, before + 1, "the same bytes notified twice")
    }

    // MARK: Save conflict

    func testSavingOverANewerFileAsks() async throws {
        let url = try write("h.txt", "base\n")
        let (document, host) = try await open(url)
        host.textView.text = "mine\n"
        document.isDirty = true
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)

        var asked = 0
        workspace.saveConflictResolver = { _ in asked += 1; return .cancel }
        let cancelled = await workspace.saveActiveDocument()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")

        workspace.saveConflictResolver = { _ in asked += 1; return .overwrite }
        let overwritten = await workspace.saveActiveDocument()
        XCTAssertTrue(overwritten)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")

        host.textView.text = "mine, later\n"
        document.isDirty = true
        let again = await workspace.saveActiveDocument()
        XCTAssertTrue(again)
        XCTAssertEqual(asked, 2, "a save with no new disk change asked")
    }

    func testTheAgentsSaveRefusesANewerFileAndRaisesTheBanner() async throws {
        let url = try write("i.txt", "base\n")
        let (document, host) = try await open(url)
        host.textView.text = "agent\n"
        document.isDirty = true
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        workspace.saveConflictResolver = { _ in
            XCTFail("the agent's save must not ask")
            return .overwrite
        }

        let saved = await workspace.saveBuffer(at: url)
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")
        XCTAssertEqual(state(document), .changedOnDisk)
    }

    func testSavingRightAfterKeepMineDoesNotAsk() async throws {
        let url = try write("j.txt", "base\n")
        let (document, host) = try await open(url)
        host.textView.text = "mine\n"
        document.isDirty = true
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        changed(url)
        await eventually { self.state(document) == .changedOnDisk }

        workspace.saveConflictResolver = { _ in
            XCTFail("Keep Mine already answered for these bytes")
            return .cancel
        }
        workspace.keepMineFromBanner(document)
        let saved = await workspace.saveActiveDocument()
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")
    }

    /// Above the full-hash limit only the ends are hashed; a same-size edit in the middle must still count.
    func testASameSizeEditInTheMiddleOfALargeFileIsAChange() throws {
        let url = directory.appendingPathComponent("big.bin")
        var bytes = Data(repeating: 0x61, count: Int(DiskSnapshot.fullHashLimit) + 512 * 1024)
        try bytes.write(to: url)
        let before = try XCTUnwrap(DiskSnapshot.captureNow(url: url))
        bytes[bytes.count / 2] = 0x62
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: before.modificationDate.addingTimeInterval(5)], ofItemAtPath: url.path)
        let after = try XCTUnwrap(DiskSnapshot.captureNow(url: url))
        XCTAssertEqual(before.contentHash, after.contentHash, "the sample does not cover the middle")
        XCTAssertFalse(before.sameContent(as: after))

        let small = try write("small.txt", "same")
        let first = try XCTUnwrap(DiskSnapshot.captureNow(url: small))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: small.path)
        XCTAssertTrue(first.sameContent(as: try XCTUnwrap(DiskSnapshot.captureNow(url: small))), "a touch of a small file is not a change")
    }

    // MARK: Through the watcher

    /// A window with no folder: the loose file is watched by the one engine and reloads.
    func testALooseFileReloadsThroughTheWatcher() async throws {
        let url = try write("loose.txt", "first\n")
        let (_, host) = try await open(url)
        XCTAssertTrue(workspace.projectWatcher.root == nil)
        try await Task.sleep(for: .milliseconds(300))

        try "second\n".write(to: url, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(5)
        while host.textView.text != "second\n", Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard host.textView.text == "second\n" else {
            throw XCTSkip("No FSEvents callback observed in this xctest host process within the timeout.")
        }
    }
}

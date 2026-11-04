import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// F25 in the window: a file over 50 MB opens as plain text under a banner, Enable Anyway reloads it
/// with full service, a read-only tier holds, and skipped index files are announced once.
@MainActor
final class LargeFileModeUmbraTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        // 1 MB instead of 50: the same code path, without a 53 MB file taking a minute to analyse.
        workspace.largeFileBasePolicy = LargeFilePolicy(degradeBytes: 1_048_576, readOnlyBytes: 500 * 1_048_576)
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeSwift(_ name: String, megabytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data(String(repeating: "let value = compute(items) // padding padding\n", count: 22_000).utf8) // ~1 MB
        for _ in 0..<megabytes { try handle.write(contentsOf: chunk) }
        try handle.close()
        return url
    }

    private func eventually(_ message: String, seconds: Double = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), message)
    }

    private func openLarge() async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        let url = try writeSwift("generated.swift", megabytes: 2) // over the 1 MiB test threshold (a chunk is ~1.01 million bytes)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        await eventually("the editor never showed the file") { host.textView.documentLength > 0 }
        return (document, host)
    }

    func testAFileOver50MBOpensAsPlainTextUnderATier() async throws {
        let (document, host) = try await openLarge()
        XCTAssertEqual(document.largeFileNotice?.tier, .degraded)
        XCTAssertNil(document.language)
        XCTAssertEqual(document.languageIdentifier, "swift", "the status bar still says what the file is")
        XCTAssertNil(document.intelligenceLanguageIdentifier)
        XCTAssertEqual(host.textView.largeFileTier, .degraded)
        XCTAssertNil(host.textView.languageIdentifier, "no language services for it")
        XCTAssertFalse(host.textView.isLineFoldingEnabled)
        XCTAssertTrue(host.textView.isEditable, "degraded is still editable")
    }

    func testEnableAnywayReloadsWithFullService() async throws {
        let (document, host) = try await openLarge()
        workspace.enableLargeFileFeatures(for: document)
        await eventually("Enable Anyway never reloaded") { document.largeFileNotice == nil && host.textView.largeFileTier == .normal }
        XCTAssertNotNil(document.language)
        XCTAssertEqual(host.textView.languageIdentifier, "swift")
        XCTAssertTrue(workspace.liftedLargeFilePaths.contains(document.url!.standardizedFileURL.path))
    }

    func testATabWithUnsavedEditsCannotEnableAnywayBecauseTheReloadWouldDropThem() async throws {
        // A small file given a notice: a dirty 53 MB buffer is slow to tear down, and the guard is the point.
        let url = directory.appendingPathComponent("small.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        document.largeFileNotice = LargeFileNotice(tier: .degraded, byteCount: 60 * 1_048_576)
        document.isDirty = true
        workspace.enableLargeFileFeatures(for: document)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(document.largeFileNotice)
        XCTAssertTrue(workspace.liftedLargeFilePaths.isEmpty)
        document.isDirty = false
    }

    func testTheReadOnlyTierHoldsInTheWindow() async throws {
        let url = directory.appendingPathComponent("small.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let pane = workspace.workbench.activePane
        let host = workspace.host(for: pane.id)
        await eventually("the editor never showed the file") { host.textView.documentLength > 0 }
        XCTAssertTrue(host.textView.isEditable)

        document.largeFileNotice = LargeFileNotice(tier: .readOnly, byteCount: 600 * 1_048_576)
        document.contentGeneration &+= 1 // a reload does this; without it the pane keeps what it shows
        workspace.showDocument(in: pane, host: host)

        await eventually("the reload never applied the tier") { host.textView.largeFileTier == .readOnly }
        XCTAssertFalse(host.textView.isEditable)
    }

    func testSkippedSourceFilesAreAnnouncedOncePerSet() {
        let files = [URL(fileURLWithPath: "/p/Big.swift"), URL(fileURLWithPath: "/p/Huge.swift")]
        let before = workspace.notifications.items.count
        workspace.noteOversizedSourceFiles(files, language: "Swift")
        workspace.noteOversizedSourceFiles(files, language: "Swift")
        XCTAssertEqual(workspace.notifications.items.count, before + 1)
        XCTAssertEqual(workspace.notifications.items.first?.title, "2 Swift files over 1 MB not indexed")
    }
}

import AppKit
import Foundation
import XCTest
@testable import Umbra

/// F-11: the availability refreshes write `runEligibility`, not workspace vars. Drives the real
/// updater with a real editor and asserts the store, pinning the path the module-contribution
/// tests read from the other side.
@MainActor
final class IDERunEligibilityTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eligibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    func testHTTPGutterSetsSendEligibility() async throws {
        let url = directory.appendingPathComponent("api.http")
        try "GET https://example.com/items\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView

        workspace.refreshHTTPGutter(from: textView, fileURL: url, text: textView.text)
        XCTAssertTrue(workspace.runEligibility.httpFileCanSend)

        // A new generation: the stamp dedupes same-generation refreshes, so the buffer edits.
        textView.replace(NSRange(location: 0, length: textView.documentLength), withText: "# just a comment\n")
        workspace.refreshHTTPGutter(from: textView, fileURL: url, text: textView.text)
        XCTAssertFalse(workspace.runEligibility.httpFileCanSend)
    }

    func testNonHTTPDocumentClearsSendEligibility() async throws {
        let url = directory.appendingPathComponent("api.http")
        try "GET https://example.com/items\n".write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        workspace.refreshHTTPGutter(from: textView, fileURL: url, text: textView.text)
        XCTAssertTrue(workspace.runEligibility.httpFileCanSend)

        let notes = directory.appendingPathComponent("notes.txt")
        try "hello\n".write(to: notes, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: notes)
        workspace.refreshHTTPSendAvailability(from: textView)
        XCTAssertFalse(workspace.runEligibility.httpFileCanSend)
    }
}

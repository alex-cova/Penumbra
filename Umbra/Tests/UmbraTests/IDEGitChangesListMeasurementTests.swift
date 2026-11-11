import AppKit
import GitIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// How many change-row bodies run while the commit field changes. Debug, not Instruments.
/// A 2,000-file repository, an offscreen hosting view, twenty assignments to `commitMessage`
/// (the same observation the text field's binding writes).
@MainActor
final class IDEGitChangesListMeasurementTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace?
    private var window: NSWindow?
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-list-measure-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        window?.contentView = nil
        window?.close()
        window = nil
        workspace?.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTypingTheCommitMessageDoesNotRebuildChangeRows() async throws {
        let count = 2_000
        let bytes = Data("a\n".utf8)
        for index in 0..<count {
            try bytes.write(to: directory.appendingPathComponent(String(format: "f%04d.txt", index)))
        }
        _ = try await runner.run(["add", "-A"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "base"], in: directory)
        let edited = Data("b\n".utf8)
        for index in 0..<count {
            try edited.write(to: directory.appendingPathComponent(String(format: "f%04d.txt", index)))
        }

        let workspace = IDEWorkspace()
        self.workspace = workspace
        workspace.bootstrap()
        workspace.gitStatus.setRoot(directory)
        try await waitUntil("2,000 changes") { workspace.gitStatus.changes.count == count }

        let host = NSHostingView(
            rootView: IDEChangesPanel(gitStatus: workspace.gitStatus)
                .environment(workspace)
                .frame(width: 360, height: 640)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        host.layoutSubtreeIfNeeded()
        await spin()
        await spin()

        let beforeRows = IDEBodyDiagnostics.count("IDESourceControlChangeRow")
        XCTAssertGreaterThan(beforeRows, 0, "the list did not realize any rows")
        let beforePanel = IDEBodyDiagnostics.count("IDEChangesPanel")
        let beforeDiff = IDEBodyDiagnostics.count("IDEEmbeddedDiffView")
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<20 {
            workspace.gitStatus.commitMessage.append("a")
            await spin()
        }
        let elapsed = clock.now - started
        let rowDelta = IDEBodyDiagnostics.count("IDESourceControlChangeRow") - beforeRows
        let panelDelta = IDEBodyDiagnostics.count("IDEChangesPanel") - beforePanel
        let diffDelta = IDEBodyDiagnostics.count("IDEEmbeddedDiffView") - beforeDiff
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        print(
            "CHANGES_LIST rows=\(rowDelta) panel=\(panelDelta) diff=\(diffDelta) characters=20 changes=\(count) " +
            "elapsed=\(elapsed) configuration=\(configuration) NSHostingView 360x640 offscreen no file selected"
        )
        XCTAssertEqual(workspace.gitStatus.changes.count, count)
        XCTAssertEqual(workspace.gitStatus.commitMessage.count, 20)
        XCTAssertEqual(rowDelta, 0, "commit-field edits rebuilt change rows")
        XCTAssertEqual(diffDelta, 0)
        XCTAssertGreaterThan(panelDelta, 0, "the panel did not update while the message changed")
    }

    private func spin() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

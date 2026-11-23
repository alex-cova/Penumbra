import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Audit G-07: git reports paths under its own, symlink-resolved spelling of the work tree. A
/// project opened through a symlink must therefore be opened as the resolved folder, or every
/// status lookup by the user's spelling misses.
@MainActor
final class IDEGitSymlinkRootTests: XCTestCase {
    private var base: URL!
    private var real: URL!
    private var link: URL!
    private var workspace: IDEWorkspace!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        // `base` is resolved so `real` is the true path; `link` is a genuine symlink to it.
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-symlink-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        real = base.appendingPathComponent("real", isDirectory: true)
        link = base.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: real)
        }
        try "1\n".write(to: real.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: real)
        _ = try await runner.run(["commit", "-qm", "base"], in: real)
        try "2\n".write(to: real.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testAProjectOpenedThroughASymlinkIsOpenedAsTheResolvedFolderAndHasGitState() async throws {
        XCTAssertNotEqual(link.resolvingSymlinksInPath().path, link.path, "the fixture's link must be a real symlink")
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.openProjectFolder(link)

        XCTAssertEqual(workspace.project.rootURL?.standardizedFileURL.path, real.path)
        try await waitUntil("git state") { self.workspace.gitStatus.workspaceSnapshot != nil }
        XCTAssertEqual(
            workspace.gitStatus.status(for: real.appendingPathComponent("a.txt"), isDirectory: false), .modified,
            "the modified file must show in the Explorer"
        )
        XCTAssertEqual(workspace.gitStatus.changes.map(\.relativePath), ["a.txt"])
    }

    func testReplacingTheProjectWithASymlinkResolvesIt() async throws {
        workspace = IDEWorkspace()
        workspace.bootstrap()
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        workspace.openProjectFolder(other)
        workspace.replaceProject(with: link)
        XCTAssertEqual(workspace.project.rootURL?.standardizedFileURL.path, real.path)
        try await waitUntil("git state") { self.workspace.gitStatus.workspaceSnapshot != nil }
        XCTAssertEqual(workspace.gitStatus.status(for: real.appendingPathComponent("a.txt"), isDirectory: false), .modified)
    }
}

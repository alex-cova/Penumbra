import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Opening a project must not run a program its `.git/config` names (`core.fsmonitor` runs on
/// `status`). The library suite covers the commands; this opens the repository through the model.
@MainActor
final class IDEGitUntrustedConfigTests: XCTestCase {
    func testOpeningARepositoryWithAnFsmonitorHookRunsNothing() async throws {
        let runner = SystemGitRunner()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-open-hostile-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        try "a\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        let marker = base.appendingPathComponent("fsmonitor-ran")
        let hook = base.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await runner.run(["config", "core.fsmonitor", hook.path], in: directory)
        try "b\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let model = IDEGitStatusModel()
        model.setRoot(directory)
        let deadline = Date().addingTimeInterval(10)
        while model.workspaceSnapshot == nil, Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertNotNil(model.workspaceSnapshot, "the repository never loaded")
        XCTAssertEqual(model.changes.map(\.relativePath), ["a.txt"])
        model.setRoot(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "opening the project ran core.fsmonitor")
    }
}

import Foundation
import GitIntelligence
import XCTest

@testable import Umbra

/// The harness-5 worktree manifest: only Umbra-created paths are ever removed.
final class IDEAgentWorktreeStoreTests: XCTestCase {
    private var directory: URL!
    private var repo: URL!
    private var store: IDEAgentWorktreeStore!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-worktrees-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        directory = base.appendingPathComponent("store", isDirectory: true)
        repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "T")
        try git("config", "commit.gpgsign", "false")
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "base")
        store = IDEAgentWorktreeStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }

    private func repository() async -> GitRepository? {
        await GitRepository.discover(from: repo)
    }

    func testBranchNameIsSluggedAndSuffixedWhenTaken() {
        XCTAssertEqual(
            IDEAgentWorktreeStore.branchName(for: "Fix the login crash!", taken: []), "fix-the-login-crash")
        XCTAssertEqual(
            IDEAgentWorktreeStore.branchName(for: "Fix the login crash!", taken: ["fix-the-login-crash"]),
            "fix-the-login-crash-2")
        XCTAssertEqual(IDEAgentWorktreeStore.branchName(for: "!!!", taken: []), "worktree")
    }

    func testCreateRegistersAndDiscardRemovesOnlyThatWorktree() async throws {
        let discovered = await self.repository()
        let repository = try XCTUnwrap(discovered)
        let (path, branch) = try await store.create(repository: repository, title: "My Feature")
        XCTAssertEqual(branch, "my-feature")
        XCTAssertTrue(store.contains(path: path.path))
        XCTAssertFalse(store.contains(path: repo.path), "the main tree is never in the manifest")

        // The chat's root would be the worktree while the main tree stays clean.
        try "two\n".write(to: path.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path))

        // A dirty worktree is refused, never forced away.
        do {
            _ = try await store.discard(repository: repository, path: path.path)
            XCTFail("Expected a dirty worktree to be refused")
        } catch {
            XCTAssertTrue(store.contains(path: path.path), "a refused discard keeps the manifest entry")
        }
        try FileManager.default.removeItem(at: path.appendingPathComponent("b.txt"))

        let report = try await store.discard(repository: repository, path: path.path)
        XCTAssertTrue(report.contains("my-feature"), report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(store.contains(path: path.path))
        let branches = try await repository.branches().filter { $0.kind == .localBranch }.map(\.name)
        XCTAssertFalse(branches.contains("my-feature"))
        // The main tree is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }

    func testDiscardRefusesPathsOutsideTheManifest() async throws {
        let discovered = await self.repository()
        let repository = try XCTUnwrap(discovered)
        do {
            _ = try await store.discard(repository: repository, path: repo.path)
            XCTFail("Expected the main tree to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a worktree Umbra created"))
        }
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        do {
            _ = try await store.discard(repository: repository, path: elsewhere.path)
            XCTFail("Expected an unmanifested path to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a worktree Umbra created"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "refused paths are never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }
}

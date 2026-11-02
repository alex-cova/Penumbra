import Foundation
import Testing

@testable import GitIntelligence

@Suite struct GitWorktreeParserTests {
    @Test func parsesMainAndLinkedWorktrees() {
        let porcelain = """
        worktree /repo
        HEAD abc123def456abc123def456abc123def456abc1
        branch refs/heads/main

        worktree /tmp/umbra/feature
        HEAD def456abc123def456abc123def456abc123def4
        branch refs/heads/feature

        """
        let worktrees = GitWorktreeParser.parse(porcelain)
        #expect(worktrees.count == 2)
        #expect(worktrees[0].path == "/repo")
        #expect(worktrees[0].branch == "main")
        #expect(!worktrees[0].isBare && !worktrees[0].isDetached)
        #expect(worktrees[1].path == "/tmp/umbra/feature")
        #expect(worktrees[1].branch == "feature")
    }

    @Test func parsesDetachedBareAndExtraLines() {
        let porcelain = """
        worktree /repo/detached
        HEAD abc123def456abc123def456abc123def456abc1
        detached

        worktree /repo/bare.git
        HEAD abc123def456abc123def456abc123def456abc1
        bare
        locked

        worktree /repo/gone
        HEAD abc123def456abc123def456abc123def456abc1
        branch refs/heads/stale
        prunable

        """
        let worktrees = GitWorktreeParser.parse(porcelain)
        #expect(worktrees.count == 3)
        #expect(worktrees[0].isDetached && worktrees[0].branch == nil)
        #expect(worktrees[1].isBare && worktrees[1].branch == nil)
        #expect(worktrees[2].branch == "stale")
    }

    @Test func emptyOutputIsNoWorktrees() {
        #expect(GitWorktreeParser.parse("").isEmpty)
    }

    @Test func addListAndRemoveRoundTrip() async throws {
        guard FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath) else { return }
        let runner = SystemGitRunner()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: root)
        }
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: root)
        _ = try await runner.run(["commit", "-q", "-m", "base"], in: root)

        let repository = GitRepository(root: root, runner: runner)
        let linked = root.deletingLastPathComponent()
            .appendingPathComponent("git-worktree-linked-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: linked) }

        _ = try await repository.worktreeAdd(path: linked.path, branch: "feature")
        // git prints the canonical path (/private/var/…); the test's TMPDIR may use /var/….
        let suffix = "/" + linked.lastPathComponent
        let listed = try await repository.worktreeList()
        #expect(listed.count == 2)
        let entry = listed.first(where: { $0.path.hasSuffix(suffix) })
        #expect(entry != nil)
        #expect(entry?.branch == "feature")

        _ = try await repository.worktreeRemove(path: linked.path)
        let after = try await repository.worktreeList()
        #expect(after.count == 1)
        #expect(!after.contains(where: { $0.path.hasSuffix(suffix) }))
    }
}

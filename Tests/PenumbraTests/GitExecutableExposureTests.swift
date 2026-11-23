import XCTest
@testable import GitIntelligence

/// `executableExposure()` lists what a repository's own files could make git run on a user action:
/// hooks and config that name programs. Umbra asks before the first change in such a repository.
final class GitExecutableExposureTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-exposure-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func repository() async throws -> GitRepository {
        let found = await GitRepository.discover(from: directory)
        return try XCTUnwrap(found)
    }

    private func config(_ key: String, _ value: String) async throws {
        _ = try await runner.run(["config", "--local", key, value], in: directory)
    }

    private func names(_ repo: GitRepository) async -> [String] {
        await repo.executableExposure().map(\.name)
    }

    func testAPlainRepositoryExposesNothing() async throws {
        let repo = try await repository()
        let exposure = await repo.executableExposure()
        XCTAssertEqual(exposure, [])
    }

    func testOnlyExecutableHooksCountAndSamplesDoNot() async throws {
        let hooks = directory.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: hooks.appendingPathComponent("pre-commit.sample"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("pre-commit.sample").path)
        try "#!/bin/sh\n".write(to: hooks.appendingPathComponent("commit-msg"), atomically: true, encoding: .utf8)
        let repo = try await repository()
        let notExecutable = await names(repo)
        XCTAssertEqual(notExecutable, [], "git does not run a hook without the execute bit")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("commit-msg").path)
        let executable = await repo.executableExposure()
        XCTAssertEqual(executable, [GitExecutableExposure(kind: .hook, name: "commit-msg")])
    }

    func testConfigThatNamesAProgramIsListed() async throws {
        try await config("core.sshCommand", "ssh -i key")
        try await config("filter.lfs.clean", "git-lfs clean -- %f")
        try await config("filter.lfs.smudge", "git-lfs smudge -- %f")
        try await config("diff.external", "/tmp/x")
        try await config("diff.evil.textconv", "/tmp/y")
        try await config("merge.mine.driver", "/tmp/z %A")
        try await config("credential.https://example.com.helper", "!/tmp/h")
        try await config("alias.sh", "!echo hi")
        try await config("core.hooksPath", "/tmp/hooks")
        let repo = try await repository()
        let found = Set(await names(repo).map { $0.lowercased() })
        XCTAssertEqual(found, [
            "core.sshcommand", "filter.lfs.clean", "filter.lfs.smudge", "diff.external", "diff.evil.textconv",
            "merge.mine.driver", "credential.https://example.com.helper", "alias.sh", "core.hookspath"
        ])
    }

    func testOrdinarySettingsAndPlainAliasesAreNotExposure() async throws {
        try await config("core.autocrlf", "input")
        try await config("pull.rebase", "true")
        try await config("alias.st", "status -s")
        try await config("diff.evil.binary", "true")
        let repo = try await repository()
        let exposure = await names(repo)
        XCTAssertEqual(exposure, [])
    }

    func testALinkedWorktreeSeesTheMainRepositorysHooks() async throws {
        try "x\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        let hooks = directory.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: hooks.appendingPathComponent("pre-push"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("pre-push").path)
        let linked = directory.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString)")
        _ = try await runner.run(["worktree", "add", "-q", "-b", "side", linked.path], in: directory)
        defer { try? FileManager.default.removeItem(at: linked) }
        let found = await GitRepository.discover(from: linked)
        let repo = try XCTUnwrap(found)
        let exposure = await names(repo)
        XCTAssertEqual(exposure, ["pre-push"])
    }
}

import XCTest
@testable import GitIntelligence

/// A repository's own `.git/config` and `.git/info/attributes` can name programs: `core.fsmonitor`
/// runs on `status` and `ls-files`, `diff.external` and a `textconv` driver run on patch output and
/// blame. Umbra reads every repository it opens, so none of those may run without a user action.
final class GitUntrustedConfigTests: XCTestCase {
    private var directory: URL!
    private var markers: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-untrusted-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("repo", isDirectory: true)
        markers = base.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    }

    /// Writes a shell script that records its own name in `markers`, then echoes its last argument's
    /// content so a textconv or external-diff run still produces output.
    private func script(_ name: String, failing: Bool = false) throws -> String {
        let url = markers.deletingLastPathComponent().appendingPathComponent("\(name).sh")
        // A failing hook makes git treat every file as possibly changed, so it cannot hide a diff.
        let tail = failing ? "exit 1" : "cat \"$1\" 2>/dev/null"
        try "#!/bin/sh\ntouch '\(markers.path)/marker-\(name)'\n\(tail)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func firedMarkers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []).sorted()
    }

    private func configureHostileRepository() async throws -> GitRepository {
        try "a\nb\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "f.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        let fsmonitor = try script("fsmonitor", failing: true)
        _ = try await runner.run(["config", "core.fsmonitor", "\(fsmonitor) #"], in: directory)
        _ = try await runner.run(["config", "diff.external", try script("extdiff")], in: directory)
        _ = try await runner.run(["config", "diff.evil.textconv", try script("textconv")], in: directory)
        try "f.txt diff=evil\n".write(to: directory.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        try "a\nB\nc\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let found = await GitRepository.discover(from: directory)
        // Discovery and the setup commands above must not have fired anything either.
        try? FileManager.default.removeItem(at: markers)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        return try XCTUnwrap(found)
    }

    /// Asserts that nothing ran since the last call, then forgets the markers.
    private func assertNothingRan(_ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(firedMarkers(), [], "\(what) ran a program named by the repository's config", file: file, line: line)
        try? FileManager.default.removeItem(at: markers)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    }

    func testReadingARepositoryRunsNoProgramNamedByItsConfig() async throws {
        let repo = try await configureHostileRepository()

        _ = try await repo.status()
        try assertNothingRan("status")
        _ = try await repo.status(includingIgnored: true)
        try assertNothingRan("status --ignored")
        _ = await GitRepository.visibleFiles(under: directory)
        try assertNothingRan("ls-files")

        _ = try await repo.unstagedDiff(path: "f.txt")
        try assertNothingRan("diff")
        _ = try await repo.workingTreeDiff(path: "f.txt", isUntracked: false)
        try assertNothingRan("diff HEAD")
        _ = try await runner.run(["add", "f.txt"], in: directory)
        try? FileManager.default.removeItem(at: markers)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        _ = try await repo.stagedDiff(path: "f.txt")
        try assertNothingRan("diff --cached")

        _ = try await runner.run(["commit", "-qm", "second"], in: directory)
        try? FileManager.default.removeItem(at: markers)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let commits = try await repo.log(scope: .all)
        let hash = try XCTUnwrap(commits.first?.hash)
        _ = try await repo.commitDiff(hash: hash, path: "f.txt")
        try assertNothingRan("show <commit> -- path")
        _ = try await repo.show(hash: hash)
        try assertNothingRan("show")

        _ = try await repo.blame(relativePath: "f.txt", contents: Data("a\nB\nc\n".utf8))
        try assertNothingRan("blame")
        _ = try await repo.lineHistory(path: "f.txt", start: 1, end: 2)
        try assertNothingRan("log -L")
    }

    /// `git status` compares a modified file with the index by running its clean filter, so merely
    /// reading a repository runs `filter.<name>.clean`. Blanking the filter commands stops that.
    func testBlankedFiltersDoNotRunDuringStatusEvenWhenRequired() async throws {
        try "a\nb\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "f.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        _ = try await runner.run(["config", "filter.evil.clean", try script("clean")], in: directory)
        _ = try await runner.run(["config", "filter.evil.required", "true"], in: directory)
        try "f.txt filter=evil\n".write(to: directory.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        try "a\nB\n".write(to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let discovered = await GitRepository.discover(from: directory)
        let plain = try XCTUnwrap(discovered)

        _ = try? await plain.status()
        XCTAssertEqual(firedMarkers(), ["marker-clean"], "control: the plain runner does run the filter")
        try? FileManager.default.removeItem(at: markers)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)

        let overrides = await plain.filterOverrides()
        XCTAssertFalse(overrides.isEmpty)
        let guarded = plain.withRunner(GitConfigOverridingRunner(base: runner, overrides: overrides))
        let entries = try await guarded.status()
        XCTAssertEqual(entries.map(\.path), ["f.txt"])
        try assertNothingRan("status with filters blanked")
        _ = try await guarded.unstagedDiff(path: "f.txt")
        try assertNothingRan("diff with filters blanked")
    }
}

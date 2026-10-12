import XCTest
@testable import GitIntelligence

final class GitCloneIntegrationTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-clone-it-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A repository with one commit, as the clone source.
    private func makeSource() async throws -> URL {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@example.com"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: source)
        }
        try "hello\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: source)
        _ = try await runner.run(["commit", "-q", "-m", "first"], in: source)
        return source
    }

    func testRepositoryNames() {
        XCTAssertEqual(GitRepository.repositoryName(fromURL: "https://github.com/o/Penumbra.git"), "Penumbra")
        XCTAssertEqual(GitRepository.repositoryName(fromURL: "git@github.com:o/Penumbra.git"), "Penumbra")
        XCTAssertEqual(GitRepository.repositoryName(fromURL: "ssh://git@host:2222/group/sub/proj/"), "proj")
        XCTAssertEqual(GitRepository.repositoryName(fromURL: "/tmp/some repo.git"), "some repo")
        XCTAssertEqual(GitRepository.repositoryName(fromURL: "host:repo"), "repo")
        XCTAssertEqual(GitRepository.repositoryName(fromURL: ""), "")
    }

    func testCloneCopiesTheRepositoryAndReportsProgress() async throws {
        let source = try await makeSource()
        let destination = directory.appendingPathComponent("copy", isDirectory: true)
        let box = ProgressBox()

        let repo = try await GitRepository.clone(url: source.path, into: destination, onProgress: { box.add($0) })

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "hello\n")
        let log = try await repo.log(scope: .head)
        XCTAssertEqual(log.map(\.subject), ["first"])
        XCTAssertTrue(box.values.contains { $0.text.contains("Cloning into") })
    }

    func testCloneRefusesANonEmptyDestinationAndABadURL() async throws {
        let source = try await makeSource()
        let busy = directory.appendingPathComponent("busy", isDirectory: true)
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try "x".write(to: busy.appendingPathComponent("file"), atomically: true, encoding: .utf8)

        for (url, destination) in [(source.path, busy), ("", directory.appendingPathComponent("x")),
                                   ("--upload-pack=evil", directory.appendingPathComponent("y"))] {
            do {
                _ = try await GitRepository.clone(url: url, into: destination)
                XCTFail("must refuse \(url)")
            } catch {
                XCTAssertTrue(error is GitError)
            }
        }
    }

    func testCheckRemote() async throws {
        let source = try await makeSource()
        try await GitRepository.checkRemote(url: source.path)
        do {
            try await GitRepository.checkRemote(url: directory.appendingPathComponent("nope").path)
            XCTFail("a missing repository must fail")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testInitialize() async throws {
        let repo = try await GitRepository.initialize(at: directory, initialBranch: "trunk")
        let branch = await repo.currentBranch()
        XCTAssertEqual(branch, "trunk", "an unborn branch still has a name")
        XCTAssertEqual(repo.state().head, .branch("trunk"))
        do {
            _ = try await GitRepository.initialize(at: directory, initialBranch: "-bad")
            XCTFail("a branch starting with a dash must be refused")
        } catch {
            XCTAssertTrue(error is GitError)
        }
    }

    func testIgnorePatterns() {
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "build", isDirectory: true), "/build/")
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "src/app.log", isDirectory: false), "/src/app.log")
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "a[1]*.txt", isDirectory: false), "/a\\[1\\]\\*.txt")
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "#notes", isDirectory: false), "/\\#notes")
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "dir/", isDirectory: true), "/dir/")
        XCTAssertEqual(GitIgnoreWriter.pattern(forRelativePath: "name  ", isDirectory: false), "/name\\ \\ ")
    }

    func testAppendingKeepsTheFileTidyAndNeverDuplicates() {
        XCTAssertEqual(GitIgnoreWriter.appending("/build/", to: ""), "/build/\n")
        XCTAssertEqual(GitIgnoreWriter.appending("/build/", to: "*.log"), "*.log\n/build/\n")
        XCTAssertEqual(GitIgnoreWriter.appending("/build/", to: "*.log\n"), "*.log\n/build/\n")
        XCTAssertNil(GitIgnoreWriter.appending("/build/", to: "*.log\n/build/\n"))
    }

    func testAPatternGitReallyHonours() async throws {
        let repo = try await GitRepository.initialize(at: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a[1]"), withIntermediateDirectories: true)
        try "x".write(to: directory.appendingPathComponent("a[1]/f.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: directory.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let pattern = GitIgnoreWriter.pattern(forRelativePath: "a[1]", isDirectory: true)
        try (GitIgnoreWriter.appending(pattern, to: "") ?? "")
            .write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let status = try await repo.status()

        XCTAssertFalse(status.contains { $0.path.hasPrefix("a[1]") }, "the escaped directory is ignored")
        XCTAssertTrue(status.contains { $0.path == "keep.txt" })
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GitProgress] = []
        var values: [GitProgress] { lock.withLock { stored } }
        func add(_ value: GitProgress) { lock.withLock { stored.append(value) } }
    }
}

import AgentKit
import GitIntelligence
import XCTest
@testable import Umbra

/// `grep` and `glob` in a window go through `IDEAgentWorkspace`, which asks git what to open.
@MainActor
final class IDEGitVisibleFilesTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-visible-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = SystemGitRunner()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"], ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testGlobAndGrepSkipGitignoredFiles() async throws {
        try "class A {}\n".write(to: directory.appendingPathComponent("A.java"), atomically: true, encoding: .utf8)
        try "class Hidden {}\n".write(to: directory.appendingPathComponent("Hidden.java"), atomically: true, encoding: .utf8)
        try "Hidden.java\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let found = await GitRepository.discover(from: directory)
        let repo = try XCTUnwrap(found)
        _ = try await repo.commit(message: "base", paths: [], untrackedPaths: ["A.java", ".gitignore"], amend: false)

        let host = VisibleFilesHost(root: directory)
        let workspace = IDEAgentWorkspace(root: directory, box: IDEAgentHostBox(host))
        let context = ToolContext(workspace: workspace, ledger: ReadLedger(), callID: "c")

        let glob = await GlobTool().execute(argumentsJSON: #"{"pattern":"*.java"}"#, context: context)
        XCTAssertEqual(glob.text, "A.java")
        let grep = await GrepTool().execute(argumentsJSON: #"{"pattern":"class"}"#, context: context)
        XCTAssertEqual(grep.text, "A.java:1: class A {}")
        XCTAssertFalse(grep.text.contains("Hidden"))
    }
}

@MainActor
private final class VisibleFilesHost: IDEAgentHost {
    var agentProjectRoot: URL?
    init(root: URL) { agentProjectRoot = root }
    func agentUnsavedBuffers() -> [String: String] { [:] }
    func agentEditorContext() -> String { "" }
    func agentProblems() -> [IDEAgentProblem] { [] }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {}
    func agentCreateFile(relativePath: String, contents: String) async throws {}
    func agentTrashFile(relativePath: String) async throws {}
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { [:] }
    func agentSaveBuffers(relativePaths: [String]) async {}
    var agentIsGradleProject: Bool { false }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome {
        .notStarted("not a Gradle project")
    }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems { IDEAgentFreshProblems() }
}

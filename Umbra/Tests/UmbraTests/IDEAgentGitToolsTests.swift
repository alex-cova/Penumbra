import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// The harness-5 Phase 1 tools: `git_log`, `git_commit` and `git_branch` through a real repository.
final class IDEAgentGitToolsTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("agent-git-tools-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "T")
        try git("config", "commit.gpgsign", "false")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func source(root: URL? = nil, patterns: [String] = [], unsaved: [String: String] = [:]) -> IDEAgentGitSource {
        IDEAgentGitSource(
            projectRoot: root ?? repo, secretPatterns: SecretFilePolicy.patterns(from: patterns), unsavedBuffers: { unsaved })
    }

    private func context() -> ToolContext {
        ToolContext(workspace: DiskAgentWorkspace(root: repo), ledger: ReadLedger(), callID: "c")
    }

    private func run(_ tool: any AgentTool, _ json: String = "{}") async -> ToolOutput {
        await tool.execute(argumentsJSON: json, context: context())
    }

    private func commitBase() throws {
        try write("A.txt", "one\ntwo\n")
        try write("B.txt", "b\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
    }

    // MARK: - git_log

    func testLogListsRecentCommitsWithStyleMaterial() async throws {
        try commitBase()
        try write("A.txt", "one\n2\n")
        try git("add", "A.txt")
        try git("commit", "-q", "-m", "second subject")
        let output = await run(IDEGitLogTool(source: source()))
        XCTAssertFalse(output.isError, output.text)
        XCTAssertTrue(output.text.hasPrefix("Branch: main\n"))
        XCTAssertTrue(output.text.contains("second subject") && output.text.contains("base"), output.text)
        XCTAssertTrue(output.text.contains("T "), "the author is shown so the model can match message style")
    }

    func testLogFiltersByPathAndCapsLimit() async throws {
        try commitBase()
        for index in 0..<55 {
            try write("A.txt", "one\n\(index)\n")
            try git("add", "A.txt")
            try git("commit", "-q", "-m", "change \(index)")
        }
        let capped = await run(IDEGitLogTool(source: source()), #"{"limit":100}"#)
        XCTAssertFalse(capped.isError, capped.text)
        XCTAssertLessThanOrEqual(capped.text.split(separator: "\n").count, 51, "branch line plus at most 50 commits")

        let path = await run(IDEGitLogTool(source: source()), #"{"path":"B.txt"}"#)
        XCTAssertTrue(path.text.contains("base") && !path.text.contains("change 54"), path.text)
    }

    // MARK: - git_commit

    func testCommitCommitsTwoNamedFilesInProcess() async throws {
        try commitBase()
        try write("A.txt", "one\nchanged\n")
        try write("B.txt", "b\nchanged\n")
        let output = await run(
            IDEGitCommitTool(source: source()),
            #"{"message":"two files","paths":["A.txt","B.txt"]}"#)
        XCTAssertFalse(output.isError, output.text)
        let log = try git("log", "--format=%s")
        XCTAssertTrue(log.split(separator: "\n").first == "two files", log)
        let status = try git("status", "--porcelain")
        XCTAssertTrue(status.isEmpty, status)
    }

    func testCommitRefusesSecretsAndMissingInput() async throws {
        try commitBase()
        try write(".env", "API_KEY=hunter2\n")
        let secret = await run(
            IDEGitCommitTool(source: source()),
            #"{"message":"oops","paths":[".env"]}"#)
        XCTAssertTrue(secret.isError && !secret.text.contains("hunter2"), secret.text)
        XCTAssertTrue(secret.text.contains("credentials"), secret.text)

        let noMessage = await run(IDEGitCommitTool(source: source()), #"{"message":"","paths":["A.txt"]}"#)
        XCTAssertTrue(noMessage.isError)
        let noPaths = await run(IDEGitCommitTool(source: source()), #"{"message":"x","paths":[]}"#)
        XCTAssertTrue(noPaths.isError, "there is no commit-everything default")
    }

    func testCommitHasNoAmendOrSkipHooksPath() {
        let parameters = IDEGitCommitTool(source: source()).definition.parameters.map(\.name)
        XCTAssertEqual(parameters, ["message", "paths", "signoff"])
    }

    func testCommitApprovalCardNamesMessageAndFiles() async throws {
        try commitBase()
        try write("A.txt", "one\nchanged\n")
        let card = await IDEGitCommitTool(source: source()).approvalRequest(
            for: try ToolArguments(json: #"{"message":"my change","paths":["A.txt","B.txt"]}"#), context: context())
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.title, "Commit 2 files")
        XCTAssertTrue(card?.notes.contains("Message: my change") ?? false)
        XCTAssertTrue(card?.command.contains("A.txt") ?? false && (card?.command.contains("B.txt") ?? false))
    }

    // MARK: - git_branch

    func testBranchCreateAndSwitch() async throws {
        try commitBase()
        let created = await run(IDEGitBranchTool(source: source()), #"{"action":"create","name":"feature"}"#)
        XCTAssertFalse(created.isError, created.text)
        XCTAssertEqual(try git("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines), "feature")

        let switched = await run(IDEGitBranchTool(source: source()), #"{"action":"switch","name":"main"}"#)
        XCTAssertFalse(switched.isError, switched.text)
        XCTAssertEqual(try git("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    func testBranchRejectsAnythingElse() async throws {
        try commitBase()
        let unknown = await run(IDEGitBranchTool(source: source()), #"{"action":"delete","name":"main"}"#)
        XCTAssertTrue(unknown.isError)
        let empty = await run(IDEGitBranchTool(source: source()), #"{"action":"create","name":""}"#)
        XCTAssertTrue(empty.isError)
    }

    func testBranchApprovalCardShowsTheCommand() async throws {
        try commitBase()
        let card = await IDEGitBranchTool(source: source()).approvalRequest(
            for: try ToolArguments(json: #"{"action":"create","name":"feature"}"#), context: context())
        XCTAssertEqual(card?.command, "git switch -c feature")
    }
}

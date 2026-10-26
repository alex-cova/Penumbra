import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

final class IDEGitCommitChecksUnitTests: XCTestCase {
    func testACleanCommitHasNoFindings() {
        XCTAssertTrue(IDEGitCommitChecks.evaluate(IDEGitCommitFacts()).isEmpty)
    }

    func testEachFactBecomesAFindingWithTheRightSeverity() {
        var facts = IDEGitCommitFacts()
        facts.hasUserName = false
        facts.isDetachedHead = true
        facts.largeFiles = [.init(path: "big.bin", bytes: 12 * 1_048_576)]
        facts.crlfPaths = ["dos.txt"]
        facts.conflictMarkerPaths = ["a.txt"]
        facts.unresolvedPaths = ["b.txt"]

        let findings = IDEGitCommitChecks.evaluate(facts)

        XCTAssertEqual(Set(findings.map(\.kind)), [
            .authorMissing, .detachedHead, .largeFiles, .lineEndings, .conflictMarkers, .unresolvedConflicts
        ])
        XCTAssertEqual(findings.filter { $0.severity == .blocking }.map(\.kind).sorted { "\($0)" < "\($1)" },
                       [.authorMissing, .unresolvedConflicts].sorted { "\($0)" < "\($1)" })
        XCTAssertTrue(IDEGitCommitChecks.hasBlocking(findings))
        XCTAssertTrue(findings.first { $0.kind == .largeFiles }?.detail.contains("12.0 MB") == true)
    }

    func testAnAmendOfADetachedHeadIsNotWarnedAbout() {
        var facts = IDEGitCommitFacts()
        facts.isDetachedHead = true
        facts.isAmend = true
        XCTAssertTrue(IDEGitCommitChecks.evaluate(facts).isEmpty)
    }

    func testOnlyWarningsLetTheUserCommitAnyway() {
        var facts = IDEGitCommitFacts()
        facts.crlfPaths = ["a.txt"]
        XCTAssertFalse(IDEGitCommitChecks.hasBlocking(IDEGitCommitChecks.evaluate(facts)))
    }

    func testRecentMessagesAreNewestFirstDeduplicatedAndBounded() {
        let suite = "umbra-recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = IDEGitRecentMessages(defaults: defaults)
        recent.record("first", for: "/repo")
        recent.record("second", for: "/repo")
        recent.record("first", for: "/repo")
        recent.record("  ", for: "/repo")
        recent.record("elsewhere", for: "/other")

        XCTAssertEqual(recent.messages(for: "/repo"), ["first", "second"])
        XCTAssertEqual(recent.messages(for: "/other"), ["elsewhere"])
        for index in 0 ..< 30 { recent.record("message \(index)", for: "/repo") }
        XCTAssertEqual(recent.messages(for: "/repo").count, IDEGitRecentMessages.limit)
        XCTAssertEqual(recent.messages(for: "/repo").first, "message 29")
    }
}

@MainActor
final class IDEGitCommitFlowTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-commit-flow-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.autocrlf", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository && model.currentBranch != nil }
        return model
    }

    private func stage(_ model: IDEGitStatusModel, _ name: String, _ text: String) async throws {
        try write(name, text)
        _ = try await runner.run(["add", name], in: directory)
        model.refresh()
        try await waitUntil("the staged file") { model.changes.contains { $0.relativePath == name && $0.staged != nil } }
    }

    func testACleanCommitGoesStraightThrough() async throws {
        let model = try await makeModel()
        try await stage(model, "a.txt", "1\n")
        model.commitMessage = "first"

        model.commit()

        try await waitUntil("the commit") { model.commits.first?.subject == "first" }
        XCTAssertEqual(model.commitMessage, "")
        XCTAssertNil(model.sheets.current)
        XCTAssertEqual(model.recentCommitMessages, ["first"])
    }

    func testLeftoverConflictMarkersAskBeforeCommitting() async throws {
        let model = try await makeModel()
        try await stage(model, "a.txt", "x\n<<<<<<< HEAD\nl\n=======\nr\n>>>>>>> other\n")
        model.commitMessage = "has markers"

        model.commit()
        try await waitUntil("the checks sheet") { model.sheets.current != nil }

        guard case .commitChecks(let request)? = model.sheets.current else { return XCTFail("expected the checks sheet") }
        XCTAssertEqual(request.findings.map(\.kind), [.conflictMarkers])
        XCTAssertTrue(model.commits.isEmpty, "nothing is committed before the user decides")
        model.sheets.finish(model.sheets.current!.id)
        model.performCommit(message: request.message, options: request.options)
        try await waitUntil("the commit") { model.commits.first?.subject == "has markers" }
    }

    func testCRLFCanBeConvertedFromTheFinding() async throws {
        // Not converting, whatever the user's global configuration says.
        _ = try await runner.run(["config", "core.autocrlf", "false"], in: directory)
        let model = try await makeModel()
        try await stage(model, "dos.txt", "one\r\ntwo\r\n")
        model.commitMessage = "dos file"

        model.commit()
        try await waitUntil("the checks sheet") { model.sheets.current != nil }
        guard case .commitChecks(let request)? = model.sheets.current else { return XCTFail("expected the checks sheet") }
        XCTAssertEqual(request.findings.map(\.kind), [.lineEndings])
        model.sheets.finish(model.sheets.current!.id)

        var converted = false
        model.normalizeLineEndings(paths: ["dos.txt"]) { converted = true }
        try await waitUntil("the conversion") { converted }

        let endings = try await runner.run(["ls-files", "--eol", "dos.txt"], in: directory)
        XCTAssertTrue(endings.text.contains("i/lf"), endings.text)
    }

    func testAmendPrefillsTheLastMessageAndSignoffAddsTheTrailer() async throws {
        let model = try await makeModel()
        try await stage(model, "a.txt", "1\n")
        model.commitMessage = "original"
        model.commit()
        try await waitUntil("the commit") { model.commits.count == 1 }

        model.setAmend(true)
        try await waitUntil("the prefill") { model.commitMessage == "original" }
        model.commitMessage = "reworded"
        model.commitOptions.signoff = true
        model.commit()

        try await waitUntil("the amend") { model.commits.first?.subject == "reworded" }
        XCTAssertEqual(model.commits.count, 1)
        let body = try await runner.run(["log", "-1", "--format=%B"], in: directory)
        XCTAssertTrue(body.text.contains("Signed-off-by: Tester <t@example.com>"), body.text)
        XCTAssertFalse(model.commitOptions.amend, "amend is one-shot")
    }

    func testCommitAndPushOpensThePushDialogAfterCommitting() async throws {
        let model = try await makeModel()
        try await stage(model, "a.txt", "1\n")
        model.commitMessage = "to push"
        var options = model.commitOptions
        options.pushAfter = true

        model.requestCommit(options: options)

        try await waitUntil("the push sheet") {
            if case .push? = model.sheets.current { return true }
            return false
        }
        try await waitUntil("the log") { model.commits.first?.subject == "to push" }
    }

    func testPrefixesBuildFixupMessages() async throws {
        let model = try await makeModel()
        try await stage(model, "a.txt", "1\n")
        model.commitMessage = "feature"
        model.commit()
        try await waitUntil("the commit") { model.commits.count == 1 }

        model.applyCommitPrefix("fixup", to: model.commits[0])

        XCTAssertEqual(model.commitMessage, "fixup! feature")
    }

    func testTheRepositoryTemplateFillsAnEmptyMessageWithoutItsComments() async throws {
        let template = directory.appendingPathComponent("template.txt")
        try "# Describe the change\n\nIssue: \n# Why\n".write(to: template, atomically: true, encoding: .utf8)
        _ = try await runner.run(["config", "commit.template", template.path], in: directory)

        let model = try await makeModel()

        try await waitUntil("the template") { !model.commitMessage.isEmpty }
        XCTAssertEqual(model.commitMessage, "Issue:")
    }

    func testNothingStagedAndMessageMissingAreRefused() async throws {
        let model = try await makeModel()
        model.commit()
        XCTAssertEqual(model.actionStatus, "Enter a commit message.")
        model.commitMessage = "x"
        model.commit()
        try await waitUntil("the refusal") { model.actionStatus == "Nothing staged to commit." }
    }
}

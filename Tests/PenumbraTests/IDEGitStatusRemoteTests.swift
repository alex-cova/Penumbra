import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Fetch, update, push, smart checkout, branch commands, compare and the credential/sheet plumbing
/// of `IDEGitStatusModel`, against a scratch repository with a local bare repository as the remote.
@MainActor
final class IDEGitStatusRemoteTests: XCTestCase {
    private var directory: URL!
    private var remote: URL!
    private var scratch: [URL] = []
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = try makeDirectory("git-model-remote")
        remote = try makeDirectory("git-model-bare")
        _ = try await runner.run(["init", "-q", "--bare", "-b", "main", remote.path], in: directory)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"],
                     ["remote", "add", "origin", remote.path]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Helpers

    private func makeDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    private func git(_ args: [String], in url: URL? = nil) async throws {
        _ = try await runner.run(args, in: url ?? directory)
    }

    private func commit(_ name: String, _ text: String, _ message: String, in url: URL? = nil) async throws {
        let root = url ?? directory!
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await git(["add", name], in: root)
        try await git(["commit", "-q", "-m", message], in: root)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits for the model to be idle with a status line from the action that just ran.
    private func waitForAction(_ model: IDEGitStatusModel, _ description: String = "the action") async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        try await waitUntil(description) { !model.isBusy && !model.actionStatus.isEmpty }
    }

    /// A model on `directory` with `main` pushed, and a second clone acting as a teammate.
    private func makePublishedModel() async throws -> (model: IDEGitStatusModel, clone: URL) {
        try await commit("a.txt", "base\n", "base")
        try await git(["push", "-q", "-u", "origin", "main"])
        let clone = try makeDirectory("git-model-clone")
        try FileManager.default.removeItem(at: clone)
        _ = try await runner.run(["clone", "-q", remote.path, clone.path], in: directory)
        for args in [["config", "user.name", "Mate"], ["config", "user.email", "m@example.com"], ["config", "commit.gpgsign", "false"]] {
            try await git(args, in: clone)
        }
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository && model.currentBranch == "main" }
        return (model, clone)
    }

    // MARK: - Fetch, update, push

    func testFetchBringsInTheTeammatesCommitAndCountsItBehind() async throws {
        let (model, clone) = try await makePublishedModel()
        try await commit("b.txt", "b\n", "teammate", in: clone)
        try await git(["push", "-q"], in: clone)

        model.fetch()
        try await waitForAction(model)

        XCTAssertEqual(model.actionStatus, "Fetched 1 update")
        try await waitUntil("behind to show") { model.branchInfos.first { $0.name == "main" }?.behind == 1 }
        XCTAssertFalse(model.isNetworkBusy)
    }

    func testUpdateWithMergeIntegratesTheRemoteWork() async throws {
        let (model, clone) = try await makePublishedModel()
        try await commit("remote.txt", "r\n", "remote work", in: clone)
        try await git(["push", "-q"], in: clone)
        try await commit("local.txt", "l\n", "local work")
        model.fetch()
        try await waitForAction(model)

        var reloaded = false
        model.onWorkingTreeChanged = { reloaded = true }
        model.update(strategy: .merge, autostash: true)
        try await waitUntil("the merge") { reloaded }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote.txt").path))
        try await waitUntil("the log") { model.commits.first?.parents.count == 2 }
    }

    func testPushSendsTheCommitAndReportsWhatMoved() async throws {
        let (model, clone) = try await makePublishedModel()
        try await commit("a.txt", "two\n", "second")

        model.push(GitPushOptions(remote: "origin", source: "main", targetBranch: "main"))
        try await waitForAction(model)

        XCTAssertFalse(model.actionFailed, model.actionStatus)
        XCTAssertTrue(model.actionStatus.contains("main -> main"), model.actionStatus)
        let log = try await runner.run(["log", "-1", "--format=%s", "origin/main"], in: clone)
        _ = log
        let remoteTip = try await runner.run(["--git-dir", remote.path, "log", "-1", "--format=%s", "main"], in: directory)
        XCTAssertEqual(remoteTip.text.trimmingCharacters(in: .whitespacesAndNewlines), "second")
    }

    func testForcePushToAProtectedBranchIsRefusedWithoutRunningGit() async throws {
        let (model, _) = try await makePublishedModel()
        UserDefaults.standard.removeObject(forKey: IDEGitPreferences.protectedBranchesKey)
        try await git(["commit", "-q", "--amend", "-m", "rewritten"])

        model.push(GitPushOptions(remote: "origin", source: "main", targetBranch: "main", forceWithLease: true))

        XCTAssertTrue(model.actionFailed)
        XCTAssertTrue(model.actionStatus.contains("protected"), model.actionStatus)
        XCTAssertFalse(model.isBusy)
        let remoteTip = try await runner.run(["--git-dir", remote.path, "log", "-1", "--format=%s", "main"], in: directory)
        XCTAssertEqual(remoteTip.text.trimmingCharacters(in: .whitespacesAndNewlines), "base")
    }

    func testOutgoingCommitsAreWhatTheRemoteLacks() async throws {
        let (model, _) = try await makePublishedModel()
        try await commit("a.txt", "two\n", "second")
        try await commit("a.txt", "three\n", "third")

        let commits = await model.outgoingCommits(source: "main", remote: "origin", target: "main")

        XCTAssertEqual(commits.map(\.subject), ["third", "second"])
    }

    func testPushSummaryPicksTheLineThatSaysWhatMoved() {
        let report = """
        Enumerating objects: 5, done.
        Counting objects: 100% (5/5), done.
        remote: Create a pull request for 'x' on GitHub by visiting:
        To /tmp/remote
           abc1234..def5678  main -> main
        """
        XCTAssertEqual(IDEGitSupport.pushSummary(report), "Pushed abc1234..def5678  main -> main")
        XCTAssertEqual(IDEGitSupport.pushSummary("Everything up-to-date\n"), "Everything up-to-date")
        XCTAssertEqual(IDEGitSupport.pushSummary(" * [new branch]      feature -> feature"), "* [new branch]      feature -> feature")
    }

    // MARK: - Checkout

    func testCheckoutWithDirtyFilesOffersSmartCheckoutAndCarriesTheChanges() async throws {
        try await commit("a.txt", "main\nsep\nline3\n", "one")
        try await git(["switch", "-q", "-c", "feature"])
        try await commit("a.txt", "feature\nsep\nline3\n", "feature")
        try await git(["switch", "-q", "main"])
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository && model.localBranches.contains("feature") }
        try "main\nsep\nline3 edited\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let feature = try XCTUnwrap(model.branchInfos.first { $0.name == "feature" })

        model.checkout(feature)
        try await waitUntil("the smart checkout offer") { model.sheets.current != nil }

        guard case .smartCheckout(let request)? = model.sheets.current else { return XCTFail("expected a smart checkout sheet") }
        XCTAssertEqual(request.files, ["a.txt"])
        XCTAssertEqual(request.branch, "feature")
        model.sheets.finish(model.sheets.current!.id)
        model.smartCheckout(request)
        try await waitUntil("the switch") { model.currentBranch == "feature" }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt"), encoding: .utf8), "feature\nsep\nline3 edited\n")
    }

    func testCheckoutOfARemoteBranchCreatesATrackingBranch() async throws {
        let (model, clone) = try await makePublishedModel()
        try await git(["switch", "-q", "-c", "topic"], in: clone)
        try await commit("t.txt", "t\n", "topic", in: clone)
        try await git(["push", "-q", "-u", "origin", "topic"], in: clone)
        model.fetch()
        try await waitForAction(model)
        try await waitUntil("the remote branch") { model.branchInfos.contains { $0.name == "origin/topic" } }
        let tracking = try XCTUnwrap(model.branchInfos.first { $0.name == "origin/topic" })

        model.checkout(tracking)

        try await waitUntil("the checkout") { model.currentBranch == "topic" }
        XCTAssertEqual(model.branchInfos.first { $0.name == "topic" }?.upstream, "origin/topic")
    }

    // MARK: - Branches and compare

    func testDeletingAnUnmergedBranchAsksBeforeForcing() async throws {
        try await commit("a.txt", "1\n", "one")
        try await git(["switch", "-q", "-c", "topic"])
        try await commit("a.txt", "topic\n", "topic work")
        try await git(["switch", "-q", "main"])
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.localBranches.contains("topic") }

        model.deleteBranch("topic")
        try await waitUntil("the confirmation") { model.sheets.current != nil }

        guard case .confirm(let confirmation)? = model.sheets.current else { return XCTFail("expected a confirmation") }
        XCTAssertTrue(confirmation.isDestructive)
        confirmation.action()
        try await waitUntil("the delete") { !model.localBranches.contains("topic") }
    }

    func testCompareWithBranchHoldsTheResultAndAsksToShowIt() async throws {
        try await commit("a.txt", "base\n", "base")
        try await git(["switch", "-q", "-c", "feature"])
        try await commit("f.txt", "f\n", "feature work")
        try await git(["switch", "-q", "main"])
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.currentBranch == "main" }
        var shown = false
        model.onShowComparison = { shown = true }

        model.compare(with: "feature")
        try await waitUntil("the comparison") { shown }

        let comparison = try XCTUnwrap(model.comparison)
        XCTAssertEqual(comparison.left, "main")
        XCTAssertEqual(comparison.onlyInRight.map(\.subject), ["feature work"])
        XCTAssertEqual(comparison.files.map(\.path), ["f.txt"])
    }

    func testTagsAreLoadedForThePopup() async throws {
        try await commit("a.txt", "1\n", "one")
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.isRepository }

        model.createTag("v1", message: "first")
        try await waitUntil("the tag list") { model.tags.map(\.name) == ["v1"] }
    }

    // MARK: - Sheets and credentials

    func testSheetsAreShownOneAtATimeInOrder() {
        let queue = IDEGitSheetQueue()
        let first = IDEGitConfirmation(title: "A", message: "", confirmTitle: "OK", action: {})
        let second = IDEGitConfirmation(title: "B", message: "", confirmTitle: "OK", action: {})
        queue.present(.confirm(first))
        queue.present(.confirm(second))

        guard case .confirm(let current)? = queue.current else { return XCTFail() }
        XCTAssertEqual(current.title, "A")
        queue.finish(queue.current!.id)
        guard case .confirm(let next)? = queue.current else { return XCTFail() }
        XCTAssertEqual(next.title, "B")
        queue.finish("stale-id")
        XCTAssertNotNil(queue.current, "a stale id must not skip a sheet")
        queue.finish(queue.current!.id)
        XCTAssertNil(queue.current)
    }

    func testACredentialPromptReachesTheSheetAndTheAnswerComesBack() async throws {
        let model = IDEGitStatusModel()
        let reply = Task { await model.requestCredential(prompt: "Password for 'https://me@host': ") }

        try await waitUntil("the credential sheet") { model.sheets.current != nil }
        guard case .credential(let request)? = model.sheets.current else { return XCTFail("expected a credential sheet") }
        XCTAssertEqual(request.kind, .secret)
        request.answer("hunter2")
        model.sheets.finish(model.sheets.current!.id)

        let answered = await reply.value
        XCTAssertEqual(answered, IDEGitAskPassReply(answer: "hunter2", cancelled: false))
    }

    func testClosingTheProjectCancelsAPendingCredentialPrompt() async throws {
        let model = IDEGitStatusModel()
        let reply = Task { await model.requestCredential(prompt: "Username for 'https://host': ") }
        try await waitUntil("the credential sheet") { model.sheets.current != nil }

        model.setRoot(nil)

        let answered = await reply.value
        XCTAssertTrue(answered.cancelled)
        XCTAssertNil(model.sheets.current)
    }

    func testDismissingTheCredentialSheetCancelsThePrompt() async throws {
        let model = IDEGitStatusModel()
        let reply = Task { await model.requestCredential(prompt: "Password: ") }
        try await waitUntil("the credential sheet") { model.sheets.current != nil }

        model.sheets.dismissCurrent()

        let answered = await reply.value
        XCTAssertTrue(answered.cancelled)
    }

    // MARK: - Preferences

    func testProtectedBranchPatternsSupportGlobs() {
        XCTAssertTrue(IDEGitPreferences.isProtected("main", patterns: ["main", "release/*"]))
        XCTAssertTrue(IDEGitPreferences.isProtected("release/1.2", patterns: ["main", "release/*"]))
        XCTAssertFalse(IDEGitPreferences.isProtected("feature/x", patterns: ["main", "release/*"]))
        XCTAssertEqual(IDEGitPreferences.patterns(from: "main, master\nrelease/*"), ["main", "master", "release/*"])
    }

    func testTheUpdateSheetDefaultsFromPullRebase() {
        XCTAssertEqual(IDEGitPreferences.initialUpdateStrategy(repositoryPullRebase: "true"), .rebase)
        XCTAssertEqual(IDEGitPreferences.initialUpdateStrategy(repositoryPullRebase: "false"), .merge)
    }
}

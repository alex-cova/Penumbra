import AppKit
import Foundation
import GitIntelligence
import XCTest
@testable import Penumbra
@testable import Umbra

/// The blame column, revision blame, hidden revisions and "show in log", against a scratch repository.
@MainActor
final class IDEBlameControllerTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()
    private var snapshotRoots: [String] = []

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath),
                          "git is not installed at \(SystemGitRunner.executablePath)")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-blame-model-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        // Snapshots go to the real cache: leave nothing of ours behind.
        for root in snapshotRoots {
            try? FileManager.default.removeItem(
                at: IDEGitRevisionFiles.defaultCacheRoot.appendingPathComponent(IDEGitRevisionFiles.repositoryKey(root)))
        }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    @discardableResult
    private func commit(_ name: String, _ text: String, _ message: String) async throws -> String {
        try text.write(to: file(name), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", name], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", message], in: directory)
        let head = try await runner.run(["rev-parse", "HEAD"], in: directory)
        return head.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository to load") { model.isRepository }
        return model
    }

    private func makeController() -> IDEBlameController {
        let suite = "blame-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return IDEBlameController(defaults: defaults)
    }

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        textView.layoutIfNeeded()
        return textView
    }

    // MARK: - The model

    func testBlameAtARevisionAnnotatesTheFileAsItWasThen() async throws {
        let first = try await commit("a.txt", "one\ntwo\n", "first")
        let second = try await commit("a.txt", "one\ntwo\nthree\n", "second")
        let model = try await makeModel()
        let root = try XCTUnwrap(model.repositoryRootPath)

        let old = try await XCTUnwrapAsync(await model.blame(revision: first, relativePath: "a.txt", repositoryRoot: root))
        XCTAssertEqual(old.map(\.hash), [first, first])
        let current = try await XCTUnwrapAsync(await model.blame(revision: second, relativePath: "a.txt", repositoryRoot: root))
        XCTAssertEqual(current.map(\.hash), [first, first, second])
        // A snapshot of another repository is not this window's to blame.
        let foreign = await model.blame(revision: first, relativePath: "a.txt", repositoryRoot: "/somewhere/else")
        XCTAssertNil(foreign)
    }

    func testTheCommitBodyDropsItsSubject() async throws {
        let hash = try await commit("a.txt", "x\n", "Subject line\n\nThe body explains why.\nSecond line.")
        let model = try await makeModel()
        let body = await model.commitMessageBody(hash: hash)
        XCTAssertEqual(body, "The body explains why.\nSecond line.")
        let single = try await commit("b.txt", "y\n", "Only a subject")
        let none = await model.commitMessageBody(hash: single)
        XCTAssertEqual(none, "")
    }

    func testShowInLogNarrowsToTheFileAndSelectsTheCommit() async throws {
        let wanted = try await commit("a.txt", "1\n", "add a")
        try await commit("b.txt", "1\n", "add b")
        try await commit("a.txt", "2\n", "change a")
        let model = try await makeModel()
        try await waitUntil("the log") { model.commits.count == 3 }

        model.revealCommit(wanted, inHistoryOf: file("a.txt").path)
        try await waitUntil("the commit to be selected") { model.selectedCommitHash == wanted }
        XCTAssertEqual(model.commits.map(\.subject), ["change a", "add a"], "only a.txt's history")
        XCTAssertNil(model.pendingRevealHash)
    }

    // MARK: - The column

    func testTheColumnFillsAndHidingARevisionAttributesTheLinesToTheCommitBefore() async throws {
        let first = try await commit("a.txt", "keep\nformat me\n", "first")
        let formatting = try await commit("a.txt", "keep\nformat me!\n", "formatting")
        let model = try await makeModel()
        let controller = makeController()
        let textView = makeTextView("keep\nformat me!\n")
        let url = file("a.txt")
        controller.enable(url)

        controller.refresh(textView: textView, url: url, git: model)
        try await waitUntil("the column") { textView.hasGutterAnnotations }
        XCTAssertTrue(textView.gutterAnnotationForTesting(atRow: 1)?.tooltip.hasPrefix(String(formatting.prefix(7)) + " formatting") == true)
        XCTAssertNotNil(textView.gutterAnnotationForTesting(atRow: 1)?.tint, "the column is tinted by age by default")

        var asked = 0
        controller.onNeedsBlame = { asked += 1 }
        controller.hideRevision(formatting, in: url)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(controller.hiddenRevisionCount(for: url), 1)
        controller.refresh(textView: textView, url: url, git: model, force: true)
        try await waitUntil("the line to go back to the first commit") {
            textView.gutterAnnotationForTesting(atRow: 1)?.tooltip.hasPrefix(String(first.prefix(7)) + " first") == true
        }

        controller.restoreHiddenRevisions(in: url)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(controller.hiddenRevisionCount(for: url), 0)
        controller.refresh(textView: textView, url: url, git: model, force: true)
        try await waitUntil("the line to be the formatting commit's again") {
            textView.gutterAnnotationForTesting(atRow: 1)?.tooltip.hasPrefix(String(formatting.prefix(7)) + " formatting") == true
        }
    }

    func testChangingHowTheColumnReadsRepresentsWithoutAskingGitAgain() async throws {
        try await commit("a.txt", "one\n", "first")
        let model = try await makeModel()
        let controller = makeController()
        let textView = makeTextView("one\n")
        let url = file("a.txt")
        controller.enable(url)
        controller.refresh(textView: textView, url: url, git: model)
        try await waitUntil("the column") { textView.hasGutterAnnotations }
        XCTAssertTrue(textView.gutterAnnotationForTesting(atRow: 0)?.text.hasSuffix(" Tester") == true,
                      "a compact date, then the author")

        var asked = 0
        controller.onNeedsBlame = { asked += 1 }
        controller.updateSettings { $0.authorStyle = .initials; $0.showsDate = false; $0.coloring = .none }
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 0)?.text, "T")
        XCTAssertNil(textView.gutterAnnotationForTesting(atRow: 0)?.tint)
        XCTAssertEqual(asked, 0, "a View or Color change needs no new blame")

        controller.updateSettings { $0.ignoresWhitespace = true }
        XCTAssertEqual(asked, 1, "what git is asked changed")
    }

    func testARevisionSnapshotIsBlamedAtItsRevision() async throws {
        let first = try await commit("a.txt", "one\ntwo\n", "first")
        try await commit("a.txt", "one\nTWO\n", "second")
        let model = try await makeModel()
        let root = try XCTUnwrap(model.repositoryRootPath)
        snapshotRoots.append(root)
        let blob = await model.fileContents(at: .commit(first), relativePath: "a.txt")
        let data = try XCTUnwrap(blob)
        let snapshot = try XCTUnwrap(IDEGitRevisionFiles.write(data, repositoryRoot: root, hash: first, relativePath: "a.txt"))

        let controller = makeController()
        let textView = makeTextView(String(decoding: data, as: UTF8.self))
        controller.enable(snapshot)
        controller.refresh(textView: textView, url: snapshot, git: model)
        try await waitUntil("the column") { textView.hasGutterAnnotations }
        // Both lines are the first commit's: the second one has not happened yet at that revision.
        XCTAssertTrue(textView.gutterAnnotationForTesting(atRow: 1)?.tooltip.hasPrefix(String(first.prefix(7)) + " first") == true)
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 0)?.id, textView.gutterAnnotationForTesting(atRow: 1)?.id)
    }

    func testBlameIsOffForAFileUntilAskedAndNothingIsLeftBehindWhenItIsClosed() async throws {
        try await commit("a.txt", "one\n", "first")
        let model = try await makeModel()
        let controller = makeController()
        let textView = makeTextView("one\n")
        let url = file("a.txt")

        controller.refresh(textView: textView, url: url, git: model)
        XCTAssertFalse(textView.hasGutterAnnotations)
        XCTAssertTrue(controller.toggle(for: url))
        controller.refresh(textView: textView, url: url, git: model)
        try await waitUntil("the column") { textView.hasGutterAnnotations }

        XCTAssertFalse(controller.toggle(for: url))
        controller.refresh(textView: textView, url: url, git: model)
        XCTAssertFalse(textView.hasGutterAnnotations)
    }
}

/// `XCTUnwrap` for an expression that has to be awaited.
@MainActor
private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}

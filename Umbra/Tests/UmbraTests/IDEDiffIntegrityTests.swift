import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Audit WP2: the diff viewer must not rewrite what it cannot read as UTF-8, and hunk staging must
/// write the bytes git would have stored.
@MainActor
final class IDEDiffIntegrityTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff-integrity-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"],
                     ["config", "commit.gpgsign", "false"], ["config", "core.autocrlf", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func git(_ args: [String]) async throws -> String {
        try await runner.run(args, in: directory).text
    }

    private func commit(_ name: String, _ data: Data, message: String = "base") async throws {
        try data.write(to: directory.appendingPathComponent(name))
        _ = try await git(["add", "--", name])
        _ = try await git(["commit", "-qm", message])
    }

    private func loadedModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        let deadline = Date().addingTimeInterval(10)
        while model.workspaceSnapshot == nil, Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertNotNil(model.workspaceSnapshot)
        return model
    }

    private func readySession(_ model: IDEGitStatusModel, relative: String, staged: Bool = false) async throws -> IDEDiffSession {
        let request = IDEDiffRequest.change(
            path: directory.appendingPathComponent(relative).path, relativePath: relative, staged: staged, isNew: false
        )
        let session = IDEDiffSession(
            request: request, siblings: [], settings: IDEDiffSettings(), settingsPrefix: "test-\(UUID().uuidString)"
        )
        session.loadContent = { await model.diffContent($0) }
        session.indexBlobID = { await model.indexBlobID(relativePath: $0) }
        session.applyIndexPatch = { await model.applyHunk($0) }
        session.reload()
        let deadline = Date().addingTimeInterval(10)
        while session.state != .ready || session.chunks.isEmpty {
            if Date() > deadline { XCTFail("diff not ready: \(session.state)"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return session
    }

    private func waitUntilIdle(_ session: IDEDiffSession) async throws {
        let deadline = Date().addingTimeInterval(10)
        while session.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: G-05

    func testANonUTF8WorkingTreeSideIsReadOnlyAndNeverRewritten() async throws {
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x78, 0x0A])   // "caf\xE9\nx\n" (Latin-1)
        try await commit("l.txt", original)
        let edited = Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x79, 0x0A])
        try edited.write(to: directory.appendingPathComponent("l.txt"))

        let model = try await loadedModel()
        let session = try await readySession(model, relative: "l.txt")
        XCTAssertNotNil(session.readOnlyReason, "a file git cannot show as UTF-8 must not be editable here")
        XCTAssertFalse(session.isRightEditable)
        XCTAssertTrue(session.readOnlyReason?.contains("not UTF-8") == true, session.readOnlyReason ?? "nil")

        // Even a forced edit and save cannot reach the disk.
        session.currentRightText = { "caf\u{FFFD}\ny\n" }
        session.rightTextDidChange()
        session.save()
        let disk = try Data(contentsOf: directory.appendingPathComponent("l.txt"))
        XCTAssertEqual(disk, edited)
    }

    func testSaveRefusesWhenTheFileOnDiskIsNotUTF8EvenIfTheSessionThoughtItWasText() async throws {
        try await commit("t.txt", Data("a\n".utf8))
        try Data("b\n".utf8).write(to: directory.appendingPathComponent("t.txt"))
        let model = try await loadedModel()
        let session = try await readySession(model, relative: "t.txt")
        XCTAssertNil(session.readOnlyReason)
        // The file turns into Latin-1 after the diff loaded.
        let latin = Data([0x62, 0xE9, 0x0A])
        try latin.write(to: directory.appendingPathComponent("t.txt"))
        session.currentRightText = { "edited\n" }
        session.rightTextDidChange()
        session.save()
        let disk = try Data(contentsOf: directory.appendingPathComponent("t.txt"))
        XCTAssertEqual(disk, latin)
        XCTAssertTrue(session.message?.contains("not UTF-8") == true, session.message ?? "nil")
    }

    // MARK: Hunk staging

    private func chunkIndex(_ session: IDEDiffSession, containingRightLine line: Int) throws -> Int {
        try XCTUnwrap(session.chunks.firstIndex { $0.right.contains(line) || ($0.right.isEmpty && $0.right.lowerBound == line) })
    }

    private func stage(_ session: IDEDiffSession, chunk: Int) async throws {
        session.applyToIndex(chunkAt: chunk)
        try await waitUntilIdle(session)
    }

    // G-04: CRLF must not reach an LF index.
    func testStagingAHunkOfACRLFWorkingTreeFileKeepsAnLFIndexUnderAutocrlf() async throws {
        _ = try await git(["config", "core.autocrlf", "true"])
        try await commit("f.txt", Data("a\nb\nc\n".utf8))
        let before = try await git(["ls-files", "--eol", "f.txt"])
        XCTAssertTrue(before.hasPrefix("i/lf"), before)
        try Data("a\r\nB\r\nc\r\n".utf8).write(to: directory.appendingPathComponent("f.txt"))

        let model = try await loadedModel()
        let session = try await readySession(model, relative: "f.txt")
        try await stage(session, chunk: try chunkIndex(session, containingRightLine: 1))
        XCTAssertNil(session.message)
        let eol = try await git(["ls-files", "--eol", "f.txt"])
        XCTAssertTrue(eol.hasPrefix("i/lf"), "the index must stay LF: \(eol)")
        let blob = try await git(["show", ":f.txt"])
        XCTAssertEqual(blob, "a\nB\nc\n")
    }

    func testStagingAHunkUnderAnEolCrlfAttributeKeepsAnLFIndex() async throws {
        try "* text eol=crlf\n".write(to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try await commit("f.txt", Data("a\nb\nc\n".utf8))
        let before = try await git(["ls-files", "--eol", "f.txt"])
        XCTAssertTrue(before.hasPrefix("i/lf"), before)
        try Data("a\r\nB\r\nc\r\n".utf8).write(to: directory.appendingPathComponent("f.txt"))

        let model = try await loadedModel()
        let session = try await readySession(model, relative: "f.txt")
        try await stage(session, chunk: try chunkIndex(session, containingRightLine: 1))
        XCTAssertNil(session.message)
        let blob = try await git(["show", ":f.txt"])
        XCTAssertEqual(blob, "a\nB\nc\n")
    }

    // G-08: the name is no obstacle.
    func testHunksOfFilesWithASpaceOrATabInTheNameStage() async throws {
        for name in ["my file.txt", "tab\tname.txt", "quote\"d.txt"] {
            try await commit(name, Data("1\n2\n3\n".utf8), message: "add \(name)")
            try Data("1\nTWO\n3\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        let model = try await loadedModel()
        for name in ["my file.txt", "tab\tname.txt", "quote\"d.txt"] {
            let session = try await readySession(model, relative: name)
            try await stage(session, chunk: 0)
            XCTAssertNil(session.message, "\(name): \(session.message ?? "")")
            let cached = try await git(["diff", "--cached", "--no-color", "--", name])
            XCTAssertTrue(cached.contains("-2\n+TWO"), "\(name) was not staged:\n\(cached)")
        }
    }

    // G-11: the blob id belongs to the text the chunks were computed from.
    func testAnIndexChangeWhileTheDiffLoadsIsRefusedNotAppliedToTheWrongText() async throws {
        try await commit("f.txt", Data("1\n2\n3\n".utf8))
        try Data("1\nTWO\n3\n".utf8).write(to: directory.appendingPathComponent("f.txt"))
        let model = try await loadedModel()
        let request = IDEDiffRequest.change(
            path: directory.appendingPathComponent("f.txt").path, relativePath: "f.txt", staged: false, isNew: false
        )
        let session = IDEDiffSession(request: request, siblings: [], settings: IDEDiffSettings(), settingsPrefix: "test-\(UUID().uuidString)")
        let repoDirectory = directory!
        let runner = self.runner
        var changedOnce = false
        session.loadContent = { source in
            let content = await model.diffContent(source)
            // Someone stages a different first line right after the index text was read.
            if case .revision(.index, _) = source, !changedOnce {
                changedOnce = true
                try? Data("0\n1\n2\n3\n".utf8).write(to: repoDirectory.appendingPathComponent("f.txt"))
                _ = try? await runner.run(["add", "f.txt"], in: repoDirectory)
                try? Data("1\nTWO\n3\n".utf8).write(to: repoDirectory.appendingPathComponent("f.txt"))
            }
            return content
        }
        session.indexBlobID = { await model.indexBlobID(relativePath: $0) }
        session.applyIndexPatch = { await model.applyHunk($0) }
        session.reload()
        let deadline = Date().addingTimeInterval(10)
        while session.state != .ready || session.chunks.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let indexBefore = try await git(["show", ":f.txt"])
        XCTAssertEqual(indexBefore, "0\n1\n2\n3\n")

        try await stage(session, chunk: 0)
        XCTAssertTrue(session.message?.contains("index changed") == true, "expected a refusal, got \(session.message ?? "nil")")
        let indexAfter = try await git(["show", ":f.txt"])
        XCTAssertEqual(indexAfter, indexBefore, "the index must be untouched")
    }

    // G-21: git does not break lines at a bare CR.
    func testAFileWithABareCarriageReturnIsNotStagedAsAHunk() async throws {
        try await commit("f.txt", Data("a\nb\n".utf8))
        try Data("a\nb\rc\n".utf8).write(to: directory.appendingPathComponent("f.txt"))
        let model = try await loadedModel()
        let session = try await readySession(model, relative: "f.txt")
        let indexBefore = try await git(["show", ":f.txt"])
        try await stage(session, chunk: 0)
        XCTAssertNotNil(session.message)
        XCTAssertTrue(session.message?.lowercased().contains("carriage return") == true, session.message ?? "nil")
        let indexAfter = try await git(["show", ":f.txt"])
        XCTAssertEqual(indexAfter, indexBefore)
    }
}

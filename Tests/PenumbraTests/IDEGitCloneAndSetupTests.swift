import AppKit
import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEGitCloneAndSetupTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-setup-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

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

    // MARK: - Clone

    func testRepositoryAddressesAreRecognised() {
        for good in ["https://github.com/o/r.git", "ssh://git@host/o/r", "git@github.com:o/r.git", "git://host/o/r.git"] {
            XCTAssertTrue(IDEGitCloneModel.looksLikeRepositoryAddress(good), good)
        }
        for bad in ["", "hello world", "just text", "/Users/me/file.txt", "https://a b", "multi\nline"] {
            XCTAssertFalse(IDEGitCloneModel.looksLikeRepositoryAddress(bad), bad)
        }
    }

    func testTheFolderNameFollowsTheAddressUntilEdited() {
        let model = IDEGitCloneModel(parentDirectory: directory, networkSession: "s")
        model.url = "https://github.com/o/Penumbra.git"
        model.urlDidChange()
        XCTAssertEqual(model.name, "Penumbra")
        XCTAssertEqual(model.destination?.standardizedFileURL.path, directory.appendingPathComponent("Penumbra").path)

        model.name = "mine"
        model.nameDidChange()
        model.url = "https://github.com/o/Other.git"
        model.urlDidChange()
        XCTAssertEqual(model.name, "mine", "an edited name is kept")
        XCTAssertTrue(model.canClone)

        model.name = "../escape"
        XCTAssertNil(model.destination, "a name cannot leave the chosen folder")
        model.name = ""
        XCTAssertFalse(model.canClone)
    }

    func testTheClipboardAddressPrefillsTheDialog() {
        let model = IDEGitCloneModel(
            parentDirectory: directory, networkSession: "s", clipboard: " git@github.com:o/r.git \n".trimmingCharacters(in: .newlines))
        XCTAssertEqual(model.url, "git@github.com:o/r.git")
        XCTAssertEqual(model.name, "r")
        let none = IDEGitCloneModel(parentDirectory: directory, networkSession: "s", clipboard: "not an address")
        XCTAssertEqual(none.url, "")
    }

    func testCloneCopiesTheRepositoryAndReportsTheDestination() async throws {
        let source = try await makeSource()
        let model = IDEGitCloneModel(parentDirectory: directory, networkSession: "s")
        model.url = source.path
        model.urlDidChange()
        // The address names `source`, which exists: the copy goes under another name.
        model.name = "copy"
        model.nameDidChange()
        model.recurseSubmodules = false
        var finished: URL?
        model.onFinished = { finished = $0 }

        model.clone()
        try await waitUntil("the clone") { finished != nil || model.error != nil }

        XCTAssertNil(model.error)
        let destination = try XCTUnwrap(finished)
        XCTAssertEqual(destination.lastPathComponent, "copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
    }

    func testAFailedCloneRemovesWhatItLeftAndShowsTheError() async throws {
        let model = IDEGitCloneModel(parentDirectory: directory, networkSession: "s")
        model.url = directory.appendingPathComponent("does-not-exist").path
        model.name = "target"
        model.nameDidChange()

        model.clone()
        try await waitUntil("the failure") { model.error != nil }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("target").path))
        XCTAssertFalse(model.isWorking)
    }

    // MARK: - Create repository

    func testCreateRepositoryAsksThenRunsGitInit() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.project.setRoot(directory)
        workspace.gitStatus.setRoot(directory)
        XCTAssertFalse(workspace.gitStatus.isRepository)

        workspace.promptCreateRepository()
        guard case .confirm(let confirmation)? = workspace.gitStatus.sheets.current else { return XCTFail("expected a confirmation") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
        workspace.gitStatus.sheets.finish(workspace.gitStatus.sheets.current!.id)
        confirmation.action()

        try await waitUntil("the repository") { workspace.gitStatus.isRepository }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
    }

    // MARK: - Ignore files

    private func repositoryWorkspace() async throws -> IDEWorkspace {
        _ = try await runner.run(["init", "-q", "-b", "main"], in: directory)
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.gitStatus.setRoot(directory)
        try await waitUntil("the repository") { workspace.gitStatus.isRepository }
        return workspace
    }

    func testAddToGitignoreIgnoresTheFileAndANestedFileUsesTheNearestIgnoreFile() async throws {
        let workspace = try await repositoryWorkspace()
        defer { workspace.teardown() }
        let nested = directory.appendingPathComponent("module", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "*.class\n".write(to: nested.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let rootFile = directory.appendingPathComponent("notes.txt")
        let nestedFile = nested.appendingPathComponent("scratch.txt")
        try "n".write(to: rootFile, atomically: true, encoding: .utf8)
        try "s".write(to: nestedFile, atomically: true, encoding: .utf8)

        workspace.addToIgnoreFile([rootFile], target: .nearest)
        workspace.addToIgnoreFile([nestedFile], target: .nearest)

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8), "/notes.txt\n")
        XCTAssertEqual(try String(contentsOf: nested.appendingPathComponent(".gitignore"), encoding: .utf8), "*.class\n/scratch.txt\n")
        workspace.gitStatus.refresh()
        try await waitUntil("the files to be ignored") {
            workspace.gitStatus.status(for: rootFile, isDirectory: false) != .untracked
                && workspace.gitStatus.status(for: nestedFile, isDirectory: false) != .untracked
        }
    }

    func testAddToLocalExcludeNeverTouchesGitignore() async throws {
        let workspace = try await repositoryWorkspace()
        defer { workspace.teardown() }
        let file = directory.appendingPathComponent("private.txt")
        try "p".write(to: file, atomically: true, encoding: .utf8)

        workspace.addToIgnoreFile([file], target: .localExclude)

        let exclude = try String(contentsOf: directory.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertTrue(exclude.contains("/private.txt\n"), exclude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".gitignore").path))
    }

    func testAFolderGetsATrailingSlashAndADuplicateIsNotWrittenTwice() async throws {
        let workspace = try await repositoryWorkspace()
        defer { workspace.teardown() }
        let folder = directory.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        workspace.addToIgnoreFile([folder], target: .root)
        workspace.addToIgnoreFile([folder], target: .root)

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8), "/build/\n")
    }
}

import Foundation
import GitIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// A repository whose hooks or config name programs gets one question before Umbra changes it:
/// staging runs clean filters, committing runs hooks. Reading it never asks (see
/// `GitUntrustedConfigTests` in the library suite).
@MainActor
final class IDEGitTrustGateTests: XCTestCase {
    private var base: URL!
    private var directory: URL!
    private var markers: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-trust-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("repo", isDirectory: true)
        markers = base.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        try "one\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        try "two\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func installHook(_ name: String) throws {
        let hooks = directory.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let file = hooks.appendingPathComponent(name)
        try "#!/bin/sh\ntouch '\(markers.path)/hook-\(name)'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func porcelain() async throws -> String {
        try await runner.run(["status", "--porcelain"], in: directory).text
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func loadedModel() async throws -> IDEGitStatusModel {
        let model = IDEGitStatusModel(trust: ProjectTrustStore(storeURL: base.appendingPathComponent("trust.json")))
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        return model
    }

    private func confirmation(_ model: IDEGitStatusModel) -> IDEGitConfirmation? {
        if case .confirm(let value) = model.sheets.current { return value }
        return nil
    }

    func testADeclinedQuestionStagesNothingAndRunsNothing() async throws {
        try installHook("pre-commit")
        let model = try await loadedModel()
        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the question") { self.confirmation(model) != nil }
        let sheet = try XCTUnwrap(confirmation(model))
        XCTAssertEqual(sheet.title, "Trust This Repository?")
        XCTAssertTrue(sheet.message.contains("pre-commit"), sheet.message)
        let before = try await porcelain()
        XCTAssertEqual(before, " M a.txt\n")

        sheet.onCancel?()
        model.sheets.finish(model.sheets.current!.id)
        try await waitUntil("the action to end") { !model.isBusy }
        XCTAssertTrue(model.actionFailed)
        XCTAssertTrue(model.actionStatus.contains("trust"), model.actionStatus)
        let after = try await porcelain()
        XCTAssertEqual(after, " M a.txt\n", "a declined stage must leave the index alone")
        XCTAssertFalse(model.gitTrust.isTrusted(directory))
    }

    func testTrustingRunsTheActionAndIsRemembered() async throws {
        try installHook("pre-commit")
        let model = try await loadedModel()
        let path = directory.appendingPathComponent("a.txt").path
        model.stage(paths: [path])
        try await waitUntil("the question") { self.confirmation(model) != nil }
        let sheet = try XCTUnwrap(confirmation(model))
        model.sheets.finish(model.sheets.current!.id)
        sheet.action()
        try await waitUntil("the stage") { !model.isBusy && model.changes.first?.staged != nil }
        let staged = try await porcelain()
        XCTAssertEqual(staged, "M  a.txt\n")
        XCTAssertTrue(model.gitTrust.isTrusted(directory))

        model.unstage(paths: [path])
        try await waitUntil("the unstage") { !model.isBusy && model.changes.first?.staged == nil }
        XCTAssertNil(confirmation(model), "a trusted repository is not asked again")
    }

    func testARepositoryWithNothingToRunIsNeverAsked() async throws {
        let model = try await loadedModel()
        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the stage") { !model.isBusy && model.changes.first?.staged != nil }
        XCTAssertNil(confirmation(model))
    }

    func testACleanFilterDoesNotRunUntilTheRepositoryIsTrusted() async throws {
        let script = base.appendingPathComponent("clean.sh")
        try "#!/bin/sh\ntouch '\(markers.path)/filter'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try await runner.run(["config", "filter.x.clean", script.path], in: directory)
        try "a.txt filter=x\n".write(to: directory.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let model = try await loadedModel()
        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the question") { self.confirmation(model) != nil }
        let sheet = try XCTUnwrap(confirmation(model))
        sheet.onCancel?()
        model.sheets.finish(model.sheets.current!.id)
        try await waitUntil("the action to end") { !model.isBusy }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markers.appendingPathComponent("filter").path))
    }

    func testOpeningARepositoryWithAFilterRunsNoFilterAndTrustingLetsStagingUseIt() async throws {
        let script = base.appendingPathComponent("clean.sh")
        try "#!/bin/sh\ntouch '\(markers.path)/filter'\ntr a-z A-Z\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try await runner.run(["config", "filter.x.clean", script.path], in: directory)
        _ = try await runner.run(["config", "filter.x.required", "true"], in: directory)
        try "a.txt filter=x\n".write(to: directory.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let model = try await loadedModel()
        let marker = markers.appendingPathComponent("filter").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "opening and refreshing ran the clean filter")
        XCTAssertEqual(model.changes.map(\.relativePath), ["a.txt"])

        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the question") { self.confirmation(model) != nil }
        let sheet = try XCTUnwrap(confirmation(model))
        model.sheets.finish(model.sheets.current!.id)
        sheet.action()
        try await waitUntil("the stage") { !model.isBusy && model.changes.first?.staged != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "a trusted repository stages through its filter")
        let blob = try await runner.run(["show", ":a.txt"], in: directory).text
        XCTAssertEqual(blob, "TWO\n")
    }

    func testClosingTheProjectAnswersAPendingQuestionAsNo() async throws {
        try installHook("pre-commit")
        let model = try await loadedModel()
        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the question") { self.confirmation(model) != nil }
        model.setRoot(nil)
        try await waitUntil("the action to end") { !model.isBusy }
        XCTAssertNil(confirmation(model))
    }

    func testAHunkIsGatedToo() async throws {
        try installHook("pre-commit")
        let model = try await loadedModel()
        let request = GitHunkApply(relativePath: "a.txt", baseBlobID: nil, patch: "", reverse: false)
        let task = Task { await model.applyHunk(request) }
        try await waitUntil("the question") { self.confirmation(model) != nil }
        confirmation(model)?.onCancel?()
        model.sheets.finish(model.sheets.current!.id)
        let message = await task.value
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("trust") == true, message ?? "")
    }
}

import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

/// A stand-in workspace: no editors are open, so every file is rewritten on disk.
@MainActor
private final class ClosedFilesHost: IDEWorkspaceEditHost {
    let editProjectRoot: URL?

    init(root: URL?) {
        editProjectRoot = root
    }

    func editTarget(for url: URL) async -> IDEWorkspaceEditTarget { .closed }
    func renameFile(from: URL, to: URL) throws {}
    func moveFile(from: URL, to: URL) throws {}
    func deleteFile(at: URL) throws {}
}

@MainActor
final class IDEReplaceInFilesTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("replace-project-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    private func write(_ path: String, _ text: String) throws -> URL {
        let url = project.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func plan(_ query: WorkspaceSearchQuery, _ replacement: String, files: [URL]) throws -> WorkspaceEditPlan {
        var entries: [WorkspaceEditPlanEntry] = []
        for url in files {
            entries += ProjectReplacePlanner.entries(for: query, replacement: replacement, in: try read(url), url: url)
        }
        return WorkspaceEditPlan(entries: entries, title: "Replace")
    }

    private func texts(_ files: [URL]) throws -> [URL: String] {
        Dictionary(uniqueKeysWithValues: try files.map { ($0, try read($0)) })
    }

    // MARK: Guard

    func testAnUnchangedFileKeepsEveryEdit() throws {
        let a = try write("src/A.txt", "old one, old two")
        let plan = try plan(WorkspaceSearchQuery(text: "old"), "new", files: [a])

        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: try texts([a]))

        XCTAssertEqual(outcome.edit.changes[a]?.count, 2)
        XCTAssertTrue(outcome.staleCounts.isEmpty)
    }

    func testAnEditWhoseTextMovedIsDropped() throws {
        let a = try write("src/A.txt", "old one, old two")
        let plan = try plan(WorkspaceSearchQuery(text: "old"), "new", files: [a])
        // Text inserted at the top since the search: every planned range now points at other text.
        let drifted = [a: "// header\nold one, old two"]

        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: drifted)

        XCTAssertNil(outcome.edit.changes[a])
        XCTAssertEqual(outcome.staleCounts[a], 2)
    }

    func testOnlyTheEditsThatDriftedAreDropped() throws {
        let a = try write("src/A.txt", "old\nold")
        let plan = try plan(WorkspaceSearchQuery(text: "old"), "new", files: [a])
        // The second line was edited; the first is untouched.
        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: [a: "old\nolx"])

        XCTAssertEqual(outcome.edit.changes[a]?.count, 1)
        XCTAssertEqual(outcome.staleCounts[a], 1)
    }

    func testAFileTheEditorCannotReadCountsAsChanged() throws {
        let a = try write("src/A.txt", "old")
        let plan = try plan(WorkspaceSearchQuery(text: "old"), "new", files: [a])

        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: [:])

        XCTAssertNil(outcome.edit.changes[a])
        XCTAssertEqual(outcome.staleCounts[a], 1)
    }

    func testARangePastTheEndOfTheFileIsDropped() throws {
        let a = try write("src/A.txt", "old old old")
        let plan = try plan(WorkspaceSearchQuery(text: "old"), "new", files: [a])

        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: [a: "old"])

        XCTAssertEqual(outcome.edit.changes[a]?.count, 1, "The first match is still there; the others are gone")
        XCTAssertEqual(outcome.staleCounts[a], 2)
    }

    // MARK: Guard plus applier, on disk

    func testReplaceAcrossFilesRewritesThemOnDisk() async throws {
        let a = try write("src/A.txt", "Foo bar foo\nlast foo\n")
        let b = try write("B.txt", "no match\nfoo\n")
        let untouched = try write("C.txt", "nothing here\n")
        let files = [a, b, untouched]
        let plan = try plan(WorkspaceSearchQuery(text: "foo"), "baz", files: files)
        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: try texts(files))

        let host = ClosedFilesHost(root: project)
        let result = await IDEWorkspaceEditApplier(host: host).apply(outcome.edit)

        XCTAssertTrue(result.isSuccess, "\(result.failures)")
        XCTAssertEqual(try read(a), "baz bar baz\nlast baz\n")
        XCTAssertEqual(try read(b), "no match\nbaz\n")
        XCTAssertEqual(try read(untouched), "nothing here\n")
        XCTAssertEqual(Set(result.appliedFiles), [a, b])
    }

    func testRegexReplacementWithCaptureGroupsRewritesTheFile() async throws {
        let a = try write("Names.txt", "ann@home\nbob@work\n")
        let query = WorkspaceSearchQuery(text: "(\\w+)@(\\w+)", useRegularExpression: true)
        let plan = try plan(query, "$2/$1", files: [a])
        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: try texts([a]))

        let host = ClosedFilesHost(root: project)
        let result = await IDEWorkspaceEditApplier(host: host).apply(outcome.edit)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try read(a), "home/ann\nwork/bob\n")
    }

    func testAFileChangedAfterThePlanIsLeftAloneAndReported() async throws {
        let a = try write("A.txt", "foo\n")
        let b = try write("B.txt", "foo\n")
        let plan = try plan(WorkspaceSearchQuery(text: "foo"), "bar", files: [a, b])
        // B is rewritten by something else between the search and Apply.
        _ = try write("B.txt", "prefix\nfoo\n")
        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: try texts([a, b]))

        let host = ClosedFilesHost(root: project)
        let result = await IDEWorkspaceEditApplier(host: host).apply(outcome.edit)

        XCTAssertEqual(try read(a), "bar\n")
        XCTAssertEqual(try read(b), "prefix\nfoo\n", "The drifted file is not touched")
        XCTAssertEqual(outcome.staleCounts[b], 1)
        XCTAssertEqual(result.appliedFiles, [a])
    }

    func testDeselectedEntriesAreNotApplied() async throws {
        let a = try write("A.txt", "foo foo foo")
        let plan = try plan(WorkspaceSearchQuery(text: "foo"), "x", files: [a])
        let chosen = Set(plan.entries.dropFirst().map(\.id))
        let edit = plan.workspaceEdit(including: chosen)
        let outcome = IDEReplaceInFilesGuard.verified(edit, against: plan, texts: try texts([a]))

        let host = ClosedFilesHost(root: project)
        _ = await IDEWorkspaceEditApplier(host: host).apply(outcome.edit)

        XCTAssertEqual(try read(a), "foo x x")
    }

    func testAFileOutsideTheProjectIsRefused() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("replace-outside-\(UUID().uuidString).txt").resolvingSymlinksInPath()
        try "foo".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let plan = try plan(WorkspaceSearchQuery(text: "foo"), "bar", files: [outside])
        let outcome = IDEReplaceInFilesGuard.verified(plan.workspaceEdit(), against: plan, texts: try texts([outside]))

        let host = ClosedFilesHost(root: project)
        let result = await IDEWorkspaceEditApplier(host: host).apply(outcome.edit)

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(try read(outside), "foo", "Nothing outside the project folder is written")
    }
}

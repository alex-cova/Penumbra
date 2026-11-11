import AppKit
import Darwin
import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// The Changes preview and Show Diff build one `IDEDiffRequest`. These cases do not run git.
final class IDEGitChangeDiffTests: XCTestCase {
    private func change(
        _ path: String,
        relative: String? = nil,
        staged: IDEGitFileStatus? = nil,
        unstaged: IDEGitFileStatus? = nil,
        original: String? = nil,
        index: Character = " ",
        worktree: Character = " "
    ) -> IDEGitChange {
        IDEGitChange(
            path: path,
            relativePath: relative ?? (path as NSString).lastPathComponent,
            staged: staged,
            unstaged: unstaged,
            originalPath: original,
            indexCode: index,
            worktreeCode: worktree
        )
    }

    func testAnUnstagedEditMatchesTheWorkingTreeRequest() {
        let file = change("/repo/a.txt", unstaged: .modified, worktree: "M")
        let preview = IDEGitChangeDiff.preview(of: file.path, in: [file])
        let opened = IDEGitChangeDiff.requests(in: [file], staged: false)
        XCTAssertEqual(preview?.request, opened.first)
        XCTAssertEqual(preview?.siblings, opened)
        XCTAssertEqual(preview?.request.indexAction, .stage)
        XCTAssertEqual(preview?.request.left.title, "Staged")
        XCTAssertEqual(preview?.request.right.title, "Your Version")
        XCTAssertEqual(preview?.relativePath, "a.txt")
    }

    func testAFileThatIsBothStagedAndUnstagedOpensTheUnstagedComparison() {
        let file = change("/repo/a.txt", staged: .modified, unstaged: .modified, index: "M", worktree: "M")
        let onlyStaged = change("/repo/b.txt", staged: .added, index: "A")
        let preview = IDEGitChangeDiff.preview(of: file.path, in: [file, onlyStaged])
        XCTAssertEqual(preview?.request.indexAction, .stage)
        XCTAssertEqual(preview?.siblings.map(\.filePath), [file.path])
        let stagedSide = IDEGitChangeDiff.requests(in: [file, onlyStaged], staged: true)
        XCTAssertEqual(stagedSide.map(\.filePath), [file.path, onlyStaged.path])
        XCTAssertEqual(stagedSide.last?.left.title, "Not in HEAD")
        XCTAssertNotEqual(preview?.request.id, stagedSide.first?.id)
    }

    func testDeletedRenamedCopiedAndUntrackedRequests() {
        let deleted = change("/repo/gone.txt", unstaged: .modified, worktree: "D")
        let deletedPreview = IDEGitChangeDiff.preview(of: deleted.path, in: [deleted])
        XCTAssertEqual(deletedPreview?.request.indexAction, .stage)
        XCTAssertEqual(deletedPreview?.request.left.title, "Staged")
        XCTAssertEqual(deletedPreview?.request.right.source, .workingTree(path: deleted.path))

        let renamed = change("/repo/new.txt", relative: "new.txt", staged: .modified, original: "old.txt", index: "R")
        let renamedPreview = IDEGitChangeDiff.preview(of: renamed.path, in: [renamed])
        XCTAssertEqual(renamedPreview?.request.left.title, "HEAD")
        XCTAssertEqual(renamedPreview?.request.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(renamedPreview?.request.right.source, .revision(.index, relativePath: "new.txt"))
        XCTAssertEqual(renamedPreview?.request.repositoryRelativePath, "new.txt")
        XCTAssertEqual(renamedPreview?.request.revisionPaths, ["old.txt", "new.txt"])
        XCTAssertEqual(renamedPreview?.request.indexAction, .unstage)
        XCTAssertTrue(renamedPreview?.request.comparesDistinctPaths ?? false)

        let copied = change("/repo/copy.txt", relative: "copy.txt", staged: .modified, original: "old.txt", index: "C")
        let copiedPreview = IDEGitChangeDiff.preview(of: copied.path, in: [copied])
        XCTAssertEqual(copiedPreview?.request.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(copiedPreview?.request.right.source, .revision(.index, relativePath: "copy.txt"))

        let untracked = change("/repo/n.txt", unstaged: .untracked, worktree: "?")
        let untrackedPreview = IDEGitChangeDiff.preview(of: untracked.path, in: [untracked])
        XCTAssertNil(untrackedPreview?.request.indexAction)
        XCTAssertEqual(untrackedPreview?.request.left.title, "Untracked")
        XCTAssertNil(untrackedPreview?.request.repositoryRelativePath)
        XCTAssertEqual(untrackedPreview?.relativePath, "n.txt")
    }

    func testARenameUsesTheOldPathOnlyOnTheSideThatGitMarked() {
        let mixed = change(
            "/repo/new.txt", relative: "new.txt", staged: .modified, unstaged: .modified,
            original: "old.txt", index: "R", worktree: "M"
        )
        let staged = IDEGitChangeDiff.request(for: mixed, staged: true)
        XCTAssertEqual(staged.left.source, .revision(.head, relativePath: "old.txt"))
        XCTAssertEqual(staged.right.source, .revision(.index, relativePath: "new.txt"))
        let unstaged = IDEGitChangeDiff.request(for: mixed, staged: false)
        XCTAssertEqual(unstaged.left.source, .revision(.index, relativePath: "new.txt"))
        XCTAssertEqual(unstaged.right.source, .workingTree(path: mixed.path))
        XCTAssertFalse(unstaged.comparesDistinctPaths)

        let worktreeRename = change(
            "/repo/moved.txt", relative: "moved.txt", unstaged: .modified,
            original: "old.txt", index: " ", worktree: "R"
        )
        let request = IDEGitChangeDiff.request(for: worktreeRename, staged: false)
        XCTAssertEqual(request.left.source, .revision(.index, relativePath: "old.txt"))
        XCTAssertEqual(request.right.source, .workingTree(path: worktreeRename.path))
        XCTAssertEqual(request.repositoryRelativePath, "old.txt")
        XCTAssertEqual(request.revisionPaths, ["old.txt", "moved.txt"])
        XCTAssertTrue(request.comparesDistinctPaths)
    }

    func testAMissingRenameSourceIsNotGuessedFromAnotherFile() {
        let renamed = change(
            "/repo/new.txt", relative: "new.txt", staged: .modified, original: nil, index: "R"
        )
        let neighbor = change(
            "/repo/old.txt", relative: "old.txt", unstaged: .modified, worktree: "D"
        )
        let request = IDEGitChangeDiff.request(for: renamed, staged: true)
        XCTAssertEqual(request.left.source, .revision(.head, relativePath: "new.txt"))
        XCTAssertEqual(request.right.source, .revision(.index, relativePath: "new.txt"))
        XCTAssertFalse(request.comparesDistinctPaths)
        XCTAssertNil(IDEGitChangeDiff.sourcePath(for: renamed, staged: true))
        XCTAssertNil(IDEGitChangeDiff.preview(of: renamed.path, section: .unstaged, in: [renamed, neighbor]))
        XCTAssertNotNil(IDEGitChangeDiff.preview(of: renamed.path, section: .staged, in: [renamed, neighbor]))
    }

    func testAPathThatLeftTheListHasNoPreview() {
        let file = change("/repo/a.txt", unstaged: .modified, worktree: "M")
        XCTAssertNil(IDEGitChangeDiff.preview(of: "/repo/missing.txt", in: [file]))
        XCTAssertNil(IDEGitChangeDiff.preview(of: file.path, in: []))
    }

    func testReloadSkipsADirtySessionAndAnUnrelatedPath() {
        XCTAssertFalse(IDEEmbeddedDiffReload.shouldReload(relativePath: "a.txt", paths: ["b.txt"], isRightDirty: false))
        XCTAssertFalse(IDEEmbeddedDiffReload.shouldReload(relativePath: "a.txt", paths: ["a.txt"], isRightDirty: true))
        XCTAssertFalse(IDEEmbeddedDiffReload.shouldReload(relativePath: nil, paths: ["a.txt"], isRightDirty: false))
        XCTAssertTrue(IDEEmbeddedDiffReload.shouldReload(relativePath: "n.txt", paths: ["n.txt"], isRightDirty: false))
    }
}

/// Embedded Changes sessions: the same comparison in two viewers, reloads, and cleanup.
@MainActor
final class IDEGitChangeDiffSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func textRequest(_ left: String, _ right: String, title: String) -> IDEDiffRequest {
        IDEDiffRequest(
            left: IDEDiffSide(source: .text(left), title: "Left"),
            right: IDEDiffSide(source: .text(right), title: "Right"),
            filePath: nil,
            title: title
        )
    }

    func testAReloadWithTheSameTextsDoesNotMoveTheCaret() async throws {
        let session = IDEDiffSession(
            request: textRequest("one\ntwo\nthree\nfour\n", "one\ntwo\nTHREE\nfour\n", title: "a"),
            siblings: []
        )
        var loads = 0
        session.loadContent = { source in
            loads += 1
            if case .text(let text) = source { return .text(text) }
            return .failed("no")
        }
        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        viewer.show(session, preferences: IDEPreferences.shared)
        await waitForCondition("chunks") { session.chunks.count == 1 }
        viewer.rightTextView.selectedRange = NSRange(location: 8, length: 0)
        let offset = viewer.rightTextView.contentOffset
        let loaded = loads
        session.reload()
        await waitForCondition("the reload reads both sides") { loads >= loaded + 2 }
        XCTAssertEqual(viewer.rightTextView.selectedRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(viewer.rightTextView.contentOffset, offset)
        viewer.detach(session)
        session.cancel()
    }

    func testAMissingFileLoadsAsAnEmptyWorkingTree() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt").path
        let session = IDEDiffSession(
            request: IDEDiffRequest.change(path: missing, relativePath: "gone.txt", staged: false, isNew: false),
            siblings: []
        )
        session.loadContent = { source in
            switch source {
            case .revision: return .text("old\n")
            case .workingTree(let path):
                guard let data = FileManager.default.contents(atPath: path) else { return .text("") }
                return .text(String(decoding: data, as: UTF8.self))
            case .text(let text): return .text(text)
            }
        }
        session.reload()
        await waitForCondition("the deletion") { session.state == .ready && !session.chunks.isEmpty }
        XCTAssertEqual(session.left.string, "old\n")
        XCTAssertEqual(session.right.string, "")
        session.cancel()
    }

    func testRapidSelectionDropsTheLoadsItSuperseded() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let first = textRequest("a\n", "A\n", title: "first")
        let second = textRequest("b\n", "B\n", title: "second")
        let third = textRequest("c\n", "C\n", title: "third")
        func view(_ request: IDEDiffRequest, epoch: UInt64 = 0) -> IDEEmbeddedDiffView {
            IDEEmbeddedDiffView(
                workspace: workspace, request: request, siblings: [first, second, third],
                reloadEpoch: epoch, onRequestChanged: { _ in }
            )
        }
        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let coordinator = IDEEmbeddedDiffView.Coordinator()
        coordinator.viewer = viewer
        coordinator.update(view(first))
        let session = try XCTUnwrap(coordinator.session)
        session.loadContent = { source in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if case .text(let text) = source { return .text(text) }
            return .text("")
        }
        coordinator.update(view(second))
        coordinator.update(view(third))
        await waitForCondition("the last file") { session.request.title == "third" && session.right.string == "C\n" }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.request.title, "third")
        XCTAssertEqual(session.right.string, "C\n")
        XCTAssertEqual(session.left.string, "c\n")
        coordinator.teardown()
        XCTAssertNil(coordinator.session)
    }

    func testAnUnrelatedRefreshDoesNotReloadAndAMatchingOneDoes() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let request = textRequest("a\n", "b\n", title: "a")
        func view(epoch: UInt64, paths: Set<String>) -> IDEEmbeddedDiffView {
            IDEEmbeddedDiffView(
                workspace: workspace, request: request, siblings: [request],
                reloadEpoch: epoch, reloadPaths: paths, reloadRelativePath: "a.txt",
                onRequestChanged: { _ in }
            )
        }
        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let coordinator = IDEEmbeddedDiffView.Coordinator()
        coordinator.viewer = viewer
        coordinator.update(view(epoch: 1, paths: ["a.txt"]))
        let session = try XCTUnwrap(coordinator.session)
        var loads = 0
        session.loadContent = { source in
            loads += 1
            if case .text(let text) = source { return .text(text) }
            return .text("")
        }
        session.reload()
        await waitForCondition("the first load") { loads >= 2 && session.state == .ready }
        let settled = loads
        coordinator.update(view(epoch: 2, paths: ["other.txt"]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(loads, settled, "a refresh of another file reloaded this one")

        session.rightTextDidChange()
        coordinator.update(view(epoch: 3, paths: ["a.txt"]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(loads, settled, "a dirty right side was reloaded over its edits")

        session.loadContent = { _ in
            loads += 1
            return .text("changed\n")
        }
        session.reload()
        await waitForCondition("the dirty buffer was discarded") { !session.isRightDirty && session.right.string == "changed\n" }
        let afterDiscard = loads
        coordinator.update(view(epoch: 4, paths: ["a.txt"]))
        await waitForCondition("the matching refresh") { loads >= afterDiscard + 2 }
        coordinator.teardown()
    }

    func testTwoViewersKeepIndependentScrollFocusAndHunkResults() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        UserDefaults.standard.removeObject(forKey: IDEDiffSettings.changesPrefix + "layout")
        let lines = (0 ..< 80).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let changed = lines.replacingOccurrences(of: "line 40\n", with: "line FORTY\n")
        let request = IDEDiffRequest.change(path: "/repo/a.txt", relativePath: "a.txt", staged: false, isNew: false)
        func session() -> IDEDiffSession {
            let made = workspace.makeEmbeddedDiffSession(
                request, siblings: [request],
                settingsPrefix: IDEDiffSettings.changesPrefix, defaultLayout: .sideBySide
            )
            made.loadContent = { source in
                switch source {
                case .revision: return .text(lines)
                case .workingTree, .text: return .text(changed)
                }
            }
            return made
        }
        let first = session()
        let second = session()
        XCTAssertFalse(first === second)
        XCTAssertTrue(workspace.diffSessionStore.isEmpty, "the sidebar session is not a tab")
        XCTAssertEqual(first.settings.layout, .sideBySide)
        XCTAssertEqual(second.settings.layout, .sideBySide)
        first.settings.layout = .unified
        XCTAssertEqual(second.settings.layout, .sideBySide)

        let frame = CGRect(x: 0, y: 0, width: 700, height: 160)
        let viewerA = IDEDiffViewerView(frame: frame)
        let viewerB = IDEDiffViewerView(frame: frame)
        let windowA = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        windowA.contentView = viewerA
        windowB.contentView = viewerB
        viewerA.show(first, preferences: workspace.preferences)
        viewerB.show(second, preferences: workspace.preferences)
        await waitForCondition("both viewers") {
            viewerA.layoutSubtreeIfNeeded()
            viewerB.layoutSubtreeIfNeeded()
            return first.chunks.count == 1 && second.chunks.count == 1
                && viewerA.rightTextView.contentSize.height > viewerA.rightTextView.bounds.height
        }
        XCTAssertFalse(viewerA.rightTextView === viewerB.rightTextView)
        viewerB.rightTextView.contentOffset.y = 90
        viewerA.rightTextView.contentOffset.y = 0
        viewerA.rightTextView.selectedRange = NSRange(location: 4, length: 0)
        windowA.makeFirstResponder(viewerA.rightTextView)
        XCTAssertEqual(viewerA.rightTextView.contentOffset.y, 0, accuracy: 0.5)
        XCTAssertEqual(viewerB.rightTextView.contentOffset.y, 90, accuracy: 0.5)
        XCTAssertEqual(viewerA.rightTextView.selectedRange.location, 4)
        XCTAssertNotEqual(viewerB.rightTextView.selectedRange.location, 4)
        XCTAssertTrue(windowA.firstResponder === viewerA.rightTextView)
        XCTAssertFalse(windowB.firstResponder === viewerB.rightTextView)
        viewerA.rightTextView.contentOffset.y = 40
        XCTAssertEqual(viewerB.rightTextView.contentOffset.y, 90, accuracy: 0.5, "scrolling one viewer moved the other")

        var lostCalls = 0
        var otherCalls = 0
        first.applyIndexPatch = { _ in
            lostCalls += 1
            return "The index changed."
        }
        second.applyIndexPatch = { _ in
            otherCalls += 1
            return nil
        }
        first.applyToIndex(chunkAt: 0)
        await waitForCondition("the losing viewer") { first.message == "The index changed." }
        XCTAssertEqual(lostCalls, 1)
        XCTAssertNil(second.message)
        second.applyToIndex(chunkAt: 0)
        await waitForCondition("the other viewer still stages") { otherCalls == 1 }
        XCTAssertEqual(first.message, "The index changed.")
        viewerA.detach(first)
        viewerB.detach(second)
        first.cancel()
        second.cancel()
    }

    func testAnUnsavedEditorMakesTheChangesSessionReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diff-dirty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try "disk\n".write(to: file, atomically: true, encoding: .utf8)
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        await workspace.openDocument(from: file)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        document.isDirty = true
        let path = file.standardizedFileURL.path
        let session = workspace.makeEmbeddedDiffSession(
            IDEDiffRequest.change(path: path, relativePath: "a.txt", staged: false, isNew: false),
            siblings: [],
            settingsPrefix: IDEDiffSettings.changesPrefix,
            defaultLayout: .sideBySide
        )
        defer { session.cancel() }
        XCTAssertNotNil(session.applyIndexPatch)
        XCTAssertEqual(
            session.readOnlyReasonProvider?(path),
            "Unsaved changes in the editor tab: save them to edit here"
        )
        document.isDirty = false
        XCTAssertNil(session.readOnlyReasonProvider?(path))
    }

    func testTheDiffHeaderBandFollowsTheEditorTokens() {
        let band = IDESourceControlDiffView.gitHeaderBandColor
        let expected = IDEAppearance.NSToken.editor.blended(withFraction: 0.08, of: IDEAppearance.NSToken.foreground)
        XCTAssertEqual(band, expected)
        XCTAssertEqual(band.alphaComponent, 1, accuracy: 0.001)
        XCTAssertNotEqual(band, NSColor.white.withAlphaComponent(0.06))
    }

    func testTeardownReleasesTheEmbeddedSession() async throws {
        weak var weakSession: IDEDiffSession?
        do {
            let workspace = IDEWorkspace()
            workspace.bootstrap()
            defer { workspace.teardown() }
            let request = textRequest("a\n", "b\n", title: "a")
            let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
            let coordinator = IDEEmbeddedDiffView.Coordinator()
            coordinator.viewer = viewer
            coordinator.update(IDEEmbeddedDiffView(
                workspace: workspace, request: request, siblings: [request], onRequestChanged: { _ in }
            ))
            weakSession = coordinator.session
            await waitForCondition("loaded") { weakSession?.state == .ready }
            coordinator.teardown()
        }
        for _ in 0 ..< 50 where weakSession != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(weakSession, "the embedded session outlived its view")
    }

    /// No millisecond budget. The log line is the sample of a 2,000-line selection:
    /// load plus the off-main-actor recompute in `IDEDiffSession.recompute`.
    func testSelectingATwoThousandLineDiffRecordsItsCost() async throws {
        let leftLines = (1 ... 2_000).map { "line \($0)" }
        var rightLines = leftLines
        rightLines[1_000] = "line 1000 changed"
        let session = IDEDiffSession(
            request: textRequest(
                leftLines.joined(separator: "\n") + "\n",
                rightLines.joined(separator: "\n") + "\n",
                title: "big"
            ),
            siblings: [],
            settings: IDEDiffSettings(),
            settingsPrefix: "umbra.test.diff.sample."
        )
        session.loadContent = { source in
            if case .text(let text) = source { return .text(text) }
            return .failed("no")
        }
        let before = residentBytes()
        let start = ContinuousClock.now
        session.reload()
        await waitForCondition("2,000 lines") { session.state == .ready && session.chunks.count == 1 }
        let elapsed = start.duration(to: .now)
        let after = residentBytes()
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        print(
            "PHASE3_DIFF_2000 elapsed=\(elapsed) resident_before=\(before) resident_after=\(after) " +
            "delta=\(Int64(after) - Int64(before)) configuration=\(configuration)"
        )
        XCTAssertEqual(session.chunks.count, 1)
        XCTAssertFalse(session.isStale)
        session.cancel()
    }
}

/// Show Diff and the Changes preview open the same request, including after a real status.
@MainActor
final class IDEGitChangeDiffIdentityTests: XCTestCase {
    private let runner = SystemGitRunner()
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diff-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Test"],
            ["config", "user.email", "t@example.com"],
            ["config", "commit.gpgsign", "false"],
        ] {
            _ = try await runner.run(args, in: directory)
        }
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "note\n".write(to: directory.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: directory.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt", "note.txt", "keep.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "base"], in: directory)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.gitStatus.setRoot(directory)
    }

    override func tearDown() async throws {
        workspace?.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        await waitForCondition(description) { condition() }
    }

    func testOpenChangeDiffMatchesTheChangesPreview() async throws {
        let model = workspace.gitStatus
        await waitUntil("the repository") { model.isRepository && model.currentBranch == "main" }
        _ = try await runner.run(["checkout", "-q", "-b", "side"], in: directory)
        try "side\n".write(to: directory.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "side.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "side"], in: directory)
        _ = try await runner.run(["checkout", "-q", "main"], in: directory)
        model.refresh()
        await waitUntil("back on main") {
            model.currentBranch == "main" && !model.changes.contains { $0.relativePath == "side.txt" }
        }
        let sidePath = directory.appendingPathComponent("side.txt").standardizedFileURL.path
        XCTAssertNil(IDEGitChangeDiff.preview(of: sidePath, in: model.changes))

        try "2\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        model.refresh()
        await waitUntil("a.txt and b.txt") {
            model.changes.contains { $0.relativePath == "a.txt" && $0.unstaged != nil }
                && model.changes.contains { $0.relativePath == "b.txt" && $0.unstaged == .untracked }
        }
        for relative in ["a.txt", "b.txt"] {
            let change = try XCTUnwrap(model.changes.first { $0.relativePath == relative })
            let preview = try XCTUnwrap(IDEGitChangeDiff.preview(of: change.path, in: model.changes))
            workspace.openChangeDiff(path: change.path, staged: IDEGitChangeDiff.prefersStaged(change))
            let session = try XCTUnwrap(workspace.diffSessionStore.diffs.values.first { $0.request.id == preview.request.id })
            XCTAssertEqual(session.request, preview.request)
            XCTAssertEqual(session.siblings, preview.siblings)
        }

        _ = try await runner.run(["mv", "keep.txt", "renamed.txt"], in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("note.txt"))
        model.refresh()
        await waitUntil("the rename and the deletion") {
            model.changes.contains { $0.relativePath == "renamed.txt" }
                && model.changes.contains { $0.relativePath == "note.txt" }
        }
        let renamed = try XCTUnwrap(model.changes.first { $0.relativePath == "renamed.txt" })
        let renamedPreview = try XCTUnwrap(IDEGitChangeDiff.preview(of: renamed.path, in: model.changes))
        XCTAssertEqual(renamedPreview.request.left.title, "HEAD")
        XCTAssertEqual(renamedPreview.request.left.source, .revision(.head, relativePath: "keep.txt"))
        XCTAssertEqual(renamedPreview.request.right.source, .revision(.index, relativePath: "renamed.txt"))
        XCTAssertEqual(renamedPreview.request.repositoryRelativePath, "renamed.txt")
        XCTAssertEqual(renamedPreview.request, IDEGitChangeDiff.requests(in: model.changes, staged: true).first { $0.filePath == renamed.path })

        let deleted = try XCTUnwrap(model.changes.first { $0.relativePath == "note.txt" })
        let deletedPreview = try XCTUnwrap(IDEGitChangeDiff.preview(of: deleted.path, in: model.changes))
        XCTAssertEqual(deletedPreview.request.right.source, .workingTree(path: deleted.path))
        XCTAssertEqual(deletedPreview.request.left.title, "Staged")
    }
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size
}

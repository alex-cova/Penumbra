import AppKit
import Foundation
import GitIntelligence
import SwiftUI
import XCTest
@testable import Penumbra
@testable import Umbra

/// Palette routing, list keys, and the F7 bindings. The diff view's own F7 stays a key interceptor.
final class IDEGitCommandRoutingTests: XCTestCase {
    func testListShortcutsAreCommandSAndCommandUOnly() {
        XCTAssertEqual(IDEGitListShortcut.action(characters: "s", modifiers: .command), .stage)
        XCTAssertEqual(IDEGitListShortcut.action(characters: "S", modifiers: .command), .stage)
        XCTAssertEqual(IDEGitListShortcut.action(characters: "u", modifiers: .command), .unstage)
        XCTAssertNil(IDEGitListShortcut.action(characters: "s", modifiers: [.command, .shift]))
        XCTAssertNil(IDEGitListShortcut.action(characters: "s", modifiers: [.command, .option]))
        XCTAssertNil(IDEGitListShortcut.action(characters: "s", modifiers: [.command, .control]))
        XCTAssertNil(IDEGitListShortcut.action(characters: "u", modifiers: []))
        XCTAssertNil(IDEGitListShortcut.action(characters: "k", modifiers: .command))
    }

    func testStageShortcutReplacesOnlyTheCommandBoundToCommandS() {
        for preset in [KeymapPreset.default_, .sublime, .vsCode] {
            XCTAssertEqual(IDEGitSaveIntercept.commandBoundToStageShortcut(in: preset), .save, "\(preset)")
            XCTAssertTrue(IDEGitSaveIntercept.shouldStage(changesListFocused: true, command: .save, preset: preset))
            XCTAssertFalse(IDEGitSaveIntercept.shouldStage(changesListFocused: true, command: .saveAll, preset: preset))
            XCTAssertFalse(IDEGitSaveIntercept.shouldStage(changesListFocused: false, command: .save, preset: preset))
        }
        XCTAssertEqual(IDEGitSaveIntercept.commandBoundToStageShortcut(in: .intelliJ), .saveAll)
        XCTAssertTrue(IDEGitSaveIntercept.shouldStage(changesListFocused: true, command: .saveAll, preset: .intelliJ))
        XCTAssertFalse(IDEGitSaveIntercept.shouldStage(changesListFocused: true, command: .save, preset: .intelliJ))
        XCTAssertFalse(IDEGitSaveIntercept.shouldStage(changesListFocused: false, command: .saveAll, preset: .intelliJ))
    }

    func testCommitRefusalUsesTheButtonWordingAndNotTheModelSentences() {
        XCTAssertEqual(
            IDEGitCommitRefusal.reason(isBusy: true, stagedCount: 1, isAmend: false, message: "hi"),
            "Wait for the current Git command to finish."
        )
        XCTAssertEqual(
            IDEGitCommitRefusal.reason(isBusy: false, stagedCount: 0, isAmend: false, message: "hi"),
            "Stage files to commit them"
        )
        XCTAssertEqual(
            IDEGitCommitRefusal.reason(isBusy: false, stagedCount: 0, isAmend: true, message: "  "),
            "Enter a commit message"
        )
        XCTAssertEqual(
            IDEGitCommitRefusal.reason(isBusy: false, stagedCount: 2, isAmend: false, message: ""),
            "Enter a commit message"
        )
        XCTAssertNil(IDEGitCommitRefusal.reason(isBusy: false, stagedCount: 1, isAmend: false, message: "Fix"))
        XCTAssertNotEqual(IDEGitCommitRefusal.emptyMessage, "Enter a commit message.")
        XCTAssertNotEqual(IDEGitCommitRefusal.nothingStaged, "Nothing staged to commit.")
    }

    func testIndexPathsUseTheSelectionThenTheActiveFile() {
        let changes = [
            change("/repo/a.txt", staged: nil, unstaged: .modified),
            change("/repo/b.txt", staged: .added, unstaged: nil),
            change("/repo/c.txt", staged: .conflicted, unstaged: .conflicted),
            change("/repo/d.txt", staged: .modified, unstaged: .modified),
        ]
        XCTAssertEqual(
            IDEGitIndexPaths.toStage(selected: ["/repo/a.txt", "/repo/b.txt", "/repo/c.txt"], changes: changes, activeFile: "/repo/d.txt"),
            ["/repo/a.txt"]
        )
        XCTAssertEqual(
            IDEGitIndexPaths.toUnstage(selected: ["/repo/a.txt", "/repo/d.txt", "/repo/c.txt"], changes: changes, activeFile: nil),
            ["/repo/d.txt"]
        )
        XCTAssertEqual(
            IDEGitIndexPaths.toStage(selected: [], changes: changes, activeFile: "/repo/a.txt"),
            ["/repo/a.txt"]
        )
        XCTAssertEqual(IDEGitIndexPaths.toStage(selected: [], changes: changes, activeFile: "/repo/b.txt"), [])
        XCTAssertEqual(
            IDEGitIndexPaths.toUnstage(selected: [], changes: changes, activeFile: "/repo/b.txt"),
            ["/repo/b.txt"]
        )
        XCTAssertEqual(IDEGitIndexPaths.toStage(selected: ["/repo/b.txt"], changes: changes, activeFile: "/repo/a.txt"), [])
    }

    func testConflictNavigationWalksPastTheOpenFile() {
        let paths = ["/repo/a.txt", "/repo/b.txt", "/repo/c.txt"]
        XCTAssertNil(IDEGitConflictNavigation.next(paths: [], currentPath: nil))
        XCTAssertEqual(IDEGitConflictNavigation.next(paths: paths, currentPath: nil), .open("/repo/a.txt"))
        XCTAssertEqual(IDEGitConflictNavigation.next(paths: paths, currentPath: "/repo/other.txt"), .open("/repo/a.txt"))
        XCTAssertEqual(IDEGitConflictNavigation.next(paths: paths, currentPath: "/repo/a.txt"), .open("/repo/b.txt"))
        XCTAssertEqual(IDEGitConflictNavigation.next(paths: paths, currentPath: "/repo/c.txt"), .stayed("/repo/c.txt"))
    }

    func testF7MovesBetweenEditorChangesAndDoesNotStealTheDiffOrTheDebugger() {
        let f7 = KeyStroke(KeyChord(code: 0x62))
        let shiftF7 = KeyStroke(KeyChord(code: 0x62, .shift))
        for keymap in [Keymap.default_, .sublime, .vsCode] {
            XCTAssertEqual(keymap.action(for: f7), .nextChange)
            XCTAssertEqual(keymap.action(for: shiftF7), .previousChange)
        }
        XCTAssertNil(Keymap.intelliJ.action(for: f7))
        XCTAssertNil(Keymap.intelliJ.action(for: shiftF7))
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x7D, [.control, .option, .shift]))),
            .nextChange
        )
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x7E, [.control, .option, .shift]))),
            .previousChange
        )
        for preset in [KeymapPreset.default_, .sublime, .vsCode] {
            XCTAssertNil(IDEMenuShortcuts.shortcut(for: .debugStepInto, in: preset), "\(preset) must not take F7")
            XCTAssertNil(IDEMenuShortcuts.shortcut(for: .debugSmartStepInto, in: preset), "\(preset) must not take ⇧F7")
        }
        XCTAssertEqual(
            IDEMenuShortcuts.shortcut(for: .debugStepInto, in: .intelliJ)?.key.character,
            Character(UnicodeScalar(NSF7FunctionKey)!)
        )
    }

    private func change(_ path: String, staged: IDEGitFileStatus?, unstaged: IDEGitFileStatus?) -> IDEGitChange {
        IDEGitChange(path: path, relativePath: (path as NSString).lastPathComponent, staged: staged, unstaged: unstaged)
    }
}

/// Commands against a real repository: focus, stage, and the commit refusal the model does not own.
@MainActor
final class IDEGitCommandFlowTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-commands-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.gitStatus.setRoot(directory)
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testFocusCommitMessageRequestsFocusWhenChangesIsAlreadyShowing() async throws {
        try await waitUntil("the repository") { self.workspace.gitStatus.isRepository }
        workspace.showSidebarTab(.changes)
        let request = workspace.sidebarFocusRequestID
        XCTAssertEqual(workspace.selectedSidebarTab, .changes)
        XCTAssertNil(workspace.pendingSidebarFocusTab)

        workspace.focusCommitMessage()

        XCTAssertEqual(workspace.selectedSidebarTab, .changes)
        XCTAssertEqual(workspace.pendingSidebarFocusTab, .changes)
        XCTAssertEqual(workspace.sidebarFocusRequestID, request + 1)
    }

    func testStageAndUnstageTheSelection() async throws {
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "add a"], in: directory)
        try "2\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        workspace.gitStatus.refresh()
        let model = workspace.gitStatus
        try await waitUntil("the edit") {
            model.changes.contains { $0.relativePath == "a.txt" && $0.unstaged != nil }
        }
        model.selectChange(model.changes.first { $0.relativePath == "a.txt" }?.path)

        workspace.stageSelectedChanges()
        try await waitUntil("staged") {
            model.changes.contains { $0.relativePath == "a.txt" && $0.staged != nil && $0.unstaged == nil }
        }

        workspace.unstageSelectedChanges()
        try await waitUntil("unstaged") {
            model.changes.contains { $0.relativePath == "a.txt" && $0.staged == nil && $0.unstaged != nil }
        }
    }

    func testCommitStagedRefusesBeforeTheModelChecksAndLeavesThoseSentencesAlone() async throws {
        try await waitUntil("the repository") { self.workspace.gitStatus.isRepository }
        let model = workspace.gitStatus
        model.commitMessage = "hello"
        workspace.commitStagedChanges()
        XCTAssertEqual(model.actionStatus, "Stage files to commit them")
        XCTAssertTrue(model.actionFailed)

        model.commitOptions.amend = true
        model.commitMessage = "  "
        workspace.commitStagedChanges()
        XCTAssertEqual(model.actionStatus, "Enter a commit message")

        model.requestCommit(options: model.commitOptions)
        XCTAssertEqual(model.actionStatus, "Enter a commit message.")
        model.commitOptions.amend = false
        model.commitMessage = "hello"
        model.requestCommit(options: model.commitOptions)
        XCTAssertEqual(model.actionStatus, "Nothing staged to commit.")
    }

    func testNextConflictWithNoneFails() async throws {
        try await waitUntil("the repository") { self.workspace.gitStatus.isRepository }
        workspace.openNextConflict()
        XCTAssertEqual(workspace.gitStatus.actionStatus, "No conflicts")
        XCTAssertTrue(workspace.gitStatus.actionFailed)
    }
}

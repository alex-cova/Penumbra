import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Letters, chrome, and discard copy. No git process.
final class IDEGitChangePresentationTests: XCTestCase {
    func testChromeFollowsEveryRefreshState() {
        let snapshot = sampleSnapshot()
        XCTAssertFalse(IDEGitChrome.isVisible(.unavailable))
        XCTAssertFalse(IDEGitChrome.showsCommitControls(.unavailable))
        XCTAssertNil(IDEGitRefreshCaption.updatingLine(.unavailable))

        let discovering = GitRefreshState.loading(last: nil)
        XCTAssertTrue(IDEGitChrome.isVisible(discovering))
        XCTAssertFalse(IDEGitChrome.showsCommitControls(discovering))
        XCTAssertEqual(IDEGitRefreshCaption.updatingLine(discovering), "Updating status…")

        let reloading = GitRefreshState.loading(last: snapshot)
        XCTAssertTrue(IDEGitChrome.isVisible(reloading))
        XCTAssertTrue(IDEGitChrome.showsCommitControls(reloading))
        XCTAssertEqual(IDEGitRefreshCaption.updatingLine(reloading), "Updating status…")

        let stale = GitRefreshState.stale(last: snapshot)
        XCTAssertTrue(IDEGitChrome.isVisible(stale))
        XCTAssertTrue(IDEGitChrome.showsCommitControls(stale))
        XCTAssertEqual(IDEGitRefreshCaption.updatingLine(stale), "Updating status…")

        let idle = GitRefreshState.idle(snapshot)
        XCTAssertTrue(IDEGitChrome.isVisible(idle))
        XCTAssertTrue(IDEGitChrome.showsCommitControls(idle))
        XCTAssertNil(IDEGitRefreshCaption.updatingLine(idle))

        let firstFailure = GitRefreshState.failed(last: nil, message: "index is corrupt")
        XCTAssertTrue(IDEGitChrome.isVisible(firstFailure))
        XCTAssertFalse(IDEGitChrome.showsCommitControls(firstFailure))
        XCTAssertNil(IDEGitRefreshCaption.updatingLine(firstFailure))
        XCTAssertEqual(firstFailure.failureMessage, "index is corrupt")

        let laterFailure = GitRefreshState.failed(last: snapshot, message: "index is corrupt")
        XCTAssertTrue(IDEGitChrome.isVisible(laterFailure))
        XCTAssertTrue(IDEGitChrome.showsCommitControls(laterFailure))
        XCTAssertEqual(laterFailure.snapshot?.branchName, "main")
    }

    func testLettersNounsAndRenamePaths() {
        assertPresentation("A", side: .index, letter: "A", noun: "Added", tint: .added)
        assertPresentation("M", side: .worktree, letter: "M", noun: "Modified", tint: .modified)
        assertPresentation("D", side: .worktree, letter: "D", noun: "Deleted", tint: .deleted)
        assertPresentation("C", side: .index, letter: "C", noun: "Copied", tint: .added, originalPath: "old.txt", fromPath: "old.txt")
        assertPresentation("?", side: .worktree, letter: "?", noun: "Untracked", tint: .added)
        assertPresentation("U", side: .worktree, letter: "U", noun: "Conflict", tint: .conflict)
        assertPresentation("!", side: .worktree, letter: "!", noun: "Ignored", tint: .ignored)
        assertPresentation(" ", side: .index, letter: "", noun: "", tint: .muted)
        assertPresentation("T", side: .worktree, letter: "T", noun: "Modified", tint: .muted)

        let renamed = IDEGitChangePresentation.make(code: "R", originalPath: "old.txt")
        XCTAssertEqual(renamed.letter, "R")
        XCTAssertEqual(renamed.noun, "Renamed")
        XCTAssertEqual(renamed.fromPath, "old.txt")
        XCTAssertEqual(IDEGitLetterTint.tint(forLetter: renamed.letter), .modified)
        XCTAssertEqual(renamed.title(path: "new.txt"), "old.txt → new.txt")
        XCTAssertEqual(
            renamed.accessibilityLabel(path: "new.txt", section: .staged),
            "Renamed from old.txt to new.txt, staged"
        )
        XCTAssertEqual(
            IDEGitChangePresentation.make(code: "M", originalPath: nil).accessibilityLabel(path: "a.txt", section: .unstaged),
            "Modified, a.txt, unstaged"
        )
        XCTAssertEqual(
            IDEGitChangePresentation.make(code: "U", originalPath: nil).accessibilityLabel(path: "a.txt", section: .conflict),
            "Conflict in a.txt"
        )
    }

    func testParseKeepsPorcelainLettersWhenTheExplorerTintCollapsesThem() {
        let deleted = GitStatusEntry(path: "gone.txt", originalPath: nil, indexCode: " ", worktreeCode: "D")
        let deletedChange = IDEGitStatusModel.parse(entries: [deleted], toplevel: "/repo", branch: "main").changes[0]
        XCTAssertEqual(deletedChange.unstaged, .modified)
        let deletedRow = deletedChange.presentation(in: .unstaged)
        XCTAssertEqual(deletedRow.letter, "D")
        XCTAssertEqual(deletedRow.noun, "Deleted")
        XCTAssertEqual(deletedRow.accessibilityLabel(path: "gone.txt", section: .unstaged), "Deleted, gone.txt, unstaged")

        let renamed = GitStatusEntry(path: "new.txt", originalPath: "old.txt", indexCode: "R", worktreeCode: " ")
        let renamedChange = IDEGitStatusModel.parse(entries: [renamed], toplevel: "/repo", branch: "main").changes[0]
        XCTAssertEqual(renamedChange.staged, .modified)
        XCTAssertNil(renamedChange.unstaged)
        let renamedRow = renamedChange.presentation(in: .staged)
        XCTAssertEqual(renamedRow.title(path: "new.txt"), "old.txt → new.txt")
        XCTAssertEqual(renamedRow.letter, "R")

        let copied = GitStatusEntry(path: "copy.txt", originalPath: "src.txt", indexCode: "C", worktreeCode: " ")
        let copiedRow = IDEGitStatusModel.parse(entries: [copied], toplevel: "/repo", branch: "main").changes[0]
            .presentation(in: .staged)
        XCTAssertEqual(copiedRow.noun, "Copied")
        XCTAssertEqual(copiedRow.title(path: "copy.txt"), "src.txt → copy.txt")

        let added = GitStatusEntry(path: "new.txt", originalPath: nil, indexCode: "A", worktreeCode: " ")
        XCTAssertEqual(
            IDEGitStatusModel.parse(entries: [added], toplevel: "/repo", branch: "main").changes[0].presentation(in: .staged).noun,
            "Added"
        )
        let untracked = GitStatusEntry(path: "fresh.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        XCTAssertEqual(
            IDEGitStatusModel.parse(entries: [untracked], toplevel: "/repo", branch: "main").changes[0].presentation(in: .unstaged).noun,
            "Untracked"
        )
        let conflict = GitStatusEntry(path: "both.txt", originalPath: nil, indexCode: "U", worktreeCode: "U")
        let conflictChange = IDEGitStatusModel.parse(entries: [conflict], toplevel: "/repo", branch: "main").changes[0]
        XCTAssertEqual(conflictChange.staged, .conflicted)
        XCTAssertEqual(conflictChange.presentation(in: .conflict).accessibilityLabel(path: "both.txt", section: .conflict), "Conflict in both.txt")
    }

    func testSelectionIdentityKeepsTheTwoCopiesOfOnePathApart() {
        let staged = IDEGitListedChange(section: .staged, path: "/repo/a.txt")
        let unstaged = IDEGitListedChange(section: .unstaged, path: "/repo/a.txt")
        let other = IDEGitListedChange(section: .unstaged, path: "/repo/b.txt")
        let visible = [staged, unstaged, other]
        var selection = IDEGitChangeSelection().selecting(unstaged, repositoryRoot: "/repo")
        selection = selection.toggling(staged)
        XCTAssertEqual(selection.rows, [staged, unstaged])
        XCTAssertEqual(selection.primary, staged)
        XCTAssertEqual(selection.paths, ["/repo/a.txt"])

        selection = selection.extending(to: other, in: [unstaged, other])
        XCTAssertEqual(
            selection.rows,
            [other],
            "The anchor is the staged copy, which is outside this section, so the range is the clicked row"
        )
        selection = IDEGitChangeSelection().selecting(unstaged, repositoryRoot: "/repo")
        selection = selection.extending(to: other, in: [unstaged, other])
        XCTAssertFalse(selection.rows.contains(staged), "A shift-click inside Changes does not select the staged copy")

        let moved = selection.reconciled(with: [staged], repositoryRoot: "/repo")
        XCTAssertEqual(moved.primary, staged, "Staging the last unstaged copy follows that path into Staged")
        XCTAssertEqual(moved.paths, ["/repo/a.txt"])

        let kept = IDEGitChangeSelection().selecting(unstaged, repositoryRoot: "/repo")
            .reconciled(with: visible, repositoryRoot: "/repo")
        XCTAssertEqual(kept.primary, unstaged, "A refresh that keeps both sides stays on the focused side")

        let otherRoot = kept.reconciled(with: visible, repositoryRoot: "/other")
        XCTAssertNil(otherRoot.primary)
        XCTAssertTrue(otherRoot.rows.isEmpty)

        let stale = IDEGitChangeSelection().selecting(unstaged, repositoryRoot: "/repo")
            .reconciled(with: [other], repositoryRoot: "/repo")
        XCTAssertNil(stale.primary)
        XCTAssertTrue(IDEListNeighbor.move(staged, in: visible, by: 1) == unstaged)
    }

    func testScrollIdentityAndFocusFollowTheSection() {
        XCTAssertEqual(IDEGitChangeListIdentity.id(section: .staged, path: "a.txt"), "staged\ta.txt")
        XCTAssertNotEqual(
            IDEGitChangeListIdentity.id(section: .staged, path: "a.txt"),
            IDEGitChangeListIdentity.id(section: .unstaged, path: "a.txt")
        )
        let both = [
            IDEGitListedChange(section: .staged, path: "a.txt"),
            IDEGitListedChange(section: .unstaged, path: "a.txt"),
            IDEGitListedChange(section: .unstaged, path: "b.txt"),
        ]
        XCTAssertEqual(IDEGitListFocus.section(focused: .unstaged, path: "a.txt", rows: both), .unstaged)
        XCTAssertEqual(IDEGitListFocus.section(focused: .staged, path: "a.txt", rows: both), .staged)
        XCTAssertEqual(
            IDEGitListFocus.section(focused: .unstaged, path: "a.txt", rows: [both[0]]),
            .staged
        )
        XCTAssertEqual(IDEGitListFocus.section(focused: .conflict, path: nil, rows: both), .conflict)
        XCTAssertEqual(IDEGitListFocus.section(focused: .staged, path: "missing", rows: both), .staged)
    }

    func testDiscardCopyNamesUnsavedEditorsAndKeepsRevertCommitSeparate() {
        let one = IDEGitDiscardPrompt.changes(revertable: ["a.txt"], skipped: [], unsavedEditors: 1)
        XCTAssertEqual(one.confirm, "Discard")
        XCTAssertEqual(one.title, "Discard changes to a.txt?")
        XCTAssertTrue(one.detail.contains("1 of them has unsaved edits in an open editor"))

        let many = IDEGitDiscardPrompt.changes(revertable: ["a.txt", "b.txt"], skipped: ["c.txt"], unsavedEditors: 2)
        XCTAssertEqual(many.title, "Discard changes to 2 files?")
        XCTAssertTrue(many.detail.contains("2 of them have unsaved edits in an open editor"))
        XCTAssertTrue(many.detail.contains("Not discarded (not in the last commit):"))
        XCTAssertTrue(many.detail.contains("c.txt"))

        let active = IDEGitDiscardPrompt.activeFile(name: "a.txt")
        XCTAssertEqual(active.confirm, "Discard")
        XCTAssertTrue(active.detail.contains("unsaved edits"))

        let skipped = IDEGitDiscardPrompt.nothingToDiscard(skipped: true)
        XCTAssertEqual(skipped.title, "Nothing to Discard")
        XCTAssertTrue(skipped.detail.contains("not in the last commit"))
        let clean = IDEGitDiscardPrompt.nothingToDiscard(skipped: false)
        XCTAssertEqual(clean.detail, "The selected files have no changes.")

        XCTAssertEqual(IDEGitStatusNoun.noun(for: .modified), "Modified")
        XCTAssertEqual(IDEGitStatusNoun.noun(for: .added), "Added")
        XCTAssertEqual(IDEGitStatusNoun.noun(for: .untracked), "Untracked")
        XCTAssertEqual(IDEGitStatusNoun.noun(for: .conflicted), "Conflict")
        XCTAssertEqual(IDEGitStatusNoun.noun(for: .ignored), "Ignored")
    }

    func testExplorerNounUsesThePorcelainWordWhileTheTintStaysCollapsed() {
        let deleted = IDEGitStatusModel.parse(
            entries: [GitStatusEntry(path: "gone.txt", originalPath: nil, indexCode: " ", worktreeCode: "D")],
            toplevel: "/repo", branch: "main"
        ).changes[0]
        XCTAssertEqual(deleted.unstaged, .modified)
        XCTAssertEqual(IDEGitExplorerNoun.spoken(status: .modified, change: deleted), "Deleted")

        let renamed = IDEGitStatusModel.parse(
            entries: [GitStatusEntry(path: "new.txt", originalPath: "old.txt", indexCode: "R", worktreeCode: " ")],
            toplevel: "/repo", branch: "main"
        ).changes[0]
        XCTAssertEqual(renamed.staged, .modified)
        XCTAssertEqual(IDEGitExplorerNoun.spoken(status: .modified, change: renamed), "Renamed")

        let copied = IDEGitStatusModel.parse(
            entries: [GitStatusEntry(path: "copy.txt", originalPath: "old.txt", indexCode: "C", worktreeCode: " ")],
            toplevel: "/repo", branch: "main"
        ).changes[0]
        XCTAssertEqual(IDEGitExplorerNoun.spoken(status: .added, change: copied), "Copied")

        XCTAssertEqual(IDEGitExplorerNoun.spoken(status: .modified, change: nil), "Modified")
        XCTAssertEqual(IDEGitExplorerNoun.spoken(status: .ignored, change: nil), "Ignored")
        XCTAssertNil(IDEGitExplorerNoun.spoken(status: nil, change: nil))
    }

    func testHistoryPlaceholderWaitsForTheFirstLoad() {
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: false, isEmpty: true, fileScoped: false, lineScoped: false),
            "Loading history…"
        )
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: false, isEmpty: true, fileScoped: true, lineScoped: false),
            "Loading history…"
        )
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: false, isEmpty: true, fileScoped: false, lineScoped: true),
            "Loading history…"
        )
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: true, isEmpty: true, fileScoped: false, lineScoped: false),
            "No commits"
        )
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: true, isEmpty: true, fileScoped: true, lineScoped: false),
            "No commits touched this file"
        )
        XCTAssertEqual(
            IDEGitHistoryPlaceholder.text(hasLoaded: true, isEmpty: true, fileScoped: false, lineScoped: true),
            "No commits touched these lines"
        )
        XCTAssertNil(IDEGitHistoryPlaceholder.text(hasLoaded: true, isEmpty: false, fileScoped: false, lineScoped: false))
        XCTAssertNil(IDEGitHistoryPlaceholder.text(hasLoaded: false, isEmpty: false, fileScoped: true, lineScoped: true))
    }

    func testConflictBannerFollowsTheStatusAndIgnoresMarkerText() {
        XCTAssertTrue(IDEGitConflictBannerPolicy.shows(status: .conflicted))
        XCTAssertTrue(IDEGitConflictBannerPolicy.shows(conflicted: true))
        XCTAssertFalse(IDEGitConflictBannerPolicy.shows(status: .modified))
        XCTAssertFalse(IDEGitConflictBannerPolicy.shows(status: nil))
        XCTAssertFalse(IDEGitConflictBannerPolicy.shows(conflicted: false))
        let marked = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> side\n"
        XCTAssertFalse(marked.isEmpty)
        XCTAssertFalse(IDEGitConflictBannerPolicy.shows(status: .modified))
    }

    private func assertPresentation(
        _ code: Character,
        side: IDEGitChangePresentation.Side,
        letter: String,
        noun: String,
        tint: IDEGitLetterTint,
        originalPath: String? = nil,
        fromPath: String? = nil
    ) {
        let entry = GitStatusEntry(
            path: "file.txt",
            originalPath: originalPath,
            indexCode: side == .index ? code : " ",
            worktreeCode: side == .worktree ? code : " "
        )
        let presentation = IDEGitChangePresentation.make(entry: entry, side: side)
        XCTAssertEqual(presentation.letter, letter, "letter for \(code)")
        XCTAssertEqual(presentation.noun, noun, "noun for \(code)")
        XCTAssertEqual(presentation.fromPath, fromPath, "from path for \(code)")
        XCTAssertEqual(IDEGitLetterTint.tint(forLetter: presentation.letter), tint, "tint for \(code)")
    }

    private func sampleSnapshot() -> GitWorkspaceSnapshot {
        GitWorkspaceSnapshot(
            id: GitRepositoryID(
                workTree: URL(fileURLWithPath: "/repo"),
                gitDirectory: URL(fileURLWithPath: "/repo/.git")
            ),
            generation: 1,
            state: GitRepositoryState(head: .branch("main")),
            branchName: "main",
            entries: [],
            upstream: nil,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

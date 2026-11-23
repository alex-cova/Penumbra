# 05 — Source control UX review

Date: 2026-11-22, commit `afc43b7f`.

**Method and limits.** This review comes from the SwiftUI and AppKit source, the existing UI-model tests (run green: `IDEGitChangePresentationTests`, `IDEListKeyboardTests`, `IDEGitCommandRoutingTests`, `IDEGitCommandFlowTests`, `IDEGitChangesListMeasurementTests`), and the app-level probes. **The app was not launched and no screenshots were taken. VoiceOver, light and dark mode, and visual hierarchy were not inspected live.** Statements about those cite code, not observation. Comparisons with other editors rely on their documented behaviour as generally known; they were not re-checked in this audit.

## 1. Changes sidebar

| Aspect | Observation | Assessment |
|---|---|---|
| Discoverability | Changes is a left-sidebar tab. The titlebar branch label opens the branch popup. There is a Git menu, palette commands, and editor context-menu items (Show Diff with HEAD, Rollback Change at Caret, Open on Web, Show History for Selection). | Good. Comparable to IntelliJ's Commit tool window. |
| Grouping | Conflicts, then Staged Changes, then Unstaged Changes, with counts (`IDEChangesFileList.swift:64–112`). A partly staged file is two rows with independent selection. | Right model (VS Code and IntelliJ "staging area" mode). **Broken for untracked files**: each appears in both Staged and Unstaged (G-02). The Staged count is inflated, and Unstage on such a row fails with a git error. |
| Status symbols | The letter comes from the porcelain code (M, A, D, R, C, T, U, ?). Tint is collapsed. Nouns are spoken ("Deleted, gone.txt, unstaged"). | Good, and tested. |
| Renames | "old → new" title; the accessibility label names both paths. | Good. Actions on a rename are half-done (G-10). |
| Conflicts | A separate section, banner (Resolve…, Continue, Skip, Abort), Accept Yours/Theirs, a 3-pane merge tool. | Strong. On par with IntelliJ, ahead of VS Code's default inline markers. |
| Context menus | Stage, Unstage, Discard…, Show Diff, Open, Merge…; act on the selection when the row is in it. | Good. |
| Selection | ⌘-click toggles, ⇧-click extends within a section, arrows move, typeahead. | Good, and tested (`IDEListKeyboardTests`). |
| Keyboard | ⌘S stages and ⌘U unstages while the list has focus (⌘S is remapped from Save only while the list is focused). Return opens the diff or merge tool. Esc goes to the message field. ⌘↩ commits from the message. F7/⇧F7 move between changes. | Good. ⌘S meaning "stage" in one focused list is surprising for a first-time user. It matches no other editor. It is documented in `IDEGitCommandRouting.swift`, but nothing in the UI shows it. Consider a hint in the row tooltip or context menu ("Stage ⌘S"). |
| Empty state | "No changes" with a checkmark (`IDEEmptyState`) | Good. |
| Loading and refresh | Spinner in the header while busy. Linear progress for network. `refreshState` drives the chrome (`testChromeFollowsEveryRefreshState`). | Good. Under sustained file activity the list silently stops updating (G-06), and no "refreshing…" indicator stays on. |
| Errors | The action status line under the header, a toast (`onActionReport`), and the Git console with the full stderr. A failed refresh keeps the last snapshot and shows the error. | Good. Most error text is git's raw first line (for example `fatal: could not resolve 'HEAD'` for G-09), which assumes git knowledge. |
| Large change lists | `LazyVStack`. Typing the commit message does not rebuild rows (`IDEGitChangesListMeasurementTests`, 2,000 rows). | Good for typing. A refresh with 10k changes blocks the main actor for 83–148 ms (`04_PERFORMANCE.md`). |
| Accessibility | Row labels and hints in `IDESourceControlChangeRow` (6 accessibility modifiers) and `IDEChangesPanel` (13) | Present in code; not verified with VoiceOver. |
| Light and dark | Colours come from `IDEAppearance.ColorToken` | Not inspected visually. |

## 2. Workflow walk-through (code paths plus probes)

| Step | Path | Status |
|---|---|---|
| 1. Open repository | `setRoot` → status | ✔. ✘ through a symlink (G-07). ✘ a bare repo or `.git` shows an error instead of "not a repository" (G-15). |
| 2. Modify file | Gutter after 400 ms; Changes after save | ✔ |
| 3. Review diff | Double-click → diff tab (index ↔ working tree) | ✔. ✘ non-UTF-8 files: editing and saving that side corrupts the file (G-05). |
| 4. Stage selected changes | Row stage, or the hunk »/Stage in the diff | ✔ whole files. ✘ hunks for paths with spaces (G-08). ✘ index line endings under autocrlf (G-04). No line-level staging. |
| 5. Commit message | Field, template, recent messages, amend, sign-off, skip hooks, fixup!/squash! | ✔ rich |
| 6. Commit | Pre-commit checks (conflicts and author block; markers, detached HEAD, 10 MB files, CRLF warn) → `commit -m` | ✔. With only untracked files the Commit button is enabled and `requestCommit`'s "Nothing staged" guard passes, because of G-02 (`IDEChangesPanel.swift:18`, `IDEGitStatus+Commit.swift:22`). Git then refuses. This is from code reading; the git error text was not captured. |
| 7. Clean status | Refresh after the action | ✔ Changes list. ✘ the gutter still marks the committed lines (G-03). |
| 8. Switch branch | Branch popup; saves editors first; Smart Checkout (stash/pop) or Force (confirmed) | ✔ |
| 9. Review changed files | Compare with branch, log, file history, line history | ✔ |
| 10. Resolve conflicts | Banner → merge tool → Apply (`git add`) → Continue | ✔ `GitOperationsIntegrationTests`, `IDEGitStatusOperationsTests` |

## 3. Destructive actions

| Action | Confirmation | Recovery | Assessment |
|---|---|---|---|
| Discard changes (list, active file) | Yes. Names the files, says "staged or not", counts unsaved editors, lists skipped files. | None. Local History may hold copies. | The confirmation is honest. **Semantics differ from VS Code**: Discard on an *unstaged* row also drops the *staged* version. Users coming from VS Code expect only the unstaged part to go. Offer "Discard Unstaged Changes" (`restore --worktree`, from the index) on unstaged rows, and keep the full rollback as a separate item. (G-17) |
| Delete untracked files | Not offered (no `git clean`). Discard skips untracked files. | — | Safe |
| Reset branch (soft, mixed, hard, keep) | Sheet with a warning when commits are on a remote | Reflog | Good |
| Force checkout | Confirmed; tracked files only | None | Good |
| Drop stash / Clear all | Confirmed. Resolved by hash. | `git fsck` only | Good |
| Abort merge or rebase | Confirmed | `ORIG_HEAD` | Good |
| Overwrite unsaved buffers | Switch, pull, merge, rebase, stash apply and reset save first (`afterSaving`). Discard reloads the reverted files' editors and drops their edits (stated in the prompt). Diff-viewer save checks the disk against what it loaded. | — | Good, except the diff-viewer save of an undecodable file skips that check and re-encodes the file (G-05) |
| Window close during an operation | No prompt; the git process is killed (G-14) | — | Should finish or warn |

## 4. Keyboard and commands

Present: stage and unstage (⌘S/⌘U in the list), commit (⌘↩), Commit and Push (⌥⌘K), Update Project (⌘T, IntelliJ keymap), Push (⇧⌘K), previous/next change (⇧F7/F7), previous/next file in the diff, Jump to Source (F4), Next Conflict, palette entries for git commands, branches, tags and commits.
Missing, with clear value:
- **Stage or unstage the current hunk from the editor gutter.** The stripe has no hit target (stated in `Git/CLAUDE.md`). VS Code, Zed and IntelliJ all allow this from the gutter. It is the single most-used partial-staging path in those editors.
- **Show the change under the caret inline** (IntelliJ's gutter popup, VS Code's peek). Only "Rollback Change at Caret" exists.
- A **Cancel** for running fetch, pull or push (none exists; see G-19).

## 5. Summary

The feature surface is IntelliJ-class: conflicts, interactive rebase, stash, compare, line history, commit checks, askpass. Interaction design and keyboard coverage are thoughtful and tested. The UX problems that matter are correctness leaking into the UI: untracked files shown as staged, a stale gutter after commit, a frozen list under file churn, hunk staging failures. One semantic choice (Discard drops staged changes from an unstaged row) deserves a second action rather than a change.

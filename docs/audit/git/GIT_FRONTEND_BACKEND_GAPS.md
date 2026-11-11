# Umbra Git frontend — backend gaps

Date: 2026-11-11. Companion to `GIT_FRONTEND_AUDIT.md`. The contract is `GIT_BACKEND_API_CONTRACT.md`.

The frontend phases 1–5 need no change to that contract. They read `GitRefreshState`, `GitWorkspaceSnapshot.entries`, and the model methods that already enter `GitMutationLane`. This document lists capabilities a later UI might want that the contract does not provide, and the precise change that would provide them. None of these are implemented by calling `git` from SwiftUI or by adding a second repository type beside `GitRepository`.

## Already sufficient

The UI work does not need new engine API for:

| Need | What exists |
|---|---|
| Loading, stale, failed, unavailable | `GitRefreshState` on `IDEGitStatusModel.refreshState` |
| Last good list after a failed refresh | `.failed(last:message:)` and `.stale(last:)` |
| Delete and rename labels | `GitStatusEntry.indexCode`, `worktreeCode`, `originalPath` on `workspaceSnapshot.entries`. `IDEGitChange.originalPath` is copied, and a diff uses it only when that side’s code is `R` or `C` |
| Stage, unstage, commit the index | `stage`, `unstage`, `stageAll`, `unstageAll`, `commitIndex` |
| Hunk stage, including rejection | `GitHunkApply`, `GitRepository.applyHunk`, `IDEDiffSession.applyToIndex` |
| Dirty editor must not enter the index | `applyToIndex` refuses `isRightDirty` and `readOnlyReasonProvider` |
| Conflicts | `GitStatusEntry.isConflicted`, `conflictStages`, `resolve`, `repositoryState.operation` |
| Fetch, pull, push progress | `GitProgress` published as `networkProgress` |
| History paging | `log(skip:limit:)`, `historyLimit` |
| Worktree operations | `worktreeList`, `worktreeAdd`, `worktreeRemove` on `GitRepository` |

`IDEGitStatusModel` is enough presentation state. Selection, the commit string, sheets, and `actionStatus` are UI state and stay on the model. They do not belong on `GitWorkspaceSnapshot`.

## Gaps

### G1 — Second repository in one window

**Priority.** P3. Product decision. Phase 8 of the backend plan left it undone.

**Why the UI cannot improvise.** `showsSourceControlTab`, the watcher, and `onRefreshed` assume one `repository` on the model. A nested `.git` discovered by walking the project would be a second source of truth if a view called `GitRepository.discover` itself.

**Change, if the product wants it.** Not a new type. A window holds an ordered list of `GitRepositoryID` it has been asked to show, and one `IDEGitStatusModel` per id, or the existing model gains an explicit active id and a second model owned by the window. Each model keeps its own `GitRefreshState` and its own lane key (`gitDirectory`). The contract’s rule stands: two worktrees do not share a lane, and two windows on the same `gitDirectory` do. Discovery of nested repos is a new method only if `discover(from:)` walking to the outermost root is the wrong default. Today that walk is specified. A nested-repo list would be a separate call, for example `GitRepository.nested(from: URL) async throws -> [GitRepositoryID]`, implemented as a read-only scan that does not change `discover`. Owner: `GitIntelligence` for the scan, the window for which ids are open.

**Until that exists.** One work tree per window. The Changes list is that work tree’s status, including when the opened folder is a subdirectory.

### G2 — Worktree switcher wrappers

**Priority.** P3. Optional phase 6 of the frontend plan.

**What is missing.** Not the Git commands. `GitRepository.worktreeList`, `worktreeAdd`, and `worktreeRemove` exist and are tested (`GitWorktreeTests`). The model has no methods, so a view that called them would skip `runGitAction` and the lane.

**Change.** On `IDEGitStatusModel`, not on a new type:

- `func listWorktrees() async -> [GitWorktree]` — read-only, no lane, empty array on throw, error via `fail`.
- `func addWorktree(path:branch:)` — `runGitAction` around `worktreeAdd`. Validation of an empty path and a leading `-` stays inside `worktreeAdd`, which already throws `GitError.invalidRequest`.
- `func removeWorktree(path:force:)` — `runGitAction` around `worktreeRemove`. The confirm sheet stays in the UI.

Opening the listed path is `IDEWindowRegistry`, which is app UI, not engine.

**Do not.** Put `[GitWorktree]` on `GitWorkspaceSnapshot`. The list is not status, and status refresh must not grow a `worktree list` process.

### G3 — Submodule update

**Priority.** P3.

**Today.** Porcelain v1 reports a submodule as `M`. There is no `submodule update`, `submodule init`, or absorb. Clone can pass `--recurse-submodules`.

**Change, if a UI offers it.** `GitRepository.submoduleUpdate(paths:recursive:)` async throws, mutation lane at the host, progress optional through the existing `GitProgressHandler`. Owner: `GitIntelligence`. The UI then treats a submodule path like any other `GitStatusEntry` plus this command. No SwiftUI `Process`.

**Until that exists.** The row shows the submodule as modified. That is honest about the porcelain the engine returns. Do not special-case the letter in the view by running `git submodule status`.

### G4 — Marker-only conflict detection

**Priority.** Do not build.

**Contract.** Callers use `isConflicted` and `conflictStages`. A buffer that contains `<<<<<<<` and is not unmerged is not a conflict.

**No API.** An editor banner keys off `IDEGitStatusModel.status(for:) == .conflicted`.

### G5 — Stage unsaved editor bytes

**Priority.** Do not build.

**Contract.** `applyHunk` does not read the editor. `IDEDiffSession.applyToIndex` refuses a dirty right side and an unsaved buffer. `commitIndex` commits the index. `commitFiles` records work-tree bytes and is the agent tool, not the panel.

**No API.** A future “stage the selection from the buffer” operation would be a new `GitHunkApply` source flag plus a write to the work tree first, specified in the contract before any button calls it. This audit does not add that flag.

### G6 — `AsyncStream` of refresh state

**Priority.** Do not build.

**Contract.** The panel reads the `@Observable` model. Section 7 of the contract records that the stream was considered and rejected.

**No API.** SwiftUI already observes `refreshState`.

### G7 — Rename and delete as engine status kinds

**Priority.** Not a gap for the UI. Phase 8 listed it. The snapshot already has the codes.

**No API.** `IDEGitChangePresentation` maps `GitStatusEntry` in the app target. Adding an enum case on `GitStatusEntry` would be churn. Do it only if a non-Umbra client needs the noun. The agent can read `indexCode` today.

### G8 — Porcelain v2

**Priority.** Not a UI task.

**Contract.** Worth doing only if a profile still shows too many spawns after `--ignored` left the hot path. The UI’s refresh caption (frontend phase 1) does not depend on how many processes a refresh uses.

### G9 — Ignored paths on the hot snapshot

**Priority.** P3, already specified.

**Today.** The hot status omits `--ignored`. A later pass merges `!!` rows. Its failure does not set `refreshError`. Until it returns, the explorer treats those paths as unknown.

**No new API.** The UI must not paint “modified” for a path missing from `statuses`. `status(for:)` already returns nil in that case. Leave the lag.

### G10 — Operation progress for local commands

**Priority.** Not a gap.

**Today.** `GitProgressHandler` covers fetch, pull, and push. Stage and commit do not stream. The frontend caption (“Staging…”) is local UI state set when `isBusy` flips. It does not need Git to emit percentages for `git add`.

## Rules for any later engine change

- The type lives in `GitIntelligence` and does not import SwiftUI, AppKit, Metal, CoreGraphics, or Penumbra.
- Mutations are entered from `IDEGitStatusModel.runGitAction` or `applyHunk`. A new method does not take the lane itself unless the contract says the host does, which is the current rule. A nested `perform` for the same `gitDirectory` deadlocks.
- Status failure keeps the last `GitWorkspaceSnapshot`.
- The view does not grow a `GitRunning` of its own.

# Umbra Git backend API contract

Date: 2026-11-11. Companion to `GIT_BACKEND_AUDIT.md` and `GIT_BACKEND_IMPLEMENTATION_PLAN.md`.

This is the boundary between the Git engine and any UI. The current panel calls `IDEGitStatusModel`. That model is `@MainActor`, imports AppKit, and owns sheets, selection, and the commit box. A second UI should read the types below and keep using that model for sheets and selection. It must not spawn `git` or add another Git stack.

The types in sections 1–4 are in the tree as of 2026-11-11. Where this document still says **proposed**, that item was not added. The one proposed item that stayed proposed is an `AsyncStream` of refresh state (section 7). The panel reads the `@Observable` model.

The engine stays in `GitIntelligence`. It must not import SwiftUI, AppKit, Metal, CoreGraphics, or `Penumbra`.

## 1. Identity

**Exists.** `GitRepository.root`, `GitRepository.gitDirectory`, and `GitRepository.id`. Both URLs are absolute. `discover(from:)` still returns nil when the directory is not a work tree, and also when the runner throws. `discoverOutcome(from:runner:network:)` returns `.notARepository` for Git’s “not a git repository” / “not a git work tree” text and throws any other runner error.

`GitRepositoryID` is the value below. `laneKey` is `gitDirectory` after resolving symlinks and standardizing. Two worktrees that share objects do not share a lane. The window that opened the work tree owns the snapshot. Closing it cancels that window’s tasks. A mutation another window already started runs to completion.

```swift
public struct GitRepositoryID: Sendable, Hashable, Codable {
    /// Work tree root. Standardized, symlinks resolved the same way `discover` does today.
    public var workTree: URL
    /// Directory that contains `HEAD` and the index. For a linked worktree this is
    /// `.git/worktrees/<name>`, not the common `.git`.
    public var gitDirectory: URL
}
```

**Classification.** Landed. `GitRepository.id` returns this value.

**Owner.** `GitIntelligence`.

**Concurrency.** Immutable value. No actor.

**Errors.** `discover` returns nil for “not a repository” and for a thrown runner error. Callers that must tell those apart use `discoverOutcome`. `IDEGitSupport.repository(for:)` throws `GitError.notARepository` only for `.notARepository`.

**Cancellation.** `discover` runs one `rev-parse`. Cancelling the calling task cancels that process through `SystemGitRunner`.

**UI.** Window title branch, “is this folder a repo,” and which watcher roots to add.

## 2. Snapshot

**Exists.** Private `IDEGitStatusModel.GitSnapshot`, plus public `GitRepositoryState`, `GitStatusEntry`, `GitSyncStatus`, `GitBranch`.

`GitStatusEntry.path` is the current path. For a rename or copy, `originalPath` is the old path. That matches Git 2.54 porcelain v1 `-z` (`R  new\0old\0`) and `GitStatusParser`. `isConflicted` is true for `AA`, `DD`, and any index or work-tree code of `U`.

**Landed.** `generation` is the refresh epoch captured when that load was requested. An apply whose epoch is no longer current is dropped. The model also publishes `refreshEpoch`, `lastAppliedRefreshEpoch`, and `lastDroppedRefreshEpoch`.

```swift
public struct GitWorkspaceSnapshot: Sendable, Equatable {
    public var id: GitRepositoryID
    /// Incremented when a load is started. An apply from an older generation is ignored.
    public var generation: UInt64
    public var state: GitRepositoryState
    /// Short branch name, or the short hash when detached. Nil when `state.head` is `.unknown`.
    public var branchName: String?
    public var entries: [GitStatusEntry]
    /// From `branchList` for the current branch. Nil when there is no upstream.
    /// Commit lists for the push sheet are not in this snapshot.
    public var upstream: GitUpstream?
    public var fetchedAt: Date
}

public struct GitUpstream: Sendable, Equatable {
    public var name: String
    public var ahead: Int
    public var behind: Int
    /// True when `%(upstream:track)` reported `[gone]`.
    public var gone: Bool
}

public enum GitRefreshState: Sendable, Equatable {
    /// No folder is open, or discover found no work tree.
    case unavailable
    /// A load is in flight and no snapshot has succeeded yet.
    case loading(last: GitWorkspaceSnapshot?)
    /// A snapshot is showing. A newer load is in flight, or a mutation has invalidated it.
    case stale(last: GitWorkspaceSnapshot)
    case idle(GitWorkspaceSnapshot)
    /// The last load failed. `last` is still what the panel shows. This is not “not a repository.”
    case failed(last: GitWorkspaceSnapshot?, message: String)
}
```

**Classification.** Landed. `GitStatusEntry` and `GitRepositoryState` stay as they are. `.unavailable` and `.stale` were added beyond the three-case sketch.

**Owner.** Value built by the app’s load (`IDEGitStatusModel.loadSnapshot` today) from `GitRepository` results. The type lives in `GitIntelligence` so the agent can read it without Umbra.

**Concurrency.** Published on the main actor. Loads run off the main actor. `apply` happens on the main actor and drops a snapshot whose `generation` is older than the newest mutation or `setRoot`.

**Errors.** `.failed` keeps `last` and is published as `IDEGitStatusModel.refreshError`. It is not an empty snapshot. “Not a repository” is `.unavailable`, which clears the snapshot. Do not use `.failed` for a folder that was never a work tree, and do not use `.unavailable` for a command that failed inside a known repository.

**Cancellation.** A cancelled load does not change `GitRefreshState`.

**UI.** Changes list, explorer colors, branch label, ahead/behind, operation banner (`state.operation`), conflict section (`entries` where `isConflicted`).

Ignored paths are not in the hot snapshot. A later pass merges `!!` entries into the model’s file statuses. Until it returns, the explorer treats those paths as unknown, not modified. A failure of that pass does not set `refreshError`.

`IDEGitChange.originalPath` is set from `GitStatusEntry.originalPath`. The row’s kind is still `.modified` for a delete or a rename. Listing the raw codes in the UI was not done.

## 3. Diff and hunks

**Exists.**

```swift
public func fileContents(at revision: GitRevision, path: String) async throws -> Data?
public func unstagedDiff(path: String) async throws -> String
public func stagedDiff(path: String) async throws -> String
public func workingTreeDiff(path: String, isUntracked: Bool) async throws -> String
public func commitDiff(hash: String, path: String) async throws -> String
public func applyPatch(_ patch: String, toIndex: Bool, reverse: Bool) async throws
```

`GitRevision` is `.head`, `.index`, `.commit`, `.parent`, `.ref`, `.stage(1|2|3)`.

`IDEDiffComputer.lineChunks` (app target, no SwiftUI) turns two strings into hunks for the viewer, the gutter, and the merge tool. It stays there. The engine does not learn about `TextView`, colors, or Metal.

The gutter’s question is buffer versus `HEAD`. The Changes list’s question is index versus work tree, and `HEAD` versus index. Callers pass the bytes they mean. Git does not read the editor.

**Landed.** `baseBlobID` is the index blob `:path` for both directions. Unstage does not check `HEAD:path`. `git apply --cached` edits the index, so that is the blob that must still match. Nil means the index had no blob when the patch was built.

```swift
public struct GitHunkApply: Sendable, Equatable {
    public var relativePath: String
    /// Blob id of `:path` when the patch was built. Nil when the index has no blob.
    public var baseBlobID: String?
    public var patch: String
    /// False stages into the index. True removes the hunk from the index.
    public var reverse: Bool
}

extension GitRepository {
    /// Applies `request.patch` with `git apply --cached --unidiff-zero` when `:path` is still `baseBlobID`.
    /// Does not write the work tree. Does not read unsaved editor buffers.
    public func applyHunk(_ request: GitHunkApply) async throws
}
```

**Classification.** `fileContents` and the diff string methods: keep, and they pass `--literal-pathspecs` when a path is set. `applyPatch`: keep as the primitive. `applyHunk`: landed. `IDEDiffPatchBuilder` stays in Umbra. It quotes a path that contains a space or a tab. It returns nil for an empty path, a newline, a quote, or a backslash. `IDEDiffSession.applyToIndex` refuses when the right side is dirty or `readOnlyReasonProvider` reports an unsaved editor, and it does not copy that buffer into the patch.

**Owner.** `GitRepository` for bytes and apply. The app for turning two texts into a patch.

**Concurrency.** Async, off the main actor. `applyHunk` takes the mutation lane (phase 4).

**Errors.** Throws `GitError.failed` when apply rejects the patch. Throws `GitError.invalidRequest` when the blob id moved. A zero exit is not enough for the caller to skip the blob check inside `applyHunk`.

**Cancellation.** A cancelled apply is a cancelled mutation. Phase 4 says a new stage must not cancel it. User-cancel and `setRoot` may.

**UI.** Stage hunk, unstage hunk. The panel commit is a different operation and commits the index as a whole.

**Buffer rule.** The UI may display unsaved text in the diff. It must not pass that text to `applyHunk` until the file has been saved, or until a future explicit operation says it is staging editor bytes. That operation is not in this contract.

## 4. Operations

These methods run off the main actor. They do not take the lane themselves. The host does: `IDEGitStatusModel.runGitAction` and `applyHunk`, and the agent commit and branch tools, call `GitMutationLane.shared.perform(gitDirectory:)`. Read-only commands do not. A nested `perform` for the same directory deadlocks. None of these are called from SwiftUI view bodies.

| Operation | Exists today | Lane | Result | UI |
|---|---|---|---|---|
| `stage(paths:)` | Yes. `--literal-pathspecs`, chunked at 200. | At the host | Throws `GitError` | Stage file. Stage all uses `stageAll` |
| `unstage(paths:)` | Yes. Same pathspec handling. | At the host | Throws | Unstage |
| `stageAll()` / `unstageAll()` | Yes | At the host | Throws | Stage all / unstage all |
| `applyHunk` | Yes. `applyPatch` remains. | At the host | Throws | Hunk buttons |
| `commit(message:paths:untrackedPaths:amend:signoff:skipHooks:)` | Yes. Path lists are literal. `--only` is one invocation. | At the host | Throws | Prefer `commitIndex` or `commitFiles` |
| `revert(paths:)` | Yes, literal and chunked | Mutation | `GitRevertResult` | Discard changes |
| `switchBranch` / `createBranch` / `checkout` | Yes | Mutation | Throws the Git message | Branch popup |
| `forceSwitchBranch` | Yes | Mutation | Throws | Only after the confirmation sheet |
| `merge` / `rebase` / `cherryPick` / `revertCommits` / `continueOperation` / `skipOperation` / `abortOperation` | Yes | Mutation | `GitIntegrationResult` (`.completed` or `.stopped`) | Banner, log actions |
| `fetch` / `pull` / `push` | Yes | Mutation, network environment | Throws, or the pull/push string | Fetch, update, push |
| `reset(to:mode:)` | Yes | Mutation | Throws | Reset sheet. `.hard` is destructive and confirmed in the UI. |
| `preservingLocalChanges` | Yes | Holds the lane across stash, operation, and pop | Outcome enum | Smart checkout |

**Index commit versus file commit.**

- Panel `performCommit` calls `commitIndex`. No pathspec. Amend, sign-off, and skip-hooks come from `IDEGitCommitOptions`. Hooks run unless skip is set. Signing uses the askpass environment (`credentials: true`).
- Agent `IDEGitCommitTool` calls `commitFiles` inside the lane. That is `commit --only` of the named paths after adding untracked ones. It records the work-tree bytes of those paths.

`commitIndex` and `commitFiles` are wrappers over `commit`. `commit` remains. An empty message throws `GitError.invalidRequest`. `commitFiles` also throws that when `paths` is empty.

```swift
public struct GitIndexCommit: Sendable, Equatable {
    public var message: String
    public var amend: Bool
    public var signoff: Bool
    public var skipHooks: Bool
}

extension GitRepository {
    /// `git commit` of the current index. No pathspec. Refuses an empty message.
    public func commitIndex(_ commit: GitIndexCommit) async throws -> String

    /// `git commit --only` of these literal paths, after adding `untrackedPaths`.
    /// Records the work-tree contents of `paths`. Used by the agent tool.
    public func commitFiles(message: String, paths: [String], untrackedPaths: [String], signoff: Bool) async throws -> String
}
```

**Classification.** Landed. The panel uses `commitIndex`. The agent uses `commitFiles`. `commit` remains for other callers.

**Errors.** Hook failure, missing identity, and empty commits surface as `GitError.failed` with stderr, or stdout when stderr is empty (merge and rebase already do this). A stop during merge or rebase is `GitIntegrationResult.stopped`, not a throw. `continueOperation` on a merge that still has conflicts throws.

**Cancellation.** Described in section 7.

**Progress.** `GitProgressHandler` already exists for fetch, pull, and push. The model publishes `networkProgress` on the main actor. Snapshots do not include progress. It updates many times per command.

## 5. History

**Exists.** `log`, `commit(hash:)`, `commitChanges`, `show`, `lineHistory`, `branchesContaining`, `authors`, `GitGraphLayout`.

Keep them. The log is not part of `GitWorkspaceSnapshot`. Reloading it on every status was an explicit cost tradeoff (`historyStale`). The contract keeps that rule: status refresh does not imply a new log. `noteRefsChanged` does.

**Pagination.** `log` already takes `skip` and `limit`. The panel uses `historyLimit` starting at 300. Keep that. Do not load the full history.

**UI.** History list, commit files, line history, compare (`compare(_:_:commitLimit:)` exists).

## 6. Conflicts

**Exists.**

```swift
public func conflictedFiles() async throws -> [String]
public func conflictStages(of path: String) async throws -> GitConflictStages
public func resolve(paths: [String], taking side: GitConflictSide) async throws
public func resolve(path: String, with contents: Data) async throws
public func markResolved(paths: [String]) async throws
```

`GitConflictStages` reports whether stages 1, 2, and 3 exist. A missing side is a deletion. `GitRevision.stage` reads one side. `GitRepositoryState.operation` reports merge, rebase, cherry-pick, revert, mailbox apply, and bisect, including step and total when Git wrote them.

**Classification.** Keep.

**UI.** Conflict section, banner, merge viewer. The merge viewer’s three texts are stage 2, the computed result, and stage 3, loaded as bytes. `IDEMergeComputer` stays in the app. The engine does not contain a three-way UI.

**Not in the contract.** Marker-only detection. Callers use `isConflicted` and `conflictStages`.

## 7. Publication, invalidation, cancellation

**Publication that exists.** `IDEGitStatusModel` is `@Observable` on the main actor. The panel reads it. `onRefreshed`, `onWorkingTreeChanged`, and `onActionReport` are callbacks the workspace sets.

**Not added.** An `AsyncStream<GitRefreshState>` was considered and not built. The panel and the agent read the `@Observable` model or call `GitRepository` directly. Do not add a notification bus.

**Invalidation rules.**

| Event | Status snapshot | Log | `HEAD` blob cache |
|---|---|---|---|
| Work-tree file change inside the project | Refresh | Unchanged | Unchanged |
| Index change | Refresh | Unchanged | Unchanged |
| `HEAD`, refs, packed-refs | Refresh and `noteRefsChanged` | Reload | Drop all |
| Operation files | Refresh and `noteRefsChanged` | Reload | Unchanged unless `HEAD` moved |
| App became active | Refresh and `noteRefsChanged` | Reload | Unchanged unless `HEAD` moved |
| Mutation finished | Refresh and `noteRefsChanged` | Reload | Follow the `HEAD` rule |
| Editor keystroke | None | None | None. Gutter debounces against the cache. |

Phase 3 adds the Git directory as a source of the first four rows when it sits outside the project.

**Cancellation rules.**

- Status and log tasks cancel when a newer load is enough or the window closes. Their results must not `apply`.
- A mutation is not cancelled because another mutation started. It is cancelled when that window closes (`setRoot`) or the user cancels that operation. The cancelled waiter’s body does not run. The mutation it was waiting behind is left running.
- Cancel sends SIGTERM, then SIGKILL after 2 seconds, to the Git process only. Hooks are not in the process group. The contract requires the follow-up status to keep the last snapshot if Git reports `index.lock`.
- Network progress stops when that task ends.

## 8. Errors

**Exists.** `GitError`: `.gitNotFound`, `.failed(status:stderr:stdout:)`, `.notARepository`, `.invalidBranchName`, `.invalidRequest`. `errorDescription` uses stderr, then stdout.

`GitIntegrationResult`: `.completed(String)` or `.stopped(String)`.

**Classification.** Keep. Map `.failed` into `GitRefreshState.failed` for status. Map `.stopped` into a successful state update plus `state.operation`, not into `.failed`.

**UI.** `actionStatus` / `actionFailed` today. The snapshot’s `.failed` is for refresh. Action errors stay on the action, because a failed push must not look like a lost repository.

## 9. Compatibility and migration

| Symbol | Class | Note |
|---|---|---|
| `GitRepository`, `discover`, `discoverOutcome`, `state`, `id` | Keep | `discover` still collapses runner failures to nil. |
| `GitStatusEntry`, `GitRepositoryState`, `GitRevision`, `GitError`, `GitIntegrationResult` | Keep | Rename field order is already correct. |
| `GitRunning`, `SystemGitRunner` | Keep | Test seam. |
| `status`, `branchList`, `log`, `fileContents`, diff strings | Keep | Hot refresh passes `includingIgnored: false`. A second pass passes true. |
| `stage`, `unstage`, `commit`, `commitIndex`, `commitFiles` | Keep | Literal pathspecs on the path-taking forms. |
| `applyPatch`, `applyHunk` | Keep | `applyHunk` checks `:path`, then calls `applyPatch`. |
| `IDEGitStatusModel` | Keep | Publishes `refreshState` and `workspaceSnapshot`. Keeps sheets and selection. |
| `IDEGitChange` | Keep | `originalPath` is set. Delete and rename are still shown as modified. |
| `IDEGitCommit` | Keep | Presentation over `GitCommit`. |
| `GitRepositoryController` as a new framework | Do not introduce | The model plus `GitRepository` is the controller. |
| libgit2 types | Do not introduce | |

No flag day. The panel does not move packages. Steps 1–7 of the original migration are in the tree, except that the agent status tool still calls `GitRepository` rather than reading `GitWorkspaceSnapshot`.

## 10. What a UI agent can rely on

1. `GitRepositoryID` and `GitWorkspaceSnapshot` / `GitRefreshState`. `.failed` keeps the last snapshot. `.unavailable` means there is no work tree. `.stale` means the showing snapshot is invalidated. `generation` is the epoch of that load. An older load is not published.
2. `commitIndex` commits the index. `commitFiles` is `commit --only` of named work-tree paths. Hunk apply is neither.
3. `GitHunkApply`: relative path, index blob id (`:path`, both directions), patch, `reverse`. The session refuses an unsaved editor buffer and a dirty right side. The repository refuses a blob id that no longer matches.
4. Publication is the `@Observable` model on the main actor. `refreshError` is the message for `.failed`. There is no `AsyncStream`.
5. Mutations for one git directory are serialized at the host. Read-only status, log, diff, and blame are not. Cancelling a waiter does not cancel the mutation it is waiting for.

Build screens against `IDEGitStatusModel` and these types. Do not spawn `git`. Do not stage from an unsaved buffer. A path with a newline cannot be hunk-staged; stage that file as a whole. Ignored-file coloring can lag the hot snapshot.

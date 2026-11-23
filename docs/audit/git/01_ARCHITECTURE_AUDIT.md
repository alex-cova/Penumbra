# 01 — Git integration: architecture audit

Date: 2026-11-22. Commit `afc43b7f` (main, clean tree). Apple Git 2.54.0 (Apple Git-157), macOS 27.2.1, Apple M5 Max, 64 GB.

Scope: every component that runs git, holds git state, or shows it. This pass read the code. Behaviour claims cite either a test or a probe from this audit (see `07_TEST_COVERAGE.md` § Probes). An earlier audit set from 2026-11-11/17 sits in this folder (`GIT_BACKEND_AUDIT.md`, `GIT_FINAL_VERIFICATION.md`, …). This report does not repeat it. Where its fixes changed behaviour, this report says so.

## 1. Components

### 1.1 Execution layer

| Component | File | Role |
|---|---|---|
| `SubprocessRunner` / `SubprocessJob` | `Packages/SubprocessKit/Sources/SubprocessKit/` | `posix_spawn` plus pipes. Cancellation sends SIGTERM, then SIGKILL after `terminationGrace` (2 s default). No shell. |
| `GitRunning`, `SystemGitRunner` | `Packages/GitIntelligence/Sources/GitIntelligence/Process/GitRunner.swift` | Runs `/usr/bin/git -c core.quotepath=off …`. Merges the caller's environment over the process environment. Reports every command to a `GitCommandObserving`. A non-zero exit throws `GitError.failed`. **No timeout.** |
| `GitRepository.readOnly` | `GitRepository.swift:165` | Prefixes `--no-optional-locks`, so a status never rewrites the index and cannot trigger the watcher. |
| `GitRepository.mutate` | `GitRepository+Remotes.swift:12` | Adds the network environment (askpass or batch mode) when asked. |
| `GitMutationLane` | `GitMutationLane.swift` | One process-wide actor. Serializes mutations per resolved git directory. Waiters can be cancelled before they start. |
| `IDEGitSupport.runner` | `Umbra/Sources/Umbra/Git/IDEGitSupport.swift:9` | The one `SystemGitRunner` Umbra uses. Its observer feeds `IDEGitCommandStore` (last 500 commands that changed something or failed; in memory only). |
| Askpass | `Umbra/Sources/Umbra/Git/IDEGitAskPass.swift` | Umbra re-executes itself as `GIT_ASKPASS`/`SSH_ASKPASS`. The prompt goes over a Unix socket in a 0700 directory, with a per-launch token and a session id. |

### 1.2 Domain models (pure, `GitIntelligence`)

`GitStatusEntry` (porcelain v1 XY plus the original path), `GitRepositoryState` (HEAD and the operation in progress, read from `.git` files), `GitWorkspaceSnapshot` and `GitRefreshState` (generation-stamped snapshot), `GitHunkApply` (patch plus base blob id), `GitCommit`, `GitBranch`, `GitStash`, `GitRebasePlan`, `GitConflictStages`, `GitRevision`. Parsers: `GitStatusParser`, `GitLogParser`, `GitNameStatusParser`, `GitBlameParser`, `GitRefParsers`, `GitWorktreeParser`, `GitProgressParser`.

### 1.3 Repository operations (`GitRepository` and extensions)

A stateless `struct` per work tree: `root`, `gitDirectory`, runner, network environment. About 90 public methods over these files: `GitRepository.swift` (status, diff, blob reads, stage/unstage, hunk apply, commit, revert), `+Branches`, `+Remotes`, `+Operations` (merge, rebase, conflicts), `+History` (cherry-pick, revert, reset, interactive rebase), `+Stash`, `+Checks`, `+Clone`, `+Worktree`.

### 1.4 State and synchronization (Umbra)

| Component | File | Role |
|---|---|---|
| `IDEGitStatusModel` | `Umbra/Sources/Umbra/Git/IDEGitStatus.swift` (1,309 lines) plus `+Commit`, `+History`, `+Operations`, `+Remote`, `+Stash`, `+Web` | One per window. `@MainActor @Observable`. Holds status, changes, branches, log, stash, sync, selection, sheets, busy flags, and the action status line. Runs every mutation (`runGitAction`). |
| Refresh pipeline | `refresh(invalidating:)` → `beginRefresh` → `loadSnapshot` (off main) → `applyLoaded` | Epoch counter, one load in flight, `needsAnotherPass`, a token per task, and an ignored pass after each load. |
| `IDEProjectWatcher` | `Umbra/Sources/Umbra/Workspace/IDEProjectWatcher.swift` | The only FSEvents stream. Sorts `.git/index`, `HEAD`, `refs/**`, `packed-refs` and operation files into `gitMetadataChanged`, `gitRefsChanged` and `gitOperationChanged`. Watches a git directory that sits outside the project. Batches are coalesced over 150 ms. |
| Workspace glue | `IDEWorkspace.swift:320–343` (`onRefreshed`), `:5080–5110` (watcher batch → `gitStatus.refresh`) | After each refresh: blame, diff-tab reloads, HEAD-cache invalidation, gutter refresh. |
| Change markers (gutter) | `Umbra/Sources/Umbra/Editor/IDEChangeMarkers.swift` | Buffer against a cached `HEAD` blob (LRU: 128 entries, 32 MB). A diff runs off the main thread 400 ms after typing. |
| Diff viewer | `Umbra/Sources/Umbra/Diff/` (`IDEDiffSession`, `IDEDiffComputer`, `IDEDiffPatchBuilder`, `IDEDiffSessionStore`) | Side-by-side and unified views. Hunk stage and unstage use `git apply --cached --unidiff-zero`. The working-tree side is editable. |
| Merge tool | `Umbra/Sources/Umbra/Git/Merge/` | Pure diff3 (`IDEMergeComputer`) over index stages 1/2/3. |
| Blame | `Umbra/Sources/Umbra/Git/IDEGitBlame.swift` | `blame --porcelain --contents -` on the live buffer. |

### 1.5 Presentation

`IDEChangesPanel` and `IDEChangesFileList` (sidebar Changes: conflicts, staged, unstaged; a `LazyVStack`), `IDESourceControlPanel` (History: log, console, compare, stashes), `IDEGitBranchPopup`, `IDEGitOperationBanner`, `IDEGitSheets`/`IDEGitSheetViews` (one sheet queue per window), `IDEGitConsoleView`, `IDEGitStashPanel`, `IDEGitCompareView`, Explorer tints via `IDEGitStatusModel.status(for:)`.

### 1.6 Other consumers

`IDEAgentGitTools` (agent status, log and commit; commit needs approval), `IDEAgentWorktreeStore` (agent worktrees), `IDEGitVisibleFiles` (`ls-files` for search).

## 2. Diagram

```
┌──────────────────────────── UI (SwiftUI, @MainActor) ─────────────────────────────┐
│ IDEChangesPanel / IDEChangesFileList   IDESourceControlPanel (Log·Console·Compare·│
│ IDEGitBranchPopup  IDEGitOperationBanner   Stashes)   Explorer tints   Sheets     │
│ Editor gutter (IDEChangeMarkerController, IDEGitBlame)   Diff tab (IDEDiffViewer) │
└───────────────▲───────────────────────────────▲───────────────────▲───────────────┘
                │ @Observable reads              │ onRefreshed       │ session.reload
┌───────────────┴──── State (Umbra, per window, @MainActor) ───────┴───────────────┐
│ IDEGitStatusModel ── statuses/changes/branches/log/stash/sync/selection/sheets    │
│   refresh(): epoch ▸ one load ▸ needsAnotherPass ▸ drop superseded ▸ ignored pass │
│   runGitAction(): GitMutationLane ▸ invalidateForMutation ▸ action ▸ refresh      │
│ IDEDiffSessionStore (diff tabs)   IDEMergeSession   IDEChangeMarkerController      │
└──────▲──────────────────────────────▲──────────────────────────────▲─────────────┘
       │ batches (150 ms)             │ async calls (off main)        │ GitHunkApply
┌──────┴───────────┐   ┌──────────────┴──── GitIntelligence (pure Swift) ───────────┐
│ IDEProjectWatcher│   │ GitRepository (+Branches,+Remotes,+Operations,+History,     │
│ FSEvents: root + │   │   +Stash,+Checks,+Clone,+Worktree)   GitRepositoryState     │
│ external git dir │   │ Parsers   Models   GitMutationLane (process-wide actor)    │
└──────────────────┘   └──────────────────────────────▲──────────────────────────────┘
                                                       │ [String] args, stdin
                       ┌───────────────────────────────┴─────────────────────────────┐
                       │ SystemGitRunner ▸ SubprocessKit (posix_spawn, SIGTERM/KILL) │
                       │ /usr/bin/git -c core.quotepath=off [--no-optional-locks] …  │
                       └──────────────────────────────────────────────────────────────┘
```

Dependencies point down only. `GitIntelligence` depends on `SubprocessKit` and Foundation. It has no AppKit and no Penumbra. Nothing in `Penumbra` or `EditorIntelligence` imports it (checked with `grep`). That matches the CLAUDE.md layering rules.

## 3. Strengths (keep)

- **Process boundary.** Arguments are arrays, never a shell string. User-controlled names are checked against a leading `-` or passed after `--`. Path operations use `--literal-pathspecs` (probe 7: `*`, `:(glob)*` and `-rf` are staged as literal names). Reads take no optional locks.
- **Repository state without a process.** `GitRepositoryState.read` reads HEAD and the operation in progress from files, so a merge started in a terminal shows up (probe 2: `MERGE_HEAD` and all four conflict shapes were reported correctly).
- **Mutation lane.** It is process-wide and keyed by the git directory, so two windows on one work tree cannot overlap mutations and linked worktrees do not block each other. `GitMutationLaneTests` cover it.
- **Stash by hash.** Stash operations resolve the current `stash@{n}` from the hash first, so a stash added or dropped in between cannot make Drop hit the wrong entry.
- **Interactive rebase without an editor.** It re-checks that `base..HEAD` still matches the plan before it writes the todo.
- **Generation-stamped snapshots and an explicit refresh state** (`GitRefreshState`). A failed status keeps the last snapshot.
- **One watcher, with git-directory classification.** A save refreshes status only. A ref change also reloads the log.

## 4. Weaknesses

| # | Weakness | Evidence | Consequence |
|---|---|---|---|
| A1 | `IDEGitStatusModel` is a 1,300-line model plus six extensions (about 2,500 lines) that own status, history, stash, remotes, commit, selection, sheets and busy state together. | Its file sizes, and the fields at `IDEGitStatus.swift:56–216` | Every `@Observable` write sits on one object. Fixes such as the epoch work interact in non-obvious ways (see A3). Tests have to build the whole model. |
| A2 | The status vocabulary is translated twice. Porcelain XY becomes `IDEGitFileStatus` (5 cases) through `statusFromIndexChar`/`statusFromWorkTreeChar`, and the rows then read raw `indexCode`/`worktreeCode` again for letters. | `IDEGitStatus.swift:1269–1288`, `IDEGitChange.indexCode` | The lossy mapping has a `default: .modified` branch. It sends untracked `?` to a **staged** side (finding G-02, confirmed). A typed porcelain enum in `GitIntelligence` would make that impossible. |
| A3 | "Drop superseded result" plus "re-run" is a policy that can starve. | `IDEGitStatus.swift:322–333`; probe 10 | While watcher batches arrive faster than a status completes, no snapshot is ever applied (G-06). The previous audit's F7 introduced this to fix a stale flash. Applying the finished snapshot and then re-running would be correct, because each load starts after the last one finished. |
| A4 | Whether HEAD moved is read from the symbolic HEAD, not the commit id. | `IDEGitStatus.swift:386` (`state.head != repositoryState.head`) | A commit, amend, reset or fast-forward on the same branch does not invalidate the gutter's HEAD-blob cache (G-03, confirmed). This came from the previous audit's F6 fix. |
| A5 | Path identity is spelled two ways. The model's keys use git's `--show-toplevel` spelling (symlinks resolved). Editors, the Explorer and the watcher use the folder the user opened. | `IDEGitStatus.swift:1146`, `IDEWindowRegistry.swift:265` | A project opened through a symlink gets no statuses, gutter marks or editor git actions (G-07, confirmed). |
| A6 | The diff viewer reads and writes the working tree as raw UTF-8 bytes, beside an editor that has its own encoding detection. It bypasses git's clean filters as well. | `IDEGitStatus.swift:885–893`, `IDEDiffSession.save` | Lossy re-encoding on save (G-05) and CRLF written into the index by hunk staging (G-04), both confirmed. |
| A7 | An "ignored pass" after every refresh runs `git status --ignored`. | `IDEGitStatus.swift:466–479` | 1.67 s per refresh on this checkout. `git ls-files -o -i --exclude-standard --directory` returns an identical set in 30 ms (G-12). |
| A8 | Window close or a root change cancels this window's running mutation, which kills git. | `setRoot` cancels `mutationTasks`, the lane's `onCancel` cancels the body, and SubprocessKit sends SIGTERM | A commit or rebase step can be interrupted (G-14; code reading, not reproduced). The comment on `GitRepositoryID` says other windows' mutations finish. This window's do not. |
| A9 | No trust boundary before git reads repository-local config. | No `fsmonitor`, `--no-ext-diff`, or trust check anywhere in `GitIntelligence` or `Umbra/Sources/Umbra/Git` | A crafted `.git/config` runs commands on the first automatic refresh (G-01, confirmed). |

## 5. Duplicated or overlapping state

- `statuses`, `changes`, `changeByPath`, `conflictedPaths`, `dirtyDirectories` and `workspaceSnapshot.entries` all derive from one status. They are rebuilt together in `apply`, so they do not drift today. `workspaceSnapshot.entries` and `changes` are two encodings of the same list (A2).
- `currentBranch` (from `symbolic-ref`, plus `rev-parse` when detached) and `repositoryState.head` (from the `HEAD` file) answer the same question from two sources in one refresh. That is one process per refresh, two when detached, that `state()` makes unnecessary: it already gives the branch, and `Head.detached` holds the hash.
- `sync` duplicates `branchInfos.first(where: \.isCurrent)`'s counts, plus lazily loaded commit lists. This is intentional and fine.

## 6. Unnecessary abstraction

None worth removing. `GitRunning` exists for test injection and was useful in this audit (probe 10 wraps it to slow `status`). `GitWorkspaceSnapshot` and `GitRefreshState` are used. The `GitRepository` extensions divide the work by topic and carry no hierarchy.

## 7. Recommendations (architecture only; findings in `GIT_INTEGRATION_FINAL_AUDIT.md`)

1. Replace `IDEGitFileStatus` derivation with a typed `GitPorcelainCode` (index and work tree, exhaustive) in `GitIntelligence`. Derive the sections from it in one pure function with a table test over every XY pair git documents. (G-02, A2)
2. Refresh policy: apply every completed snapshot whose load *started* after the last mutation fence. Re-run when dirty. Drop only results that started before a mutation. (G-06, A3)
3. Carry `HEAD`'s object id in `GitRepositoryState`, either by reading the ref file or from the status `branch.oid` header if the status moves to porcelain v2, and key the HEAD-blob cache on it. (G-03, A4)
4. Canonicalize once. `setRoot` resolves symlinks, or the model maps between the opened root and git's top level, in one place. (G-07, A5)
5. Make the diff viewer's working-tree side go through the same `TextFileEncoding` load and save path as editor tabs. Build staged hunks in git's index form, with clean and EOL conversion, for example from `git diff` output rather than raw disk bytes. (G-04, G-05, A6)
6. Add a git trust gate, or at least `-c core.fsmonitor=false` and `--no-ext-diff`/`--no-textconv` on automatic reads, until the user trusts the folder. (G-01, A9)
7. Let a started mutation finish when its window closes (detach it from the window's task), as the lane comment already promises for other windows. (G-14, A8)
8. Do not split `IDEGitStatusModel` for its own sake. If it changes, the useful seam is pulling the refresh pipeline (`beginRefresh`, `applyLoaded`, the epoch and token state) into a small type that can be tested alone, since that is where the confirmed concurrency defects are.

# 03 — State synchronization and Swift concurrency

Date: 2026-11-22, commit `afc43b7f`. Evidence labels as in `02_CORRECTNESS_AND_DIFF.md`.

## 1. Edit → UI sequence

| Step | What happens | Where |
|---|---|---|
| 1. Edit in the editor | The gutter shifts spans at once and schedules a diff 400 ms after the pause, against the cached `HEAD` blob. No git process runs. | `IDEWorkspace+TextViewDelegate.swift:34`, `IDEChangeMarkerController.refresh` |
| 2. Save | Write to disk. The FSEvents stream sees the file. | Saving pipeline |
| 3. Detection | `IDEProjectWatcher.record` → `pending.paths`, coalesced for 150 ms, then the batch | `IDEProjectWatcher.swift:163–186` |
| 4. Status | `gitStatus.refresh(invalidating: batch.paths)` → epoch += 1 → one `loadSnapshot` off main: `status --porcelain=v1 -z`, `symbolic-ref`, `for-each-ref` (branches with ahead and behind), the `HEAD` file read, then `parse` | `IDEWorkspace.swift:5091`, `IDEGitStatus.swift:262–349`, `:1124–1155` |
| 5. Diff info | `applyLoaded` → `onRefreshed` → diff tabs whose paths changed reload; every visible editor's gutter re-diffs (`force: true, delay: .zero`); the HEAD cache is flushed only if `headMoved` | `IDEWorkspace.swift:331–343` |
| 6. UI | `@Observable` properties are written only when they differ (`apply`) | `IDEGitStatus.swift:840–856` |
| 7. Ignored pass | `status --ignored` after every applied refresh, dropped if the epoch moved | `IDEGitStatus.swift:466–479` |

External changes (terminal, another tool) take the same path: a working-tree write reaches step 3. `.git/index` and `HEAD` writes set `gitMetadataChanged`. `refs/**`, `packed-refs`, `ORIG_HEAD` and `FETCH_HEAD` set `gitRefsChanged` (the log reloads). `MERGE_HEAD`, `rebase-*/` and `sequencer/` set `gitOperationChanged` (the banner). A git directory outside the project (a worktree, a submodule, a project inside a larger repository) is added to the stream (`setGitDirectory`). Coverage: `IDEProjectWatcherTests`, `testAnExternalGitDirectoryReportsHeadAndSkipsObjects` (cited in the earlier audit; it ran in that pass, not this one).

Other triggers: `NSApplication.didBecomeActiveNotification` (refresh plus a log and authors reload), the end of every `runGitAction`, manual refresh, `setRoot`.

**Gaps in detection**

- Paths under `IDEProjectModel.ignoredDirectoryNames` (`node_modules`, `.build`, …) never reach git refresh. A *tracked* file inside such a folder that changes externally is not picked up until another trigger. [code]
- A repository whose top level is above the project folder: files changed outside the project folder are not watched, but `git status` lists them. They show up only on the next trigger. [code]

## 2. Concurrency model

| Mechanism | Implementation | Assessment |
|---|---|---|
| Isolation | `IDEGitStatusModel` is `@MainActor`. Git work runs in `nonisolated static` functions called from `Task {}`, so it hops off main. `GitRepository` is a `Sendable` value. | ✔ No main-thread git. |
| One status in flight | `refreshTask` and `refreshToken`. Another `refresh()` during a load sets `needsAnotherPass`. | ✔ Bounded: at most one load plus one queued. [probe-app] 8: 50 calls → 1 load applied, 3 dropped. |
| Generation | `refreshEpoch` is bumped by every `refresh()`, every mutation start (`invalidateForMutation`) and `setRoot`. A load applies only if the epoch is unchanged. | **Too strict**: see G-06 below. |
| Cancellation | `setRoot` cancels refresh, ignored pass, sync, history, detail and **mutation** tasks. A cancelled load restores the previous `refreshState`. | ✔ for reads. ✘ for mutations (G-14). |
| Mutations | `GitMutationLane.shared.perform(gitDirectory:)`: process-wide, FIFO per git directory, no nesting | ✔ `GitMutationLaneTests` (2) |
| Hunk staging | Lane plus a check of the index blob id | ✔ fence. ✘ the blob id is read late (G-11). |
| Network | `isNetworkBusy` counts. `runGitAction` puts **every** action, network included, through `GitMutationLane` (`IDEGitStatus.swift:1006`). A fetch or push therefore blocks Stage, Unstage and Commit for that repository, in every window, until it ends. That contradicts the `isNetworkBusy` doc comment and `Git/CLAUDE.md` ("local commands still go through meanwhile"). `SystemGitRunner` sets no timeout and there is no Cancel, so a stalled network command blocks local mutations indefinitely. | P2 (G-19) [code] |
| Stale async UI loads | History, commit detail, sync lists and blame check the task, root and selection before applying | ✔ [code] |

### Critical invariant: older results never overwrite newer state

Holds. Every status load captures the epoch, and `applyLoaded` runs only when `refreshEpoch == epoch`. Mutations bump the epoch inside the lane before they run, so a status that started before a commit cannot be applied after it. The diff session uses `loadGeneration` and `computeGeneration`. The gutter uses `contentGeneration`. History uses the task, the root and the file path.

The way it holds causes the next defect.

### G-06: status starves while watcher batches keep arriving

`beginRefresh` drops a finished load if *any* `refresh()` arrived during it (`superseded = refreshEpoch != epoch`). It then starts another load, which is dropped the same way if another batch arrives. While batches arrive at least once per status duration, the panel, Explorer tints, gutter refresh and diff reloads all freeze at the last snapshot.

- [probe-app] 10: `status` slowed to 400 ms (a stand-in for a large repository), `refresh()` every 150 ms for 4 s → **0 snapshots applied, 25 dropped**. The change appeared only after the calls stopped.
- Real numbers (`04_PERFORMANCE.md`): the refresh command set takes 150 ms at 50k tracked files and 271 ms at 100k, against a 150 ms watcher cadence. A code generator, `npm install` into a non-ignored folder, or a checkout touching many files can keep the window frozen while it runs.
- Dropping is unnecessary for ordering. Loads never overlap, so a finished load is newer than everything already applied. Only a mutation that began *after* the load started can make it stale. Fix: keep a separate `mutationFence` epoch. Apply when `epoch >= mutationFence`, then run the queued pass.

### G-14: closing a window kills a running mutation

`setRoot(nil)` (teardown, Close Folder, Replace Project) cancels `mutationTasks`. The lane's `withTaskCancellationHandler` cancels the body task. `SubprocessRunner` sends SIGTERM to git, then SIGKILL after 2 s. A commit (with hooks), a pull or a rebase step can be interrupted part-way. Git cleans its lock files on SIGTERM. After SIGKILL, `index.lock` can remain (not reproduced, here or in the earlier audit). [code]
Fix: detach mutations from the window lifetime. Let the lane task finish and drop its UI callbacks.

### Mutations running beside reads

Reads take no lock (`--no-optional-locks`). A status that runs *during* a mutation (started by a watcher batch after `invalidateForMutation`) can show an intermediate index. The refresh that `runGitAction` starts afterwards replaces it, so this is a transient flash, not a stale end state. [code]

## 3. Event scenarios

| Scenario | Behaviour | Evidence |
|---|---|---|
| Rapid file modifications | Coalesced 150 ms, at most one load plus one queued. **Can starve** (G-06). | [probe-app] 8, 10 |
| Repeated staging | Each action waits its turn in the lane. Each ends with `refresh()`. | [code], `GitMutationLaneTests` |
| Branch switch outside Umbra | The `HEAD` write gives `gitRefsChanged` → log reload and status. `headMoved` is true (the branch name changed) → HEAD cache flushed. | [code] |
| External commit on the current branch | Refs changed → log reload and status. **`headMoved` false → gutter stale.** | G-03 [probe-app] 9 |
| Git in Umbra's terminal | Same as external | [code] |
| Switching repositories (Replace Project) | `setRoot` cancels everything, bumps the epoch, clears state, unregisters askpass | [code], `IDEGitRefreshTests` |
| Closing a window during a git operation | Reads are cancelled (fine). **Mutations are killed** (G-14). | [code] |
| Repository deleted while open | The next status fails → `.failed(last:)`, then discovery says not-a-repo → `.unavailable` | [code], `IDEGitRefreshTests.testAMissingRepositoryStaysUnavailable` |
| Two windows, same repository | Separate models and one lane. Each refreshes on its own watcher. Duplicate status runs (one per window). | [code] |
| App activation | Every window refreshes and reloads its log and authors (`log --all -n 300`, `branches`, `log --all -n 5000 --format=%an`). Cheap on this repository (13 + 15 ms). Cost grows with history width, not file count. | [cli] |

## 4. Task and priority notes

- `Task {}` from the main actor inherits user-initiated priority. Background fetch is opt-in (off at 0).
- The ignored pass and `fillSyncCommitsIfNeeded` are cancelled and replaced on each refresh (bounded).
- `IDEGitStatusModel.init` adds a `NotificationCenter` block observer that is never removed. The closure holds `self` weakly, so the cost is one leaked observer token per window opened. P3 (G-22).
- `RevertOutcome` uses a lock to carry results across the `@Sendable` boundary. That is correct.

## 5. Verdict

Ordering is correct: no older result overwrote a newer one in any probe or test. Liveness is not: G-06 can freeze git state during sustained file activity, and G-03 leaves the gutter stale after any same-branch commit. Cancellation is right for reads and wrong for mutations (G-14). The fixes are local to `beginRefresh` and `applyLoaded`, `GitRepositoryState`, and `setRoot`.

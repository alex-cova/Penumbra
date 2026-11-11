# Umbra Git backend test strategy

Date: 2026-11-11. Companion to `GIT_BACKEND_AUDIT.md`.

The suites below were read, not executed, for this audit. Running them needs a live display (`caffeinate -u -d -i -s swift test` for the library package, and the same with `--package-path Umbra` for the app). A failure that appears only after the machine sleeps is the display policy in `CLAUDE.md`, not a Git result.

Every confirmed P1 gets a regression test before the fix is called done. The tests use a temporary repository and real `/usr/bin/git`. They must not touch the developer’s checkout.

## Implementation status (2026-11-11)

The tests named in `GIT_BACKEND_AUDIT.md` under “Tests that were run” were executed and passed. That includes literal pathspecs, hunk blob checks, refresh failure, cancellation, epoch ordering, the hot status omitting `--ignored`, dirty-buffer refusal, and the mutation lane. `testAnExternalGitDirectoryReportsHeadAndSkipsObjects` passed on this host (0.314s). It still skips when a host delivers no FSEvents. The full Umbra suite was not run.

## 1. Existing coverage

Pattern: create a temp directory, `git init`, set `user.name`, `user.email`, and `commit.gpgsign=false`, skip when `/usr/bin/git` is missing, delete the directory in teardown.

### Library (`Tests/PenumbraTests`)

| File | What it actually exercises |
|---|---|
| `GitRepositoryIntegrationTests` | Commit, log, blame with unsaved bytes passed in, `--only` leaving other files, untracked diff, stage/unstage, `visibleFiles` inside a nested folder, push/pull against a local bare remote, switch refusal, revert including rename and glob characters, `fileContents` for `HEAD` / index / commit, `applyPatch` of one hunk on disk |
| `GitOperationsIntegrationTests` | Merge and rebase complete, stop, resolve ours/theirs, modify/delete, abort, continue, skip |
| `GitHistoryIntegrationTests` | Cherry-pick, revert, reset modes, undo, amend message leaving the index out, line history, interactive rebase plans, conflict during rebase, commit checks, sign-off, skipped hooks, CRLF renormalize |
| `GitRemoteIntegrationTests` | Fetch prune, pull merge/rebase/ff-only, autostash, force-with-lease, tags, branch rename/delete, detached checkout, smart checkout, failed operation restores the stash |
| `GitStashIntegrationTests` | Push, pop, apply, keep index, drop by hash rather than by a stale index, conflicts |
| `GitRepositoryStateTests` | Branch, detached, merge, rebase step, cherry-pick, revert, abort, linked worktree Git dir, missing directory |
| `GitParsersTests` | Status rename order (synthetic, matches Git 2.54 `-z`), log, name-status, blame, progress, branch and tag parsers |
| `SystemGitRunnerTests` | Stdin, non-zero exit, environment, `core.quotepath`, large stdout with stderr open, cancel, observer, progress |
| `GitCloneIntegrationTests` | Clone, refuse bad URL and non-empty destination, init, ignore patterns |
| `GitRebasePlanTests` | Todo text, shell quoting, validation, squash and fixup builders |
| `GitGraphLayoutTests`, `GitGraphDiagramTests` | Graph lanes and diagram drawing. Not repository behavior. |

`Packages/GitIntelligence/Tests` only contains `GitWorktreeTests` (list/add/remove porcelain). The rest of the package is tested from the root package because `GitIntelligence` is also a root target.

### App (`Umbra/Tests/UmbraTests`)

| File | What it drives |
|---|---|
| `IDEGitStatusOperationsTests` | Model merge, rebase, conflict resolve, banner state, against a temp repo |
| `IDEGitStatusHistoryActionsTests`, `IDEGitStatusModelHistoryTests` | Log actions, file history, revert through the model |
| `IDEGitStatusRemoteTests` | Fetch, pull, push, branch checkout through the model, local bare remote |
| `IDEGitCommitChecksTests`, commit flow tests | Blocking conflicts and identity, warnings, amend, template |
| Stash, askpass, clone, hosting URL tests | Those surfaces, real Git where the operation needs it |
| `IDEDiffTabTests`, `IDEDiffComputerTests`, `IDEDiffPatchBuilderTests` | Viewer hunks and patch text. Patch apply against Git is the library test, not these. |
| `IDEMergeComputerTests` | Diff3 versus `git merge-file` on random edits |
| `IDEAgentGitToolsTests`, parts of `IDEAgentNavigationTests` | Agent status and diff, including unsaved buffer text passed in, secret paths |

`GitRunning` is the seam. Production uses `SystemGitRunner`. Tests that need a failure should pass a fake runner. Tests that claim index bytes should use real Git.

## 2. Missing scenarios

Regression order matches the audit. Each row is required for the finding it names.

| # | Scenario | Finding | Layer |
|---|---|---|---|
| 1 | `stage(["star*.txt"])` does not stage `starX.txt`. Same for `unstage` and `commit(paths:)` | F1 | Integration |
| 2 | After a good snapshot, a failing `status` leaves `currentBranch` and sets an error | F3 | Model, fake runner |
| 3 | Project subdirectory: a commit in the parent is invisible until the Git directory is watched, then visible without `didBecomeActive` | F2 | Integration |
| 4 | Linked worktree: index lives outside the work tree; staging updates the model only after that Git dir is watched | F2 | Integration |
| 5 | Hunk apply: index blob matches the staged hunk and not the unstaged lines. Dirty buffer does not change `:path` | F4 | Integration |
| 6 | Two overlapping commits: both finish, `index.lock` is absent, `git ls-files -s` matches | F7 | Concurrency |
| 7 | A status load started before a commit does not `apply` over the post-commit snapshot | F7 | Model |
| 8 | Cancelled status task does not `apply` | F7 | Model |
| 9 | Newline in a filename on `stage`. Space and non-ASCII already exist for `revert` | F1 | Integration |
| 10 | `status` with and without `--ignored` on a fixture with a large ignored directory. Record time and process count. Wide ceiling if it is in CI | F5 | Benchmark |

Also missing, not tied to a P1, and not required for the first repair:

- Bare repo: `discover` returns nil. Small, worth one test.
- Submodule: status shows `M` for a gitlink change. No update command to test until one exists.
- Two `IDEGitStatusModel`s on one `gitDirectory` sharing a lane. After phase 4.
- Hook that fails a commit: covered in spirit by skip-hooks tests; a hook that exits non-zero should be explicit if it is not already.
- `preservingLocalChanges` when the operation throws and `stash pop` also throws. Today the pop error is discarded. Test the message the caller sees once that path is defined.
- Worktree watcher and submodule watcher are the F2 rows above. Do not add a third framework test.

## 3. Fixture

The suites already build repos inline. Extract a helper only when phase 1’s tests need the same skeleton in more than one file.

Proposed helper, copied per test target. `PenumbraTests` and `UmbraTests` cannot share one target. Put the library copy next to the Git tests and the app copy under `Umbra/Tests/UmbraTests/Support` only if an Umbra test needs it.

```text
GitFixture.make() -> temp root
  init -b main, identity, gpgsign false
  commit("a.txt", "base\n", message: "base")
  optional: branch "feature"
  optional: stage a one-line edit while leaving another line unstaged
  optional: diverged branch and a conflicted merge
  optional: linked worktree via `git worktree add`
  teardown: remove the temp directory and the worktree
```

The helper shells out only through `SystemGitRunner` or `git` argv in the test, never `Foundation.Process`. It writes under `FileManager.default.temporaryDirectory` with a UUID. It does not use the Penumbra repo.

Assert index contents with `git ls-files -s` or `git rev-parse :path` and `git cat-file blob`, not with “the function returned.”

## 4. Isolation

- One temp directory per test. No shared repo.
- `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE` unset in the child environment the test controls. `SystemGitRunner` inherits the process environment when the caller passes nil. Tests that mutate config should set identity inside the repo, as they do today, not in the user global file.
- Do not set `user.name` globally.
- Skip with `XCTSkipUnless` when `/usr/bin/git` is missing, as `GitRepositoryStateTests` does.
- Askpass tests must not open a real network prompt. Use the local bare remote or the fake socket the askpass tests already use.
- No test depends on the order of other tests.

## 5. How the layers divide

| Layer | Belongs here | Does not |
|---|---|---|
| Unit | Parsers, `GitRebasePlan`, `GitRepositoryState.read` on a directory the test wrote, `IDEGitCommitChecks.evaluate`, `IDEDiffPatchBuilder` text | `git status` |
| Integration | Any claim about the index, a branch, a hook, a worktree, or a conflict. Real Git. | SwiftUI |
| Model | `IDEGitStatusModel` against a temp repo or a fake `GitRunning` | Pixel output |
| Concurrency | Two tasks, one repo, then `ls-files -s` | Sleeps as the only synchronization. Use the generation or the lane’s completion. |
| Benchmark | F5 timing, process count per refresh | A 100ms assertion on a loaded CI machine |
| End to end | Existing Umbra tests that open a workspace and call the model | A new UI snapshot suite for this audit |

Parser tests may keep synthetic strings. `GitParsersTests.testStatusParsesRenameOriginAndUntracked` matches the `-z` order measured on Git 2.54. If a future Git changes that order, add a real `git status -z` sample next to the synthetic test so the drift is obvious.

## 6. Concurrency tests

Phase 4 acceptance, in `GitRepositoryIntegrationTests` or a new file in the same target:

1. Start two `commit` tasks on one repo with different files already staged in sequence, or stage inside the call if the lane allows it. Wait for both. Assert one `index.lock` is not left behind. Assert `git ls-files -s` and `git log -2 --format=%s`.
2. Start `status` (slow fake runner that waits) and a real `commit`. Release the status after the commit. Assert the model’s generation check drops the pre-commit entries.
3. Cancel a `refresh` task while `status` is in flight. Assert `changes` is unchanged (`SystemGitRunnerTests` already shows cancel ends the process).

Do not SIGKILL a real `git commit` in CI to look for a stuck lock. That is flaky and dirties the assertion. The lane test is the one that must pass. The lock-file risk stays a code comment until someone reproduces it.

## 7. Performance

Not part of the correctness suite.

- Record, on a dev machine, `git status --porcelain=v1 -z --untracked-files=normal` and the same with `--ignored`, in the Penumbra checkout and in a fixture that contains an ignored directory of many small files (create it under `/tmp`, do not point it at `~/Library`).
- The 2026-11-11 sample on this checkout was 0.05s and 0 bytes without `--ignored`, 5.14s and 861 bytes with it, Apple Git 2.54. One sample. Re-measure after phase 6 and replace that sentence if the numbers move.
- A `GitRunning` observer in a model test can count invocations per `refresh`. Assert the default refresh’s status arguments do not contain `--ignored` once phase 6 lands. That assertion is exact and cheap. The wall-clock number is not an XCTest failure unless it exceeds a ceiling generous enough for CI (several seconds even for the fast command).

`PerfHarness` is the editor’s enter-latency tool. Do not bolt Git status onto it unless a later change wants a single `swift run` entry. A small test or a script under `Tools/` is enough.

## 8. Regression priority

| When | Test |
|---|---|
| With phase 1 | Row 1 and row 9 |
| With phase 2 | Row 2 |
| With phase 3 | Rows 3 and 4 |
| With phase 4 | Rows 6, 7, and 8 |
| With phase 5 | Row 5 |
| With phase 6 | Row 10’s argument assertion; timing recorded by hand |

A phase does not close with a green run of an unrelated suite alone. The row for that phase has to exist and pass.

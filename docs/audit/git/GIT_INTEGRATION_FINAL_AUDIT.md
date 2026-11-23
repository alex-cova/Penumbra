# Umbra Git integration — final audit

Date: 2026-11-22. Commit `afc43b7f` (main, clean). Apple Git 2.54.0 (Apple Git-157), macOS 27.2.1, Apple M5 Max, 64 GB.

Detail reports: `01_ARCHITECTURE_AUDIT.md`, `02_CORRECTNESS_AND_DIFF.md`, `03_STATE_AND_CONCURRENCY.md`, `04_PERFORMANCE.md`, `05_UX_REVIEW.md`, `06_FEATURE_GAPS.md`, `07_TEST_COVERAGE.md`, `08_SECURITY.md`. The earlier audit set in this folder (2026-11-11/17) is referenced where its fixes changed behaviour.

Audit conduct: no production code, test or document in this checkout was changed other than the nine `0x_*.md` and this file. No commits. The repository's index and working tree were not touched (`git status` clean before and after). Probes ran in a scratch package and in a scratch `git clone --local` copy. Read-only measurements on this checkout used `--no-optional-locks`.

## 1. Executive summary

Umbra's Git integration is broad (IntelliJ-class: conflicts, a merge tool, editor-free interactive rebase, stash, compare, line history, commit checks, askpass) and built on a sound base. Git runs off the main thread through argument arrays with literal pathspecs. Mutations are serialized per git directory across windows. Refresh results are generation-stamped, and no older result overwrote a newer one in any test or probe. All 461 existing Git-related tests pass.

The audit nevertheless **confirmed 12 defects by execution** that those tests do not catch: 9 through the real Umbra code (probes A1–A10), plus G-01, G-15 and G-16 at the git and library level. G-11's git behaviour was confirmed too, though its race window comes from code reading. G-12 was measured.

The main ones:

- one P0 security issue: a crafted `.git/config` runs commands when the folder is opened;
- one P0 data-integrity issue: the diff viewer's save re-encodes non-UTF-8 files;
- four P1 correctness issues: untracked files listed as staged; the gutter goes stale after a commit; hunk staging corrupts index line endings under autocrlf; projects opened through a symlink lose all git state;
- several P2s: status starvation under file churn, hunk staging failing for paths with spaces, unstage failing in a new repository, half-done rename unstage, and a 1.67 s ignored pass after every refresh on this very checkout.

Two of the P1/P2 defects are regressions introduced by fixes from the previous audit (F6 → G-03, F7 → G-06). A third was "verified" there by a test that never ran git (G-08).

## 2. Production readiness

**Requires targeted fixes.**

The defects are concentrated and local: about eight functions across `IDEGitStatus.swift`, `IDEDiffSession.swift`, `IDEDiffPatchBuilder.swift`, `GitRepository.swift` and the runner arguments. None needs an architectural rewrite. Until G-01, G-05, G-02, G-03 and G-04 are fixed, Umbra's status display and partial staging cannot be fully trusted, and opening untrusted folders is unsafe.

## 3. Findings (severity-ranked)

Evidence labels: **[probe-app]** XCTest against the real Umbra types in a scratch clone; **[probe-lib]** real `GitIntelligence` in a scratch package; **[cli]** git in a scratch repository; **[code]** reading only; **[test]** an existing test. Probe IDs refer to `07_TEST_COVERAGE.md` § 2.

---

### G-01 · P0 · Security — repository-local config executes commands on folder open
- **Files**: `GitRepository.status`/`readOnly` (`Packages/GitIntelligence/Sources/GitIntelligence/GitRepository.swift:165, 224`), `unstagedDiff`/`stagedDiff`/`workingTreeDiff`/`commitDiff` (`:339–382`), `IDEGitStatusModel.setRoot`/`refresh`.
- **Description**: Git honours `core.fsmonitor` and `diff.external` from `.git/config`. Umbra runs `status` automatically on open, save and activation, and `diff` for diff text, with no trust gate and no overrides.
- **Repro**: a scratch repository → `git config core.fsmonitor "touch /tmp/x; false #"` → run Umbra's exact status arguments → `/tmp/x` exists. The same with `diff.external` and `diff -- path`. Opening such a folder in Umbra runs the same command on the first refresh.
- **Expected**: no repository-defined program runs before the user trusts the folder. **Actual**: it runs at once.
- **Root cause**: proven. Git semantics plus no `-c core.fsmonitor=false` or `--no-ext-diff`, and no trust gate (`grep`).
- **Evidence**: C1 [cli]; `08_SECURITY.md` §2. Vector: archives, shared volumes. Not `git clone`.
- **Fix**: `-c core.fsmonitor=false` on automatic reads; `--no-ext-diff --no-textconv` on diff reads; a per-repository trust gate reusing Umbra's existing trust store. **Complexity**: S (flags), M (gate).
- **Regression test**: marker-writing `core.fsmonitor`; `setRoot`; assert no marker.
- **Fix status**: Fixed, not committed. `-c core.fsmonitor=false` on every command; `--no-ext-diff --no-textconv` on patch output and blame; while a repository is untrusted its filter commands are blanked (a second hole this work found: `git status` runs `filter.*.clean`); a per-repository trust gate asks before hooks, clean filters and other configured programs run on a user action (`confirmTrusted`, `git-trust.json`). Tests: `GitUntrustedConfigTests` (both), `GitExecutableExposureTests`, `IDEGitUntrustedConfigTests`, `IDEGitTrustGateTests`.

### G-05 · P0 · Data integrity — diff-viewer save corrupts non-UTF-8 files
- **Files**: `IDEGitStatusModel.diffContent`/`diffContent(of:)` (`IDEGitStatus.swift:885–893, 946–949`), `IDEDiffSession.save` (`Umbra/Sources/Umbra/Diff/IDEDiffSession.swift:314–333`).
- **Description**: the working-tree side is decoded with `String(decoding:as:UTF8)` (lossy). Saving writes `.utf8`. When the disk file does not decode as UTF-8, the "changed on disk" check is skipped ("nothing readable to lose") and the write proceeds.
- **Repro**: commit `café` in ISO-8859-1 (`63 61 66 E9`); change line 2; open the unstaged diff; type in the right side; leave the tab or press ⌘S.
- **Expected**: bytes preserved, or the save refused. **Actual**: `63 61 66 EF BF BD …`. Every non-UTF-8 byte in the file is replaced.
- **Root cause**: proven (probe A2).
- **Fix**: load and save the working-tree side through `TextFileEncoding` (the editor's detection, as tabs do), or make the side read-only when the bytes are not valid UTF-8. **Complexity**: S (read-only), M (encoding parity).
- **Regression test**: the Latin-1 round trip in `IDEDiffHunkSafetyTests`.
- **Fix status**: Fixed, not committed. A non-UTF-8 working-tree side is `lossyText`, read-only; `save()` refuses when the disk bytes are not UTF-8. Tests: `IDEDiffIntegrityTests.testANonUTF8WorkingTreeSideIsReadOnlyAndNeverRewritten`, `testSaveRefusesWhenTheFileOnDiskIsNotUTF8EvenIfTheSessionThoughtItWasText`.

### G-02 · P1 · Status — untracked files appear under Staged Changes
- **Files**: `IDEGitStatusModel.statusFromIndexChar` (`IDEGitStatus.swift:1269–1277`), `IDEGitChangeRows.listed`, `IDEChangesFileList.stagedChanges`, `IDEChangesPanel.swift:18`, `IDEGitStatus+Commit.swift:22`.
- **Repro**: commit a file; create `fresh.txt`; open Changes.
- **Expected**: `fresh.txt` once, under Unstaged, as Untracked. **Actual**: `staged = .modified`, rows `[staged, unstaged]`. The Staged count is inflated. Unstage on that row fails. Commit is enabled and its "nothing staged" guard passes with only untracked files.
- **Root cause**: proven. `default: return .modified` catches `?`.
- **Fix**: return nil for `?` and `!`. Better, a typed porcelain code with an exhaustive switch (`01` A2). **Complexity**: S.
- **Regression test**: the untracked-section test in `07` §4 plus a table test over every XY.
- **Fix status**: Fixed, not committed. Explicit letter mapping; `?`/`!` have no staged side. Tests: `IDEGitStatusCorrectnessTests.testUntrackedFilesAreNotStaged`, `testEveryPorcelainPairMapsToTheRightSides`, `testCommitWithOnlyUntrackedFilesFailsWithoutRunningGit`.

### G-03 · P1 · Gutter — change markers stay stale after a commit on the same branch
- **Files**: `IDEGitStatusModel.applyLoaded` (`IDEGitStatus.swift:386`: `headChanged = state.head != repositoryState.head`), `IDEWorkspace.swift:339–341`, `IDEChangeMarkerController.headCache`.
- **Repro**: edit and commit (in Umbra or a terminal) on `main`; look at the editor gutter.
- **Expected**: the marks clear. **Actual**: `headMoved == false` (probe A9), so the cached pre-commit blob stays. Committed lines stay marked until a branch switch or LRU eviction. "Rollback Change at Caret" reads HEAD fresh, so it disagrees with the stripe.
- **Root cause**: proven. `Head.branch("main")` equals itself across commits. Introduced by the previous audit's F6 fix.
- **Fix**: compare HEAD's object id (read the ref file, or the porcelain v2 `branch.oid` header) and key the cache on it. **Complexity**: S.
- **Regression test**: same-branch commit → assert the cache was invalidated.
- **Fix status**: Fixed, not committed. Snapshot carries HEAD's commit id; `headMoved` compares it. Tests: `IDEGitRefreshLivenessTests.testACommitOnTheSameBranchMovesHeadAndFlushesTheGutterCache`.

### G-04 · P1 · Data integrity — hunk staging writes CRLF into an LF index
- **Files**: `IDEDiffSession.applyToIndex`, `IDEDiffPatchBuilder.patch`, `GitRepository.applyHunk` / `applyPatch` (`apply --cached`).
- **Repro**: `core.autocrlf=true` (or `* text eol=crlf`); CRLF working tree; edit one line; stage that hunk.
- **Expected**: the index stays `i/lf`, as `git add -p` would leave it. **Actual**: `i/mixed`, and the next commit contains a CRLF line (probe A4, [cli]).
- **Root cause**: proven. "+" lines come from raw disk bytes, and `git apply --cached` performs no clean or EOL conversion.
- **Fix**: build stage patches from git's view (`git diff -U0 -- path` output, which applies the clean filter and EOL conversion), or convert the "+" lines to the index's EOL (`ls-files --eol`) before applying. Refuse when a non-EOL filter (`filter=`) applies. **Complexity**: M.
- **Regression test**: the autocrlf test in `07` §4.
- **Fix status**: Fixed, not committed. `applyHunk` swaps the lines into the index blob and hashes with `hash-object --path` (no `git apply`). Tests: `IDEDiffIntegrityTests.testStagingAHunkOfACRLFWorkingTreeFileKeepsAnLFIndexUnderAutocrlf`, `testStagingAHunkUnderAnEolCrlfAttributeKeepsAnLFIndex`, `GitHunkBlobTests`.

### G-07 · P1 · Discovery — a project opened through a symlink has no git state
- **Files**: `IDEWindowRegistry.swift:265` (passes the unresolved `item.url`), `IDEGitStatusModel.parse` (keys from `--show-toplevel`, resolved), `relativePath(for:)`.
- **Repro**: `ln -s ~/real/repo ~/link`; open `~/link`.
- **Expected**: statuses, gutter and editor actions. **Actual**: `status(for:)` nil, `repositoryRelativePath` nil (probe A7). The Explorer is untinted, the gutter hidden, Rollback and blame unavailable. The Changes list still lists rows, under the resolved paths.
- **Fix**: resolve symlinks when the project opens (the router already normalizes for comparison), or map git's top level back into the opened spelling in one place. **Complexity**: S–M.
- **Regression test**: `setRoot(link)` → status by the link path.
- **Fix status**: Fixed, not committed (decision: resolve at open). `applyProjectRoot` resolves symlinks. Tests: `IDEGitSymlinkRootTests`.

### G-06 · P2 · Concurrency — status never publishes while watcher batches keep arriving
- **Files**: `IDEGitStatusModel.beginRefresh` (`IDEGitStatus.swift:319–333`).
- **Repro**: probe A10. Status takes 400 ms and `refresh()` is called every 150 ms for 4 s → **0 snapshots applied, 25 dropped**. Real status takes 150 ms (50k files) to 271 ms (100k) for the refresh set, so a code generator or install writing files keeps the panel, tints and gutter frozen.
- **Root cause**: proven. A finished load is dropped whenever any refresh request arrived during it, although loads never overlap and are therefore never older than what is already applied. Introduced by the previous audit's F7 fix.
- **Fix**: separate a mutation fence from request epochs. Apply loads that started after the fence, then run the queued pass. **Complexity**: S.
- **Regression test**: the liveness test in `07` §4.
- **Fix status**: Fixed, not committed. `mutationEpoch` separates "a mutation started" from "a refresh was requested". Test: `IDEGitRefreshLivenessTests.testStatusPublishesWhileRefreshRequestsKeepArriving`.

### G-08 · P2 · Partial staging — hunk staging fails for paths with a space or tab
- **Files**: `IDEDiffPatchBuilder.headerPath`/`patch` (`IDEDiffPatchBuilder.swift:27, 39–45`).
- **Repro**: stage a hunk of `my file.txt`. **Actual**: `error: "my file.txt": does not exist in index` (probe A3). **Expected**: staged. Git's form is `"a/my file.txt"`, not `a/"my file.txt"`.
- **Fix**: emit git's c-quoted form: quote the whole `a/…`/`b/…` token and escape `\t`, `"`, `\` and newline. This also removes the need to reject those characters. **Complexity**: S.
- **Regression test**: apply the generated patch with git (extend `testPatchesApplyWithGit` with spaced, tabbed and quoted names). Replace the string-only assertion.
- **Fix status**: Fixed, not committed. Test: `IDEDiffPatchBuilderTests.testAHunkOfAFileWithASpaceOrATabInItsNameStagesThroughTheModel` (the one authorized rewrite) and `IDEDiffIntegrityTests.testHunksOfFilesWithASpaceOrATabInTheNameStage`.

### G-09 · P2 · Index — Unstage and Unstage All fail before the first commit
- **Files**: `GitRepository.unstage`/`unstageAll` (`restore --staged`).
- **Repro**: `git init`; `git add a`; Unstage → `fatal: could not resolve 'HEAD'` (probes L4, A6).
- **Fix**: when `HEAD` is unborn, use `rm --cached -q -- <paths>` (and `rm -r --cached .` for all). **Complexity**: S.
- **Fix status**: Fixed, not committed. `rm --cached -f -r` on an unborn branch. Tests: `GitRepositoryIntegrationTests.testUnstageWorksBeforeTheFirstCommit`, `testUnstageAWorkTreeEditedFileBeforeTheFirstCommitKeepsTheEdit`, `testUnstageAllOfAnEmptyUnbornIndexIsNotAnError`.

### G-10 · P2 · Index — staged renames: unstage is half-done, discard impossible
- **Files**: `IDEGitStatusModel.unstage(paths:)`/`relativePaths` (relative path only), `GitRepository.revert`.
- **Repro**: `git mv old new`; Unstage → `D  old.txt` stays staged, `new.txt` untracked (probe A5). Discard → skipped "not in last commit" (probe L5).
- **Fix**: include `originalPath` in unstage and revert path lists for `R`/`C` rows; revert `old` from HEAD and remove `new` from the index (asking whether to delete it from disk). **Complexity**: S.
- **Fix status**: Fixed, not committed (decision: the discarded rename's new file stays on disk, untracked, and the confirmation says so). Tests: `IDEGitStatusCorrectnessTests.testUnstagingAStagedRenameUnstagesBothPaths`, `testDiscardingAStagedRenameRestoresTheOldFileAndKeepsTheNewOneUntracked`, `testTheDiscardConfirmationSaysTheRenamedFileStaysOnDisk`.

### G-11 · P2 · Partial staging — hunk base blob read after the texts (TOCTOU)
- **Files**: `IDEDiffSession.reload` (`IDEDiffSession.swift:199–203`).
- **Description**: the blob id the apply checks against is captured *after* both sides load. If the index changes in between, the check passes against a patch built from older text. With `--unidiff-zero`, a pure insertion carries no content to verify and is applied at a stale line ([cli] L6: `X` landed in the wrong place with no error).
- **Fix**: read the blob id first and load the index side *by that blob id* (`cat-file blob <id>`). **Complexity**: S.
- **Fix status**: Fixed, not committed. The blob id is read before the texts; the library re-checks it. Test: `IDEDiffIntegrityTests.testAnIndexChangeWhileTheDiffLoadsIsRefusedNotAppliedToTheWrongText`.

### G-12 · P2 · Performance — the ignored pass costs 1.67 s per refresh on this checkout
- **Files**: `IDEGitStatusModel.startIgnoredPass` (`IDEGitStatus.swift:466–479`).
- **Evidence**: `status --ignored` 1,671 ms against `ls-files -z --others --ignored --exclude-standard --directory` 30 ms, identical 38-entry set (diffed). It runs after every save, stage, watcher batch and activation (off main; CPU and disk).
- **Fix**: use the `ls-files` form. Optionally run it only when refs or `.gitignore` files change. **Complexity**: S.
- **Fix status**: Fixed, not committed. `GitRepository.ignoredPaths()` (`ls-files`), same set as `!!`. Tests: `GitRepositoryIntegrationTests.testIgnoredPathsAreTheSameSetAsStatusReports`, `IDEGitRefreshLivenessTests.testTheIgnoredPassNeverRunsStatusOverIgnoredFiles`. Re-measured here: 38 ignored entries from both; `status --ignored` 3.2-4.8 s (a release build was using the CPU) against `ls-files` 0.04-0.05 s.

### G-13 · P2 · Performance — large change sets: 1.2 s refresh, 83–148 ms main-actor stall
- **Evidence**: release-build probe. 10k changes → end-to-end about 1.2 s (git about 0.16 s, `parse` about 0.09 s, about 0.9 s **unattributed**). Largest main-actor gap 83 ms (50k repository) and 148 ms (100k). `parse` of 100k entries takes 1.19 s.
- **Fix**: profile first (Instruments). Likely costs: `localizedStandardCompare` sorting, O(n) `String.count` in the `markDirty` ancestor walk, and full dictionary rebuilds and comparisons in `apply`. **Complexity**: M.
- **Fix status**: Fixed, not committed. `markDirty` no longer bridges to `NSString` per ancestor and stops at an already-marked folder (`parse` 632 ms to 34 ms); `reconciled` returns early for an empty selection (main-actor gap 143 ms to 11 ms). Refresh at 100k files and 10k changes: 950 ms to 224 ms. Test: `IDEGitRefreshCostTests` (opt-in, `UMBRA_GIT_COST_REPO`; `UMBRA_GIT_COST_BUDGET=1` holds the budget). Numbers in `04_PERFORMANCE.md` §8.

### G-14 · P2 · Concurrency — closing a window kills a running mutation
- **Files**: `IDEGitStatusModel.setRoot` (cancels `mutationTasks`), `GitMutationLane.perform` (`onCancel` cancels the body), SubprocessKit (SIGTERM, then SIGKILL after 2 s).
- **Evidence**: [code]; not reproduced. A commit, pull or rebase step started in a window is interrupted when that window closes or its project is replaced.
- **Fix**: detach the lane body from the window task; drop only the UI callbacks. **Complexity**: S.
- **Fix status**: Fixed, not committed. The lane body runs in a detached task. Test: `IDEGitMutationLifetimeTests.testClosingTheWindowDoesNotKillARunningCommit`.

### G-19 · P2 · Concurrency/UX — network commands block local mutations, with no timeout or Cancel
- **Files**: `runGitAction` (`IDEGitStatus.swift:1006`, lane for every action), `SystemGitRunner` (no `timeout`).
- **Evidence**: [code]. Fetch and push share the per-repository lane with stage and commit, contrary to `Git/CLAUDE.md` ("local commands still go through meanwhile"). A stalled network command blocks Stage and Commit in every window on that repository.
- **Fix**: keep network commands out of the local lane (git's own `index.lock` arbitrates), add a Cancel, and add a generous timeout for batch-mode fetch. **Complexity**: S–M.
- **Fix status**: Fixed, not committed. Network actions take no lane, have `cancelNetworkActions()` and a Cancel button; `GitRunning.run(…, timeout:)` is used by background fetch (300 s). Tests: `IDEGitMutationLifetimeTests.testAStageFinishesWhileAFetchIsStillRunning`, `testCancellingTheNetworkActionStopsItAndNothingElse`, `SystemGitRunnerTests.testATimeLimitStopsAnyRunnerAndThrowsTimedOut`, `testATimeLimitEndsARealSlowGitCommand`.

### P3 findings
| ID | Finding | Evidence |
|---|---|---|
| G-15 | A bare repository or the `.git` folder opened as a project shows a failed refresh ("must be run in a work tree") instead of "not a repository". Treat that message as `.notARepository`. | [probe-lib] L3 |
| G-16 | A filename starting with a combining mark loses it (`Character` slicing in `GitStatusParser`). Slice on UTF-8 bytes. | [probe-lib] L1 |
| G-17 | Discard on an unstaged row also discards staged changes (stated in the dialog). Add "Discard Unstaged Changes" (`restore --worktree`) for unstaged rows. | [code] |
| G-18 | The gutter decodes the HEAD blob as UTF-8 while the buffer uses the file's encoding, so every non-ASCII line in a Latin-1 file is marked modified. | [code] |
| G-20 | A clone address with embedded credentials is shown in the in-memory Git console. Redact `user:pass@`. | [code] |
| G-21 | `IDEDiffText` treats a lone `\r` as a line break and git does not, so hunk line numbers drift in files with bare CR. Refuse hunk staging when the text contains a bare CR. | [code] |
| G-22 | One `NotificationCenter` observer per model is never removed. | [code] |
| G-23 | `currentBranch` duplicates `state()` (one process per refresh). `remotes()` repeats within loads. | [code] |

**P3 fix status.** G-15 fixed (`GitRepositoryIntegrationTests.testABareRepositoryAndADotGitFolderAreNotRepositories`). G-16 fixed (`GitParsersTests.testALeadingCombiningMarkSurvivesInAPath`, `testRenameRecordsStillPairWithTheirOldPathAfterTheByteParse`). G-21 fixed (`IDEDiffIntegrityTests.testAFileWithABareCarriageReturnIsNotStagedAsAHunk`). G-23 half fixed: `currentBranch` no longer costs a process per refresh (`IDEGitRefreshLivenessTests.testARefreshAsksGitForHeadOnce`); `remotes()` still repeats within loads. G-17, G-18, G-20 and G-22 were out of scope and are unchanged. None of this is committed.

## 4. Performance results

Medians, warm cache, release build (`04_PERFORMANCE.md`):

| | 100 | 5k | 50k | 100k |
|---|---:|---:|---:|---:|
| Hot status | 7.5 ms | 12.7 | 64.9 | 120.8 |
| Refresh command set | 33.8 | 45.9 | 149.6 | 270.9 |
| End-to-end model refresh, clean | — | 55 | 82 | 143 |
| End-to-end, 10k changes | — | 557 (5k changes) | 1,165 | 1,200 |
| Largest main-actor gap, 10k changes | — | 2.1 | 83 | 148 |

The wrapper adds no measurable overhead over raw git (120.8 against 123.9 ms; process floor 8 ms). There is no git work per keystroke. The bottlenecks, in order: the ignored pass (G-12, 1.67 s on this checkout), the large-change publish (G-13), and starvation under churn (G-06).

## 5. Architecture assessment

| Disposition | Components |
|---|---|
| **Preserve** | `SubprocessKit` boundary and `SystemGitRunner`; `GitRepository` as a stateless value; `GitMutationLane`; `GitRepositoryState` file reads; parsers (with the G-16 fix); stash-by-hash; `GitRebasePlan`; `IDEMergeComputer`; askpass design; the one-watcher model; `IDEDiffComputer`. |
| **Simplify** | Status vocabulary: replace `IDEGitFileStatus` derivation with a typed porcelain code (removes G-02's class). Drop the `currentBranch` process (use `state()`). |
| **Consolidate** | Path identity: one canonical root spelling shared by the model, the watcher and the editors (G-07). Working-tree text I/O: the diff viewer uses the editor's encoding path (G-05). |
| **Rework** | The refresh admission policy (G-06); HEAD identity for the gutter cache (G-03); hunk patch construction from git's index view (G-04, G-08, G-11); mutation lifetime against window lifetime (G-14); the network lane (G-19); a trust gate (G-01). |
| **Remove** | `status --ignored` as the ignored pass (replace it, G-12). Nothing else is demonstrably unnecessary. |

## 6. Test coverage matrix (summary; full matrix in `07` §4)

| Area | Verified | Missing | Unreliable |
|---|---|---|---|
| Parsing | porcelain v1, conflicts, log, blame, refs, worktrees | combining-mark names | — |
| Status model | partial staging, rename display, refresh failure, epoch ordering | untracked section, liveness, HEAD moved, symlink root, bare | — |
| Index operations | stage, discard, hunk (LF/ASCII), commit, conflicts | unborn HEAD, rename unstage, EOL filters, encodings | hunk path quoting test (asserts the broken form) |
| Concurrency | lane, epoch, read cancellation | starvation, mutation on close, network blocking | — |
| Security | literal paths, option refusal, askpass | repository-local config | — |

461 of 461 existing tests passed; 0 skipped. Probes confirmed 12 defects the suite does not cover (9 through Umbra's own types).

## 7. Competitive assessment

From each product's documented behaviour; not re-tested here.
- **Ahead** of VS Code, Zed and Xcode on interactive rebase without an editor, commit checks, line history, merge-tool fidelity, and smart checkout. On par with IntelliJ on most of these.
- **Comparable** on history, blame, branches, remotes, stash and conflicts.
- **Behind** on gutter peek and stage (VS Code, Zed, IntelliJ), line-level staging (VS Code, IntelliJ), workspace trust before running git (VS Code), and submodule and worktree UI.

## 8. Roadmap

### Phase A — Correctness and data protection
- **Items**: G-01 (flags first, then the gate), G-05, G-02, G-04, G-08, G-09, G-10, G-11, G-07.
- **Prerequisites**: none. Each is local.
- **Affected**: `GitRepository.swift` (read flags, unborn-HEAD unstage, rename paths), `IDEGitStatus.swift` (`statusFromIndexChar`, unstage and revert path lists), `IDEDiffSession.swift` (encoding, blob-id order), `IDEDiffPatchBuilder.swift` (quoting, EOL), `IDEWindowRegistry` or `setRoot` (symlinks).
- **Acceptance**: every regression test in `07` §4 for these IDs passes; probes A1–A7 and C1 pass as written.
- **Tests**: as listed per finding. Plus a table test over every porcelain XY, and an EOL/encoding fixture matrix (LF, CRLF, autocrlf true/input, `eol=crlf`, Latin-1, UTF-8 BOM).

### Phase B — State synchronization and concurrency
- **Items**: G-06, G-03, G-14, G-19.
- **Prerequisites**: none. G-03 benefits from moving status to porcelain v2 (`branch.oid` header), which is optional.
- **Affected**: `beginRefresh`/`invalidateForMutation`, `GitRepositoryState` (HEAD oid), `setRoot` mutation handling, `runGitAction` network path, `SystemGitRunner` timeout.
- **Acceptance**: probes A9 and A10 pass; a commit with a 2 s hook survives `setRoot(nil)`; a stage completes while a held fetch is pending.
- **Tests**: the liveness, HEAD-moved, mutation-on-close and network-blocking tests from `07` §4.

### Phase C — Performance and resources
- **Items**: G-12, G-13, G-23.
- **Prerequisites**: an Instruments profile of the 10k-change refresh before touching `parse` or `apply`.
- **Affected**: `startIgnoredPass`, `IDEGitStatusModel.parse`/`apply`, `loadSnapshot`.
- **Acceptance**: ignored pass under 50 ms on this checkout; a 10k-change refresh with a main-actor gap under 50 ms and end to end under 400 ms on the 100k fixture (M5 Max, release).
- **Tests**: a process-count observer test per refresh; an opt-in timed refresh test on a generated 50k fixture.

### Phase D — UX and workflow consistency
- **Items**: G-17 (Discard Unstaged), G-15, G-18, G-21, G-20; surface the ⌘S/⌘U list shortcuts; a "refreshing" indicator while a pass is queued.
- **Affected**: `IDEChangesFileList`, `IDEGitDiscardPrompt`, `discoverOutcome`, `IDEChangeMarkerPresentation`, `IDEGitCommandStore`.
- **Acceptance**: Discard from an unstaged row keeps the staged half when the user picks the new action; a bare repository shows the "not a repository" state.

### Phase E — Optional competitive features
- **Items**: a gutter hit target (peek, stage or rollback the hunk under the pointer); line-level staging in the diff viewer; worktree UI; submodule diff summary ("Submodule a → b").
- **Prerequisites**: Phase A's patch construction (G-04, G-08, G-11), which these reuse.
- **Acceptance**: gutter stage produces the same index as `git add -p` for the same hunk, checked with `git diff --cached` in tests.

## 9. Final verdict

1. **Can developers safely trust Umbra's Git status?** Mostly, not fully. Tracked-file status is accurate, and staged and unstaged stay independent. Untracked files are wrongly also shown as staged (G-02). Projects opened through symlinks show nothing (G-07). Under sustained file churn the display can freeze (G-06).
2. **Can they trust the staged and unstaged diffs?** The baselines (HEAD↔index, index↔worktree) are right. The *display* is right for UTF-8 files. Non-UTF-8 files display with replacement characters, and staging hunks is unsafe under EOL conversion (G-04) and fails for spaced paths (G-08). The gutter goes stale after commits (G-03).
3. **Can Git operations accidentally lose user changes?** Yes, in one confirmed path: saving the diff viewer's working-tree side of a non-UTF-8 file (G-05). Index line endings can be silently altered (G-04). Discard intentionally drops staged changes too, but it says so. Untracked files are never deleted. Unsaved editors are saved or warned about before every tree-rewriting operation.
4. **Does it stay correct when Git changes externally?** Yes for status, branches, operations and the log: the watcher covers the index, refs, HEAD and operation files, including an external git directory. Not for the gutter after an external commit on the same branch (G-03).
5. **Is the architecture appropriate for a long-lived native IDE?** Yes. The layering is clean, git sits behind a pure library, and mutations are serialized. The weaknesses are policies (refresh admission, HEAD identity, trust, path canonicalization, encoding parity), not structure.
6. **Is Git adding unnecessary latency to the editor?** Not to typing: there is no git work per keystroke. In the background, yes: a 1.67 s ignored pass per refresh on this checkout (G-12), and a 83–148 ms main-actor stall when refreshing 10k changes (G-13).
7. **Are concurrency and cancellation handled correctly?** Ordering, yes: no stale overwrite was observed and the epochs work. Liveness, no (G-06). Cancellation is right for reads and wrong for mutations on window close (G-14). Network commands block local mutations (G-19).
8. **Is the test suite sufficient?** No. It is good integration-style coverage of the happy path with real git, but it missed all 12 execution-confirmed defects, and one test asserts the broken patch format. Encoding and EOL fixtures, liveness, the HEAD-moved trigger, unborn-HEAD, symlink-root and trust tests are missing.
9. **Five highest-value improvements**:
   1. A git trust gate, or at least `core.fsmonitor=false` and `--no-ext-diff`/`--no-textconv` on automatic reads (G-01).
   2. Encoding- and EOL-correct working-tree handling in the diff viewer and hunk staging (G-05, G-04, with G-08 and G-11 in the same code).
   3. Fix the untracked→staged mapping with a typed porcelain code (G-02).
   4. Refresh liveness plus HEAD-oid identity for the gutter (G-06, G-03).
   5. Replace the ignored pass with `ls-files -o -i --directory` (G-12): a one-line change, 55× faster here.
10. **What should remain untouched?** `SubprocessKit` and `SystemGitRunner`; `GitMutationLane`; `GitRepositoryState`'s file-based reads; the porcelain, log, blame and worktree parsers; stash-by-hash; `GitRebasePlan` and editor-free interactive rebase; `IDEMergeComputer` and the merge tool; the askpass design; the one-watcher model with git-directory classification; the conflict section, banner and operation handling. These were verified by passing real-git tests and by this audit's probes.

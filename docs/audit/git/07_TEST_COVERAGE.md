# 07 — Automated test quality and coverage

Date: 2026-11-22, commit `afc43b7f`. No test or production file in this checkout was changed. Probes ran in a scratch package and in a scratch clone of this repository (`git clone --local`). The clone and the probes live only in the session scratchpad. They are not part of this repository. Section 2's descriptions are enough to rewrite them.

## 1. Executed

| Suite set | Command | Executed | Passed | Failed | Skipped |
|---|---|---:|---:|---:|---:|
| `GitIntelligence` package (Swift Testing: `GitMutationLaneTests`, `GitWorktreeParserTests`, worktree round trip) | `swift test --package-path Packages/GitIntelligence` | 6 | 6 | 0 | 0 |
| Root library, filter `Git\|SystemGitRunner` (15 XCTest suites¹) | `swift test --filter 'Git\|SystemGitRunner'` | 186 | 186 | 0 | 0 |
| Umbra, filter `IDEGit\|IDEChangeMarker\|IDEDiff\|IDEMerge\|IDESaveBefore\|IDEAgentWorktree\|IDEBlame\|IDEListKeyboard\|IDEAgentNavigation` (33 suites) | `swift test --package-path Umbra --filter …` | 269 | 269 | 0 | 0 |
| **Total existing** | | **461** | **461** | **0** | **0** |

¹ `GitCloneIntegrationTests`, `GitCommitChecksIntegrationTests`, `GitGraphDiagramTests`, `GitGraphLayoutTests`, `GitHistoryIntegrationTests`, `GitIgnoreLanguageTests`, `GitOperationsIntegrationTests`, `GitParsersTests`, `GitRebasePlanTests`, `GitRemoteIntegrationTests`, `GitRepositoryIntegrationTests`, `GitRepositoryStateTests`, `GitStashIntegrationTests`, `SystemGitRunnerTests`, and `LunaDiagramTests` (picked up by the filter; not git-related).

All runs used `caffeinate -u -d -i -s` with the display on. There were no environment-dependent failures, no flaky reruns and no skips. The full Umbra and root suites were **not** run, so unrelated failures elsewhere, if any, are not reported here.

**A green suite did not mean correct behaviour.** All 461 passed while the probes below confirmed 12 defects (9 through the real Umbra types).

## 2. Probes (audit-only, not committed)

| # | Probe | Kind | Outcome | Finding |
|---|---|---|---|---|
| L1 | Status of 16 states and unusual names vs porcelain v2 | lib | Parser correct; leading combining mark dropped | G-16 |
| L2 | AA, UU, UD, DU conflicts + `MERGE_HEAD` state | lib | Correct | — |
| L3 | Discovery: root, nested, `.git`, bare, symlink, worktree, non-git, nested repo | lib | `.git` and bare throw | G-15 |
| L4 | Empty repo: unstage, unstageAll, workingTreeDiff | lib | All fail (`could not resolve 'HEAD'`) | G-09 |
| L5 | Staged rename: revert, unstage | lib | Revert skips; unstage leaves `D old` | G-10 |
| L6 | `--unidiff-zero` insertion on a changed index | lib | Applied at the wrong place, no error | G-11 |
| L7 | `*`, `:(glob)*`, `-rf` as literal paths | lib | Correct | — |
| A1 | Untracked file sections | app | `staged = .modified`, rows `[staged, unstaged]` | **G-02** |
| A2 | Diff viewer save of a Latin-1 file | app | `E9` → `EF BF BD` | **G-05** |
| A3 | Hunk stage `my file.txt` | app | `error: "my file.txt": does not exist in index` | **G-08** |
| A4 | Hunk stage under `core.autocrlf=true` | app | `i/mixed` index | **G-04** |
| A5 | Unstage a staged rename through the model | app | `D  old.txt` + `?? new.txt` | **G-10** |
| A6 | Unstage before the first commit through the model | app | `fatal: could not resolve 'HEAD'` | **G-09** |
| A7 | Project opened through a symlink | app | `status(for:)` nil, `repositoryRelativePath` nil | **G-07** |
| A8 | 50 `refresh()` calls | app | 1 applied, 3 dropped (coalesces) | — |
| A9 | Commit on the same branch → `headMoved` | app | `false` | **G-03** |
| A10 | Slow status (400 ms) + refresh every 150 ms for 4 s | app | 0 applied, 25 dropped | **G-06** |
| P1–P2 | Parse cost and end-to-end refresh on 5k, 50k and 100k repositories | app, release | `04_PERFORMANCE.md` | G-13 |
| C1 | `core.fsmonitor` / `diff.external` in `.git/config` with Umbra's exact status, diff and ls-files arguments | cli | Commands executed | **G-01** |

## 3. How good are the existing tests?

**Strengths**
- Most library tests are **real-git integration tests** in temporary repositories (`git init` under the temp directory, `user.name` and `email` set, `commit.gpgsign=false`), not mocks. That includes the remote tests (a local bare remote), the stash tests, the operation tests (real conflicts), and the history tests (real interactive rebase).
- Model tests (`IDEGitRefreshTests`, `IDEGitRenameAndSelectionTests`, `IDEGitStatusOperationsTests`) drive `IDEGitStatusModel` against real repositories and wait on observable state.
- `IDEDiffPatchBuilderTests.testPatchesApplyWithGit` applies the generated patches with `git apply`. This is the right pattern.
- `IDEMergeComputerTests` checks against `git merge-file` on random edits.
- The concurrency primitives have direct tests (`GitMutationLaneTests`, `testAStaleStatusDoesNotReplaceANewerEpoch`, `testCancellingARefreshDoesNotPublishAFailure`).
- Isolation: each test uses a fresh UUID-named directory and deletes it in `tearDown`. Tests do not touch the developer's repository.

**Weaknesses**
- **Assertions that never ask git.** `testASpaceInThePathIsQuotedAndANewlineIsRejected` asserts that the patch *contains* `a/"my file.txt"`, a form git rejects (G-08). It locks in the bug.
- **Untracked rows are only checked on the unstaged side.** Several tests read `unstaged == .untracked`. None asserts `staged == nil` or the section list (G-02).
- **Liveness is untested.** The epoch tests prove an old result is dropped. No test checks that a result *is* eventually applied under continuous refresh requests (G-06).
- **No test of the HEAD-cache invalidation trigger** (G-03). The cache tests cover the LRU caps only.
- **No encoding or EOL-conversion fixtures** (autocrlf, `.gitattributes eol=`, Latin-1, a UTF-16 BOM) anywhere in the git or diff tests.
- **No empty-repository tests** for unstage or diff.
- **No symlinked-root tests.** The test setup calls `resolvingSymlinksInPath()` on the temp directory, which hides the class of bug in G-07.
- **No security tests** for repository-local configuration.
- Performance: one row-rebuild budget test (`IDEGitChangesListMeasurementTests`). No status or refresh process-count assertion, which the earlier strategy document proposed.

## 4. Verification matrix

✔ covered by a real-git test that passed · ◐ partial · ✘ missing · ✗ covered but asserts wrong behaviour

| Capability | Existing coverage | Gap | Required test (exact) |
|---|---|---|---|
| Staged + unstaged on one file | ✔ `testSelectionKeepsBothSectionsAndFollowsAStagedFile` | — | — |
| Untracked file section | ◐ unstaged only | ✘ staged side | `git init`; commit `a`; write `b`; model loads; assert `b.staged == nil` and `IDEGitChangeRows.listed` gives `[.unstaged]` for `b`. Table-test `parse` over every XY in `git help status`. |
| Renames and copies | ✔ parse, diff paths | ✘ unstage and discard of a rename | `git mv old new`; `model.unstage([new])`; assert porcelain is ` D old`/`?? new` → after the fix, a clean `old`. |
| Unmerged paths | ✔ `GitOperationsIntegrationTests` (+ L2) | — | — |
| Empty repository | ✘ | unstage, unstageAll, diff | `git init`; add `a`; `unstage([a])` succeeds and `a` becomes `??`. |
| Detached HEAD | ✔ `GitRepositoryStateTests` | — | — |
| Unusual names | ◐ spaces, non-ASCII, globs (`testPathsWithSpacesNonASCIIAndGlobCharactersAreLiteral`) | ✘ hunk with space; ✘ leading combining mark | Stage a hunk of `my file.txt` through `model.applyHunk` and assert `git diff --cached` shows it. Status of `"́x"` round-trips. |
| Concurrent refresh | ✔ epoch drop | ✘ liveness | `GitRunning` wrapper delays `status` 400 ms; `refresh()` every 150 ms for 3 s; assert at least one `onRefreshed` and the change visible during the burst. |
| External modifications | ✔ `IDEProjectWatcherTests`, external git dir | ✘ commit → gutter | Commit on the same branch externally; refresh; assert `headMoved` (or a HEAD oid change) and that `invalidateHeadCache` ran. |
| Cancellation during refresh | ✔ `testCancellingARefreshDoesNotPublishAFailure` | ✘ mutation on close | Start a commit with a `pre-commit` hook that sleeps 2 s; call `setRoot(nil)`; assert the commit exists afterwards (after the fix). |
| Large change sets | ◐ 2,000-row typing budget | ✘ refresh budget | 10,000 modified files; assert the largest main-actor gap is under 50 ms during refresh (`-c release`, `UMBRA_UI_TESTS`-style opt-in). |
| Linked worktrees | ✔ `GitRepositoryStateTests`, `GitWorktreeTests` | — | — |
| Hunk staging with EOL conversion | ✘ | ✘ | `core.autocrlf=true`; CRLF working tree; stage one hunk; assert `git ls-files --eol` starts with `i/lf`. Also with `.gitattributes "* text eol=crlf"`. |
| Non-UTF-8 text in the diff viewer | ✘ | ✘ | Latin-1 file; edit the working-tree side; `save()`; assert the bytes are unchanged outside the edit, or the save is refused. |
| Symlinked project | ✘ | ✘ | `setRoot(link)`; assert `status(for: link/a.txt) == .modified`. |
| Bare repository | ✘ | ✘ | `setRoot(bare.git)`; assert `.unavailable`. |
| Repository-local config | ✘ | ✘ | Repository with `core.fsmonitor` writing a marker; `setRoot`; assert no marker (after the trust gate or `-c core.fsmonitor=false`). |
| Ignored pass cost | ✘ | ✘ | `GitRunning` observer: assert the ignored pass does not run `status --ignored` (after the switch to `ls-files`). |
| Network blocking local actions | ✘ | ✘ | A runner that holds `fetch` open; start fetch; `stage`; assert stage completes while fetch is pending (or document the serialization). |

## 5. Coverage summary

| | Verified by test or probe | Missing | Unreliable (asserts wrong behaviour) |
|---|---|---|---|
| Parsing | porcelain v1, conflicts, log, name-status, blame, worktree, refs | leading combining mark | — |
| Status model | partial staging, renames (display), refresh failure, epoch ordering | untracked section, liveness, HEAD-moved, symlink root, bare | — |
| Index mutations | stage, revert, hunk (LF, ASCII path), commit only, conflicts | empty repository, rename unstage | hunk path quoting (G-08) |
| Diff | computer, patch apply, whitespace, tabs, embedded viewer | encodings, EOL filters, bare CR | — |
| Concurrency | lane, epoch, cancellation of reads | starvation, mutation on close, network blocking | — |
| Security | literal pathspecs, leading-dash refusal, askpass token | repository-local config execution | — |

# Handoff: fix the Git audit findings

You are fixing defects that the 2026-11-22 Git audit confirmed. Read `docs/audit/git/GIT_INTEGRATION_FINAL_AUDIT.md` § 3 for the full write-up of each finding (G-xx). This file tells you what to change, in what order, how to prove each fix, and what not to touch.

Audited commit: `afc43b7f`. If `main` has moved, re-check each cited line before editing.

## Ground rules

- Follow `CLAUDE.md`, `Umbra/CLAUDE.md`, `Umbra/Sources/Umbra/Git/CLAUDE.md`, `Umbra/Sources/Umbra/Diff/CLAUDE.md` and `docs/PERFORMANCE_RULES.md`. In particular: no git on the main actor, no new work per keystroke, and `GitIntelligence` stays free of AppKit and Penumbra.
- **Write the regression test first and watch it fail.** Then fix. Every work package below names its tests.
- Test placement: tests that only need `GitIntelligence` go in `Tests/PenumbraTests` (for example `GitRepositoryIntegrationTests.swift`). Tests that import `Umbra` go in `Umbra/Tests/UmbraTests`. Use real git in a UUID temp directory, as the existing tests do. Never point a test at this repository.
- Run tests with the display on:
  - `caffeinate -u -d -i -s swift test --filter 'Git|SystemGitRunner'` (root)
  - `caffeinate -u -d -i -s swift test --package-path Umbra --filter 'IDEGit|IDEChangeMarker|IDEDiff|IDEMerge|IDESaveBefore|IDEAgentWorktree|IDEBlame|IDEListKeyboard|IDEAgentNavigation'`
  - `swift test --package-path Packages/GitIntelligence`
- Baseline: 461 of 461 tests pass on these filters. Keep it that way, except the one test this handoff says to rewrite (WP2, G-08).
- When behaviour changes, update the matching bullet in `Umbra/Sources/Umbra/Git/CLAUDE.md` or `Diff/CLAUDE.md`. Those files document behaviour, and some of them are currently wrong (see G-19).
- **Do not commit or push unless the user asks.** If they do, work on a branch, with one commit per work package.
- Two decisions belong to the user. They are marked **⚑ ASK**. Implement the default only if the user is unavailable, and say that you did.

## Order

| # | Work package | Findings | Size |
|---|---|---|---|
| 1 | Stop repository config from running programs | G-01 (flags) | S |
| 2 | Diff viewer and hunk staging integrity | G-05, G-04, G-08, G-11, G-21 | M |
| 3 | Status model correctness | G-02, G-09, G-10, G-15, G-16 | S |
| 4 | Refresh liveness and HEAD identity | G-06, G-03, G-23 | S–M |
| 5 | Ignored pass | G-12 | S |
| 6 | Symlinked project roots | G-07 ⚑ | S–M |
| 7 | Mutation lifetime and network lane | G-14, G-19 | S–M |
| 8 | Large change-set cost (profile first) | G-13 | M |

---

## WP1 — G-01: repository-local config runs commands (P0)

**Problem.** A `.git/config` with `core.fsmonitor=<cmd>` runs `<cmd>` on Umbra's automatic `git status` and `ls-files`. With `diff.external`, the program runs on `git diff`. Neither needs any user action.

**Change**

- `Packages/GitIntelligence/Sources/GitIntelligence/Process/GitRunner.swift`, `SystemGitRunner.run`. The runner already prepends `["-c", "core.quotepath=off"]`. Also prepend `"-c", "core.fsmonitor=false"` for every command.
- `GitRepository.swift`: add `--no-ext-diff --no-textconv` to `unstagedDiff`, `stagedDiff`, `workingTreeDiff` (both branches), `commitDiff` (`show`), `show(hash:)`, and the `diff` in `compare` (`+Branches.swift`).
- `+History.swift` `lineHistory` (`log -L`): add `--no-textconv`.
- `blame`: add `--no-textconv`. Run `git blame -h` to confirm Apple git 2.54 accepts it.
- Grep for every other `"diff"`, `"show"`, `"log"` with patch output and `"blame"` invocation, and treat them the same way.

**Test** (`Tests/PenumbraTests`, a new `GitUntrustedConfigTests.swift`)

1. Set up a repository with `core.fsmonitor = "touch <tmp>/marker-fsmonitor; false #"`, `diff.external = <script that touches marker-extdiff>`, and a textconv driver plus `.git/info/attributes` that touches marker-textconv.
2. Modify a tracked file.
3. Call `status()`, `unstagedDiff`, `stagedDiff`, `workingTreeDiff`, `commitDiff`, `show`, `blame` and `GitRepository.visibleFiles`.
4. Assert that no marker exists.
5. Add an Umbra-level test: `IDEGitStatusModel.setRoot` on that repository, wait for `workspaceSnapshot`, and assert no marker.

**⚑ ASK (follow-up, not required for WP1).** Should Umbra also add a per-repository git trust gate (reusing the Gradle/npm trust-store pattern), or are the flags enough? Hooks (commit, checkout) and `filter.*` clean/smudge (stage) still run on user-initiated actions. Default: flags only, and record the remaining exposure in `Git/CLAUDE.md`.

---

## WP2 — Diff viewer and hunk staging integrity

### G-05 (P0): saving the diff's working-tree side re-encodes non-UTF-8 files

- **Where.** `IDEGitStatusModel.diffContent` / `diffContent(of:)` (`Umbra/Sources/Umbra/Git/IDEGitStatus.swift` ~885–893, ~946–949) decodes lossily. `IDEDiffSession.save` (`Umbra/Sources/Umbra/Diff/IDEDiffSession.swift` ~314–333) writes `.utf8`, and skips the overwrite check when the disk does not decode.
- **Minimum fix.** Add `IDEDiffContent` information that the working-tree bytes were not valid UTF-8 (`String(data:encoding:.utf8) == nil`). Set `readOnlyReason` to "This file is not UTF-8; edit it in the editor tab" for that side, so `save()` can never run for it. Also make `save()` refuse when the disk is not valid UTF-8, instead of treating that as "nothing to lose".
- **Better (optional).** Decode and encode through the editor's `TextFileEncoding` (see `Umbra/CLAUDE.md` ▸ File encoding).
- **Test** (Umbra): commit `63 61 66 E9 0A 78 0A`, change line 2, build `IDEDiffSession` with `loadContent = model.diffContent`. Assert the right side is read-only, and that after a forced `rightTextDidChange()` and `save()` the disk bytes are unchanged.

### G-04 (P1), G-08 (P2), G-11 (P2), G-21 (P3): rebuild hunk staging around blobs, not `git apply`

Today `IDEDiffPatchBuilder` makes a zero-context patch from Umbra's decoded texts and pipes it to `git apply --cached --unidiff-zero`. This causes four defects:

- CRLF reaches an LF index (G-04).
- Paths with spaces are quoted wrong, as `a/"x y"` (G-08).
- A pure insertion is not anchored to any content, and the base blob id is read *after* the texts are loaded (G-11).
- Umbra counts a bare `\r` as a line break and git does not (G-21).

**Recommended design** (one change fixes all four):

1. In `IDEDiffSession.reload`, read `:path`'s blob id **first**. Load the index side with `cat-file blob <id>` instead of `:path`, so the text and the id match. Keep `hunkBaseBlobID` set to that id.
2. To stage one chunk, build the full new index text: the index text with that chunk's left lines replaced by its right lines. To unstage (HEAD ↔ index), replace the chunk in the index text with the HEAD lines.
3. Add `GitRepository.replaceIndexBlob(path:expectedBlobID:contents:)` in `GitRepository.swift`, run inside the lane:
   - re-check `:path` against `expectedBlobID`;
   - `hash-object -w --path=<path> --stdin`, which applies the path's attributes: `eol`, `autocrlf` and clean filters;
   - `update-index --cacheinfo <mode>,<newid>,<path>`, keeping `<mode>` from `ls-files -s -- <path>`;
   - use `--literal-pathspecs` and `--` wherever paths appear.
4. Refuse with a clear message (do not stage) when:
   - either side is not valid UTF-8;
   - the text contains a bare `\r` that is not followed by `\n`;
   - the comparison is a rename or copy (this check exists already).
5. Keep `IDEDiffPatchBuilder` only if something else needs it. `rg IDEDiffPatchBuilder` will show you. If nothing does, delete it and its tests together.

Alternative if you keep `git apply`: emit git's quoting (`"a/my file.txt"`, with `\t`, `\"`, `\\` and `\n` escaped), convert "+" lines to the index file's EOL, and refuse whenever `git check-attr filter -- <path>` reports a filter. The blob design is simpler and more correct. Choose it unless it breaks something you find.

**Tests**

- **G-08**: rewrite `testASpaceInThePathIsQuotedAndANewlineIsRejected` (`Umbra/Tests/UmbraTests/IDEDiffComputerTests.swift` ~168). It asserts the broken `a/"my file.txt"` form, so replace it with a test that stages a hunk of `my file.txt` and of `tab\tname.txt` through `IDEGitStatusModel.applyHunk` (or the new API), then checks `git diff --cached`. **This is the only existing test you are authorized to change.**
- **G-04**: with `core.autocrlf=true`, commit `a\nb\nc\n`, write `a\r\nB\r\nc\r\n`, stage the hunk, and assert `git ls-files --eol f.txt` starts with `i/lf` and the index holds `a\nB\nc\n`. Repeat with `.gitattributes` `* text eol=crlf` and no autocrlf.
- **G-11**: load a session, then change the index externally (`git add` a version with a new first line), then stage. Assert the action is refused with the "index changed" message and the index is untouched.
- **Keep green**: `IDEDiffHunkSafetyTests`, `testARenameComparisonDoesNotApplyAHunk`, `GitRepositoryIntegrationTests.testApplyHunk*`, `testPatchesApplyWithGit` (or its replacement).

---

## WP3 — Status model correctness

### G-02 (P1): untracked files are listed under Staged

- **Where.** `statusFromIndexChar` (`IDEGitStatus.swift` ~1269) maps `?` to `.modified` through `default:`.
- **Fix.** Return `nil` for `?` and `!`. Make both mapping functions list every porcelain letter (`M A D R C T U ? !` and space) explicitly. Keep `default` only as a deliberate fallback for letters git adds later.
- **Tests** (Umbra):
  - With a real repository, an untracked file gives `staged == nil`, and `IDEGitChangeRows.listed` gives only `.unstaged` for it.
  - A table test of `IDEGitStatusModel.parse` over every XY pair in `git help status` (including `??`, `!!`, `.A`, `.T`, `AA`, `DD`, `AU`, `UA`, `DU`, `UD`, `UU`, `R.`, `RM`, `C.`), asserting `staged`, `unstaged` and the section list.
  - With only untracked files, `requestCommit` fails with "Nothing staged to commit." and runs no git.

### G-09 (P2): Unstage and Unstage All fail before the first commit

- **Where.** `GitRepository.unstage` and `unstageAll` (`restore --staged` needs `HEAD`).
- **Fix.** When `rev-parse -q --verify HEAD` fails (unborn branch), use `--literal-pathspecs rm --cached -q -f -r -- <paths>` and `rm --cached -q -f -r -- .`. With `--cached`, `-f` only overrides the "staged content differs" refusal; it never touches the working tree. Verify that in the test.
- **Test** (root): `git init`, then `add a b`, then `unstage([a])`. Assert `a` becomes `??`, `b` stays `A `, and the file is still on disk. Do the same for `unstageAll`.

### G-10 (P2): staged renames

- **Where.** `IDEGitStatusModel.unstage(paths:)` and `relativePaths(_:keeping:)` send only `relativePath`. `revert` checks only the new path against `HEAD`.
- **Fix, unstage.** For a change with `originalPath` and an index code `R` or `C`, also pass `originalPath`. `restore --staged -- old new` restores both.
- **Fix, discard.** For an `R` row, restore `old` from HEAD and remove `new` from the index (`rm --cached`).
- **⚑ ASK.** For a discarded rename, should the new path's file be deleted from disk? Default: keep it on disk (it becomes untracked), and say so in the confirmation text.
- **Tests** (Umbra): `git mv old new`, then `model.unstage([new])`, then assert porcelain is ` D old` and `?? new`. That is git's own state after `restore --staged old new`; confirm the expectation with the CLI first. A second test does the same for the discard path.

### G-15 (P3): a bare repository or `.git` opened as the project shows an error

- **Fix.** In `GitRepository.isNotARepository`, also treat stderr containing `must be run in a work tree` as `.notARepository`.
- **Test** (root): `discoverOutcome` on a bare clone and on `.git` returns `.notARepository`.

### G-16 (P3): a leading combining mark is dropped from filenames

- **Where.** `GitStatusParser.parse` slices by `Character`.
- **Fix.** Split the raw `Data`/UTF-8 bytes on NUL. Take bytes 0 and 1 as XY, skip byte 2, and decode the rest as the path.
- **Test** (root): `GitParsersTests`, a record `" M \u{0301}x.txt"` keeps the mark. Rename records still pair up.

---

## WP4 — Refresh liveness and HEAD identity

### G-06 (P2): status never publishes while watcher batches keep arriving

- **Where.** `IDEGitStatusModel.beginRefresh` (~319–333) drops a finished load whenever `refreshEpoch` moved. Every `refresh()` call moves it.
- **Fix.** Add a separate `mutationEpoch`, bumped only by `invalidateForMutation()` and `setRoot`. Capture it when a load starts.
  - On completion, apply if `mutationEpoch` is unchanged, even when `refresh()` was called meanwhile. Then run the queued pass (`needsAnotherPass`).
  - Drop the load only when a mutation started after it began.
  - Keep `refreshEpoch` as the snapshot generation.
- **Must stay green**: `IDEGitRefreshTests.testAStaleStatusDoesNotReplaceANewerEpoch` (it uses `invalidateForMutation`, so it still drops) and `testCancellingARefreshDoesNotPublishAFailure`.
- **New test** (Umbra): a `GitRunning` wrapper delays any command containing `"status"` by 400 ms. After the first load, dirty a file and call `refresh()` every 150 ms for 3 s. Assert that `onRefreshed` fired at least once and that the change was visible **during** the burst.

### G-03 (P1): the gutter stays stale after a same-branch commit

- **Where.** `applyLoaded` (~386): `headChanged = state.head != repositoryState.head` compares `.branch("main")` with itself. `IDEWorkspace.swift` ~339 flushes the HEAD-blob cache only when `headMoved` is set.
- **Fix.** Track HEAD's commit id.
  - In `loadSnapshot`, replace `repo.currentBranch()` (which also closes G-23) with one `rev-parse -q --verify HEAD`. That gives the oid, or nil on an unborn branch.
  - Take the branch name, or the short hash when detached, from `repo.state()`. Keep `currentBranch`'s published value identical for detached HEAD (short hash) and unborn branches (branch name).
  - Store the oid in the snapshot and set `headMoved` when the oid **or** `state.head` changes.
- **Test** (Umbra): load, commit on the same branch with the CLI, `refresh()`, assert `headMoved == true`. Then, through `IDEChangeMarkerController.cacheHead` and `invalidateHeadCache`, assert the cache was flushed. A second refresh with no new commit must give `headMoved == false`.

---

## WP5 — G-12: the ignored pass costs 1.67 s per refresh here

- **Where.** `IDEGitStatusModel.startIgnoredPass` calls `repo.status(includingIgnored: true)`.
- **Fix.** Add `GitRepository.ignoredPaths()` running `--no-optional-locks ls-files -z --others --ignored --exclude-standard --directory`. Directories come back with a trailing `/`, as `!!` entries do. Feed the result to `mergeIgnored` in place of the status entries. On this checkout the output was verified identical to the `!!` set, in 30 ms against 1,671 ms.
- **Test** (Umbra): a recording `GitRunning`. After a refresh, assert no command contains both `status` and `--ignored`, and that an ignored file still gets `.ignored` from `status(for:)`. `IDEGitRefreshTests.testTheHotStatusOmitsIgnoredFiles` must stay green.

---

## WP6 — G-07: a project opened through a symlink has no git state ⚑

- **Where.** `IDEWindowRegistry.swift` ~265 and 269 pass `item.url` unresolved. The model keys its paths by git's `--show-toplevel` spelling, which has symlinks resolved.
- **⚑ ASK.** Should the project root be resolved at open time (recents, window title and session would then show the real path)? Or should the model translate between the two spellings (more code, keeps the user's spelling)? Default: resolve at open, using `IDEOpenRouter.normalizedPath`'s rule, in `openProjectFolder` and `replaceProject`.
- **Test** (Umbra): create a real repository plus a symlink to it, `setRoot(link)` (or `openProjectFolder` if you resolve there), modify a file, and assert `status(for: <link>/a.txt)` is `.modified` (or that the root became the resolved path and lookups by it work). Do **not** build the test directory with `resolvingSymlinksInPath()` for the link itself.

---

## WP7 — Mutation lifetime and network lane

### G-14 (P2): closing a window kills a running commit or rebase

- **Where.** `setRoot` cancels `mutationTasks`. The lane's `onCancel` cancels the body, and SubprocessKit sends SIGTERM.
- **Fix.** Run the lane body in a task that is not cancelled with the window. On `setRoot`, drop the UI callbacks (`onSuccess`, refresh) but let git finish. Do not change `GitMutationLane`'s documented semantics for waiters.
- **Test** (Umbra): install a `pre-commit` hook that sleeps 2 s, start `performCommit`, call `setRoot(nil)` after 200 ms, wait 4 s, and assert `git log -1` shows the commit and `.git/index.lock` does not exist.

### G-19 (P2): fetch and push block Stage and Commit, with no timeout or Cancel

- **Where.** `runGitAction` puts every action through `GitMutationLane` (~1006). `SystemGitRunner` has no timeout.
- **Fix.** Do not take the local lane for `network: true` actions; git's own `index.lock` arbitrates the rare overlap with pull.
  - Add a Cancel for the running network action: keep its task and cancel it. SIGTERM is fine for fetch and push.
  - Add an optional `timeout` parameter on `GitRunning.run`, used for background fetch only.
  - Update the `isNetworkBusy` doc comment and `Git/CLAUDE.md` so they match the new behaviour.
- **Test** (Umbra): a runner that blocks `fetch` until released. Start a fetch, then `stage`, and assert the stage finishes while the fetch is still blocked.

---

## WP8 — G-13: a 10k-change refresh takes about 1.2 s and stalls the main actor 83–148 ms

**Profile before you change anything.** About 0.9 s of that time is unattributed.

- **Measure.** Use the 50k and 100k fixtures from `04_PERFORMANCE.md` (regenerate them with the script described there: N files, 100 per directory, then modify 10,000). Run Instruments Time Profiler on an `-c release` test that does `setRoot`, then `refresh`.
- **Suspects**, in `IDEGitStatusModel.parse`: the `localizedStandardCompare` sort, and `markDirty`'s `String.count` (O(n)) inside the loop over ancestor folders. On the main actor: the dictionary rebuilds and comparisons in `apply`, `changeSelection.reconciled`, and repeated `IDEGitChangeRows.listed`.
- **Target.** Largest main-actor gap under 50 ms and end-to-end under 400 ms at 100k files with 10k changes (M5 Max, release).
- **Test.** An opt-in timing test (environment-gated like `UMBRA_UI_TESTS`) that records the largest main-actor gap with a 1 ms ticker during refresh.

---

## Out of scope

Leave these alone unless the user asks: G-17 (a "Discard Unstaged Changes" action), G-18, G-20, G-22, gutter hit targets, line-level staging, worktree UI and submodules. They are in the roadmap (final audit § 8, Phases D–E).

## Done means

- Every test named above exists, failed before the fix, and passes after it.
- The three filtered suites in Ground rules are green, with the one authorized rewrite.
- Re-measure G-12, and G-13 if WP8 was done, and update `04_PERFORMANCE.md` with the new numbers.
- Update `GIT_INTEGRATION_FINAL_AUDIT.md`: add a "Fix status" line under each fixed finding, giving the test name and commit if any.
- Report back: the files changed, test counts (executed, passed, failed), any ⚑ decision taken by default, and anything you could not fix along with the reason.

## Resources

The audit's probe code may still be in `/private/tmp/claude-501/-Users-alex-Developer-Penumbra/90ff0bf4-3f45-45a4-a0e4-bd40ab99686e/scratchpad`:

- `libprobe/` is a scratch package linking `GitIntelligence` by path, with the `gitbench` benchmark.
- `clone/Umbra/Tests/UmbraTests/AuditGitProbe*.swift` are the app-level probes.
- `bench/gen.py` generates the benchmark repositories.

The scratchpad can be cleared at any time. The recipes in `07_TEST_COVERAGE.md` § 4 and in this file are enough to rebuild them.

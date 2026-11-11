# Git integration — final verification

Date: 2026-11-11. HEAD `03c059d6`. The working tree already contained the Git UI work; this pass edited rename diff paths, selection identity, regression tests, and two audit documents. No commit was created. The developer repository was not mutated. Temporary Git repositories lived under the system temp directory.

This pass compared the implementation with the eight documents in `docs/audit/git/`. Prior green tests were re-run as part of the Umbra suite, and the rename and selection behavior was checked against real `git` porcelain from Apple Git, not against the previous write-up alone.

**Recommendation: Ready with limitations.**

Phases 1–5 behave as the interaction spec now describes. Rename comparisons use the porcelain old path on the side Git marked `R` or `C`. A path that appears in both Staged and Changes is two rows and one path. The release product builds. The 2,000-row list does not rebuild change-row bodies while the commit message changes, in Debug and in Release. Phase 6 (worktrees) was left undone on purpose. The Umbra suite is not fully green; the failures are outside this Git work. Live VoiceOver was not run.

## 1. Verification by completed phase

### Phase 1 — Honest Changes list

Met.

- Chrome follows refresh state. `IDEGitChangePresentationTests.testChromeFollowsEveryRefreshState` passed. A first status failure is `.failed` with an error and no repository (`IDEGitRefreshTests.testAFirstStatusFailureShowsTheErrorWithoutARepository`). A later failure keeps the last branch (`testAFailedStatusKeepsTheBranchAndRecovers`). `.unavailable` stays unavailable (`testAMissingRepositoryStaysUnavailable`).
- Letters and nouns come from the porcelain codes. A work-tree `D` is “Deleted”. An index `R` names both paths. `testLettersNounsAndRenamePaths` and `testParseKeepsPorcelainLettersWhenTheExplorerTintCollapsesThem` passed. The explorer tint stays collapsed (`testExplorerNounUsesThePorcelainWordWhileTheTintStaysCollapsed`).
- Discard copy names unsaved editors and stays separate from Revert Commit (`testDiscardCopyNamesUnsavedEditorsAndKeepsRevertCommitSeparate`).
- Scroll identity is `section + "\t" + path` (`testScrollIdentityAndFocusFollowTheSection`).

### Phase 2 — Commands

Met. `IDEGitCommandRoutingTests` (6) and `IDEGitCommandFlowTests` (4) passed.

- Stage and Unstage are palette commands. They are not menu shortcuts. `IDEGitListShortcut` returns stage for ⌘S and unstage for ⌘U only when command is down and shift, option, and control are up. ⌥⌘S stays Save All.
- `IDEGitSaveIntercept` binds ⌘S to Save on the default, Sublime, and VS Code maps, and to Save All on IntelliJ. The intercept runs only while the Changes list is focused, from the workspace save path.
- F7 and ⇧F7 are Next Change and Previous Change on default, Sublime, and VS Code (key code `0x62`). IntelliJ leaves them unbound on the keymap. IntelliJ’s menu Step Into remains F7. `testF7MovesBetweenEditorChangesAndDoesNotStealTheDiffOrTheDebugger` passed. The diff viewer and the merge viewer swallow bare F7 and ⇧F7 in their own `handleKeyDown` before the menu.
- Commit stays ⌘↩ in the message field. The palette command “Git: Commit Staged” focuses the field and commits, or fails with the button wording (`IDEGitCommitRefusal`: busy, “Stage files to commit them”, “Enter a commit message”). It does not use ⌘K. IntelliJ ⌘K stays the source-control toggle.
- Return in the list activates the selected row. A conflict opens the merge tool. Escape in the list focuses the message field. Escape in the field focuses the editor.
- Next Conflict walks conflicted paths and does not call Git to discover them (`testConflictNavigationWalksPastTheOpenFile`, `testNextConflictWithNoneFails`).

### Phase 3 — Diff session

Met, after the rename-path correction in this pass.

- The sidebar and Show Diff share `IDEDiffRequest.change`. `IDEGitChangeDiff.preview` uses the selected section. A path-only caller still prefers the unstaged side when both exist. A section the file no longer occupies returns nil.
- Hunk apply goes through `IDEDiffSession.applyToIndex`. An unsaved or dirty right side stops first with “Save the file before staging hunks. Unsaved editor text is not written to the index.” (`IDEDiffComputerTests`). A comparison with `comparesDistinctPaths` stops next with “This change renames or copies the file. Stage or unstage the whole file.” and does not call `git apply` (`testARenameComparisonDoesNotApplyAHunk`). The index blob id is still checked for a same-path hunk.
- `IDEDiffSessionStore.reload` reloads a tab whose `revisionPaths` intersect the refreshed set. An unstaged rename lists the old path and the new path. A text/text request has an empty set and is not reloaded by that call (`IDEDiffSessionStoreTests.testARenameTabReloadsWhenEitherPathChangesAndATextTabDoesNot`).
- `testTeardownReleasesTheEmbeddedSession` passed: after `coordinator.teardown()`, the embedded session is released.
- `IDEDiffComputerTests` (13), `IDEDiffDividerViewTests` (2), `IDEDiffHunkSafetyTests` (4), `IDEDiffPatchBuilderTests` (6), `IDEDiffSessionStoreTests` (4), `IDEDiffTabTests` (16), and `IDEGitChangeDiffTests` (7) passed in the full Debug suite.

### Phase 4 — Editor, explorer, conflicts

Met in source and in the automated tests. Live VoiceOver was not used.

- Row label is the noun, the path, and the section. A rename says “Renamed from old to new, staged” (the test asserts that shape). A conflict says “Conflict in \(path)”. The letter and icon are not the accessible name.
- The list disclosure is labeled “Changed files, N” with value Expanded or Collapsed (`IDESourceControlPanel`).
- Stage and Unstage buttons are labeled “Stage File” and “Unstage File”. Rows add the button trait. Focus is a 1 pt accent stroke (`gitRowFocusStroke`) while `focusEffectDisabled()` stays on the list, so the system focus ring is not the indicator.
- The conflict banner is “Conflict in \(displayName)” and follows `status == .conflicted`. A file that merely contains conflict markers does not show it (`testConflictBannerFollowsTheStatusAndIgnoresMarkerText`).
- Divider accessibility: role group, label “Diff changes”. Each hit rect is a button whose label matches the tooltip (`Stage Hunk`, `Unstage Hunk`, or “Replace with the left side”). `accessibilityPerformPress` runs the primary action. The unit test checks those strings and an empty divider’s child count. It does not drive VoiceOver.
- Explorer rows expose the porcelain noun as an accessibility value. `status(for:)` remains a dictionary lookup.

### Phase 5 — List measurement

Met. The split holds in Release. Numbers are in section 7. F-UI16 and directory grouping were not started, matching the plan.

### Phase 6 — Worktrees

Not implemented. The plan marks it optional. This pass did not add worktree UI.

### Git suites in the full Debug run

Every `IDEGit*` suite, every `IDEDiff*` suite, and `IDEListKeyboardTests` (18) passed. That includes `IDEGitRenameAndSelectionTests` (7, real temp repositories), `IDEGitRefreshTests` (6), `IDEGitStatusOperationsTests` (14), `IDEGitStatusRemoteTests` (17), `IDEGitStatusStashTests` (5), and `IDEGitChangesListMeasurementTests` (1).

## 2. Newly discovered defects

Corrected in this pass:

- A renamed file was compared using the new path on both sides. `HEAD:new` is absent after `git mv`, so the left side loaded as empty text.
- One path in both sections was one selection. Shift-click, Open Diff, and refresh could not tell the staged copy from the unstaged copy.

Confirmed and left as limitations, not guessed around:

- An unstaged filesystem move with no `git add -N` is porcelain `D` plus `??`. Those entries are not paired.
- A rewrite below Git’s similarity threshold is `D` plus `A` with `originalPath == nil`. No sibling path is invented.
- `git status --find-copies` is not a flag on this Git. `C` is honored only when porcelain already supplies `originalPath`.

Unrelated to Git, found while classifying the suite. Not fixed, except the one compile guard in section 3:

- Settings order includes the committed Terminal page. `IDELanguageModuleTests` still expects the list without it.
- The language registry includes Python. `LanguageServiceRegistryTests` still expects the pre-Python lists.
- `GhosttyPtyProcess` keeps the parent `TERM` when it is already set. This run’s parent had `TERM=dumb`, and `testTermSet` waited for `xterm-256color`. The sink tail contained `dumb`.
- `SwiftModelTests.testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling` reports grammar gaps in three files that are unchanged from HEAD.
- JaCoCo jars are not on disk, so four coverage tests throw `notBundled`.

## 3. Corrections implemented

Rename flow, only when that side’s code is `R` or `C` and `originalPath` is non-empty and different from the current path:

| Side | Left | Right |
|---|---|---|
| Staged rename or copy | `HEAD:originalPath` (empty text when the file is new) | index at the new path |
| Unstaged rename or copy | index at `originalPath` (not the empty intent-to-add blob at the new path) | working tree at the new path |
| `RM` unstaged half | index at the new path | working tree at the new path. The work-tree code is `M`, so `originalPath` is not used |
| Missing `originalPath` | the current path on both sides | |

`IDEDiffRequest.repositoryRelativePath` stays the index path: the new path for a staged rename, the old path for an unstaged rename. Hunk patches stay single-path. `additionalRevisionPaths` adds the new path for an unstaged non-new rename, because that side is a working-tree file and is not a `.revision`. `applyLoaded` records the previous snapshot’s `originalPath` values before it replaces `changes`, then the new ones, so a tab keyed by the old path reloads on the refresh that drops the rename.

Selection has one owner, `IDEGitStatusModel.changeSelection`. A row is the repository root, the section, and the path. ⌘-click toggles that row. ⇧-click extends inside the list it was given; the Changes list passes that section’s rows. If the anchor is outside that list, the click selects the clicked row. ⇧-arrow walks conflicts, then staged, then unstaged, so it can include both copies. Refresh keeps a row that still exists and follows the remaining copy when a section disappears. A different repository root clears the selection. `setRoot` clears it immediately. Stage, unstage, and discard use the selected paths when the acted-on row is inside the selection. Open Diff, Return, and the preview use the selected section.

Also:

- `IDEListKeyboardTests` passes `[] as [String]` so the path overload stays unambiguous.
- `testSelectionIdentityKeepsTheTwoCopiesOfOnePathApart` now expects the out-of-section shift-click to select the clicked row. The product behavior was already that contract.
- The measurement prints `configuration=Debug` or `configuration=Release` from the build flag. The string used to say Debug in every build.
- `IDEHTTPDeleteSelectionTests` wraps `textView.selectionRectsForTesting` in `#if DEBUG`. That property exists only inside `TextView`’s debug test hooks, so the Release test bundle did not compile. The assertion still runs in Debug. This is not a Git change.

## 4. Regression tests added

`Umbra/Tests/UmbraTests/IDEGitRenameAndSelectionTests.swift`, real temp repositories, `SystemGitRunner`, user `Tester`, `commit.gpgsign false`. All seven passed in the full Debug suite (1.451 s):

- `testAStagedRenameComparesHeadOfTheOldPathWithTheIndexOfTheNewPath`
- `testAStagedRenamePlusAWorktreeEditUsesTheNewPathOnlyForTheUnstagedSide`
- `testAnUnstagedRenameReadsTheIndexAtTheOldPath` (`git add -N`; the left side is the committed text at the old path)
- `testAStagedEditThenAnUnstagedRenameKeepsBothEntries`
- `testARewriteBelowTheRenameThresholdIsNotGivenASourcePath`
- `testCommittingAnUnstagedRenameStillReloadsATabKeyedByTheOldPath`
- `testSelectionKeepsBothSectionsAndFollowsAStagedFile` (both sections, shift inside one section, shift across the full list, command-toggle, preview by section, refresh, stage moves the primary row, `setRoot` clears)

Unit coverage next to that: `IDEGitChangeDiffTests.testARenameUsesTheOldPathOnlyOnTheSideThatGitMarked`, `IDEDiffSessionStoreTests.testARenameTabReloadsWhenEitherPathChangesAndATextTabDoesNot`, `IDEDiffComputerTests.testARenameComparisonDoesNotApplyAHunk`.

## 5. Full test-suite results

Command: `caffeinate -u -d -i -s swift test --package-path Umbra`

Debug build. Started 2026-11-11 13:26:39, finished 13:38:08. `UmbraTests.xctest`: 2893 tests, 37 skipped, 15 failures (4 unexpected) in 689.129 seconds. Exit code 1. No Git suite failed.

The “15 failures (4 unexpected)” line is 15 recorded issues in 9 test methods. On this runner the four thrown errors are the unexpected count. The other eleven are `XCTAssert` failures. None of the nine methods, and none of the code they assert, differ from HEAD `03c059d6`. A clean HEAD worktree was not built. The classification uses that identity plus the failure text.

The nine failures written in `docs/JAVA_COMPLETION_QUALITY.md` are the root library suite (5,251 tests, 24 skipped, 9 failures). This pass did not re-run that suite. That document classifies eight as pre-existing (`JavaGoToImplementationTests.testDefinitionOnConcreteOrStaticDeclarationsStaysEmpty` across four assertions, two `RecentFilesSwitcherTests`, two JaCoCo `JavaInstrumentationRealJDKTests`) and `JavaScopeTreeTests.testLargeFileBuildsQuickly` as a Debug timing flake that also fails on an untouched HEAD worktree. The JaCoCo half of that note matches this machine: `Umbra/Sources/Umbra/Tools/JaCoCo/build/` is absent.

### This Umbra run

| Test | Class | Evidence |
|---|---|---|
| `IDEInstrumentedRunWorkspaceTests` (4): `testABuildThatEndsMeanwhileIsNotTheInstrumentedRun`, `testAGradleTaskThatWroteExecutionDataIsReadFromItsMarkerLines`, `testAKilledRunSaysItWroteNoCoverageData`, `testAProgramRunWithCoverageEndsInABandedFile` | Environment-dependent | Thrown `notBundled(missing: ["jacocoagent.jar", "jacococli.jar"])` from `JavaCoverageToolchain.swift:63`. These four are the “4 unexpected”. |
| `GhosttyPtyProcessTests.testTermSet` | Environment-dependent | Timed out waiting for `xterm-256color`. The PTY printed `dumb`. `GhosttyPtyProcess` sets `TERM` to `xterm-256color` only when neither the override nor the parent environment has `TERM`. This shell had `TERM=dumb`. The file is unchanged from HEAD. |
| `IDELanguageModuleTests.testSettingsPagesKeepTheirOrderWithTheJavaPageBetweenProjectAndAgent` | Pre-existing confirmed | Actual ids include `terminal` between `appearance` and `focus`. `IDEPreferencesDomain.leading` is `[.general, .editor, .saving, .appearance, .terminal, .focus, .project]`. The test and that file match HEAD. |
| `LanguageServiceRegistryTests.testUmbraRegistryKeepsTheEngineProviderOrder` and `testUmbraRegistryOptsOutOfTheSameGenericFeaturesAsBefore` | Pre-existing confirmed | Actual lists include `python`. The test expectations and the registry source match HEAD. |
| `SwiftModelTests.testRepositorySwiftFilesStayWithinTheSyntaxProblemCeiling` | Pre-existing confirmed | Grammar gaps in `Tools/PerfHarness/Sources/JavaAllocationProfile.swift`, `Tools/PerfHarness/Sources/CompletionLatencyProfile.swift`, and `Tests/PenumbraTests/JavaIntelligence/Support/ReferenceRepair.swift`. All three match HEAD. The new Git Swift files were not in the failure list. |

No failure was classified as a Git regression. None were left unresolved.

JaCoCo setup, when coverage tests should run: execute `Umbra/Sources/Umbra/Tools/JaCoCo/fetch.sh` once. It downloads JaCoCo 0.8.15 from Maven Central into `Umbra/Sources/Umbra/Tools/JaCoCo/build/` and checks SHA-256 `fb5b0036a0899ea97edfa0fc2c7985b55f3f7c5695028163e5e60d4f3cf6075d` (`jacocoagent.jar`) and `d2b74b20b415163c1f53261e7c5ef4445b788327094208ff821e0c2baf9bc8f1` (`jacococli.jar`). The jars are gitignored. This machine has one JDK: Temurin 24.0.2 arm64 at `/Users/alex/Library/Java/JavaVirtualMachines/temurin-24.0.2/Contents/Home`. The jars were not downloaded in this pass.

## 6. Release-build results

Command: `swift build -c release --package-path Umbra --product Umbra`

Exit code 0. `Build complete! (418.08 sec)`. Product: `Umbra/.build/release/Umbra`, Mach-O 64-bit executable arm64, 233 MB, written 2026-11-11 13:51. Warnings during that build were the existing tree-sitter and parser integer-precision warnings. No Git source failed to compile.

The Release test bundle’s first compile failed in `IDEHTTPDeleteSelectionTests` on the debug-only `selectionRectsForTesting`. After the `#if DEBUG` guard, `swift test -c release` compiled (`Build complete! (115.24 sec)` incremental) and the two measurement tests passed.

## 7. Performance

Fixture for the list: a temp repository, 2,000 modified files, offscreen `NSHostingView` 360×640, no file selected, 20 appends to `commitMessage`, one main-queue spin after each append. Counts are `IDEBodyDiagnostics` (one increment per body evaluation). The counter is compiled into Release. `elapsed` includes the spins. It is a wall-clock upper bound, not a CPU sample and not an editor keystroke.

| Sample | Rows | Panel | Diff | Elapsed | Resident delta |
|---|---:|---:|---:|---:|---:|
| Debug, before the split (plan, no elapsed stored on that line) | 12 | 20 | 0 | — | — |
| Debug, after the split | 0 | 20 | 0 | 0.069826125 s | — |
| Debug, full suite this pass | 0 | 20 | 0 | 0.113040333 s | — |
| Release, this pass | 0 | 20 | 0 | 0.050655458 s | — |
| Debug suite, ~2,000-line diff open | — | — | — | 0.006238416 s | −16384 (process already ~1.7 GB) |
| Release, ~2,000-line diff open | — | — | — | 0.003160125 s | +786432 (66,994,176 → 67,780,608) |

The Release list case asserted `rowDelta == 0` and `panelDelta > 0`. Commit-field edits still rebuild the panel, which owns the field, and they do not rebuild change-row bodies. About 5.7 ms per character in the Debug suite run and about 2.5 ms per character in Release, as that upper bound. The selected-file case is unmeasured. With a file selected, the parent still hosts the embedded diff; `Coordinator.update` returns before `session.reload` when the request id, the siblings, and the status epoch are unchanged.

`xctrace` 27.2 (27B52) is installed. Templates include Time Profiler and SwiftUI. Launching the test bundle directly failed: it is a Mach-O bundle, and `posix_spawn` returned “Exec format error”. A second recording launched `/usr/bin/xctest` with the Release measurement filter. The process exited 0. The trace window was 2.889 s (shorter than the 4.274 s case time under `swift test`). The Hangs instrument, threshold 250 ms including microhangs, recorded no hang intervals. 1,458 time samples were stored. Their stacks were not decoded, so this report does not assign CPU percentages. The body counter is the measurement of row invalidation. The trace was deleted. No optimization was made from these numbers.

Rapid selection across the 2,000-row list was not given its own timer. Session cleanup is the passing `testTeardownReleasesTheEmbeddedSession`. Chunk computation stays off the main actor in `IDEDiffSession.recompute` (`runDetached`).

## 8. Automated accessibility and interaction verification

Source and tests only. Live VoiceOver was not run. No screenshots.

| Check | Result |
|---|---|
| Row label and value | Noun, path, section. Rename names both paths. Conflict says “Conflict in \(path)”. Asserted in `IDEGitChangePresentationTests`. |
| List disclosure | Label “Changed files, N”, value Expanded or Collapsed. |
| Stage, unstage, commit, diff | Buttons “Stage File” / “Unstage File”. Commit field label “Commit message”. Divider buttons “Stage Hunk” / “Unstage Hunk” / “Replace with the left side”. Press runs the primary action, not option-append. |
| Conflict without color alone | Spoken “Conflict in …”, banner text, triangle symbol in the conflict row. Banner policy ignores raw marker text. |
| Keyboard | ⌘S/⌘U only in the focused Changes list. Editor Save and IntelliJ F7 Step Into stay in place. Return, Escape, and ⌘↩ behave as section 1 describes. `IDEListKeyboardTests` (18) passed. |
| Focus | `gitRowFocusStroke` on the primary row while the list is focused. `showsFocus` is the primary row. `isSelected` is membership. |
| Loading and failure | “Updating status…” while loading with no snapshot. Failed refresh keeps the last rows and shows the error. Commit controls stay hidden until a snapshot exists. Covered by the refresh and chrome tests. |
| Command availability | Stage and unstage filter by side and skip conflicts (`IDEGitIndexPaths`). Commit refusal is decided before `commitIndex`. |

## 9. Remaining limitations

- Worktree list, add, and remove UI is not in the branch popup.
- An unstaged move is a rename only when porcelain says `R` or `C` and provides `originalPath`.
- Hunk staging refuses a two-path comparison. The whole file is staged or unstaged instead. The patch format was not extended with rename headers.
- The index blob check and `git apply` are two processes. A concurrent index change fails the blob check on the second apply.
- Directory grouping (F-UI14) and an AppKit git-ribbon color pipeline (F-UI16) were not started.
- The 2,000-row measurement does not select a file, so it does not time the embedded diff during commit-field edits.
- `focusEffectDisabled()` remains. The accent stroke is the focus indicator.
- ⌥⌘K on Commit and Push stays a button shortcut, as the interaction spec already says.
- ⇧-click whose anchor is in the other section selects the clicked row and drops the previous rows.
- No live VoiceOver pass.
- The Umbra suite still fails the nine methods in section 5 until JaCoCo is fetched and the unrelated tests are updated. Those updates were left undone.
- Ignored files stay off the hot status (`testTheHotStatusOmitsIgnoredFiles`).

## 10. Recommendation

**Ready with limitations.**

The Git sidebar, commands, diff session, rename comparisons, and selection identity match the corrected spec and passed on real temporary repositories and in the full Debug Umbra suite. The release product links. Commit-message editing does not rebuild the 2,000 change rows in Release. Ship with the limitations in section 9 visible, and with the JaCoCo fetch step documented for coverage runs. Do not treat the nine non-Git suite failures as a Git regression.

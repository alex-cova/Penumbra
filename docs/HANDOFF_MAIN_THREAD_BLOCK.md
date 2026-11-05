# Handoff: find the intermittent main-thread block after creating an `IDEWorkspace` in Umbra's tests

## Goal

Find what blocks the **main thread for about 3–6 seconds** now and then, right after a test creates an
`IDEWorkspace`. Decide whether it is (a) purely a test-harness artifact (window-less AppKit views, XCTest,
a Debug binary) or (b) a real problem the app could also hit. Investigation only: no product-code fixes
unless the cause is clear and small, and nothing committed.

## Repo and how to run

- Repo: `/Users/alex/Developer/Penumbra` (read `CLAUDE.md`, `Umbra/CLAUDE.md`, `docs/PERFORMANCE_RULES.md`).
- Umbra tests: `caffeinate -u -d -i -s swift test --package-path Umbra --filter <Class>`. The display must
  be on (see the root `CLAUDE.md`).
- Build modes: normal Debug, or `--sanitize=thread --build-path Umbra/.build-tsan`. The stall happens
  **without** TSan.

## What is established (measured)

- **Symptom:** `IDEDiffTabTests.testAClosedWorkspaceWithADiffTabIsFreed` timed out ("Timed out after 2.0s
  waiting for condition", `Umbra/Tests/UmbraTests/IDEDiffTabTests.swift`) once in a loaded run and once under
  TSan. It passes alone in 0.4 s.
- **The diff code is not at fault.** A probe that repeatedly did `IDEWorkspace()` + `bootstrap()` +
  `openDiff(...)` and polled `session.chunks.count == 1` every 2 ms measured:
  - median 238 ms from the end of `bootstrap()` to the chunks appearing, p90 262 ms;
  - rare outliers of 2,982, 3,030, 5,403 and 5,640 ms, roughly 1 in 25–90 iterations, on an idle machine;
  - with every core saturated by CPU burners, the distribution was tight (median 692 ms, max 758 ms) with no
    outliers in 25 runs.
- **During an outlier the main thread is unresponsive.** A watchdog thread (a `Thread` calling `observe()`
  every 5 ms against a heartbeat the main-actor loop `touch()`es every 2 ms) recorded
  `mainUnresponsiveMaxMs=2891` in the iteration where the chunks took 3,030 ms. So it is not a lost or
  starved async hop in `IDEDiffSession`. A separate probe with no diff at all also saw a single 2.85 s
  main-thread gap after `bootstrap()`.
- **Typical delay explained.** With a temporary timer around the closure in
  `TextView.textInputViewDidRequestLayoutFlush` (`Sources/Penumbra/TextView/Core/TextView.swift`, about lines
  3403–3420), every workspace triggered exactly 9 deferred flushes, median 224 ms in total, max single flush
  about 41–60 ms. That matches the median delay.
- **The outlier is not (only) those flushes.** In the 5.6 s iteration the 9 flushes still totalled 235 ms.
- **`bootstrap()` itself is fast** (max 120–156 ms over all iterations), so the block comes after it
  returns, while the main thread services its queue or XCTest's run loop.

## Evidence from `/usr/bin/sample` (treat with caution)

Three samples were taken during stalls:

1. A main-queue drain spending most of its time in `TextView.textInputViewDidRequestLayoutFlush` →
   `TextInputView.performDeferredLayoutFlush` → `NSView layoutSubtreeIfNeeded`, deep in
   `-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]` / `NSISEngine`, plus `IDEEditorPaneHost.init`
   constructing `IDEDiffViewerView` / `IDEMergeViewerView`. This sample file was overwritten.
2. The main thread inside `-[XCTestCase recordIssue:]` → `XCTSourceCodeContext` →
   `XCTInProcessSymbolicationService` → `CoreSymbolication` DWARF parsing (`parse_dies`,
   `extract_debug_maps_from_header`). XCTest was symbolicating the call stack of a recorded issue in the
   Debug binary. Nothing in the log showed which issue. That run printed no "Executed N tests" line at all,
   so the process may have ended abnormally; check this. This sample file was deleted.
3. Layout-flush-heavy again. This one is kept in the scratchpad (below).

**Caveat:** the sampler may perturb the very thing being measured, and sample 3 contradicts the flush timer
(about 1 s of flush work sampled in an iteration whose flushes totalled 235 ms). Prefer measurements without
a sampler to decide, and use samples only to generate hypotheses. Only sample 3 survives on disk; the
descriptions of samples 1 and 2 are from notes taken while reading them.

## Hypotheses, none confirmed

1. **XCTest symbolication of a recorded issue** (sample 2). Find which issue is recorded. It may come from
   AppKit or the Swift runtime (a runtime warning, an auto-layout "unable to satisfy constraints" message) or
   from another thread.
2. **A heavy auto-layout pass on window-less view trees** (`layoutSubtreeIfNeeded` builds temporary layout
   engines), occasionally much larger than average. The real app lays views out inside a window, so this may
   be test-only. Test it by hosting the editor views in an offscreen `NSWindow`.
3. **Blocking work on the main actor from `IDEWorkspace.bootstrap()`'s deferred jobs.**
   `IDEJavaSupport.indexJDK` / `JDKIndexRoot.make(for:)` appeared in a sample's call tree; confirm which
   thread it runs on (a nested `Task` can inherit the main actor). Also check `gitStatus` and the
   project-system refreshes, and `Process`/`waitid` use.
4. **Environment**: disk I/O stalls, Spotlight, or timer coalescing. The runs used `caffeinate`.

## Suggested method

- Recreate the probe (the file was deleted). Loop 60–100 times: `IDEWorkspace.isSessionPersistenceEnabled =
  false`, `IDEWorkspace()`, `bootstrap()`, `openDiff(...)`, poll `session.chunks.count == 1` with
  `Task.sleep(2 ms)`. Record, per iteration, ms to "ready" and to chunks, plus the watchdog's max unresponsive
  time. Print detail only for slow iterations.
- Add a **non-sampling** way to learn what the main thread is doing: for example `os_signpost` intervals
  around main-queue blocks, a hang detector, or a watchdog that on a stale heartbeat captures the main
  thread's stack through a signal handler. Avoid anything that parses the Debug binary's symbols while
  stalled.
- Record every `XCTIssue` through `XCTestObservation` (`testCase(_:didRecord:)`) to see whether an issue
  precedes each stall.
- Run the same loop with views in a real offscreen `NSWindow`, and with a plain `TextView` and no workspace,
  to bisect "workspace-level" from "view-level".
- Run the identical loop in a Release test build if feasible, to see whether the stall is Debug-only.

## Constraints

- Temporary patches to product code for timing are fine, but **revert them** and confirm `git diff` shows
  only intended changes. Do not commit.
- `docs/PERFORMANCE_RULES.md` §7 asks for a TSan run after touching shared state. If you change anything
  concurrent, run `swift test --sanitize=thread --build-path .build-tsan ...` (the `.build-tsan` directory
  is git-ignored).

## Already done, do not redo

- Mitigation (two test files): `Umbra/Tests/UmbraTests/Support/TestPolling.swift` now makes
  `waitForCondition`'s timeout a 15 s floor (waits whose condition holds still return at once), and
  `IDEDiffTabTests` has a wider deallocation loop. This only reduces flakiness and explains nothing.
- Full TSan runs of the harness and structure suites were clean after the earlier folding-provider and
  structure-refresh fixes.

## Artifacts

This session's scratchpad: `/private/tmp/claude-501/-Users-alex-Developer-Penumbra/2f3c9ae5-a01a-4a9c-9f18-452f14acbf0e/scratchpad/`

- `diff-stall-sample.txt`: the third sample (layout-heavy)
- `probe-flush.log`, `probe-unresp.log`, `probe-full.log`: raw logs of the probe runs

The scratchpad is session-specific and may not be reachable from another session; the numbers above are
the part that matters.

## Deliverable

A short report: the cause (or the narrowed candidates with evidence), whether it is test-only or can affect
the app, how often it happens and under what conditions, and a recommendation (fix, a test-environment
change, or accept). State clearly what you measured and what you inferred.

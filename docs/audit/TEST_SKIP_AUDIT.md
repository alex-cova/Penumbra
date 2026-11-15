# Test skip audit

Measured on this machine on 2026-11-15, after `docs/audit/TEST_SUITE_STABILIZATION.md`. That audit left 64
skips (27 root with the two JaCoCo cases it then fixed, 37 Umbra). No commit was created.

Environment: macOS 27.2, Xcode 27.2, JDKs 21, 24, 25 (on `PATH`, the default) and 26, plus Temurin 27.0.0+35 installed with
SDKMAN for this audit (`sdk install java 27.0.0.0+35-tem`, not made the default); iOS 27.0 Simulator runtime;
`lldb-dap` from Xcode; node 22; no `mvn`; no js-debug.

## Result

| | Before (baseline this session) | After |
|---|---|---|
| Root | did not finish: hung in `JavaResolutionReadinessTests` (below) | 5410 tests, 21 skipped, 0 failures |
| Umbra | 3091 tests, 39 skipped, 2 failures (load-sensitive, below) | 3092 tests, 38 skipped, 0 failures; Swift Testing 3/3 |

Both final runs ran one after the other with the display on (`caffeinate -u -d -i -s swift test`), not in parallel.

## Defects found and fixed

### Call Hierarchy: callees and locations empty for methods in the open file (production)

`JavaCallHierarchyProvider` found the declaring file through a `JavaNavigationSession` built with the request
file's URL and **empty text**. For a class declared in that same file (the usual case: Call Hierarchy on a method
in the editor), `sourceFile(for:)` took its same-file shortcut and returned the empty text, so `callees(of:)` was
empty and `location(of:)` was nil for methods and fields. The three `JavaCallHierarchyTests` that skipped "when
the fixture lacks navigation sources" were skipping on this bug.

`declaringSource(for:preferred:…)` now gives the session the preferred file's real text (open buffer, else
disk) and returns the declaring URL with its text; callees resolve in the declaring file, and a method's
location selects its name, as a field's already did (the test is named for that). Regression tests: callees and
location asked from another file, and a location that follows an unsaved buffer over the disk.

- `Sources/JavaIntelligence/Hierarchy/JavaCallHierarchy.swift`
- `Tests/PenumbraTests/JavaIntelligence/JavaCallHierarchyTests.swift`

### Root suite hang in `JavaInspectionService.settle()` (test infrastructure, with a production leak)

`analyzeNow` cancelled a queued pass and cleared `pendingKey[url]` but left the task in `pending[url]`. The
cancelled task cannot release itself (release requires its key to still be current), so `pending` kept a
finished task and `settle()` (`while let task = pending.values.first { await task.value }`) spun at 100 % CPU
forever. `testRepeatedResolutionWhileSourcesChurn` re-queues straddled passes and hits this when timing allows;
the baseline root run hung there for 40 minutes. In the app the stale entry was replaced by the next schedule.

`analyzeNow` now drops the task it cancels, and `settle()` drops a finished task that is still registered.
`testAnalyzeNowOverAQueuedPassLeavesNothingRegistered` is deterministic (a 60 s idle delay, then `analyzeNow`)
and failed on the old code with one leaked entry; it guards against hanging when the bug returns. The churn
test then passed 8 times in a row.

- `Sources/JavaIntelligence/Inspections/JavaInspectionService.swift`
- `Tests/PenumbraTests/JavaIntelligence/JavaResolutionReadinessTests.swift`

### Tests read the user's Application Support (isolation)

`IDEWorkspace` built `IDEDatabaseSupport()` on the shared catalog in
`~/Library/Application Support/com.umbra.editor`, so the two console tests each skipped depending on whether the
developer had saved data sources. Every other shared store (Gradle/Maven/npm/SwiftPM/Xcode trust, JDK selection,
run configurations, breakpoints, bookmarks) was read from there too by any test that made a workspace.

- `IDEWorkspace.init(databaseSupport:)` (the public `init()` is unchanged) lets a test pass its own catalog;
  both console tests now use a scratch catalog and assert instead of skipping.
- Under XCTest, `IDESharedServices` keeps every shared store in a per-process temporary directory
  (`testStoreDirectory`, detected the way `IDEAlert` already does). A real Umbra process is unchanged.
  `testTheDefaultCatalogIsNotTheUsersFileUnderXCTest` pins it.
- `JavaCompletionQualityHarness` read synced Gradle models of private projects from Application Support by
  default; it now reads them only from `JAVA_QUALITY_GRADLE_MODELS`.

## Previously skipped tests

### Now run and pass in the default suite

| Test | Why it skipped | Now |
|---|---|---|
| `JavaCallHierarchyTests.testCalleesListDirectInvocationsFromTheMethodBody` | callee bug above | passes |
| `JavaCallHierarchyTests.testAFieldLocationSelectsItsName` | location bug above | passes |
| `JavaCallHierarchyTests.testLocationSelectsTheDeclaringMethodName` | location bug above | passes |
| `IDEDatabaseTests.testNewQueryConsoleFromWelcomeBindsTheFirstDataSource` | needed saved data sources | passes, isolated catalog |
| `IDEDatabaseTests.testNewQueryConsoleWithoutDataSourcesOpensTheConnectionSheet` | needed none saved | passes, isolated catalog |

### Removed

`ThrowawayUnresolvedMemberSweepTests.testSweep` (`UMBRA_JDK_HOME`): its header said "THROWAWAY … Not committed";
it printed a sweep and asserted nothing. No other test used it.

### Opt-in, run in this session

| Gate | Tests | Result |
|---|---|---|
| `JAVA_PARITY=1` | `JavaParityCorpusTests.testParityScorecard` | pass on JDK 25 and 27; scorecard identical to `docs/JAVA_PARITY.md`, 0 valid-corpus false positives |
| `JAVA_DIFFERENTIAL=1` | `testPinnedProjectsHoldTheBaseline` | skips on JDK 25 by design (baseline is JDK 27); with `JAVA_HOME` on JDK 27: **pass**, no difference from `baseline.json` |
| `JAVA_DIFFERENTIAL_REPORT=1` | `testSliceReportPrintsRankBucketsPerRole` | pass |
| `JAVA_QUALITY=1` | `testQualityBaseline` (development set) | pass; R@1 54.1 %, R@3 79.8 %, R@8 91.0 %, MRR 0.683, 0/1766 bad insertions, 0/281 invalid candidates; documented "after, no statistics" is 53.7 / 79.3 / 90.6 / 0.679 |
| `JAVA_AUDIT=1` | `testAuditReceiverTypesAgainstJavac` | pass (report only) |
| `UMBRA_UI_TESTS=1` | `IDEViewFocusTests` (5), `IDERootViewInvalidationTests` (3), `IDEHostedWindowRetentionTests` (1) | all pass |
| `UMBRA_LLDB_DAP=1` | `DAPDebugSessionTests`, `LLDBDAPSpikeTests` | both pass |
| `UMBRA_JS_DEBUG=1` | `JSDebugSessionTests` | skipped: no js-debug server (environment) |
| `UMBRA_PREVIEW_INTEGRATION=1` | `IDESwiftUIPreviewSessionTests` (10 gated) | all pass |
| `UMBRA_PREVIEW_INTEGRATION=1` | root `SwiftPreviewPipelineIntegrationTests` (4) | all pass |
| `UMBRA_PREVIEW_INTEGRATION=1` | `IDESimulatorServiceTests` (6 gated) | 4 pass, **2 fail** (below) |

### JDK 27

With `JAVA_HOME` set to the SDKMAN Temurin 27:

- The differential baseline passes. Parity is unchanged. Development-set quality is identical to the JDK 25 run to the digit.
- The real-JDK root tests pass: `JavaPlatformReleaseDifferentialTests`, `JavaImportDifferentialTests`,
  `JavaCompilerDiagnosticsRealJDKTests`, `JavaCompletionProviderRealJDKTests` and `JavaInstrumentationRealJDKTests`,
  16 tests in all. One skips by design: `testCoverageOfAPlainMainEndToEnd`, because JaCoCo 0.8.15 supports up to Java 26
  and the product's `unsupportedLanguageLevel` message is what the test reports.
- The Umbra Java integration tests pass, 108 tests with 5 skipped (local models, packaged app). They cover Gradle,
  Maven, run, instrumented run, the debug adapter and console, evaluate, platform release and resolution.

### Actual failures (not environment), left failing

Both reproduce in isolation on an idle machine.

- **`testTapsScrollsAndTypingReachTheAppOnARealSimulator`.** This was the first run on a device (the preview notes
  said "built, not yet run on a device"). Taps, the toggle, the sheet and its button, typing and delete,
  the slider, stepper increment, tab switching, the menu, the swipe action, pull-to-refresh and wheel scrolling
  pass. These fail:
  - Stepper decrement. The test taps `maxX - 99`, a fixed offset from the row's trailing edge, which may miss the
    iOS 27 stepper's minus half.
  - Drag to scroll: the row moved by less than 150 pt.
  - The tap on a row that scrolled into view, which depends on the drag.
  - The NavigationLink push, after scrolling back to the top: `pushed` stays 0.

  The drag and push failures are in the iOS host's input routing.
- **`testTwoSessionsOfOneProjectKeepTheirOwnHosts`.** After the second session's app launches on the same device, the
  first session's reload compiles and links its thunk but stays `building("Reloading…")` for 120 s. Unverified
  hypothesis: both sessions share one simulator device, and launching the second app backgrounds and suspends
  the first. The failure message now carries the session log.

### Load-sensitive, not changed

`IDEHostEditCostTests.testTypingWithTheStructureTab{Hidden,Showing}` failed in the baseline (19 and 11 parses
against bounds of 6 and 7). That run shared the machine with the root suite, a second build and the quality
harness. Alone, twice: 5 and 4 parses. Slow keystrokes let more settle pauses fire, so these bounds hold only
on a machine that is not saturated. The bounds were not raised.

### Remaining skips, all intentional

Root, 21:

| Count | Gate | Why it stays out of the default run |
|---|---|---|
| 7 | `SWIFT_PARITY=1` | real `sourcekit-lsp`; report |
| 4 | `UMBRA_PREVIEW_INTEGRATION=1` | real builds (passed when run) |
| 2 | `JAVA_DIFFERENTIAL`, `JAVA_DIFFERENTIAL_REPORT` | network clone; baseline needs JDK 27 (`JAVA_HOME`) |
| 1 each | `JAVA_QUALITY`, `JAVA_PARITY`, `JAVA_AUDIT` | network or minutes of javac; reports |
| 1 | `mvn is not installed` | conformance against the real Maven CLI |
| 1 each | `PENUMBRA_HIGHLIGHT_STRESS`, `LARGE_FILE_MEASURE_MB` | stress and measurement |
| 1 each | `SWIFT_INSPECTION_APPLY_FIXES_TO`, `SWIFT_REFACTOR_APPLY_TO` | tools that write a repo copy |

Umbra, 38: 16 `UMBRA_PREVIEW_INTEGRATION`, 9 `UMBRA_UI_TESTS`, 4 `UMBRA_AGENT_OLLAMA_MODEL`, 1
`UMBRA_AGENT_MLX_MODEL`, 2 `UMBRA_LIVE_ACP` (paid), 2 `UMBRA_LLDB_DAP`, 1 `UMBRA_JS_DEBUG`, 1
`UMBRA_PREVIEW_IOS_PROJECT`, 1 `UMBRA_PACKAGED_APP`, 1 `UMBRA_TEMPLATE_SAMPLES`. The suites, what they need
and what they cost are listed in `docs/CI.md`, "Opt-in suites".

## Skip messages and machine paths

- `ExternalACPLiveTests` hardcoded `/Users/alex/.local/bin/claude` and `/opt/homebrew/bin/codex` and skipped with
  no reason. The CLIs now come from `UMBRA_LIVE_ACP_CODEX` / `UMBRA_LIVE_ACP_CLAUDE` or `PATH`, the adapter prefix
  from `UMBRA_LIVE_ACP_PREFIX`, and every skip says what is missing.
- `JSDebugSessionTests` now says whether `UMBRA_JS_DEBUG_PATH` or node is missing.
- The 23 `git`-presence guards carried no message; they now name the git path.
- A personal home path in two pure-string tests became `/Users/dev`.

## Default suite versus separate jobs

- **Moved into the default suite:** the call hierarchy and database tests above. They are deterministic and fast.
- **Candidate, not moved:** the `UMBRA_UI_TESTS` group took about 30 s and was deterministic here, but it needs an
  Aqua session. Whether the hosted `xcode-27` runner has one is unverified (`docs/CI.md`). Make it a default
  when the GUI job is proven, or run it in that job.
- **Separate jobs:** preview and simulator integration (minutes, real builds, devices), lldb-dap and js-debug
  (external tools), the Java parity, differential, quality and audit harnesses (network, javac, JDK-specific
  baselines), and the agent and ACP tests (models, paid accounts).

## Commands

```bash
caffeinate -u -d -i -s swift test                                    # root: 5410, 21 skipped, 0 failures
caffeinate -u -d -i -s swift test --package-path Umbra               # Umbra: 3092, 38 skipped, 0 failures
JAVA_PARITY=1 swift test --filter JavaParityCorpusTests
JAVA_HOME=~/.sdkman/candidates/java/27.0.0.0+35-tem JAVA_DIFFERENTIAL=1 swift test --filter testPinnedProjectsHoldTheBaseline
JAVA_QUALITY=1 swift test --filter JavaCompletionQualityTests/testQualityBaseline
UMBRA_UI_TESTS=1 UMBRA_LLDB_DAP=1 UMBRA_JS_DEBUG=1 caffeinate -u -d -i -s swift test --package-path Umbra \
  --filter 'IDEHostedWindowRetentionTests|IDEViewFocusTests|IDERootViewInvalidationTests|DAPDebugSessionTests|LLDBDAPSpikeTests|JSDebugSessionTests'
UMBRA_PREVIEW_INTEGRATION=1 caffeinate -u -d -i -s swift test --package-path Umbra --filter 'IDESwiftUIPreviewSessionTests|IDESimulatorServiceTests'
UMBRA_PREVIEW_INTEGRATION=1 caffeinate -u -d -i -s swift test --filter SwiftPreviewPipelineIntegrationTests
```

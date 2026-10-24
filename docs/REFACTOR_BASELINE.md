# Refactor baseline

Measured 2026-10-24 on the parent state of the Umbra architecture refactor (plan: Phase 0). Compare every phase against this.

## Tests

`caffeinate -u -d -i -s swift test` (display on): 6,756 XCTest cases, 40 skipped, about 13 minutes. Swift Testing: 21 tests in 7 suites.

Needs the JaCoCo jars: run `Example/Umbra/Tools/JaCoCo/fetch.sh` once (git-ignored `build/`). Without them six coverage tests fail with `notBundled`.

Flaky tests found and fixed while taking this baseline (all passed alone, failed under load or crashed the run):

| Test | Cause | Fix |
|---|---|---|
| `IDEAgentNotificationTests` (3) | waited for `!isRunning`, notification came after | wait for the notification |
| `IDEAgentApprovalFlowTests`, `IDEAgentPlanFlowTests`, `IDEAgentRevertAfterRelaunchTests`, `IDEAgentSessionsTests`, `IDEAgentTabsTests` | `IDEAgentConversation.consume()` set `isRunning = false` and then suspended before saving, flagging unread and notifying | `consume()` reads the session first; nothing after `isRunning = false` suspends. The approval test also waits for its status text |
| `CompletionEngineTests.testPrimaryProviderSuppressesFallbackResults` | `CompletionEngine` could yield a stale snapshot after a newer one | snapshots are versioned; a stale one is dropped |
| `ViewportParseTests`, `TextViewStateParsePolicyTests`, `TreeSitterParseSchedulingTests` | `expectation.fulfill()` from a callback that fires on every parse aborted the test process | `assertForOverFulfill = false` |
| `TextViewLineHeightEstimateTests.testChangingMultiplierMovesLinesNotYetLaidOut` | fixed 50 ms wait for the next run-loop turn | poll up to 5 s |

## Editor performance

`swift run -c release PerfHarness enter-session synthetic --lines N` (medians, Enter latency):

| Case | 20,000 lines | 120,000 lines |
|---|---|---|
| fresh, caret at top | 1.83 ms | 1.86 ms |
| fresh, middle | 2.48 ms | 2.62 ms |
| walked, top | 1.93 ms | 2.07 ms |
| walked, middle | 2.74 ms | 2.85 ms |
| walked, end | 2.83 ms | 2.90 ms |
| with line markers, middle | 2.79 ms | 2.96 ms |
| scroll page | 6.3 ms | 6.5 ms |
| select all occurrences | 62 ms (6,336) | 1,116 ms (37,896) |
| live line handles after scrolling the whole file | 573 | 574 |

Pass criterion for later phases: Enter medians within ±5 % and live handle counts unchanged.

## Build

`swift build` (incremental, warm): 32 s. A clean release build time was not taken.

## Size

`Example/Umbra`: 489 files, about 118k lines. `IDEWorkspace.swift`: 7,090 lines. `IDEAgentPanel.swift`: 1,700 lines.

## End state (after plan phases 1-8)

Measured on the same machine against the targets in the plan. Full suite: 6,787 tests, 40 skipped, 0 failures
(baseline 6,756).

| Metric | Baseline | Now | Target | |
|---|---|---|---|---|
| `IDEWorkspace.swift` lines | 7,090 | 5,995 | ≤ 3,000 | not met |
| Swift files at the root of `Example/Umbra` | 139 | 0 | (folders) | met |
| `NSAlert()` outside `IDEAlert` | 28 | 0 | ≤ 3 | met |
| Largest agent UI file (excluding the conversation model) | 1,700 | 439 | ≤ 600 | met |
| Icon-button implementations | 7+ | 1 shared, 47 uses (+ titlebar and browser-toolbar buttons left) | 1 | mostly |
| Project console controls | 5 | 1 shared (+ HTTP's own) | 1 | met |
| Project-system tabs | 5 copies | 1 shared on `IDEChromeTabItem` | 1 | met |
| All `…TabItem` structs | ~20 | 17 | 1 + wrappers | not met: the panel tabs have badges and menus and were left alone |
| Inline `Task.sleep` | 59 | 52 (9 debounces moved to `Debouncer`) | ≤ 15 | not met: the rest are polling loops and delays, not debounces |
| Literal `.font(.system(size:))` / `.padding(N)` / `cornerRadius:` | 136 / 234 / 49 | 130 / 220 / 47 | < 40 / < 100 / < 10 | not met: not worked on |
| `UserDefaults.standard` in `IDEPreferences.swift` | 141 | 141 | ≤ 20 | dropped: `@Observable` cannot use property wrappers |
| Conversation event handlers | 2 | 2 | 1 | dropped: the overlap is about 40 lines; the copy and events differ on purpose |
| Enter latency (PerfHarness) | baseline | within noise | ±5 % | met (PerfHarness does not link Umbra) |

New tested units: `Debouncer`, `IDEFindInFilesModel`, `IDEBottomPanelModel`, `IDEEditorOverlayController`, the
preferences snapshot contract (nine required keys pinned).

Lessons worth keeping:

- A path built from `#filePath` breaks when its file moves. The debug adapter and analysis server jars were found
  that way; the move silently skipped 36 tests. Development paths now come from `IDEDevelopmentPaths.sourceRoot`.
- A test that waits for `!isRunning` and then reads state saved or announced after it is racing; fix the order in the
  code (nothing after the flip suspends) or wait for the thing itself.
- Compare the skipped-test count, not only the failure count, after a mechanical move.

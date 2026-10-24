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

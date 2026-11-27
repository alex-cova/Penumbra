# Umbra inlay hints handoff

Continue in `/Users/alex/Developer/Penumbra` on the existing working tree. Preserve the uncommitted changes and do not create Git commits. The baseline revision was `b391f59311efe45ffde4c1372ccfe64ab0037543`.

Read the [original implementation plan](UMBRA_INLAY_HINTS_IMPLEMENTATION_PLAN.md), [verification report](FINAL_VERIFICATION.md), and [performance baseline](PERFORMANCE_BASELINE.md). The report predates the optimized benchmark results. Release gates remain open.

## 1. Re-establish test status

The final root and Umbra test launch was interrupted. Check for running SwiftPM processes before starting another build.

```sh
git status --short --untracked-files=all
git diff --check
caffeinate -u -d -i -s swift test --filter 'InlayHint|CodeVision|LSPFakeServer|LSPPublishedDiagnostics|JavaVersionDeclaration'
caffeinate -u -d -i -s swift test
caffeinate -u -d -i -s swift test --package-path Umbra
```

- The baseline passed with 5,727 root XCTest cases and 26 skips, and 3,585 Umbra XCTest cases and 100 skips. Both had zero failures.
- The Settings sidebar-order regression was fixed by moving Inlay Hints into an Editor subpage. A subsequent full Umbra run passed.
- The LSP display-equality regression was fixed and the focused rerun passed 86 cases. A later cancellation test hit a Swift 6 compile error because its task captured the fixture. The code now captures the client separately. Verify that correction and the new stale-publication and explicit-edit tests.
- A later Umbra run failed once in `IDEACPNativeProviderConversationTests.testTodaysCursorAntigravityAndCopilotHandshakesFillThePicker` with `[]` versus `["allow_all"]`. Baseline and an earlier full run passed. Reproduce it in isolation before assigning a cause.

## 2. Address the measured performance gaps

- **Native Java at 120k lines.** The optimized Release run returned 162 hints, with warm p95 of **907 ms** against a **20 ms** budget. The 9.25 MB fixture exceeds the 8 MiB per-entry cap in [JavaParseMemo.swift](../../Sources/JavaIntelligence/Syntax/JavaParseMemo.swift). Instrument parse and stub-build counts first. If the measurements confirm repeated parsing, reuse a revision-scoped syntax snapshot or another bounded existing cache. Verify memory alongside latency before changing the cap.
- **Enter with inlays.** The edited-row refresh and bounded width cache in [LayoutManager.swift](../../Sources/Penumbra/TextView/Core/LayoutManager.swift) reduced mid-file line-handle shift visits from **220–266 to 1**. The optimized hint-on p95 still exceeded the **0.5 ms additional latency** budget at **1k, 20k, and 120k lines**. Compare paint counters next. Hint-on runs showed about 20 decoration builds per Enter versus 2 with hints off.

```sh
caffeinate -u -d -i -s swift build -c release --product PerfHarness
.build/release/PerfHarness java-inlay synthetic --lines 120000 --samples 30
caffeinate -u -d -i -s .build/release/PerfHarness enter-session synthetic --lines 120000 --samples 40
PENUMBRA_INLAY_HINTS=180 caffeinate -u -d -i -s .build/release/PerfHarness enter-session synthetic --lines 120000 --samples 40
```

The optimized logs are `/tmp/penumbra-inlay-optimized-{off,on,native}-perf.log`. The earlier comparison is `/tmp/penumbra-inlay-final-{off,on,native}-perf.log`. For fresh comparisons, alternate hint-off and hint-on runs across the planned sizes and keep full-suite load out of the measurement window.

## 3. Finish the remaining production scope

Use the verification report’s phase table as the checklist. The largest gaps are general below-line and line-start placement with renderer parity, batched Code Vision and LSP Code Lens, non-UTF-16 LSP encoding and part-level actions, the trusted JDK downloader and installer, and end-to-end accessibility and performance verification. Native Java also needs coverage for the remaining semantic categories and a hint-specific javac differential matrix.

Reuse the existing layout and provider paths. Java hints use the shared parse memo. Both renderers share chip geometry. LSP inlay cancellation and refresh use the existing framed connection. SDK configuration currently handles local project JDK selection through existing controls.

Update [FINAL_VERIFICATION.md](FINAL_VERIFICATION.md) with exact commands, results, skips, benchmark deltas, and open release gates.

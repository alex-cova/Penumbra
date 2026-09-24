# Editor responsiveness

Release measurements from `PerfHarness keystroke` on 24 September 2026. The fixture is generated inside the harness: 80 lines (2,417 bytes) and 24,000 lines (784,930 bytes). Numbers below are seconds from that log unless noted. Debug XCTest timings are not used as budgets.

## Executive Summary

A plain keystroke was already a few milliseconds. Text mutation itself was about 0.021 ms. What scaled with buffer size was starting code intelligence: on the 785 KB untitled piece-tree buffer, building the live completion document copied the whole buffer on the main thread before `insertText` returned. That prepare step was 3.43 ms median (3.52 ms p95) and made a keystroke with completion attached 6.04 ms median, against 0.93 ms for the same insert with no intelligence controller.

That copy is gone. Completion now reads a piece-tree snapshot whenever one exists, including untitled buffers. The same stage is 0.016 ms median (0.018 ms p95) afterward, and the large intelligence keystroke is 2.89 ms median. No measured single-character mutation or visible update reached a 1 second stall. Typing while an index loop ran stayed in the same few-millisecond band as an idle large insert.

## Critical Path

```text
keyDown / insertText
    → TextInputView.replaceText
        → undo registration
        → caret / selection
        → piece-tree mutation
        → incremental parse (languageMode.textDidChange)
        → visible line redisplay
    → layoutSubviews
    → typing observer
        → completion request scheduled
        → diagnostics refresh scheduled from the debounced document event
```

The document, caret, undo group, and visible layout update finish inside `replaceText` and the layout pass that follows it. Completion ranking and diagnostics run in tasks started after that update. A provider that blocks until cancelled does not hold the keystroke; a superseded completion or diagnostics result does not change the document or the presented popup.

## Measured Bottlenecks

One row. It is the only stage whose main-thread cost grew with the buffer and sat on the keystroke. Latencies are the baseline capture, before the fix.

Subsystem: `EditorIntelligenceController.buildLiveDocument`

Operation: completion prepare while typing in a large untitled piece-tree buffer (`stage completion_prepare large`)

Current latency: median 0.003429792 s

P95 latency: 0.003520875 s

CPU cost: the stage runs on the main thread, so its CPU time tracks that wall time. A separate 20-insert batch on the small buffer cost 0.087588000 s of thread CPU across 0.087643458 s of wall time (`cpu typing_batch_wall_s` / `typing_batch_cpu_s` in the baseline log).

Memory cost: the baseline typing burst of 40 inserts moved the malloc zone by 36,144 bytes and RSS by 49,152 bytes (`allocation_delta_bytes=36144`, `rss_delta_bytes=49152`). The prepare path did not retain that memory after the keystroke; the cost was the synchronous copy of the 784,930-byte buffer.

Main-thread cost: median 0.003429792 s, p95 0.003520875 s, inside `insertText`, before it returned. The enclosing large intelligence keystroke was median 0.006041416 s, p95 0.006278625 s.

Frequency: once per identifier insertion when a completion controller is attached. The baseline recorded 8 samples on the large buffer.

Root cause: `buildLiveDocument` called `textView.text` unless `isFileBacked` was true. Untitled buffers past 256 KB are piece trees and are not file-backed, so every completion request materialized the tree on the main thread.

Potential solution: take `pieceTreeContentSnapshot()` whenever the buffer has one, and pass a ranged reader. Keep the contiguous-string path for small buffers.

Expected impact: large completion prepare drops from about 3.4 ms to well under 0.1 ms, and the large intelligence keystroke drops by roughly that amount. Plain mutation, parse, and layout stay as they were.

Other measured stages were inside the suggested budgets and were not changed. The largest remaining main-thread slice on an idle small insert is the visible update (median 0.002258250 s of a 0.002289916 s keystroke), still under 16 ms.

## Top Priority

Stop materializing the piece tree when a keystroke starts completion. That was the highest main-thread cost that grew with the document, and it ran before `insertText` returned. Tree-sitter, Metal, text storage, and Java resolution were not the measured bottleneck.

## Phase 1 — Immediate Improvements

Shipped. `buildLiveDocument` uses a piece-tree reader for every piece-tree buffer, not only file-backed ones. A large untitled keystroke still delivers the typed character to the completion provider, and `pieceTreeMaterializeCount` does not increase.

Release remeasure of `completion_prepare large`:

| Run | Median | P95 |
| --- | ---: | ---: |
| Baseline | 0.003429792 s | 0.003520875 s |
| After 1 | 0.000016292 s | 0.000017500 s |
| After 2 | 0.000017125 s | 0.000021542 s |

`typing_with_intelligence large` moved with it: baseline median 0.006041416 s / p95 0.006278625 s, after 1 median 0.002893333 s / p95 0.002978000 s, after 2 median 0.003032000 s / p95 0.003373209 s.

## Phase 2 — Editing Pipeline

Not this change. Plain text mutation is median 0.000021375 s (baseline small). Caret movement is median 0.000001000 s. Visible update on the small idle insert is median 0.002258250 s, p95 0.004033626 s, and it accounts for almost all of that keystroke. Incremental parse on a ready JavaScript tree (80 lines, `syntax tree ready=true`) is median 0.000165667 s.

The 24,000-line highlighted buffer reported `syntax tree ready=false`. Its incremental-parse samples (median 0.000001875 s) are the early return when no tree is installed, not a measured edit of a large tree. Forcing that tree onto the keystroke was not the bottleneck.

## Phase 3 — Code Intelligence

Completion, diagnostics, and index queries already run off the returned keystroke. Baseline, off the keystroke:

| Stage | Median | P95 | Worst |
| --- | ---: | ---: | ---: |
| Local completion | 0.000045625 s | 0.000114833 s | 0.000114833 s |
| Indexed completion | 0.004068750 s | 0.004732000 s | 0.004732000 s |
| Duplicate-symbol diagnostics | 0.000205500 s | 0.000400041 s | 0.000400041 s |
| Index prefix query | 0.000223417 s | 0.000234083 s | 0.000234833 s |

Semantic completion (Java resolution) was not in this harness (`note semantic_completion not_measured reason=java_provider_not_in_harness`). Indexed completion at about 4 ms is the next intelligence cost if a later profile puts it on the main thread. It did not in this capture.

Typing while a background indexer rebuilt 1,500 symbols in a loop: small median 0.004591542 s, large median 0.000998458 s. Neither is a multi-second stall. Large idle insert median was 0.000931000 s.

## Phase 4 — Large Project Scalability

Deferred. The 785 KB generated buffer did not make idle typing slower than the small buffer (large insert median 0.000931000 s, small 0.002289916 s). A real multi-module Gradle tree was not loaded. Persistent indexes and incremental project analysis stay as they are until a capture shows them on the keystroke or missing a navigation budget.

## Phase 5 — IntelliJ-Class Polish

Deferred. Prefetch, speculative completion, and further cache work are not justified by this capture. The budgets that were measured already pass. The open item is the visible-update slice of a plain keystroke, which is under 16 ms and was not the size-dependent spike.

## Benchmarks

Harness: release `PerfHarness keystroke <fixture> --at middle --samples 1`. The profile adds the stage rows; the fixture file itself is only the legacy one-sample row.

Suggested budgets against the baseline release medians:

| Budget | Target | Baseline median | Result |
| --- | ---: | ---: | --- |
| Text mutation | 0.001 s | 0.000021375 s | pass |
| Cursor movement | 0.001 s | 0.000001000 s | pass |
| Incremental parse (typical, ready tree) | 0.005 s | 0.000165667 s | pass |
| Visible update | 0.016 s | 0.002258250 s | pass |
| Local completion | 0.030 s | 0.000045625 s | pass |
| Indexed completion | 0.050 s | 0.004068750 s | pass |
| Indexed navigation (prefix query) | 0.050 s | 0.000223417 s | pass |
| Diagnostics | 0.100 s | 0.000205500 s | pass |
| Semantic completion | 0.100 s | not measured | not measured |

After the fix, the same budget rows still pass (after run 1: text mutation 0.000021334 s, visible update 0.002193999 s, incremental parse 0.000171042 s, local completion 0.000046542 s, indexed completion 0.004381542 s, index query 0.000226500 s, diagnostics 0.000208792 s).

Frame presentation succeeded in this environment. Baseline presented-frame time 0.000778666 s, 0 dropped frames. After run 1: 0.000805834 s, 0 dropped frames. No launcher failure.

Worst single-character samples in the baseline stayed under 0.01 s (`freeze_check result=pass`). Large idle insert worst was 0.000964917 s against a small idle worst of 0.004066042 s.

Editing operation medians, baseline, small then large:

| Operation | Small median | Large median |
| --- | ---: | ---: |
| Insert | 0.002289916 s | 0.000931000 s |
| Delete | 0.002288834 s | 0.001336959 s |
| Paste | 0.002852749 s | 0.000941125 s |
| Multi-cursor | 0.002669875 s | 0.001660042 s |
| Selection | 0.000001917 s | 0.000001542 s |
| Undo | 0.000129333 s | 0.000180625 s |
| Redo | 0.000120541 s | 0.000174000 s |
| Cursor movement | 0.000001000 s | 0.000000917 s |

## Risks

The visible-update pass is still most of a plain keystroke. It is under the 16 ms budget. Shrinking it means layout work, which this capture did not identify as the size-dependent stall.

The large highlighted parse was not a ready tree (`syntax tree ready=false` at 24,003 lines). A later profile that waits until that tree exists could show a higher incremental-parse number. It must not be assumed from the 0.002 ms early-return samples.

Indexed completion near 4 ms is off the keystroke. Moving that work back onto the main thread would undo the input-latency win.

Semantic Java completion was not timed here. If a future profile shows it running inside `insertText`, that becomes the next fix. It is not claimed to be under 100 ms.

The development dashboard is off unless `PENUMBRA_PERFORMANCE_DASHBOARD=1`. It writes a local file and does not open a network connection. Frame time in the readout is the presented Metal draw time when a window can present; a headless failure is logged as `frame_presentation launcher_failure` and is not filled in with a guessed frame time.

## Definition of Done

- A keystroke updates text, caret, undo, and the visible layout without waiting for a completion or diagnostics provider. Covered by `InteractivePathTests`.
- A superseded completion or diagnostics result does not change the document or the presented UI. Covered by the same tests.
- Release median and p95 of large `completion_prepare` are lower than the baseline (0.003429792 s / 0.003520875 s). After runs are 0.000016292 s / 0.000017500 s and 0.000017125 s / 0.000021542 s.
- Worst single-character mutation and visible update in the release log stay under 1 s, including typing while indexing. Both after runs print `freeze_check result=pass`.
- Large idle insert median stays in the same band as the small idle insert (0.000931000 s vs 0.002289916 s baseline; 0.000944500 s vs 0.002225458 s after). No multi-second large-buffer stall.
- The development readout is off by default and, when enabled, prints Frame, Text Mutation, Incremental Parse, Completion, Diagnostics, Index Query, Main Thread, Dropped Frames, and Memory with numeric values and no network call.

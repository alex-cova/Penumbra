# F10 — Metal/GPU blocking waits (non-default paths)

- **Priority:** P1 investigate · **Severity:** Medium · **Confidence:** Strongly suspected · **Provenance:** A+B (B ranked P0; A demoted after re-inspection)
- **Status:** ✅ Done as far as this hardware goes (2026-11-03): default path measured at zero waits; the real wait was the discrete-GPU atlas and is fixed, unverified on a discrete GPU · **Owner:** Unassigned

## Evidence

- `MetalRenderer` PageBucket/DecorationBuffer `advanceForWrite` (Sources/Penumbra/TextView/Metal/MetalRenderer.swift:71-87,199-215): `NSCondition.wait()` on `@MainActor` when all 3 triple-buffer slots are in flight.
- `MetalTextCanvasView.encodePass` waits `waitUntilScheduled` when not using deferred present; `GlyphAtlas` upload/clear waits `waitUntilCompleted` only off the unified-memory fast path (`texture.replace`).
- Corrections to the strong claim: `MetalDeferredPresent` defaults to `true`; the display-link path guards slot acquisition; unified-memory Macs bypass the staging wait. Six blocking sites exist (GlyphAtlas.swift:458,675,724; MetalTextCanvasView.swift:437,577,591) but caller frequency by default is unproven.

## Root cause

Synchronous present/upload paths fall back to blocking GPU waits instead of dropping or deferring the frame.

## Fix sketch

First measure: isolated discrete-GPU bench + scroll trace with existing `slotWait` / `waitUntilScheduled` signposts, deferred present ON (default). Only if waits fire by default: async blit budgeted into the 128-glyph raster pass, and make sync present check `canAcquireWriteSlots` like the deferred path.

## Complexity / Dependencies

S to measure; M to fix if confirmed. Requires discrete-GPU hardware for the worst case.

## Acceptance criteria

- A trace (default settings, cold scroll, large file) either shows zero blocking waits — close as non-issue — or quantifies them and the fix removes them from the frame path.

## Tests / benchmarks

- Metal System Trace + signposts; PerfHarness `scroll-frames` / `snapshot-metal`.

## Out of scope

Renderer rewrite; CG fallback changes.

## Implementation notes (2026-11-03)

- **Measured first.** `MetalWaitStats` (new, `@_spi(Benchmarks)`) wraps every blocking site and counts calls and time per site; `PerfHarness metal-waits` drives open and first paint, a 240-frame cold scroll at display pace, a 240-frame scroll with no pause between frames, 200 keystrokes at 60 Hz and 40 far jumps on a 20,000-line Java file (and a 6,000-line CJK file, 240,000 distinct glyphs). Apple M5 Max, release build, macOS 27.
- **Default path (deferred present on, unified memory): zero blocking waits in every phase**, on both files. The strong claim in the brief (slot waits on the main actor by default) does not hold: `handleDisplayLink` checks `canAcquireWriteSlots()` first and neither slot wait fired even in the no-pause scroll.
- **Deferred present off** (`--no-deferred`, the documented rollback): one `waitUntilScheduled` per presented frame, 0.07 to 0.17 ms on average (29 ms over 240 frames, max 1.8 ms). Left as is: it is the non-default rollback path and cheap here. `MetalWaitStats.presentScheduled` makes it visible if that changes.
- **The real wait: a non-unified atlas.** Simulated with `simulatesDiscreteGPUAtlas` (private storage, the old behavior). First paint: 188 blocking uploads and a page clear (37 ms). Typical Java scrolling adds none once the atlas is warm. CJK text: cold scroll 34,451 uploads, 5.57 s blocked, wall 12.35 s against 7.34 s on unified memory; scroll back 30,435 uploads and 4.26 s; far jumps 11,902 uploads and 1.82 s (max 8 ms in one wait). Each wait is a small blit through a staging buffer, so a discrete GPU, which also crosses PCIe, can only be worse.
- **Fix.** Without unified memory the atlas is `.managed` instead of `.private`, and `uploadPixels`/`clearTexture` are always `texture.replace`; the staging-buffer-and-blit branches are deleted. Same simulation after: zero waits in every phase, CJK cold scroll wall 7.09 s (unified: 7.34 s), scroll back 2.19 s (was 6.78), far jumps 2.59 s (was 3.37). `snapshot-metal synthetic` gives identical coverage, overlap and pixel difference with and without `--discrete-atlas`. Cost: a managed atlas keeps a CPU copy (up to the 32 MB LRU budget again) on machines that have a discrete GPU.
- **Tests.** `TextViewMetalSmokeTests.testDefaultPathNeverBlocksOnTheGPUWhileScrollingAndTyping` (scrolls and types in a Metal view with the shipping settings, asserts the wait table is empty; flipping `MetalDeferredPresent.defaultPropertyValue` to false fails it with 80 `presentScheduled` waits). `GlyphAtlasTests.testHasUnifiedMemoryStorageModeBranch` now pins `.managed`, asserts an upload records no wait, and that managed and shared read back the same pixels.
- **Not verified:** nothing here ran on a discrete GPU or an Intel Mac (Metal reports `.managed` as shared-like on Apple silicon, so the managed branch is exercised but not the path where CPU and GPU copies are separate); that is the one thing the brief's acceptance criteria asked for that this machine cannot give. A Metal System Trace was not taken, because the signpost-and-timer table answers the question (is the main thread ever blocked) directly. The five other blocking sites (atlas and snapshot readbacks, the render-failure present) are test/snapshot or failure paths and unchanged.

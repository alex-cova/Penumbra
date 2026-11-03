# F10 — Metal/GPU blocking waits (non-default paths)

- **Priority:** P1 investigate · **Severity:** Medium · **Confidence:** Strongly suspected · **Provenance:** A+B (B ranked P0; A demoted after re-inspection)
- **Status:** Open · **Owner:** Unassigned

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

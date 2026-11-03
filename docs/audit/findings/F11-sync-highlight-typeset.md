# F11 — Synchronous highlight/typeset on edited lines; long-token typesetter

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed, narrower than first reported · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Edited visible lines highlight synchronously on the main thread (`LineController.updateSyntaxHighlightingIfNecessary`, LayoutManager highlightAsynchronously=!recentlyEdited); large byte ranges force async. Async completions re-typeset and re-extract glyphs, coalesced into one present.
- `LineTypesetter.makeNextLineFragment:175-184` decrements length by 1 and recreates a `CTLine` until it fits. Normal suggested line breaks take one iteration — the quadratic case is only long unbreakable tokens (no-wrap width 10,000).
- By default the keystroke tree-sitter parse itself is deferred (`PenumbraSyncKeystrokeParse` default false); sync parse with its 50 ms abort is an opt-in flag, not the default path.

## Root cause

Edited-line freshness is prioritized over frame budget; the typesetter search is linear instead of binary.

## Fix sketch

Binary-search the fitting length in the typesetter loop. Add a time budget to sync highlight with async fallback (the range-size force-async is the existing precedent). Measure before changing edited-line sync policy.

## Complexity / Dependencies

M (S for the typesetter search alone).

## Acceptance criteria

- Long-unbreakable-token fixture (e.g. 10k-char line) typesets without per-char CTLine creation; profiling shows the loop gone.
- No visible highlight flicker regression on edited lines.

## Tests / benchmarks

- Time Profiler on the long-token fixture; existing highlight consistency tests (display on).

## Out of scope

Changing the deferred-parse default; highlight query redesign.

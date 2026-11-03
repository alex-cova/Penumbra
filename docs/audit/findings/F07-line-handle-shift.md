# F07 — Line-handle shifting O(H) per line, O(N·H) per paste

- **Priority:** P1 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `LineManager.shiftHandlesAfterInsert/AfterRemoval` (Sources/Penumbra/TextView/Core/LineManager.swift:535-551) iterate all `handles.values` per inserted/removed line (`insertLine:513`, `finishRemoveAcrossLines:444`).
- Handles pruned at a 4,096 cap (`line(atRow:):344`, threshold doubling), so pasting N lines into a visited document costs `O(N × min(visited, 4096))`. Instrumentation exists: `handleShiftVisits` (LineManager.swift:149-156).
- Plain character inserts do not shift: `setLength` only. Enter and multi-line paste/delete pay it.

## Root cause

Handles store absolute rows and are eagerly renumbered on every line-count change.

## Fix sketch

Lazy row offsets: store handles against a line identity / generation offset resolved on read, or shift via a pending-delta applied on access. Keep the public handle API and eviction semantics.

## Complexity / Dependencies

L. Touches LineManager internals; read `Sources/Penumbra/CLAUDE.md` handle/eviction rules first.

## Acceptance criteria

- `handleShiftVisits` per pasted line is O(1)-ish; 5,000-line paste profile flat vs handle count.
- `docs/PERFORMANCE_RULES.md` handle rules (read via `lineID(atRow:)` etc.) still hold; existing LineManager tests pass.

## Tests / benchmarks

- PerfHarness enter-session (reports shift visits per Enter) at 20k/120k.
- Unit test: paste N lines with H live handles, assert visit counter.

## Out of scope

Removing the handle API; changing eviction policy without measurement.

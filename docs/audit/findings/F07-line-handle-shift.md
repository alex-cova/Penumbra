# F07 — Line-handle shifting O(H) per line, O(N·H) per paste

- **Priority:** P1 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

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

## Implementation notes

2026-11-03. Handle rows are resolved lazily instead of renumbered. `LineManager.shiftHandlesAfterInsert/AfterRemoval` now only bump `rowVersion`. A `DocumentLineNode` caches `(row, version)` and, when it is read after an edit, resolves its row from its stable id: `PackedLineIndex` keeps `id -> leaf` for lines that have a handle (never one entry per line), and the row is the leaf's first-line index (a walk up the tree) plus the line's slot in the leaf. Public handle API and eviction are unchanged; a held handle still always names its line's current row; a removed line's handle keeps its last row; the node reads through a weak reference, so a handle that outlives its manager still answers.

- **Paired measurement** (`enter-session synthetic`, Release, display on, parent commit built in its own build path and run back to back; the parent was given the same paste stage). A 5,000-line paste in the middle with 813 live handles:

  | | parent | now |
  |---|---|---|
  | handle visits | 16,552,047 | 9,999 (about 2 per pasted line) |
  | time, 20,000-line file | 56.5 / 57.0 ms | 46.1 / 46.8 ms |
  | time, 120,000-line file | 59.2 ms | 49.7 ms |

  Shift visits per Enter fall from 190–805 (the number of live handles) to 1. Enter latency is unchanged (1.20–1.23 ms both ways), as are scroll page and step. The renumbering was a real O(lines x handles) cost, but not most of the paste: about 10 ms of 57 ms. The rest is text insertion, line scanning and layout, which this finding did not claim.
- **What `handleShiftVisits` means now:** handle rows resolved from the line index, not handles walked; the harness still prints it as `shiftVisits`.
- **Tests.** `LineManagerTests.testHeldHandlesKeepTheirRowsThroughRandomInsertsAndRemovals` (a seeded run of 400 inserts of up to 150 lines and removals of up to 120, so leaves split and empty, with ~215 held handles checked against the index every five steps; fails if the leaf-split registry update is skipped), `testPastingLinesDoesNotWalkTheLiveHandles` (the same 500-line paste with 10 and with 3,000 live handles does identical work, under four resolutions per line; fails with 1.6 million visits if the walk returns) and `testAHandleOutlivingItsManagerKeepsItsLastRow`. The existing held-handle, pruning and longest-line tests pass unchanged, as does the full suite.
- **Trade-off.** A handle's first row read after an edit costs O(tree height + 64) instead of O(1). Every consumer already followed a row read with an O(log n) lookup (`location`, `yPosition`, `next`, `previous`), and only handles that are read pay.
- **Docs updated:** `docs/PERFORMANCE_RULES.md` section 2 and the `LineManager` paragraph in `Sources/Penumbra/CLAUDE.md` described the old per-edit walk.

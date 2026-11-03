# F04 — Sequential typing rescans up to 64 KiB per keystroke

- **Priority:** P0 · **Severity:** High · **Confidence:** Confirmed algorithm, Requires-measurement duration · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `PieceTree.insertSmall` (Sources/Penumbra/TextView/Core/PieceTree.swift:777-795): the extendable tail fast path appends, then reassigns `checkpoints(for:)` at :790, rescanning the whole extended piece via `UTF8DocumentScanner.scan`.
- Pieces cap at `checkpointStride = 64 KiB`, so per-keystroke rescan grows 0→64 KiB per piece (~32 KiB average while a piece fills). Add-piece checkpoint spacing is 4 KiB — spacing is not the scan bound.

## Root cause

Checkpoints are recomputed from scratch on every tail extension instead of appended incrementally.

## Fix sketch

Extend checkpoints incrementally from the last checkpoint when appending at the tail; full recompute only on non-tail edits.

## Complexity / Dependencies

M. None. Pairs with F03.

## Acceptance criteria

- Per-keystroke scan bytes bounded by append size + one checkpoint stride, verified by counter or targeted test.
- Keystroke-budget harness shows no regression at piece-boundary sizes.

## Tests / benchmarks

- PerfHarness `keystroke-budget` in Release; unit test typing across a 64 KiB piece boundary asserting checkpoint correctness (line starts after edit).

## Out of scope

Changing the 64 KiB stride without measurement.

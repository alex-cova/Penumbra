# F03 — PieceTree.split O(file-offset) on first edit

- **Priority:** P0 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `PieceTree.split(atUTF16:)` (Sources/Penumbra/TextView/Core/PieceTree.swift:868-935) calls `UTF8DocumentScanner.utf8Position(forUTF16Offset:in:)` over the whole piece bytes with no checkpoint/cursor, then re-walks the slice for UTF-16 length.
- The original file is a single piece (PieceTree.swift:432-443), so the first non-tail edit in a large mmap file pays two linear byte walks. Subsequent splits are confined to ≤64 KiB add pieces or shrunken originals.
- A checkpoint-aware path already exists: `resolveUTF8Offset` (PieceTree.swift:1085-1129), unused by `split`.

## Root cause

`split` predates / bypasses the checkpoint machinery used by the read paths.

## Fix sketch

Make `split` checkpoint-aware like `resolveUTF8Offset`: start from the nearest checkpoint/cursor, walk only the remainder.

## Complexity / Dependencies

M. None. Pairs with F04.

## Acceptance criteria

- First-edit latency on 10 MB / 100 MB fixtures independent of edit offset (within measurement noise).
- All existing PenumbraTests buffer/editing tests pass unmodified.

## Tests / benchmarks

- PerfHarness enter-session + keystroke on large synthetic files; targeted unit test asserting scan distance via existing counters if available.

## Out of scope

Storage redesign; add-buffer compaction policy.

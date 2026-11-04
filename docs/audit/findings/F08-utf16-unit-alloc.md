# F08 — utf16Unit single-char allocation chain

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A
- **Status:** ✅ Done (2026-11-03) · **Owner:** Unassigned

## Evidence

- `PieceTree.utf16Unit(at:)` (Sources/Penumbra/TextView/Core/PieceTree.swift:998-1001) routes through `utf16Units(in:):1003-1018` → `UTF8DocumentScanner.appendUTF16Units:84-114`, which builds `String(bytes: Data(slice))` + `Array(string.utf16)` even for length 1.
- Hot caller: `LineManager.setLength` (LineManager.swift:484-506) probes 1–2 chars per call for delimiter handling; `setLength` runs 1–3× per keystroke.
- Scan distance is bounded by checkpoints/cursor; the defect is allocation, not traversal.

## Root cause

A range API is reused for single-unit reads.

## Fix sketch

Direct scalar decode from the checkpoint-bounded byte slice for the length-1 case; keep the range API for real ranges.

## Complexity / Dependencies

S. None.

## Acceptance criteria

- Allocations instrument shows no per-`setLength` Data/String/Array triple on the typing path.
- Line-splitting behaviour identical on CRLF, lone CR, and multi-byte boundaries (existing tests).

## Tests / benchmarks

- Allocations trace during scripted typing; existing LineManager/PieceTree tests.

## Out of scope

Rewriting `appendUTF16Units` for multi-unit ranges.

## Implementation notes (2026-11-03)

- **Fix.** `UTF8DocumentScanner.utf16Unit(from:utf16Offset:)` decodes the one scalar in place (strict UTF-8: truncated, overlong, surrogate and out-of-range sequences answer nil, as `String(bytes:encoding:)` rejected them) and returns the unit, or the high/low surrogate half of a 4-byte scalar. `appendUTF16Units` takes it for `length == 1`. In `PieceTree`, the byte-run selection (add-buffer checkpoint, original checkpoint, last-read cursor) moved into `withUTF16Source(of:localUTF16:_:)`, which the range read and the new `utf16Unit(of:localUTF16:)` both use, so there is one copy of that logic. `PieceTree.utf16Unit(at:)` no longer builds the `[unichar]` result of `utf16Units(in:)`.
- **Measured, debug build, `malloc_logger` hook.** A one-unit read made 5 allocations (Data, String, Array and the result array); the first cut that only fixed the scanner made 3 to 4; after the refactor it makes 0 (the hook sees every thread, so the test takes the quietest of three runs, and reads each offset once before counting because finding a piece after the caret moved allocates in the tree descent, which this finding does not cover). Mutation check: putting `utf16Units(in:)` back in `utf16Unit(at:)` fails `testSingleUnitReadDoesNotAllocate` (1,200 allocations in 400 reads).
- **Not a latency win, and not claimed as one.** Release `PerfHarness enter-session synthetic --lines 20000`, three paired runs each: Enter fresh_top 0.75-0.79 ms on both, fresh_middle 1.18-1.25 ms on both, scroll unchanged. The finding said the defect is allocation, not traversal, and the Enter path reads one or two units per edit, so the saving is a few microseconds that this harness does not resolve. The value is fewer allocations on every keystroke and a read path with no `Data`/`String` round trip.
- **Tests.** `UTF8DocumentScannerTests`: single-unit read against `String.utf16` at every offset (ASCII, 2-, 3- and 4-byte scalars, both halves of surrogate pairs) and against invalid bytes (same answer as the range read, nil). `PieceTreeTests`: `unichar(at:)` agrees with the reference string at every offset after loading and after edits that move text into the add buffer, and the allocation test above.
- **Not done:** `appendUTF16Units` for real ranges still builds `Data`, `String` and `Array` (out of scope in the brief); the other `utf16Units(in:)` callers (`bytes(in:)`, `substring`) are unchanged.

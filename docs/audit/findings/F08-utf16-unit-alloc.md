# F08 — utf16Unit single-char allocation chain

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

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

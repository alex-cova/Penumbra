# F02 — refreshStructure copies whole document per caret move

- **Priority:** P0 · **Severity:** Critical · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

## Evidence

- `IDEWorkspace.refreshStructure` (Umbra/Sources/Umbra/Workspace/IDEWorkspace.swift:5117-5136) synchronously reads `textView.text` on `@MainActor` at :5126 before awaiting the provider; called from `textViewDidChangeSelection:5968` on every caret move and from `textViewDidChange` per edit.
- For piece-tree storage this reaches `PieceTree` materialization (Sources/Penumbra/TextView/Core/PieceTree.swift:688-695).
- Mitigation present: early return when the language has no structure provider; the parse itself is awaited off the copy.

## Root cause

The structure-provider API wants a `String`, so the host materializes one per caret move.

## Fix sketch

Pass a snapshot/range reader (the piece-tree reader already used on the completion path) instead of `String`. Keep the provider await unchanged.

## Complexity / Dependencies

M. No dependencies. Coordinate with F20 (same materialization pattern).

## Acceptance criteria

- `pieceTreeMaterializeCount` (TextView.swift:176-180) does not increase on caret moves in a file-backed document.
- Structure breadcrumbs still update correctly for Java/Swift/TypeScript.

## Tests / benchmarks

- PerfHarness caret-move / enter-session profile on 120k-line file, Release, display on.
- Existing structure/breadcrumb tests in UmbraTests.

## Out of scope

Debounce policy changes; provider internals.

## Implementation notes

Done 2026-11-03 — `refreshStructure` captures `exportDocumentText()` (piece-tree snapshot, no materialize) on the main actor and builds the string in a detached task; results dropped when `contentGeneration` moved. Not done: gating on the Structure sidebar being visible (would need every show path to refresh); no Release caret-move measurement yet. Existing UmbraTests structure suite not re-run in full.

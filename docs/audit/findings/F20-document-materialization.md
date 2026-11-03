# F20 — Whole-document materialization on ordinary commands

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `selectNextOccurrence` / `skipCurrentOccurrence` / `selectAllOccurrences` (TextInputView.swift:2825,2854,2918) and legacy `SearchController.search` read `stringView.string`, materializing a file-backed document per command/search.
- A snapshot path already exists: `TextView.makeFindTextSource:184-189`, used by occurrence highlighting. `CodeFoldingManager.makeDocument` materializes per fold update (async/debounced — acceptable, verify only).
- The `TextInputView.string` setter evaluates the materializing getter before comparing, but only on programmatic set — not per keystroke. Prior "full rebuild per keystroke" readings are falsified.
- Prior audit adds: `PenumbraEditorAdapter.makeDocument` copies NSMutableString→String, amortized by the 200 ms debounce and avoided on the completion path. Keep off the keystroke path permanently.

## Root cause

Legacy call sites predate the snapshot/find-source API.

## Fix sketch

Migrate occurrence selection and legacy search to `makeFindTextSource`; guard `makeDocument` with a comment + trace assertion so it never lands on a keystroke path.

## Complexity / Dependencies

M. Coordinate with F02 (same pattern in the host).

## Acceptance criteria

- `pieceTreeMaterializeCount` flat across select-all-occurrences and legacy search on a file-backed document; results identical.

## Tests / benchmarks

- Existing occurrence/search tests; counter-based test on a large document.

## Out of scope

Removing the legacy search controller; `setState` full-text captures (separate, bounded by explicit state sets).

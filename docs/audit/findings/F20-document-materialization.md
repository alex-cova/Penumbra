# F20 — Whole-document materialization on ordinary commands

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-04) — occurrence commands, palette text search and fold updates no longer copy a piece-tree buffer on the main thread; `TextView.search(for:)` kept as the explicit whole-document API · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

Probe: `pieceTreeMaterializeCount`. Before the change, on a 300 KB piece-tree buffer, the occurrence commands copied it 4 times (⌘D ×2, ⌘K ⌘D, ⌘⇧L) and one fold update copied it twice; after, both stay at 0 (`DocumentMaterializationTests`, each verified to fail on the old code).

**Fixed.**
- **Occurrence selection** (`selectNextOccurrence`, `skipCurrentOccurrence`, `selectAllOccurrences`): `SelectNextOccurrence.nextMatch` / `allMatches` now also take a `FindTextSource`, and `TextInputView.occurrenceSource()` hands them the piece-tree snapshot (a contiguous buffer, bounded by the piece-tree threshold, still uses its string). The windowing is `FindSearchEngine`'s literal enumerator (now internal, not private), so matches across a window cut are found; `testSourceSearchEqualsTheStringSearchAcrossWindowCuts` holds the source results equal to the `NSString` ones over windows of 7–101 units with surrogate pairs and composed characters.
- **Palette `#` text search** (the one interactive caller of the legacy path, not named in the brief): every debounced keystroke ran `textView.search(for:)` (whole-buffer copy, regex over everything, every match built) and then `textView.text` (a second copy), all on the main actor, to show `limit` rows. `TextView.bufferTextMatches(for:limit:)` scans a snapshot off the main actor, stops at `limit`, and cuts each preview to 400 units either side of the match (a minified one-line file stays cheap). `BufferTextPaletteProvider` now takes that as a closure. Case-insensitive matching is `NSString`'s, not the regex's: the two differ only in rare folds (e.g. `ß`).
- **Fold updates** (`CodeFoldingManager.makeDocument`): the brief said "verify only"; it was a main-thread copy of the file per fold update (debounced, but a 100 MB file is a visible stall). It now snapshots on the main actor and builds the string detached; stale results are still dropped by the generation guard.

**Left as is, on purpose.**
- `TextView.search(for:)` and `SearchController` (public, synchronous, regex, returns every match with locations): a regular expression needs the whole string, and nothing in the app calls it any more. Documented as an explicit whole-document API.
- `PenumbraEditorAdapter.makeDocument` copy (200 ms debounce, avoided on the completion path), `TextInputView.string` setter, `setState` captures: as the brief says.
- `EditorIntelligenceController.refreshDiagnostics` and `liveDocument` still read `textView.text` (F24 left them; not on a keystroke path, but a candidate for the same export-and-materialize-detached treatment).

**Not done.** A release PerfHarness measurement of the palette search on a large file; the guard/trace assertion on `makeDocument` the brief sketches (the counter tests are the guard).

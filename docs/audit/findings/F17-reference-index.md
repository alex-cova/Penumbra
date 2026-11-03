# F17 — No persistent reference index

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Closed: premise stale, verified and measured (see Implementation notes) · **Owner:** Unassigned

## Evidence

- Prior audit: usages, rename, and call hierarchy walk per request (JavaIndex identifier shards + member walk with on-demand verification), instead of consulting a persisted scope-qualified name→uses index.
- The name index exists (`JavaNameIndex` identifier shards) but is not used by completion and does not answer reference queries directly.

## Root cause

Indexes were built for lookup-by-name and completion; reference queries were left as walks.

## Fix sketch

Add a scope-qualified name→uses index in the indexing scheduler, maintained incrementally with the existing generation/pending-edits machinery. Route find-usages, rename, and call hierarchy through it; keep on-demand verification as a filter, not the search.

## Complexity / Dependencies

L. Overlaps F15 (inheritor index) — design the shard layout together. Watch F23 staleness semantics.

## Acceptance criteria

- Find-usages and rename latency on a fixture project measured and independent of project size growth (index lookup, not walk).
- Results identical to walk-based results on the fixture.

## Tests / benchmarks

- Rename/call-hierarchy tests; PerfHarness java scenarios at 5,000-file scale (`java-name-index --files 5000` exists).

## Out of scope

Cross-language reference index unification; workspace-symbol fuzzy search.

## Implementation notes

2026-11-03. The brief's evidence did not match the code. Find Usages, Rename and the refactorings already narrow a project through the persistent identifier index (`JavaNameIndex`, `refs.idx`) and verify only the candidate files: Umbra builds all of them on `JavaIndexedOrScanningCandidates` (the index for roots it has a shard for, a text scan only for roots it has none for). The note in `Sources/JavaIntelligence/CLAUDE.md` that rename deliberately uses a text scan was stale and is corrected. No code change was needed; what was missing was the evidence the acceptance asks for.

- **Latency vs project size** (`PerfHarness java-name-index synthetic --files N`, Release; new bands): a rare identifier, 1,000 / 5,000 / 20,000 files: index 17 / 28 / 50 µs, text scan 34 / 179 / 783 ms. A common identifier through the index costs in proportion to the files it returns (2.4 / 13 / 57 ms when every file matches), which is inherent; verification then dominates. End-to-end find-usages and rename latency (parsing the candidate files) is not measured at scale.
- **Results identical to the walk** (`JavaUsageCandidateParityTests`): the same usages (file, byte range, kind) from index candidates and from the text scan for a type, a method with overloads and a field, over a fixture with decoys (the word in a comment and a string, an unrelated class of the same name in another package) and 25 filler files. An unsaved buffer reaches the index path through its overlay (the test fails without `setOverlay`).
- **Not done:** the brief's scope-qualified name→uses index (storing resolved uses) was not built: candidate narrowing plus on-demand verification meets the measured goal, and a stored-uses index would add the staleness problem F23 describes. Call hierarchy's cost was not measured separately.

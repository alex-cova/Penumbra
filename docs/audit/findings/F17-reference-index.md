# F17 — No persistent reference index

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Open · **Owner:** Unassigned

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

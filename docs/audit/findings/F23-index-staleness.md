# F23 — Generated-source staleness and index double-truth

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Open · **Owner:** Unassigned

## Evidence

- Prior audit: generated sources are indexed with `isGenerated` but staleness/refactor wiring is uninspected at the Umbra boundary; annotation-processor output lifecycle is not modelled (see also F16).
- Index truth is duplicated: `SymbolIndex` trie + `JavaIndex` + Swift/TS indexes + `JavaNameIndex`, with both `lastIndexedVersion` and `generation/pendingEdits` staleness schemes; query-path overlap between `JavaNameIndex` and `SymbolIndex` uncompared.
- Shared machinery exists and is good: `SourceFileIndex` (generic, 8-task parse fan-out, generation/pendingEdits) backs Swift and TypeScript; Java is bespoke, justified by classpath/JAR stubs pending profile comparison (F09 notes the same asymmetry).

## Root cause

Each language grew its own index before the shared one stabilized; staleness semantics were never unified.

## Fix sketch

Merge on one staleness scheme (generation/pendingEdits); audit `JavaNameIndex` vs `SymbolIndex` query paths and document or merge the overlap; wire generated-source invalidation through the scheduler with an annotation-processor fixture proving it.

## Complexity / Dependencies

M. Interacts with F15/F17 index additions — design shard/staleness layout once, together.

## Acceptance criteria

- One documented staleness scheme; fixture: touching an annotated source regenerates and reindexes its outputs without manual refresh.

## Tests / benchmarks

- Indexing tests per language; annotation-processor fixture (shared with F16 if built).

## Out of scope

Unifying the three language indexes into one implementation without profile evidence.

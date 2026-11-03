# F23 — Generated-source staleness and index double-truth

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** B
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

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

## Implementation notes

2026-11-03. Two of the brief's three claims held up under inspection and one did not; the write-up of
all of it is `docs/INDEX_STALENESS.md`.

- **Generated sources: a real gap, fixed.** `nameRoots` is `model.existingSourceDirectories`, so
  `IDEJavaSupport.filesDidChange` never matched a path under `build/generated`; a root's stamp was its
  directory's own mtime, which an in-place rewrite does not move; and the only trigger was
  `buildSucceeded()`, i.e. a build Umbra ran itself. A build in Umbra's own terminal (or anything
  else), or a `clean`, left generated stubs stale until a manual Build or resync, and a generated
  directory that did not exist at sync time was never indexed. Now a generated root is stamped by its
  content (`SourceRoot.contentStamp`) and watcher batches that touch a declared generated directory
  schedule a debounced refresh (`affectsGeneratedSources`, `refreshGeneratedSources`). Each fix is
  needed on its own (cost of the content stamp, debug build: 7 ms at 1,000 generated files, 182 ms at 50,000, on a background task): `IDEGeneratedSourcesTests` (real watcher, Java support and index) fails on the
  first-build and rewrite steps without the trigger, and on the rewrite step without the stamp.
- **"Two staleness schemes": not the same problem, nothing to merge.** Version, stamp and
  generation/pending-edits guard three different races (an unchanged buffer, a stale artifact on disk,
  an edit during a cold walk). The document lists each index with its guard and trigger.
- **`JavaNameIndex` vs `SymbolIndex`: no overlap in practice.** `SymbolIndex` holds open buffers only
  (keyed by `DocumentID`, fed by workspace events); `JavaNameIndex` holds the project on disk. They
  answer different questions and no path asks both.
- **Not done.** Regenerating on save: Umbra never runs annotation processing (`-proc:none`), so the
  brief's "touching an annotated source regenerates" is a product decision, not an indexing fix; the
  index follows a regeneration, it does not cause one. Generated roots are not name-index roots, so
  Find Usages and Rename do not search generated code (IntelliJ does include it). The annotation
  processor lifecycle for F16 (module-aware visibility) is not modelled. Merging the Swift/TypeScript
  `SourceFileIndex` with the Java index was out of scope without profile evidence, as the brief says.

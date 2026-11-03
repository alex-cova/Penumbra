# F09 — TypeScript index rebuilds whole project per file change

- **Priority:** P1 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `TypeScriptIndex.applyFileChanges` (Sources/TypeScriptIntelligence/TypeScriptIndex.swift:70-91) parses incrementally per file, then `publish(storage.storedFiles):89` → `publish:232-259` rebuilds names/exports/paletteSymbols over ALL models.
- Contrast `SwiftIndex` (Sources/SwiftIntelligence/SwiftIndex.swift:389-435): incremental add/remove per file, `O(file)`.
- Runs on an actor: main thread is not blocked; total work and result freshness are the cost. On a 10k-file project every save is `O(project)`.

## Root cause

Publish was written as a full rebuild; the incremental pattern exists in the sibling index and was not ported.

## Fix sketch

Port SwiftIndex-style incremental add/remove publish to TypeScriptIndex, reusing the shared `SourceFileIndex` generation/pending-edits machinery.

## Complexity / Dependencies

M. None.

## Acceptance criteria

- Single-file change in a 1,000-file fixture publishes in time independent of project size (PerfHarness `ts-index --files 1000`).
- Palette/export results identical before/after on the fixture.

## Tests / benchmarks

- PerfHarness ts-index scenario; TypeScriptIntelligence tests.

## Out of scope

Merging the Swift/TypeScript/Java indexes into one implementation; Java keeps its bespoke index (classpath/JAR stubs justify it pending profile evidence).

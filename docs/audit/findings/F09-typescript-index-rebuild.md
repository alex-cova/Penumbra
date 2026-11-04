# F09 — TypeScript index rebuilds whole project per file change

- **Priority:** P1 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Implemented (see Implementation notes) · **Owner:** Unassigned

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

## Implementation notes

2026-11-03. `TypeScriptIndex` keeps what each file contributed (`contributions`: its identifiers and export names, `paletteSymbolsByFile`) next to the three lookup tables. A change removes that file's old contribution and adds the new one; the cold walk and clearing the project go through the same per-file step, so a rebuilt index and an incrementally patched one cannot drift apart by construction. It also stops replacing the file map with itself on every save.

- **Measured** (`PerfHarness ts-index synthetic --files N`, new band `ts_index_file_changed`, Release, median of 8 rewrites of one file that renames its class): 1,000 files 2.86 ms → 0.12–0.15 ms; 5,000 files 15.0 ms → 0.10 ms; 10,000 files 29.1 ms → 0.11 ms; 20,000 files 0.17 ms. Before it grew linearly; now it is flat and equal to `SwiftIndex` (≈0.09 ms). Cold index time is unchanged.
- **A first version was still linear** (0.12 → 0.25 → 0.47 ms from 1,000 to 10,000 files): removing a file from an identifier's set through a local copy (`guard var files = names[name]`) copies the set, and a common word's set holds every file that mentions it. The removal now mutates through the dictionary subscript. Worth knowing for the next incremental index.
- **Equivalence, not just speed** (`TypeScriptIndexIncrementalTests`): after a rename, an add, a delete, a re-export rewrite, a messy change list (repeats, a missing file, a non-source file) and 24 mixed steps, the patched index answers `symbols`, `exports` and `externalUses` exactly like a fresh index over the final files (compared as sets; the lookups never promised an order). With the old contribution left in place four of the five fail.
- **Unchanged:** while a walk is in flight edits are recorded as pending and the published tables are not touched; the walk merges them and publishes everything when it finishes (`SourceFileIndex`'s existing guarantee).
- **Not done:** the order of palette and export results is still unspecified (it was dictionary order before and is dictionary order now).

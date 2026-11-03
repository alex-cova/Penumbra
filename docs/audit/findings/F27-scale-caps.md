# F27 — Parse-cache caps and linear symbol scans at scale

- **Priority:** P3 · **Severity:** Low · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `DocumentParseCache` (Sources/EditorIntelligence/LanguageSyntax): maxEntries 64, maxSourceBytes 32 MiB, LRU. Hundreds of open documents thrash and re-parse. A single over-cap document is exempt — correct, keep.
- Swift/TypeScript palette lookups are linear scans: `SwiftIndex.symbols(matching:)` scans `symbolsByFile.values`; `exports(matching:)` scans the name dictionary; TypeScript equivalents scan a flat array. An EditorIntelligence trie (`SymbolIndex`) exists and is not used by these paths. A <10 ms cached-lookup target fails structurally at monorepo scale.
- `SourceFileIndex.enumerate` is a synchronous FileManager walk `O(tree)` (partly detached); no 100k-file fixture exists (PerfHarness defaults: 5,000 files Java name index, 1,000 Swift/TS).
- Performance tunables are process-global `nonisolated(unsafe)` statics (11 in TreeSitterPerformanceConstants alone) shared by all windows/documents — mostly benign, but per-window profiling is impossible until injected.

## Root cause

Caps and scans were sized for the current fixture scale, never revisited.

## Fix sketch

Profile before raising: measure cache hit rate at 200 open documents, then size caps; route palette lookups through the existing trie or an equivalent bounded structure; consider one injected `PerformanceConfiguration` value in place of scattered statics.

## Complexity / Dependencies

S–M. Coordinate with F19 (routing more parsers through this cache).

## Acceptance criteria

- 200-document fixture shows no re-parse thrash; palette lookup latency flat as fixture grows 1k→10k files.

## Tests / benchmarks

- PerfHarness swift/ts-index at raised file counts; cache hit-rate counters.

## Out of scope

Monorepo (100k-file) support claims — no fixture, no claim.

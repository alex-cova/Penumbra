# F27 — Parse-cache caps and linear symbol scans at scale

- **Priority:** P3 · **Severity:** Low · **Confidence:** Confirmed · **Provenance:** A
- **Status:** ✅ Done (2026-11-04) — measured, parse-cache cap raised, lookups made lossless-prefiltered; the 100k-file claim and the global tunables are left · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

**Measured first (release, `PerfHarness swift-index|ts-index synthetic --files N`; new stages `*_lookup` and `*_parse_cache`).**

Lookup latency before, `symbols(matching:limit: 50)` / `exports(matching:limit: 50)`, median:

| files | match at once | match only in the last file | no match |
|---|---|---|---|
| 1,000 | 0.43 / 0.31 ms | 0.93 / 0.63 ms | 0.43 / 0.15 ms |
| 5,000 | 0.20 / 0.13 ms | 4.4 / 3.0 ms | 2.2 / 0.75 ms |
| 10,000 | 0.43 / 0.28 ms | 9.0 / 6.2 ms | 4.3 / 1.5 ms |
| 20,000 | 0.09 / 0.06 ms | 16.1 / 10.1 ms | 8.9 / 3.2 ms |

Early matches are flat (the scan stops at the limit); a query with few matches grows linearly and crosses the 10 ms target around 10–12k files. TypeScript is the same to within noise. Parse cache, 200 documents of 300 lines asked for in the same order three times (a re-analysis of every open tab): cap 64 gave a **0% hit rate** (600 full parses, 536 evictions, 0.19 s per pass); cap 256 gives 200 parses and a 0.018 s pass (11× cheaper).

**Done.**
- `DocumentParseCache`: default `maxEntries` 64 → 256 (the 32 MiB source-byte cap still bounds memory, and a single over-cap document stays exempt as before). Caps are now per instance (`init(…, maxEntries:, maxSourceBytes:)`, defaulting to the old statics) and the cache keeps `statistics` (hits, incremental updates, full parses, evictions). Java's cache is the same class, so it gets the cap too.
- `NameSignature` (`EditorIntelligence/Ranking`): a 64-bit set of the characters in a name. Every match tier needs each query character to occur in the candidate, compared as the matcher compares, so `query ⊄ name` means no match and costs one `AND` instead of the arrays `CompletionMatcher` builds per candidate. It is a prefilter only: names that pass still go through the matcher, so results are unchanged. A seeded property test (20,000 random names and queries, including non-ASCII, 1,000+ real matches) holds that it never rejects a name the matcher accepts.
- `SwiftIndex.symbols(matching:)` / `exports(matching:)` and `TypeScriptIndex.symbols(matching:)` / `exports(matching:)` use it. Palette symbols keep a signature array per file (updated with the file); the export lookups scan a flat array of names with signatures that is built on the first lookup after the name set changed (Swift: any change to its tables; TypeScript: only when a name appears or disappears).
- After, same stages: 20,000 files, last-file match 3.2 / 2.8 ms (was 16.1 / 10.1), no match 0.34 ms / 0.01 ms (was 8.9 / 3.2); 1,000 files, 0.2 ms. Still linear in the worst case (0.2 ms at 1k, 2.4 ms at 10k, 3.2 ms at 20k), but under the 10 ms target well past the sizes measured.
- Tests (`ScaleCapsTests`, 8): the signature property; lookups equal the matcher over every declared name for 16 queries (Swift and TypeScript); an added or removed file is seen by the next lookup (scan invalidation); 200 documents parse once by default and a cap of 64 thrashes; the byte cap still bounds the cache. Existing incremental-index tests and the 419-case completion corpus pass.

**Why not the `SymbolIndex` trie.** The matcher is fuzzy (camel humps, word starts, subsequences), which a prefix trie cannot answer losslessly; a trie in front would change results. The signature keeps them identical.

**Left on purpose.**
- No 100k-file claim: no fixture, per the brief. `SourceFileIndex.enumerate` is still an `O(tree)` walk, but both indexes already run it detached (`Task.detached`), off the main actor.
- The `nonisolated(unsafe)` tunables in `TreeSitterPerformanceConstants` (11) stay process-global; only the parse cache's caps were made per instance. An injected `PerformanceConfiguration` would be a wider refactor with no measured need.
- Worst-case lookups are still O(names); a sorted structure with word buckets would flatten them further, but at 3 ms for 20k files that is a monorepo-scale concern the brief says not to claim.

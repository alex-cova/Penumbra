# F19 — EditorIntelligence indexing parser is full-parse only

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `TreeSitterLanguageParser` (Sources/EditorIntelligence/LanguageParser/TreeSitterLanguageParser.swift:7-8,35-45): "Each document is fully parsed on demand" — `oldTree = nil`, whole-buffer `getAllBytes` copy per parse, then full re-derivation of words/imports (`extractWords` sorts a Set; both `O(nodes)`+).
- Two incremental implementations already exist: the editor path (`ts_tree_edit` + old-tree reparse in the Penumbra language layer) and `DocumentParseCache` (Sources/EditorIntelligence/LanguageSyntax, `ts_tree_edit` + full fallback, 64-entry/32 MiB caps).
- The full-parse parser is used via `IDEWorkbenchLanguageParser` for workspace symbol indexing — per indexed document, not per keystroke.

## Root cause

Three parse paths grew independently; the indexing path never got the incremental treatment.

## Fix sketch

Route workbench/indexing parsing through `DocumentParseCache` (or give `TreeSitterLanguageParser` an old-tree overload fed by it). Delete the third path if routing covers its callers.

## Complexity / Dependencies

M. Check F27 cache caps before routing hundreds of documents through a 64-entry cache.

## Acceptance criteria

- Re-indexing an edited document reuses the old tree (counter/signpost); workspace symbol results unchanged on fixtures.

## Tests / benchmarks

- LanguageServiceConformance + parse-cache tests; PerfHarness swift/ts-index scenarios.

## Out of scope

Editor highlighting path — already incremental; do not touch.

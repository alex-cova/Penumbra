# F19 — EditorIntelligence indexing parser is full-parse only

- **Priority:** P2 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A
- **Status:** ✅ Done (2026-11-04): incremental reparse in the workspace-index parser; the derivation pass is still whole-document · **Owner:** Unassigned

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

## Implementation notes (2026-11-04)

- **Where the time of an index pass goes (measured first, `PerfHarness index-parse`, release).** Java, 138,097 characters: tree-sitter parse 7.6 ms, symbols 4.6, words 2.6, imports 1.9, 16.6 ms in all; an incremental reparse after one typed character takes 0.10 ms. Swift, 258,000 characters (`TextInputView.swift`): parse 16.6, symbols 4.1, words 4.6, imports 2.6, 27.9 ms. So the parse is 40-60% of a pass and the rest is the derivation of symbols, words and imports, which an incremental tree does not shorten. The pass runs on the `IndexingService` actor after a 300 ms quiet period per open document with text (documents past the piece-tree threshold are elided and skipped), never on a keystroke, which is why this is P2.
- **The brief's route does not fit.** `DocumentParseCache` returns `LanguageSyntax.SyntaxTree` values, keyed by file URL, built for a given grammar (Java, TypeScript); the indexing path needs `EditorIntelligence.SyntaxTree` (symbols, words, imports) for any language by identifier, for documents that may have no URL. Routing would need an adapter in both directions and would put every language through a 64-entry cache built for another purpose. The third parse path was not deleted: `TreeSitterLanguageParser` stays the indexing parser and gained what the cache has.
- **Fix.** `TreeSitterLanguageParser` keeps each parsed document's last tree and text (by `DocumentID`, bounded at 64 entries and 32 MiB, least recently parsed out first; the one just stored always stays) and reparses an edited document against it. The edit is the single region between the previous text and the new one (`TextChangeRegion`: longest common prefix and suffix over UTF-8, backed off to scalar boundaries, converted to the UTF-16 byte offsets and row/column points the parser uses), handed to `ts_tree_edit`; an unchanged text parses nothing. `IDEWorkbenchLanguageParser` made a new `TreeSitterLanguageParser` for every call, so nothing could ever be reused; it now keeps one per language identifier. Counters: `fullParseCount` and `incrementalParseCount`.
- **Measured, release, one typed character in the middle, the whole pass (`TreeSitterLanguageParser.parse`, from scratch against reusing the previous tree):** Java 29,000 characters 4.3 to 2.7 ms; 138,000 characters 19.2 to 11.7 ms; 552,000 characters 77.9 to 46.6 ms; Swift 258,000 characters 30.6 to 14.4 ms. About 40-50% of a pass, as the breakdown predicts; the rest is the derivation.
- **Tests (`TreeSitterLanguageParserIncrementalTests`, `IDEWorkbenchLanguageParserTests`).** 150 random edits (insertions, deletions and replacements with newlines, quotes, braces, CJK, emoji, a combining mark, comment openers) of a JavaScript document: after every edit the incremental parser's symbols (name, kind, offsets, line and column), words and imports equal a fresh parser's, and more than 100 of the 150 were incremental. Skipping `ts_tree_edit` fails it, and so does a `newEndByte` that is off by one unit. An edit counts as incremental (counters), an unchanged text parses nothing, the cache is bounded and evicts the oldest, and `TextChangeRegion` does not split a surrogate pair. Umbra: repeated passes over edited Java and TypeScript documents through the shared workbench parser equal fresh parsers and still produce symbols.
- **Not done:** the derivation pass (`extractSymbols` and `extractImports` walk every node and make a `String` of its type each time; `extractWords` splits, hashes and sorts) is untouched and is now the larger share of a pass; a symbol-id comparison and one combined walk would shorten it. Entries of closed documents stay until evicted (there is no close hook in `LanguageParser`); F27's cache caps were not revisited, and with more than 64 open documents the oldest are parsed from scratch as before. `DocumentParseCache` and the editor's path were not touched.

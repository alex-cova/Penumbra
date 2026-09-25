# Editor performance plan: line handles and Enter

Follow-up to commit `7ec358d` (minimap, line index and text-read fixes from an Umbra Instruments
trace). It started with two costs, the `LineManager` handle table and the Enter key, and grew to
cover what the measurements turned up along the way (folding, races, memory, scrolling).

## Status

| Item | Status | Where |
|---|---|---|
| Phase 0 — `PerfHarness enter-session` (Enter, handles, scroll, memory) | Done | `d52cf54`; `--hold-seconds` and per-step autorelease pools uncommitted |
| Phase 1 — Bound the Enter indent scan | Not started (deprioritized: a Debug-build cost) | — |
| Phase 2 — Release unused handles | Done | uncommitted |
| Phase 3 — Handle-free reads on hot paths | Partly done: folding (`lineID(atRow:)`, `d52cf54`), indentation fold provider (`contentRange(atRow:)`, `d52cf54`), minimap (`lineInfo(atRow:)`, uncommitted). Open: Select All Occurrences, go-to-line, `ViewportParseWindow`, `MethodSeparatorView` | — |
| Phase 4 — Relayout after Enter | Not started | — |
| Phase 4 — O(1) row lookup by ID | Not needed: with Phase 2, Enter visits a few hundred handles | — |
| Phase 5 — Verify in a Release Umbra build with Instruments | Not started | — |
| Folding: no handle per hidden row on every edit | Done | `d52cf54` |
| Crash races: `StringView` lock, tree-sitter tree reads, node lookups | Done | `d52cf54` |
| Scrolling: placeholder theme, capture-window index, line-number view reuse | Done | `d52cf54` |
| Memory: bounded `LineControllerStorage` | Done | `d52cf54` |
| Scrolling: glyph extraction (bounds cache, key template, executor checks, run attribute cache) | Done | uncommitted |
| Select All Occurrences with tens of thousands of matches | Open | — |
| Scrolling: instance-buffer rebuild, typesetting | Open | — |

Details and numbers for each item are in the results log below.

## Baseline (2026-09-25, Debug build, M-series MacBook Pro)

Measured with a temporary XCTest that opens a generated Java file in a `TextView` configured like
Umbra's defaults (line numbers, folding, minimap, method separators, Metal on), then plays a
session: scroll the whole file a page at a time, three go-to-line jumps, Select All Occurrences of
a common word. Enter is timed as `insertText("\n")` + `layoutIfNeeded()`, 15 presses, median.
Handle counts come from DEBUG-only counters on `LineManager` (`debugHandleCount`,
`debugHandlesCreated`, `debugShiftVisits`).

### Handle growth (never released until a full rebuild)

| Step | 20k-line file | 120k-line file |
|---|---|---|
| After open | 302 | 302 |
| After scrolling the whole file | 20,089 (every line) | 64,402 |
| After 3 go-to-line jumps | 20,089 | 64,688 |
| After Select All Occurrences | 20,089 | 82,167 |

Estimated cost per handle: node object (~48 B) + `DocumentLineNodeData` (~80 B) + weak side table
+ dictionary slot ≈ 180 B. That is ~15 MB for 82k handles and ~180 MB for a fully visited
1M-line file. Every inserted or removed line then walks the whole table to fix `row`
(`shiftHandlesAfterInsert` / `shiftHandlesAfterRemoval`): 82k visits per Enter.

### Enter latency

| Caret position | Few handles (~300) | After full walk (20k / 82k handles) |
|---|---|---|
| 20k file, top | 5.7 ms | 6.1 ms |
| 20k file, middle | 26.8 ms | 26.9 ms |
| 120k file, top | 4.4 ms | 8.7 ms |
| 120k file, middle | 23.9 ms | 30.7 ms |
| 120k file, end | — | 33.9 ms |

**The handle table costs 4–7 ms per Enter at 82k handles, but the dominant cost is elsewhere.**
Profiling Enter in the middle of the 20k file: 87% of `insertText` time is
`CStyleLineIndentProvider.scan`. `EnterController.scanStartLocation` hands it up to
`maximumScanLength` = 262,144 UTF-16 units before the caret, and it lexes all of them (bracket
stack, operators via `Set<String>` lookups) on every Enter. Near the top of a file there is little
text to scan, which is why the top is fast.

### What already makes eviction safe

- Every per-line cache keys on `DocumentLineNodeID` (11 dictionaries: `LineControllerStorage`,
  `MinimapRowCache`, `ContentSizeService.lineWidths`, `HighlightService`, folding, focus mode, …).
  The ID comes from `PackedLineIndex` and is stable without a handle.
- `DocumentLineNode` equality and hashing are by `id`, so a fresh handle for the same line is
  `==` to an old one. No code compares handles with `===`.
- Long-lived holders are few: `LineController.line` (controllers are pruned via
  `removeAllLineControllers(exceptLinesWithID:)`), `initialLongestLine` (weak),
  `DocumentLineNodeData.node` (weak), and per-call locals.

## Release baseline, folding fix and race fixes (2026-09-25)

`swift run -c release PerfHarness enter-session synthetic --lines N` (median of 15 Enters, two runs
each; see `Tools/PerfHarness/Sources/EnterSessionProfile.swift`):

| | 20k lines before | 20k lines after | 120k lines before | 120k lines after |
|---|---|---|---|---|
| Handles after open | 19,286 | 302 | 302 | 302 |
| Enter, top | 9.9–10.8 ms | 2.4–2.6 ms | 2.2–2.3 ms | 2.3–2.4 ms |
| Enter, middle | 9.7–9.9 ms | 2.4 ms | 2.0–2.6 ms | 2.0–2.1 ms |
| Enter, after full walk | 9.8–11.2 ms | 2.4–2.6 ms | 2.2–2.6 ms | 2.2–2.8 ms |

What Release showed, against the Debug numbers above:

- **The indent scan is a Debug-build cost.** In Release, Enter doesn't depend on caret position.
  Bounding the scan is still worth doing for people running Umbra from Xcode, but it's no longer
  the first priority.
- **The real Release cost was folding.** `FoldingController.applyRecomputedFolds` walked every
  hidden row of every fold after each edit, calling `LineManager.line(atRow:)` on each just to read
  its ID to check whether the fold was collapsed. Nested folds cover most lines several times;
  files above `maxFoldRecomputeLineCount` (50k) skip folding, which is why the 120k file was
  faster than the 20k one. It also made a handle per line at open. Fixed: skip the walk when
  nothing was collapsed, read IDs with `LineManager.lineID(atRow:)` (no handle), and only create
  handles for lines that really are collapsed. Regression test:
  `FoldingControllerTests.testRecomputeWithoutCollapsedFoldsCreatesNoLineHandlesForFoldBodies`.
- **Handles cost little in Release:** 120k live handles add ~0.2 ms per Enter. Phase 2 is now
  about memory (~180 B per handle) more than latency.
- **Two crash races surfaced** (the harness segfaulted in 2 of 3 runs at 20k lines; found with
  Thread Sanitizer) and are fixed:
  - `StringView` methods that skipped its lock (`rangeOfComposedCharacterSequence(s)`,
    `enumerateSubstrings`, `prefetch`, `contentSnapshot`, `compactPieceTree`, counters) raced a
    background parse's `bytes(in:)` on the piece tree's lookup cache: use-after-free in
    `PieceTree.nodeContaining`. Regression test:
    `StringViewTests.testConcurrentByteReadsDuringEditsAndComposedCharacterQueries` (crashes 3 in
    5 runs without the fix).
  - `TreeSitterInternalLanguageMode.rootSyntaxNode` (fold provider, method separators) and
    `detectIndentStrategy` read the live tree off `parseLock` while a parse replaced it. They now
    get a private `ts_tree_copy` (the start-of-parse copy while a parse runs), and `canHighlight`
    checks `parseInFlight` before touching the layer.
  - Remaining TSan report: `ts_tree_copy` vs `ts_parser_reset` inside tree-sitter's atomic
    refcounting (a non-atomic assert read); treated as benign.
  - Also fixed: `treeSitterNode(at:)`, `syntaxNode(at:)` and `strategyForInsertingLineBreak`
    read the layer without the lock, even while a parse was in flight. They now go through
    `nodeLookup(at:)`: under `parseLock` when idle (injection-aware), from a copy of the
    start-of-parse root tree while a parse runs. Regression test:
    `TreeSitterLanguageModeConcurrencyTests` (TSan reports the layer races on the old code, none
    with the fix).

## Plan

### Phase 0 — Repeatable measurement (small) — done

- Turn the temporary session test into a `PerfHarness` command (`swift run -c release PerfHarness
  enter-session <path|synthetic>`) that prints the tables above, so every phase is measured the
  same way and in Release, not only in Debug.
- Keep the DEBUG counters on `LineManager`.
- Exit: Release baseline recorded in this file.

### Phase 1 — Bound the Enter indent scan — not started (Debug-build cost; deprioritized, see above)

Goal: Enter cost independent of caret position.

1. Start the scan at a structural anchor instead of 256K back: the nearest preceding line that
   starts at column 0 with a non-whitespace character that isn't `}`, `)` or a continuation (in
   Java, a top-level declaration or annotation). Walk back line by line through `PackedLineIndex`
   (cheap now), capped at the existing 256K. Pass `isTruncated` as today.
2. If a file has no such anchor (one giant method, minified code), the cap still applies. Consider
   lowering it to 32K; the provider already handles `isTruncated`.
3. Longer term, alternative: take the enclosing bracket structure from the tree-sitter tree, which
   is already parsed for Java, instead of re-lexing text. Only worth it if (1) isn't enough.
4. Check where else `CStyleLineIndentProvider` runs (typing `}` reindent, paste, reformat
   fallback) and apply the same anchor.
- Tests: the existing Enter/indent tests plus a case where the anchor search matters (caret deep
  inside a class after 300K of preceding code; result must equal the unbounded scan).
- Exit: middle-of-file Enter within ~1 ms of top-of-file Enter at 20k and 120k lines.

### Phase 2 — Release unused handles (medium risk, contained in `LineManager`) — done

Goal: live handle count scales with what's on screen, not with what has been visited.

- Prune when `handles.count` passes a threshold (for example 4× the last viewport's line count,
  minimum 2,048): drop entries whose handle nothing else holds
  (`isKnownUniquelyReferenced`), then row-shift loops only visit what's left. Run the prune from
  `line(atRow:)` creation (amortized) or once per layout pass.
- Nothing else changes for callers: a held handle stays in the table and keeps getting `row`
  updates; a dropped one is recreated on demand with the same `id`, so caches and equality keep
  working.
- Rejected alternative: a weak-reference table. It needs a box per entry and still pays the
  side-table allocation; the unique-reference prune is simpler.
- Risks to check: any code that stores a handle and expects `row` to stay current is safe (it's
  referenced, so not pruned). Code that stashes handles in a collection for a long time (e.g.
  `LineChangeSet`) just keeps those alive until released.
- Tests: new `LineManager` tests (prune keeps referenced handles; rows stay correct across
  inserts/removals after a prune; the recreated handle is `==` the old one), plus the full suite.
- Exit: after the full session, handle count < ~2× viewport lines + held controllers; Enter
  shift visits in the hundreds, not tens of thousands; ~15 MB saved at 82k lines.

### Phase 3 — Handle-free reads on hot paths (medium, incremental) — partly done

Goal: stop creating handles for rows that are only read once.

- Add `LineManager.lineInfo(atRow:) -> LineInfo` (value type: `id`, `row`, `location`, `length`,
  `delimiterLength`, `height`, `yPosition`), one tree descent, no handle.
- Move read-only walkers over, one per change, measuring each: `MinimapView.visibleLines`,
  `MethodSeparatorView`, Select All Occurrences / search highlighting, go-to-line, fold-range
  scans (`FoldingController`, `LineIndentationFoldProvider`), `ViewportParseWindow`.
- `LayoutManager` keeps handles (they back `LineController`s).
- Exit: `debugHandlesCreated` after the session drops by most of the remaining churn; minimap
  and scroll numbers from the commit `7ec358d` benchmark improve further.

### Phase 4 — Only if still needed — not started (O(1) row lookup no longer needed)

- Relayout after Enter: `LayoutManager.relayoutVisibleFragmentsAfterLineStructureChange` was the
  next item in the Enter profile (~13% of `insertText`, most of the post-Enter layout).
  Investigate re-positioning, rather than re-laying out, fragments below the edit.
- O(1) row lookup by ID (so handles need no row shifting at all): a generation-stamped lazy
  `row`. Only if Phase 2 leaves shifting measurable.

### Phase 5 — Verify in Umbra — not started

- Instruments Time Profiler on a Release build of Umbra: open a large Java file, scroll through
  it, type in the middle. Compare against the trace from 2026-09-25.
- Exit: no main-thread hangs from minimap/layout/Enter; Enter feels instant anywhere in a
  100k-line file.

## Results log

### Indentation fold provider (2026-09-25)

`LineIndentationFoldProvider` reads rows through `LineManager.contentRange(atRow:)` (no handle) and
stops at the first non-whitespace character; regression test
`FoldingControllerTests.testIndentationProviderRecomputeCreatesNoLineHandles`.

### Scrolling (2026-09-25)

`enter-session` also times each page of the whole-file scroll (offset change + layout + display).

- Handle attribution while scrolling a 20k file: minimap `visibleLines` ~80% of new handles,
  `LayoutManager.layoutLinesInViewport` ~19% (needed: `LineController`s keep them), Enter one per
  new line. Making the minimap handle-free (a `LineInfo` value type) changed neither page time
  (6.2 ms) nor handles created (layout then creates them), so it was **not kept**; it only pays
  off together with Phase 2, when released handles would otherwise be recreated every frame.
- Release scroll profile: ~84% `layoutLinesInViewport`. Within it: glyph extraction/upload to
  Metal ~27%, `LineController.prepareToDisplayString` ~23% (of which syntax highlighting from
  the capture cache ~13%), line-number views ~7%, `LineController` creation ~11%, and ~9% building
  a throwaway `DefaultTheme` (≈20 named-color lookups) as the placeholder theme of every new
  `LineController` and syntax highlighter. Fixed with a shared immutable
  `DefaultTheme.placeholder`: page time 6.2–6.3 ms → 5.4–5.6 ms (20k and 120k lines).

Then, in the same profile:

- `TreeSitterInternalLanguageMode.cachedCaptures(containing:)` filtered every capture of the
  cached window (32k UTF-16 units, thousands of captures) for each visible line, under
  `parseLock`. `CaptureWindow` now keeps a running max of capture ends and a suffix min of
  starts, so a line binary-searches the only stretch that can overlap it; same result and order
  (`CaptureWindowTests`).
- Recycled line-number views were removed from and re-added to the gutter on every page
  (`removeFromSuperview`/`addSubview`: window, layer, constraint and display invalidation).
  `ViewReuseQueue(hidesQueuedViews: true)` keeps them in place, hidden (line numbers only; the
  CG fragment queue still detaches, since tests and the Metal switch look for fragment views in
  the hierarchy). `ViewReuseQueueTests`.
- Page time: 5.4–5.6 ms → 3.8–4.1 ms (20k and 120k lines). From the start of this pass:
  6.2–6.3 ms → ~3.9 ms.

### Memory: line controllers were never released (2026-09-25)

`enter-session` now reports malloc bytes in use per step and posts a memory warning at the end.

| 120k lines (3.3 MB file) | malloc in use | live handles |
|---|---|---|
| After open | 13 MB | 302 |
| After scrolling the whole file | 895 MB | 120,007 |
| After Select All Occurrences | 942 MB | 120,007 |
| After a memory warning | 181 MB | 120,007 |

(20k lines: 29 MB → 161 MB after scrolling.)

`LineControllerStorage` keeps a `LineController` (typesetter, laid-out lines, fragment
controllers) for every line ever laid out; the only eviction is
`LayoutManager.clearMemory()` on a memory warning, which macOS rarely delivers. That's ~6 KB per
visited line, and each controller also keeps its `DocumentLineNode` handle alive, so releasing
handles (Phase 2) can't help until controllers are bounded. The remaining 181 MB after the
warning (handles ~22 MB, line widths, minimap row cache, …) isn't broken down yet.

### Bounded line controllers (2026-09-25)

`LayoutManager.evictDistantLineControllers(around:)` runs after each layout pass: once more than
max(`EditorPerformanceConstants.minimumRetainedLineControllers` = 1,024, 8× laid-out rows)
controllers are kept, `LineControllerStorage.evictLineControllers` drops those outside the laid-out
rows ± max(256, 2× laid-out rows), except the lines holding the primary selection's ends and marked
text. Line widths stay in `ContentSizeService` (content width unchanged).

Code that reads a controller's typesetting for a line that may be off-screen now lays it out on
demand: `LineMovementController.typesetLineController(for:toLocation:)` (arrow up/down) and
`LayoutManager.typesetLineController(for:)` (`closestIndex(to:)`). A new controller reports
"finished typesetting" with zero fragments until prepared, so the check is
`numberOfLineFragments == 0 || !isFinishedTypesetting`. This also fixes moving the caret into a
line that was never laid out. `LineControllerEvictionTests` (without the cap the scroll test keeps
5,000 controllers; with it ~300, and ↓ from an evicted caret line lands on the next line).

| Release, after scrolling the whole file | Before | After |
|---|---|---|
| 120k lines, malloc in use | 895 MB | 180 MB |
| 20k lines, malloc in use | 161 MB | 45 MB |
| Scroll page | 3.8–4.1 ms | 4.0–4.3 ms (p90 ~4.4 → ~5.0 ms) |
| Enter | ~2 ms | unchanged |

Not changed: `CaretRectService`, `TextInputStringTokenizer` (line-boundary moves) and `firstRect`
still read controllers without laying them out; they behave for an evicted line exactly as for a
never-laid-out one (the primary selection's lines are pinned, so the common case is covered).

### Phase 2: handles are released (2026-09-25)

- `LineManager.releaseUnreferencedHandles()` drops handles only the table references
  (`isKnownUniquelyReferenced`) once it passes max(4,096, 2× the last survivors), and right after
  layout evicts line controllers (which are what keep handles alive) and in `clearMemory()`.
  `initialLongestLine` is now held strongly (it was `weak`, alive only because nothing was ever
  released) and cleared when its line is removed.
- The minimap walks rows with `LineManager.lineInfo(atRow:)` / `row(containingYOffset:)` (value
  snapshots, no handles).
- Tests: `LineManagerTests` (bounded table, held handles keep following edits, recreated handles
  keep their ID, `initialLongestLine`), `LineControllerEvictionTests` (handles released with their
  controllers; 1,379 live without the release call, bound 1,000).
- The harness now drains an autorelease pool per step (top-level code never drained the outer
  pool: ~16 MB of pool pages at 120k lines). Heap breakdown after a 120k-line session: ~110 MB
  is tree-sitter's syntax tree (1.07M subtree allocations from the background full parse), the
  rest is small (line widths ~5 MB, a highlight-fragment table ~6 MB after Select All).

| 120k lines, Release | Before | After |
|---|---|---|
| Live handles after scrolling the whole file | 120,007 | 944 |
| Live handles after Select All Occurrences | 120,007 | 436 |
| Enter after the full walk | ~2.2 ms | ~1.8 ms |
| Scroll page | 4.0–4.3 ms | ~3.7 ms |
| malloc after scrolling | 164 MB (pool pages drained) | 141 MB |

`TextViewTypewriterScrollingTests.testUserScrollWheelSuspendsTypewriterUntilKeyPress` failed once in
a full run and passed in isolation and in two further full runs (60-line document; neither the
handle prune nor controller eviction can trigger there): a pre-existing timing flake.

### Glyph extraction (2026-09-25)

Release profile of a 20k-line scroll: `MetalRenderer.upsertFragment` ~40% of a page, almost all
`GlyphRunExtractor.extract`.

- `prepare` asked Core Text for each glyph's bounds one glyph at a time
  (`CTFontGetBoundingRectsForGlyphs` → outline path per call). `GlyphBoundsCache` (owned by the
  atlas, lock-protected so extraction stays non-isolated) keys bounds by the glyph's atlas key
  with subpixel 0 and batch-queries misses. `GlyphAtlasTests.testCachedGlyphBoundsMatchCoreText`.
- `resolve` built each glyph's `GlyphKey` twice (`GlyphKey.make` for `hasEntry`, again inside
  `atlas.lookup`), each time copying the `CGFont` and hashing the matrices. A run now builds a key
  template once and `GlyphAtlas.lookup(key:…)` takes it.
  `GlyphAtlasTests.testKeyTemplateMatchesMakeForEachGlyph`.
- Swift 6 executor checks: a main-actor closure or `@objc` member entered from non-isolated code
  checks the executor on every call. Removed from the minimap's per-line capture loop (plain loop),
  `UIView.isFlipped` (`nonisolated`; AppKit calls it on every coordinate conversion), and avoided
  in `prepare` (a first attempt made it `@MainActor`, which added checks to its closures).
- `RunAttributeCache`: per-line identity memo of run colours and colour-font checks (every token
  is a run). Colour path 4.6% → 2.0% of scroll samples; below timing noise on its own.

Interleaved A/B (20k lines, median of 3–4 paired runs; machine timings drift between sessions, so
compare pairs, not with earlier tables): without these changes 4.08 ms/page, with them ~3.7 ms
(≈9%); p90 improved similarly. Remaining shares of a page: upsert/extraction ~34%, syntax
highlighting ~19%, `prepareToDisplayString` ~19% (typesetting ~10%), Metal encode and instance
rebuild ~10% each, line-number views ~8%.

## Next

1. Scrolling: `MetalRenderer.rebuildInstanceBuffers` (~10%, includes a sort per rebuild) and
   typesetting of lines entering the viewport.
2. Select All Occurrences on tens of thousands of matches creates and typesets a controller per
   caret line before layout evicts them.
3. Phase 1 (Debug-only Enter cost) and Phases 4–5 (Instruments trace of a Release Umbra build).

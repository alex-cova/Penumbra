# Editor performance plan: line handles and Enter

Follow-up to commit `7ec358d` (minimap, line index and text-read fixes from an Umbra Instruments
trace). This plan covers the next two costs: the `LineManager` handle table and the Enter key.

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

## Release baseline and Phase 1 result (2026-09-25)

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

### Phase 0 — Repeatable measurement (small)

- Turn the temporary session test into a `PerfHarness` command (`swift run -c release PerfHarness
  enter-session <path|synthetic>`) that prints the tables above, so every phase is measured the
  same way and in Release, not only in Debug.
- Keep the DEBUG counters on `LineManager`.
- Exit: Release baseline recorded in this file.

### Phase 1 — Bound the Enter indent scan (Debug builds; deprioritized, see above)

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

### Phase 2 — Release unused handles (medium risk, contained in `LineManager`)

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

### Phase 3 — Handle-free reads on hot paths (medium, incremental)

Goal: stop creating handles for rows that are only read once.

- Add `LineManager.lineInfo(atRow:) -> LineInfo` (value type: `id`, `row`, `location`, `length`,
  `delimiterLength`, `height`, `yPosition`), one tree descent, no handle.
- Move read-only walkers over, one per change, measuring each: `MinimapView.visibleLines`,
  `MethodSeparatorView`, Select All Occurrences / search highlighting, go-to-line, fold-range
  scans (`FoldingController`, `LineIndentationFoldProvider`), `ViewportParseWindow`.
- `LayoutManager` keeps handles (they back `LineController`s).
- Exit: `debugHandlesCreated` after the session drops by most of the remaining churn; minimap
  and scroll numbers from the commit `7ec358d` benchmark improve further.

### Phase 4 — Only if still needed

- Relayout after Enter: `LayoutManager.relayoutVisibleFragmentsAfterLineStructureChange` was the
  next item in the Enter profile (~13% of `insertText`, most of the post-Enter layout).
  Investigate re-positioning, rather than re-laying out, fragments below the edit.
- O(1) row lookup by ID (so handles need no row shifting at all): a generation-stamped lazy
  `row`. Only if Phase 2 leaves shifting measurable.

### Phase 5 — Verify in Umbra

- Instruments Time Profiler on a Release build of Umbra: open a large Java file, scroll through
  it, type in the middle. Compare against the trace from 2026-09-25.
- Exit: no main-thread hangs from minimap/layout/Enter; Enter feels instant anywhere in a
  100k-line file.

## Order and sizing

Done: Phase 0 (`enter-session`), the folding fix and the two race fixes above.

Also done: `LineIndentationFoldProvider` reads rows through `LineManager.contentRange(atRow:)`
(no handle) and stops at the first non-whitespace character; regression test
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

### Memory: line controllers are never released (2026-09-25)

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

## Next

1. Phase 2: release unreferenced handles (with the handle-free minimap walk). With controllers
   bounded, handles are now the largest per-line item left (~120k live, ~22 MB at 120k lines);
   then break down the remaining ~165 MB above the 13 MB open baseline.
2. Smooth eviction: dropping a few hundred controllers at once likely explains the higher p90;
   evicting smaller batches more often would spread it.
3. Scrolling: glyph extraction/upload (~27% of a page) is the largest share.
4. Phase 1 (Debug-only Enter cost) and Phases 4–5 as follow-up.

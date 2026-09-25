# Performance rules

Rules for anyone (human or agent) changing the editor. Each one comes from a regression that was
measured and fixed; the numbers and history are in `docs/EDITOR_PERF_PLAN.md` and
`docs/EDITOR_RESPONSIVENESS_PLAN.md`. If a change needs to break a rule, say so in the commit and
show the measurement.

## Budgets

| Path | Budget (Release, 20k and 120k-line Java) | Measured today |
|---|---|---|
| Keystroke (`insertText` + layout) | < 4 ms, flat with file size | ~1–3 ms |
| Enter | < 2 ms at top of file; mid-file is a known gap (~12 ms, Phase 1) | 0.8–1.5 ms top |
| Scroll page (offset + layout + display) | < 6 ms | ~3.1–3.5 ms |
| Live line handles after a full scroll | < ~2k | ~450–950 |
| malloc after scrolling a 120k-line file | < 200 MB | ~140 MB |
| Glyph extracts / decoration builds per Enter | single digits | 6 / 2 |

Anything that runs per keystroke, per layout pass or per scrolled frame must cost O(visible lines)
or O(edit size), never O(document).

## 1. Hot paths never walk the document

The hot paths are: `insertText`/`replaceText`, `layoutSubviews`/`LayoutManager` passes, scroll,
selection changes, typing observers, and anything called from them (gutter, minimap, method
separators, folding, selection chrome, highlighting).

- No loop over every line, every match, every capture or every tree node on these paths. Limit
  work to the laid-out rows (`LayoutManager.laidOutCharacterRange`) or to the rows an edit touched.
- Per-selection work runs only for ranges near the viewport (see `SelectionOverlayController`):
  38k selected matches must not mean 38k rect computations per frame.
- Caches invalidate the rows an edit or parse touched, not the whole cache (minimap, method
  separators, semantic tokens, glyphs).
- A full scan is allowed on open, on configuration changes, and off the main thread. When it is a
  fallback for "rows went stale", shift the stored rows on edit instead
  (`MethodSeparatorController.noteLinesReplaced`).
- Respect the size cutoffs in `EditorPerformanceConstants` (e.g. `maxFoldRecomputeLineCount`); a
  new whole-document feature needs one too.

## 2. Don't create line handles to read a value

`LineManager.line(atRow:)` returns a `DocumentLineNode` handle, and every live handle is visited
on every line insert/removal.

- To read an ID, position, range or height, use `lineID(atRow:)`, `lineInfo(atRow:)`,
  `location(ofRow:)`, `contentRange(atRow:)`, `yPosition(ofRow:)`,
  `row(containingCharacterAt:)`, `row(containingYOffset:)`.
- Only take a handle when you need to hold it (it backs a `LineController`) and don't stash handles
  in long-lived collections.
- Add a test that counts handles created (see
  `FoldingControllerTests.testRecomputeWithoutCollapsedFoldsCreatesNoLineHandlesForFoldBodies`,
  `SelectionOverlayViewportTests`).

## 3. Don't copy the buffer on the main thread

- Never call `textView.text` (or otherwise materialize the piece tree) on a keystroke, layout or
  selection path. Read ranges (`StringView.bytes(in:)`, substring of a range) or take
  `pieceTreeContentSnapshot()` and read it elsewhere.
- Things that need the whole text (breadcrumbs, diagnostics, indexing) run after typing pauses,
  debounced and cancellable, off the main thread.
- Guard it with `pieceTreeMaterializeCount` in tests (see
  `InteractivePathTests.testLargeUntitledKeystrokeDoesNotMaterializeForCompletion`).

## 4. Keystrokes don't wait for intelligence

- Completion, hover, diagnostics, semantic tokens, inlay hints, parsing and indexing are scheduled
  from the keystroke, never awaited on it. The document, caret, undo group and visible layout
  finish first.
- Every async result is cancellable and checked for staleness before it's applied; a superseded
  result must not touch the document or the UI (`InteractivePathTests`).
- Repeated background updates to UI (console output, status, progress) are batched (≈100 ms), not
  posted per item.

## 5. Line controllers and memory stay bounded

- `LineControllerStorage` is evicted around the viewport after layout. Don't add a cache keyed by
  line that only ever grows: bound it, or key it by `DocumentLineNodeID` and drop entries with the
  controllers.
- Code that reads typesetting (fragments, caret rects) of a line that may be off-screen must lay
  it out on demand (`LineMovementController.typesetLineController`,
  `LayoutManager.typesetLineController(for:)`). A new or evicted controller reports "finished"
  with zero fragments.
- Shared immutable objects (themes, fonts, placeholders) are created once, not per line or per
  controller (`DefaultTheme.placeholder`).

## 6. Rendering: move, don't repaint

- A line that only moved vertically keeps its glyphs and decorations: cache keys are relative to
  the fragment origin (`GlyphExtractCacheKey.relevantEmitRect`, `DecorationBuildKey`). Don't put
  absolute content-space coordinates into a cache key.
- Don't re-extract glyphs or rebuild decorations "just in case" (e.g. while highlighting is
  pending). An equal key means the same output.
- A same-height edit must not relayout the rest of the viewport.
- Batch Core Text queries (glyph bounds) and memoize per-run lookups; never ask per glyph in a
  loop.
- Check `MetalPerformanceStats.glyphExtractCount` / `.decorationBuildCount` in tests when
  touching the renderer (`TextViewMetalSmokeTests.testReturnMovesLinesBelowWithoutReextractingThem`).

## 7. Threading

- Every `StringView` storage access takes its lock, reads included (piece-tree reads mutate lookup
  caches; an unlocked read was a use-after-free).
- Main-thread code never reads a `TreeSitterLanguageLayer`'s `tree` directly. Use
  `TreeSitterInternalLanguageMode.rootSyntaxNode` (private `ts_tree_copy`) or `nodeLookup(at:)`.
- Don't hold `parseLock` or the `StringView` lock across long work on the main thread; copy what
  you need and release.
- After touching parsing, text storage or anything shared with background work, run TSan:
  `swift build --product PerfHarness --sanitize=thread --build-path .build-tsan`, then
  `enter-session`.

## 8. Swift-level traps in hot loops

- No key-path literals inside generic hot code (`\.value` in a generic class instantiates a key
  path on every call); write the loop out.
- No `@MainActor` closures or `@objc` members called per item from non-isolated loops: each call
  pays an executor check. Keep inner loops plain; mark trivial overrides `nonisolated`.
- No `Set`/`Dictionary` rebuilt per edit from a large collection; keep sorted arrays and shift
  them.
- Don't allocate an object per tree node in walks that visit the whole tree; prefer a
  `TSTreeCursor`, and memoize per grammar symbol, not per type string.
- Drain an autorelease pool in long loops that touch AppKit/Core Text objects.

## 9. Measure, in Release, before and after

Debug timings of byte-scanning or tree-sitter code are misleading; never draw a conclusion from
them.

```bash
swift run -c release PerfHarness enter-session synthetic --lines 20000
swift run -c release PerfHarness enter-session synthetic --lines 120000
swift run -c release PerfHarness keystroke-budget <file> --lang java
swift run -c release PerfHarness java-completion synthetic   # completion changes
```

- Run the harness on the parent commit and on your change back to back (timings drift between
  sessions; compare pairs, not old tables). Report medians of at least two runs.
- Any change to layout, rendering, `LineManager`, folding, highlighting, selection, typing
  observers or the intelligence controller needs an `enter-session` run before and after.
- Make sure the harness measures what you think: check the caret really is where the step says
  (a broken `goToLine(.end)` once made every "mid-file" number a top-of-file number).
- When you fix a regression, add a test that counts the thing that was wrong (handles, rects,
  materializations, extracts), not a wall-clock threshold, and record the result in
  `docs/EDITOR_PERF_PLAN.md`.

## Checklist for a change

- [ ] Does anything new run per keystroke, per layout pass or per scrolled frame? Is it bounded by
      visible rows or edit size?
- [ ] Any `line(atRow:)` that only reads a value? Any `textView.text` on a hot path?
- [ ] Any new per-line or per-document cache? Is it bounded and invalidated by row?
- [ ] Any async result applied without a staleness check?
- [ ] Any main-thread access to tree-sitter trees or `StringView` storage without the lock/copy?
- [ ] `enter-session` at 20k and 120k lines, before and after, in Release.

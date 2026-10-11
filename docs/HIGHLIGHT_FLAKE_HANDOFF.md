# Handoff: stale heading colour after typing at several carets (Markdown)

Status: **open, not reproduced on demand.** Written 2026-10-11 on branch `external-file-changes`, after `87f3210` (drop a stale asynchronous line highlight) fixed a different flake in the same suite.

## The symptom

`IncrementalHighlightConsistencyTests.testTypingHeadingMarkersAtSeveralCarets` failed once:

```
[settled] incremental rendering differs from a fresh open:
row 3 "" col 0 "\n": Menlo-Bold 14.0 #9B2292 vs Menlo-Regular 14.0 #000000
```

The fixture is `"one\n\ntwo\n\nthree\n"`. `## ` is typed one character at a time, with carets at the start of `one`, `two` and `three` (`Edit.typeAtCarets`). Expected result:

```
row 0  ## one
row 1  (empty)
row 2  ## two
row 3  (empty)     ← its line break kept the heading's bold colour
row 4  ## three
```

After everything settled, the empty line under `## two` still carried the heading style (bold, `markup.heading` colour) on its only character, the line break. A freshly opened view of the same text shows it plain. Only colour and font differ; text, line heights, folds and method separators matched.

The failure was in **settled** mode: `settle(_:)` runs between keystrokes, so each keystroke waited for its parse and for the async highlights after it. Burst mode, which doesn't wait, passed in that run.

## How often

| Run | Failures |
| --- | --- |
| The suite alone (`--filter IncrementalHighlightConsistencyTests`), 4 runs after `87f3210` | 0 |
| The 168-test combination below, 4 runs | 1 |
| The full suite (4,755 tests), 1 run after `87f3210` | 0 |

The combination that failed:

```
caffeinate -u -d -i -s swift test --filter 'IncrementalHighlightConsistencyTests|StaleAsyncHighlightTests|SyntaxHighlight|Highlight|MarkdownLanguageTests|TextViewStateParsePolicyTests'
```

A related one-off: in another run of that combination, `testUndoingHeadingMarkerDeletion` (Markdown, backspace `## ` then undo three times) also failed. Its diff was not captured. It may be the same family, since both involve a heading forming or dissolving next to an empty line.

**Not caused by:** the stale-position bug fixed in `87f3210`. That bug shifted every token on a line by the length of an edit made above it. Here a single character on a line nobody edited has a style it never legitimately had. No intermediate state of this edit makes row 3 a heading.

## What is known about the code paths

A line can be painted by five paths. Any of them could have left this colour behind.

1. **Synchronous highlight on a keystroke.** `LineController.updateSyntaxHighlightingIfNecessary(async: false)` → `TreeSitterSyntaxHighlighter.syntaxHighlight(_:)` → `TreeSitterInternalLanguageMode.capturesIfReady(in:)`. This reads the *edited* tree (`ts_tree_edit` applied, not yet reparsed) with the line's current byte range.
2. **Asynchronous highlight** (`syntaxHighlight(_:completion:)`). Since `87f3210` it is dropped when `StringView.contentGeneration` moved, so a shifted result can no longer land through it.
3. **Capture-window cache.** `syntaxHighlightFromCache` → `cachedCapturesIfReady(in:)` / `captureWindows`, cleared in `textDidChange`.
4. **Colour shift on a one-line edit.** `TextInputView` (~line 3484) → `LayoutManager.redisplayLines(withIDs:colorShift:)`. This only applies when a single line changed. A multi-caret edit touches three lines, so in principle it shouldn't run here; confirm that it doesn't.
5. **Recolour after a parse.** `runBackgroundParse` records `pendingRootSyntaxRows` / `pendingSyntaxRows` from `changedRowRanges(old edited tree → new tree)`. Markdown has an inline child layer, so `pendingSyntaxRows` is nil and the caller recolours what is on screen. Check that this really reaches row 3, and that colour-only refreshes (`invalidateSyntaxColorsOnly`, `colorsStale`) reset the line before painting: `applyHighlights` resets unless `hasOnlyDefaultAttributes`.

Relevant query: `Sources/PenumbraMarkdownLanguage/Queries/Block/highlights.scm` captures the **whole `atx_heading` node** (`(atx_heading (atx_h2_marker)) @markup.heading.2`). If that node's range ever reaches the first byte of the next line, path 1 or 3 paints row 3 col 0. In tree-sitter-markdown the node ends after its line break, which is the exclusive start of the next line, so a correct tree should never do this.

## Hypotheses (unverified, in the order I would test them)

1. **An edited-but-not-reparsed tree briefly extends the heading over the empty line.**
   - Three insertions per keystroke mean three `ts_tree_edit`s on one tree before the parse. Edit arithmetic can leave a node ending in the wrong place until the reparse.
   - A synchronous highlight of row 3 in that window paints it. The recolour after the parse then has to reach row 3.
   - The flake would follow if, under load, the recolour sees row 3 as already highlighted (`isSyntaxHighlightingInvalid == false`), or the parse publishes after `settle` stopped looking.
2. **The recolour after a parse skips row 3.** The paths decide which rows to recolour (`pendingRootSyntaxRows` vs "everything on screen") and which lines are marked `colorsStale`. A row whose text did not change might be left out under a timing-dependent ordering, for example while a parse is in flight during the next keystroke (the `textDidChange` branch that bumps `parseEpoch` and returns an empty `LineChangeSet`).
3. **The inline (injected) layer is out of step with the block tree** after a multi-caret edit, and paints bold (`**`/heading inline content) from a stale child-layer range.

## Plan

1. **Make it reproduce.**
   - **Stress test:** add a temporary stress variant that runs `assertConsistent` for this fixture 200 times in one process, settled mode only, stopping at the first diff.
   - **Load:** run it alongside CPU load (`for i in 1 2 3 4; do yes > /dev/null & done`, kill afterwards), since the failure only appeared under a heavier test mix.
   - **Shuffle:** also try the 168-test combination in a loop.
   - **Goal:** a rate high enough to bisect, at least 1 in 20.
2. **Instrument (test-only, not on hot paths).** Record per line controller which path last painted it (sync / async / cache / colour shift / parse recolour), the `contentGeneration` and parse epoch at that moment, and the captures returned for its byte range. On a diff, dump that for the differing row together with the current tree's `atx_heading` ranges. A `#if DEBUG` hook or a `ForTesting` property on `LineController`, like `displayedLineForTesting`, is enough.
3. **Narrow by switching paths off:**
   - turn on `PenumbraSyncKeystrokeParse` (the `withSyncKeystrokeParse` helper in the test file);
   - bypass the capture-window cache;
   - force every highlight async;
   - force a full-viewport recolour after each parse.

   Whichever change makes the flake vanish names the path.
4. **Write a deterministic test** for that path once found, in the style of `StaleAsyncHighlightTests`: drive the language mode and highlighter directly, hold the parse or highlight queue (`OperationQueue.isSuspended`), and apply the three-caret edit between steps.
5. **Fix, then verify.**
   - **Stress:** the stress loop passes 0 failures in 500 iterations, under load.
   - **Suites:** the combination passes 10 times in a row, and the full suite passes.
   - **Performance:** `swift run -c release PerfHarness enter-session synthetic --lines 20000` shows no regression, measured on the parent commit and on the change, per `docs/PERFORMANCE_RULES.md`.

## Constraints

- Follow `docs/PERFORMANCE_RULES.md`: no work per keystroke that grows with document size, and don't wait for a parse on a keystroke. A fix that "reparses synchronously before highlighting" is not acceptable on the typing path.
- Follow the threading rules in the root `CLAUDE.md`: main-thread code must not read a `TreeSitterLanguageLayer`'s `tree` directly (use `rootSyntaxNode`), and every `StringView` read takes its lock.
- Remove the stress test and the instrumentation before merging, or gate them behind an environment variable so the normal suite stays fast.

## Pointers

- **Test and harness:** `Tests/PenumbraTests/IncrementalHighlightConsistencyTests.swift` (`assertConsistent`, `settle`, `differences`, `minimapDifferences`).
- **Line painting:** `Sources/Penumbra/TextView/LineController/LineController.swift` (`prepareString`, `updateSyntaxHighlightingIfNecessary`, `invalidateSyntaxColorsOnly`).
- **Highlighter:** `Sources/Penumbra/TextView/SyntaxHighlighting/Internal/TreeSitter/TreeSitterSyntaxHighlighter.swift`.
- **Parsing, captures, recolour rows:** `Sources/Penumbra/TextView/SyntaxHighlighting/Internal/TreeSitter/TreeSitterInternalLanguageMode.swift` (`textDidChange`, `runBackgroundParse`, `capturesIfReady`, `cachedCapturesIfReady`).
- **Colour shift:** `Sources/Penumbra/TextView/Core/TextInputView.swift` (~3484) and `LayoutManager.redisplayLines(withIDs:colorShift:)`.
- **Previous fix, as a model for the deterministic test:** `87f3210`, `Tests/PenumbraTests/StaleAsyncHighlightTests.swift`.

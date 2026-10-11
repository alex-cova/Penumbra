# Stale heading colour after typing at several carets (Markdown)

Status: **fixed** on branch `external-file-changes` (2026-10-11).

## The symptom

`IncrementalHighlightConsistencyTests.testTypingHeadingMarkersAtSeveralCarets` failed once under a heavy test mix: after `## ` was typed at three carets in `"one\n\ntwo\n\nthree\n"`, the empty row 3 kept the heading's bold colour on its line break (`Menlo-Bold #9B2292` vs `Menlo-Regular #000000`). `testUndoingHeadingMarkerDeletion` failed once the same way.

## Cause

The painting paths were not at fault. The **tree** was wrong.

A buffer edit reaches the language mode in two steps: `TextEditHelper.replaceText` changes `StringView` and `LineManager`, and only afterwards does `TextInputView.replaceText` call `TreeSitterInternalLanguageMode.textDidChange` (epoch bump and `ts_tree_edit`). A background parse that **publishes between the two** stores a tree built from the new text with the old, unedited tree as its base. `textDidChange` then applies the edit a second time on top of it, and every later incremental parse trusts the result. The published tree had heading nodes ending past their own line (`markup.heading.2@16..<32`, `@32..<52` in a 50-byte document), so a heading's capture reached the first byte of the empty line below it.

The window is a few instructions wide on the main thread, so it only opened when the machine was loaded. It was easy to hit with three carets because each caret is its own edit and its own parse restart.

A second defect in the same area made the stress run trap (`Negative value is not representable`, `PackedLineIndex.row(containingUTF16:)` out of range, two crash reports on 2026-10-11): `parse(completion:)` passed `NSRange(0, stringView.length)` and then `setRootIncludedUTF16Range` read the length again, so an edit in between made the whole-document request look like a viewport window and the background thread walked `LineManager` while the main thread edited it.

## Fix

- `TreeSitterInternalLanguageMode.syncedContentGeneration`: the `StringView.contentGeneration` the tree was last brought in step with (`textDidChange`, `invalidateSyntaxTree`, `parseFromBuffer`). A parse whose buffer generation is ahead of it when it publishes is dropped like one whose epoch moved on; `textDidChange` then sees `tree == nil` and the caller restarts the parse after the edit. Cost: one locked 64-bit read per parse.
- `StringView.contentGenerationSnapshot`: the locked read that makes the above safe off the main thread.
- A whole-document parse passes `nil` instead of a length (`parseUsingReader(coveringUTF16Range:)`).

## Tests

- `MultiCaretIncrementalParseTests.testAParsePublishedBetweenTheBufferChangeAndTheEditNoticeMatchesAFreshParse`: the deterministic regression test (a background parse between the buffer change and the edit notice, for each of the nine edits). Fails on the parent commit with the extra heading ranges above, passes with the fix.
- `MultiCaretIncrementalParseTests.testEveryInterleavingOfParsesMatchesAFreshParse`: parse / no parse / invalidate between the nine edits. All 6,561 combinations matched a fresh parse (set `combinationStride` to 1 to run them); the suite runs every 97th.
- `IncrementalHighlightConsistencyTests.testStressSettledMultiCaretHeadings`: skipped unless `PENUMBRA_HIGHLIGHT_STRESS=<iterations>` is set. Reruns the settled-mode fixtures until one differs; run it under CPU load (`for i in 1 2 3 4; do yes > /dev/null & done`, then `pkill yes`).

## Verification

- Stress, 100 iterations of both fixtures under 4× CPU load: 0 diffs, no crash (the parent crashed about 7 minutes in at 200).
- Highlight/tree-sitter/Markdown suite combination (195 tests), 10 runs: 0 real failures.
- `PerfHarness enter-session synthetic --lines 20000` (release), parent vs change: `enter_fresh_top` 1.86/1.96 vs 1.86/1.88 ms, `enter_fresh_middle` 21.2/21.5 vs 21.2/21.1 ms, `scroll_step` 4.0 vs 4.0 ms. No change.

## Still open (not part of this fix)

The viewport parse policy (`parse(coveringUTF16Range:)`) still converts its window to line/column points on the parse's background thread (`ViewportParseWindow.textRange` → `LineManager`), which is the same class of off-main read the whole-document path had. Converting the window on the main thread before the operation is queued would close it. Not reproduced.

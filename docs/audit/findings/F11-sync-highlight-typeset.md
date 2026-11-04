# F11 — Synchronous highlight/typeset on edited lines; long-token typesetter

- **Priority:** P1 · **Severity:** Medium · **Confidence:** Confirmed, narrower than first reported · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-03): typesetter search and word-wrap lookback fixed; sync highlight measured and left alone · **Owner:** Unassigned

## Evidence

- Edited visible lines highlight synchronously on the main thread (`LineController.updateSyntaxHighlightingIfNecessary`, LayoutManager highlightAsynchronously=!recentlyEdited); large byte ranges force async. Async completions re-typeset and re-extract glyphs, coalesced into one present.
- `LineTypesetter.makeNextLineFragment:175-184` decrements length by 1 and recreates a `CTLine` until it fits. Normal suggested line breaks take one iteration — the quadratic case is only long unbreakable tokens (no-wrap width 10,000).
- By default the keystroke tree-sitter parse itself is deferred (`PenumbraSyncKeystrokeParse` default false); sync parse with its 50 ms abort is an opt-in flag, not the default path.

## Root cause

Edited-line freshness is prioritized over frame budget; the typesetter search is linear instead of binary.

## Fix sketch

Binary-search the fitting length in the typesetter loop. Add a time budget to sync highlight with async fallback (the range-size force-async is the existing precedent). Measure before changing edited-line sync policy.

## Complexity / Dependencies

M (S for the typesetter search alone).

## Acceptance criteria

- Long-unbreakable-token fixture (e.g. 10k-char line) typesets without per-char CTLine creation; profiling shows the loop gone.
- No visible highlight flicker regression on edited lines.

## Tests / benchmarks

- Time Profiler on the long-token fixture; existing highlight consistency tests (display on).

## Out of scope

Changing the deferred-parse default; highlight query redesign.

## Implementation notes (2026-11-03)

- **The brief's premise was half wrong, and measuring found the real shape.** A long unbreakable token does not hit the decrement loop: `CTTypesetterSuggestLineBreak` breaks it at the width, so the loop runs once (one `CTLine` per fragment, counted with the new `LineTypesetter.createdLineCount`). The loop runs away when the suggested break *overhangs*, which CoreText does for trailing whitespace: a 2,000-space run before a word built 1,903 `CTLine`s for two fragments (24.5 ms for 20,000 spaces), and twenty words with 300 spaces between them built 4,120 lines for 20 fragments.
- **A second cost the brief only hinted at (the "long-token typesetter" in its title):** `WordWrappingLineBreakSuggester` looks back up to 100 characters for a place to break, and each look built an attributed substring, a `String`, a trimmed copy and a `CharacterSet` (`prefersInsertingLineBreakAfterCharacter`); `lengthOfWhitespace` did the same per hidden space. That, not the `CTLine`s, is why a 10,000-character token took 16.6 ms to typeset at width 800 and a 20,000-character base64 line 43.6 ms.
- **Fix.** (1) `LineTypesetter.longestFittingLineFragment`: build the suggested length first (one line, the normal case); if it overhangs, start at `CTTypesetterSuggestClusterBreak` (how many characters fit), check its two neighbours, and bisect when the guess is off, so the search is bounded by log2(length) lines whatever the text. It returns the same fragment the linear search did (the longest fitting prefix; the one-character fragment when nothing fits). The old code passed `length - 1` to `lengthOfWhitespace(after:)` because it had decremented once more than it used; the new call passes `startOffset + length - 1` explicitly. (2) `NSAttributedString.isWhitespaceCharacter(at:)` and the new `prefersLineBreak(after:)` read the one UTF-16 unit from the backing `CFString` (a surrogate half is neither whitespace nor punctuation, as the `U+FFFD` it became before).
- **Measured, release, `PerfHarness typeset-long`, paired against the parent commit, two runs each (median ms, parent to now):** 10k-character token at width 800: 16.6 to 3.4-4.3; 20k base64 line: 43.6 to 15.6; 50k minified line: 1.42 to 0.78; 2,000 spaces then a word: 1.42 to 0.04; 20,000 spaces then a word: 24.5 to 0.41 (4 lines built, was about 19,900); twenty words with 300-space gaps: 2.97 to 0.12 (60 lines built, was 4,120). The 50k code line at width 10,000 is unchanged at 5.1-5.3 ms (CoreText itself; 50 lines for 40 fragments).
- **Tests (`LineTypesetterTests`).** Fragment ranges (visible and hidden length) equal a copy of the old linear search with the old slow helpers, over 10 hand-built fixtures (tokens, space runs, tabs, CJK, emoji, URL, tight width) and 40 seeded random strings with random widths, in both word and character wrap; a 2,000-space run builds at most 25 lines; ordinary text builds exactly one line per fragment; the two helpers agree with the substring versions on every unit of a string with whitespace, punctuation, CJK, emoji and a combining mark. Mutations: returning the longest prefix instead of the search result fails the equality test on the space-run fixtures (it needed the visible/hidden comparison, the combined range alone hid it); dropping punctuation from `prefersLineBreak` fails it on 12 fixtures.
- **Sync highlight on edited lines: measured, left alone, as the brief said to measure first.** The synchronous path is already bounded: a line over `TreeSitterPerformanceConstants.maxSyncQueryLength` (4,096 units) is forced async, and a query that does not finish leaves the line pending (`lastSyncHighlightWasComplete`). `PerfHarness keystroke-budget --lang java`, typing in the middle of a single long line: 20 characters 0.2 ms p95, 400 0.4, 1,000 0.7, 2,000 1.2, 3,000 1.7, 4,000 2.2 (the largest line still highlighted synchronously), 8,000 1.4 (async). So the worst the sync path adds is under 1 ms, inside the 4 ms budget, and a time budget would only move a bounded cost. No change to the edited-line policy, so no flicker risk was taken.
- **Not done:** the per-fragment `CTTypesetterCreateLine` for a very long no-wrap line is still CoreText's cost (5 ms for a 50k line); a Time Profiler trace was not taken because the counter and timings answer where the time went.

# Penumbra editing-latency pass — 2026-09-15

Scope: confirmed regressions and gaps found by independently re-verifying the two existing audits
(`PERFORMANCE_AUDIT.md`, `audit.md`) against the current code and tracing the live typing/render
hot path line-by-line, rather than re-auditing from a blank slate. See those two documents for the
full architecture history (piece-tree storage, mmap load, the Metal glyph-atlas renderer, viewport
tree-sitter parsing) — none of that is re-described here; this report only covers what changed in
this pass.

## Before

**Architecture, verified current (not assumed from prior docs):** piece-tree storage for file-backed
*and* large in-memory (≥256 KiB) documents; mmap load with a fat-leaf order-statistics line index;
viewport/eager tree-sitter parse policy with `syntaxParseGeneration` staleness gating; a 9-PR Metal
glyph-atlas renderer, shipped and default-on outside XCTest; async debounced cancellable find; delta-
based undo; a real save path; `Package.swift` in genuine Swift 6 language mode
(`swiftLanguageMode(.v6)`, corrected in `PERFORMANCE_AUDIT.md` — the doc previously said Swift 5 mode
was still in effect); `Tools/PerfHarness`; 968 passing tests, 0 build errors, 2 pre-existing warnings
(both in `Tools/PerfHarness`, unrelated to this pass).

**Baseline correctness:** 19 of 20 `audit.md` P0–P2 findings independently re-verified as fixed by
direct code citation (not by trusting the document's own prior annotations); 1 partial (LSP
`utf16Offset` root conversion — `EditorIntelligenceLSP` adapter scope, out of this pass).

**Confirmed still-live problems found by this pass's own tracing** (not present in either prior
audit document):

1. A **regression** from the repo's own WIP commit `665f59b` ("fix Metal syntax-highlight white
   flash on typing"): typed characters could sit **stale/invisible** on screen until a background
   tree-sitter parse finished, and a Tree-sitter language with no highlights query could get stuck
   holding stale glyphs **permanently**.
2. Two confirmed **O(document-size) synchronous main-thread allocations** still on the per-keystroke
   path for piece-tree (large/file-backed) documents.
3. A **per-keystroke full-viewport Metal instance-buffer rebuild** even when only one fragment
   actually changed.
4. Three genuinely **absent** VS Code/Zed-table-stakes commands: toggle line comment, insert line
   above/below, sort lines — confirmed absent by exhaustive `grep`, not assumed.

## Changes

### 1. Stale/invisible glyphs while typing (regression from `665f59b`)

**Problem:** `MetalRenderer.upsertFragment` holds the *pre-edit* glyph instances whenever
`spec.isSyntaxHighlightPending` is true and the fragment already has glyphs (the original fix for
the "white flash" bug). `isSyntaxHighlightPending` is `isSyntaxHighlightingInvalid &&
canEventuallyHighlight`. `canEventuallyHighlight` is a `LineSyntaxHighlighter` protocol requirement
defaulting to `true`; `TreeSitterSyntaxHighlighter` never overrode it, so it was always `true`.

**Root cause:** the hold-previous-glyphs policy couldn't distinguish "a highlight is genuinely still
in flight" from "no highlight will ever land here" — both looked identical (`isSyntaxHighlightingInvalid
== true`, `canEventuallyHighlight == true`). Since `textDidChange` sets exactly this pending state on
routine, ordinary tree-sitter parse activity (not just rare edge cases), practically every keystroke
landing during a background parse showed the *previous* character's glyphs instead of the new one
until that parse's highlight completed.

**Solution:** added `TreeSitterLanguageLayer.highlightsQueryAvailable` (true iff this layer or any
injected child layer has a highlights query), threaded through
`TreeSitterInternalLanguageMode.highlightsQueryAvailable` and wired as
`TreeSitterSyntaxHighlighter.canEventuallyHighlight`. A language with no highlights query now
extracts immediately instead of holding glyphs forever. Also: `handleSyntaxParseFinished` now calls
`scheduleDeferredLayoutIfNeeded()` (every sibling invalidation path already did; this one didn't),
and `LayoutManager.refreshMetalGlyphsAfterSyntaxHighlight` no longer calls `presentMetalCanvasIfNeeded()`
directly — it relies on `upsertFragment`'s existing `canvasView?.setNeedsDisplay()` to coalesce
N visible lines finishing highlight in one parse round into one deferred present instead of N
separate encode+`waitUntilScheduled()` cycles.

**Files changed:** `TreeSitterLanguageLayer.swift`, `TreeSitterInternalLanguageMode.swift`,
`TreeSitterSyntaxHighlighter.swift`, `TextInputView.swift` (`handleSyntaxParseFinished`),
`LayoutManager.swift` (`refreshMetalGlyphsAfterSyntaxHighlight`).

**Verified:** existing test `TreeSitterHighlightReadinessTests
.testLineControllerLeavesHighlightPendingInsteadOfSilentlyMarkingItComplete` — which specifically
asserts the "still pending during an outstanding reparse" case stays `true` — needed its fixture
language updated to carry a real (if trivial) highlights query, since it previously (accidentally)
relied on `canEventuallyHighlight`'s old always-`true` behavior rather than exercising a language
that actually has a query. Fixed and passing; full suite green (968/968 including this one).
No dedicated pixel-level regression test was added for the stale-glyph symptom itself (would need a
`TextViewMetalSmokeTests`-style forced-slow-parse harness) — flagged under Remaining Bottlenecks.

### 2. Two per-keystroke O(document) allocations on large documents

**2a — `OccurrenceHighlightController.term(for:)`**

**Problem:** called synchronously from `selectionDidChange`, which fires on every keystroke
(`_selectedRange.didSet`) — *before* the controller's own 120 ms debounce. Opened with
`let string = stringView.string`, a full UTF-16 materialization of the whole document on a
piece-tree buffer, used only for a `.length` bound-check and to call
`SelectNextOccurrence.wordRange(at:in:tokenizer:)`.

**Root cause:** `wordRange(at:in:tokenizer:)`'s `NSString` parameter was only ever used for its
`.length` — the actual word-boundary walk is fully delegated to `tokenizer`, which is already
`StringView`-backed. The materialization was pure waste, and it ran on every keystroke rather than
after the debounce.

**Solution:** `wordRange` now takes `documentLength: Int` instead of the full string. `term(for:)`
uses `stringView.length` (O(1)) for the bound check and `stringView.substring(in:)` (bounded) for
the actual text — never touches `stringView.string`. Also fixed the same unconditional
materialization in `runSearch` (runs *after* the debounce, so lower severity, but directly
adjacent): it now uses `stringView.contentSnapshot()` (the same `Sendable`, non-materializing
`PieceTreeContentSnapshot` source `TextView.makeFindTextSource()` already uses for Find) instead of
building a `String` on the main thread before dispatching to the search task.

**2b — `restartSyntaxParseAfterCancelledEdit` → `startFullParse(of: string, …)`**

**Problem:** `string` here was `stringView.string` (full materialization). `startFullParse` called
`languageMode.parse(text) { … }`, whose implementation (`TreeSitterInternalLanguageMode.parse`)
**never read `text`** — it always called `parseUsingReader(coveringUTF16Range:)`, which walks the
piece tree in bounded chunks. So every time a keystroke landed mid-parse (exactly the condition that
triggers this path), the document was fully materialized and the copy was thrown away unused.

**Root cause:** confirmed the `NSString` parameter was dead on *every* implementation of
`InternalLanguageMode.parse(_:)`/`parse(_:completion:)` (`TreeSitterInternalLanguageMode`,
`PlainTextInternalLanguageMode`) — the protocol's own default `parseFromBuffer()` implementation
even called `parse("" as NSString)`, already treating the argument as a throwaway placeholder.

**Solution:** removed the `NSString` parameter from `InternalLanguageMode.parse()` /
`parse(completion:)` entirely (both implementations, the protocol, and every call site in
`TextInputView`), rather than patching just the one call site — the parameter was structurally
vestigial across the whole protocol, not a one-off. Also deleted a second, previously-dead code
path this cascaded into: `TreeSitterInternalLanguageMode`'s private `parse(_:isCancelled:)` and
`TreeSitterLanguageLayer.parse(_:NSString)`/`parse(ranges:from:)` had **zero remaining callers**
once the public `parse(_:)` overload's argument was removed — an entire second, unreachable
whole-text parse path alongside the real `parseUsingReader()` one. Removed rather than left as a
landmine (the same reasoning `PERFORMANCE_AUDIT.md` already used once, for the dead
`layoutLines(toLocation:)` path).

**Files changed:** `SelectNextOccurrence.swift`, `OccurrenceHighlightController.swift`,
`InternalLanguageMode.swift`, `TreeSitterInternalLanguageMode.swift`,
`PlainTextInternalLanguageMode.swift`, `TreeSitterLanguageLayer.swift`, `TextInputView.swift`,
`StringSyntaxHighlighter.swift` (one call site), plus ~15 test call sites updated mechanically
(`languageMode.parse(text as NSString)` → `languageMode.parse()`).

**Verified:** new `StringMaterializationRegressionTests.swift` — three tests on a bare,
piece-tree-backed (>256 KiB) `TextInputView` (no window, no `TextView`, no layout — see the file's
own header comment for why), asserting `stringView.materializeCount` (`PieceTree.materializeCount`,
a real counter that already existed on `StringView`/`PieceTree` before this pass) stays exactly 0
across 10+ keystrokes with occurrence highlighting enabled (empty-selection, exercising the real
`tokenizer`, and explicit-selection paths), and across a keystroke that triggers
`restartSyntaxParseAfterCancelledEdit`'s full-parse branch. All three pass. Full suite green.

### 3. Per-keystroke Metal instance-buffer full rebuild

**Problem:** `MetalRenderer.upsertFragment` set `needsInstanceRebuild = true` unconditionally on
*every* call — and `LayoutManager` calls `upsertFragment` for every visible fragment on every
layout pass (this is how display-only invalidation, e.g. marked-text/invisible-character toggles,
gets a fresh spec — there's no ID-only decoration invalidate by design). `encode()` responded to
that flag by re-bucketing *every* tracked fragment's glyph instances into fresh dictionaries, then
`.map`-copying every instance again for pixel alignment — a full-viewport-sized allocation and copy
for a single-character edit touching one fragment out of (typically) 90–200 visible ones.

**Root cause:** no comparison between the fragment's previous and newly-computed rendered output
before deciding a rebuild was needed — every upsert was treated as a change.

**Solution:** made `MetalDecorationGeometry` `Equatable` (its constituent types — `SolidInstance`,
`DecorationVertex`, `GlyphInstance` — already were). `upsertFragment` now captures the fragment's
previous `glyphs`/`decorations` before mutating, and only sets `needsInstanceRebuild`/calls
`setNeedsDisplay()` when the *new* values actually differ from the previous ones. Decorations are
still unconditionally *rebuilt* (correctness-load-bearing, per the existing design notes on why
there's no ID-only decoration invalidate) — only the downstream instance-buffer rebuild is now
skipped when nothing actually changed. This is the "partial rebuild optimization" the renderer's own
design notes already named as deliberately deferred past PR 6 ("skip the CTRun walk when both
`ctLineID` and `emitRect` match… is then a *partial* rebuild optimization, not the correctness
split") — done now that the correctness split itself is settled.

**Files changed:** `MetalDecorationBuilder.swift` (`Equatable`), `MetalRenderer.swift`
(`upsertFragment`).

**Verified:** confirmed by direct reading that `GPUFragment.frame` (also touched by every upsert) is
write-only in `MetalRenderer.swift` — nothing downstream reads it back — so gating only on
`glyphs`/`decorations` equality doesn't skip a needed rebuild for a frame-only change. Confirmed
`GlyphExtractCacheKey.shouldRebuild` (which governs *re-extraction*, a separate, already-existing
cache) is untouched by this change — it still keys on `revision`+`emitRect`, not `frame`, so this
change doesn't alter what gets re-extracted, only whether an unchanged result triggers a redundant
buffer rebuild. Full test suite green (Metal-path tests included:
`MetalDecorationTests`, `MetalTextCanvasViewTests`, `TextViewMetalSmokeTests`,
`GlyphRunExtractorTests`). No dedicated micro-benchmark isolating the instance-buffer-rebuild cost
specifically was added — `Tools/PerfHarness`'s `scroll-frames`/keystroke commands don't isolate this
layer; flagged under Remaining Bottlenecks / harness gaps below.

### 4. Feature gap — toggle line comment (⌘/)

**Confirmed absent** before this pass: exhaustive `grep` for `toggleComment`, `lineCommentPrefix`,
`blockComment`, or any comment-token concept returned nothing anywhere in `Sources/Penumbra` or the
language packs. `JoinLinesService` already special-cased `"//"` for its own comment-merge behavior —
the second place this exact logic was needed, which is the signal a shared per-language token was
worth adding.

**Solution:** added `public let lineCommentPrefix: String?` to `TreeSitterLanguage` (threaded through
`TreeSitterInternalLanguage` and exposed on `InternalLanguageMode` as
`var lineCommentPrefix: String? { get }`, default `nil`, overridden by
`TreeSitterInternalLanguageMode` to read the root layer's language). New `CommentToggleService`
(pure computation, mirrors `JoinLinesService`'s shape exactly): decides comment-vs-uncomment
direction (comments if any touched non-blank row lacks the prefix, matching VS Code/Zed), computes
one edit per row at the row's indentation boundary (not column 0). `TextInputView.toggleComment()`
applies all edits under one undo group (`beginIsolatedUndoGrouping`), multi-caret aware — mirrors
`shiftAllSelections`'s row-set + descending-application shape. Public `TextView.toggleComment()`.
Bound to ⌘/ in the default keymap (inherited by the IntelliJ preset, which doesn't touch `/`) — no
existing binding collision (confirmed by grep before assigning).

**Files changed:** `TreeSitterLanguage.swift`, `TreeSitterInternalLanguage.swift`,
`InternalLanguageMode.swift`, `TreeSitterInternalLanguageMode.swift`, new
`CommentToggleService.swift`, `TextInputView.swift`, `TextView.swift`, `EditorActionID.swift`,
`Keymap.swift`, `TextInputView+MouseKeyboard.swift`.

**Two follow-up gaps found and fixed after the initial pass**, both caught by re-auditing the
delivered work rather than assuming "wired up" meant "usable":

1. **No bundled language actually had `lineCommentPrefix` set.** Adding the field to
   `TreeSitterLanguage` made the feature *possible*, but every real, shippable language
   (`PenumbraLanguages`' JS/TS/Python/YAML/Swift/Go/Java/Kotlin/Bash/SQL/TOML/HTTP/Mermaid, plus
   `PenumbraGraphQLLanguage`) still left it at the default `nil` — ⌘/ would have been a silent
   no-op for every one of them. Fixed by setting the real per-language token at each of their 9
   call sites (`//` for the C-family languages, `#` for Python/YAML/Bash/TOML/HTTP/GraphQL, `--`
   for SQL, `%%` for Mermaid); JSON/HTML/CSS correctly keep `nil` — none has line-comment syntax.
   Verified by new `LanguagePackTests.testBundledLanguagesHaveTheirRealLineCommentPrefix`, asserting
   both the populated and the deliberately-`nil` cases.
2. **The 5 new `EditorActionID`s were never added to `CommandRegistry.findActionIDs`.** That list
   is a hand-maintained array, not automatically derived from every `EditorActionID` with a
   built-in title as its own doc comment claims — so despite being fully wired end-to-end
   (dispatch, keymap), none of the 5 new commands would have appeared in the Find Action palette or
   Search Everywhere's `>` actions scope; `sortLinesAscending`/`sortLinesDescending` (deliberately
   keybinding-less) would have been *entirely unreachable* through the UI. Fixed by adding all 5 to
   `findActionIDs`. Added a standing regression guard,
   `CommandPaletteControllerTests.testFindActionIDsCoversEveryBuiltInTitledAction`, asserting
   `findActionIDs` and `EditorActionID.builtInTitles` stay in sync — so the next new action can't
   silently repeat this gap.

**Verified:** new `CommentToggleServiceTests.swift` (16 pure-function tests: direction decision,
indent-aware comment/uncomment, blank-line handling, multi-row, configurable prefix) and 8 of the 21
tests in `LineCommentAndInsertLineTests.swift` (integration: single/multi-caret, indent
preservation, one-undo-step, no-op with no prefix configured, ⌘/ keyboard dispatch), plus the two
follow-up fixes' own tests above. All pass.

### 5. Feature gap — insert line above/below (⌘⏎ / ⌘⇧⏎)

**Confirmed absent**, same method. `TextInputView.insertLine(above:)`: for each distinct touched
row, computes an indent-matched blank-line insertion (handles the "last line has no trailing
delimiter yet" edge case correctly — inserts the delimiter on the correct side). Multi-caret aware.

**Correctness note — a real bug caught and fixed before this shipped:** the first implementation
computed each caret's final resting position *during* the descending-order edit-application loop
(`caretLocations.append(insertion.location + insertion.caretOffset)`), which is exactly the pattern
`duplicateSelectedLines` (the closest existing precedent) deliberately does *not* use — because
inserting a line changes row *count*, a later (lower-location) insertion in the same batch shifts an
already-computed, already-stored caret target for an earlier-processed (higher-location) insertion,
silently making it stale. Caught via manual trace during implementation (not by a failing test — the
existing single-caret tests couldn't have caught it), fixed by switching to the same two-phase
pattern `duplicateSelectedLines` and `toggleComment` already use correctly: apply all edits first
(precomputed locations, descending order, so pending locations stay valid), then re-resolve every
final caret position via `location(forRow:column:)` against the fully-updated `lineManager` —
`sortedRows[i]`'s own blank line lands at final row `row + i` (above) / `row + i + 1` (below), a
direct consequence of exactly `i` earlier insertions having already landed before it.

**Files changed:** `TextInputView.swift`, `TextView.swift`, `EditorActionID.swift`, `Keymap.swift`,
`TextInputView+MouseKeyboard.swift`.

**Verified:** `LineCommentAndInsertLineTests.swift` — single-caret above/below, indent matching,
first-line/last-line edge cases, **multi-caret** (the case that caught the bug above), one-undo-step,
⌘⏎/⌘⇧⏎ keyboard dispatch. All pass.

### 6. Feature gap — sort lines (command palette / Find Action only, no default keybinding)

**Confirmed absent**, same method. New `LineSortService` (pure computation, mirrors
`JoinLinesService`): sorts a contiguous row block by content, case-sensitive, ascending or
descending; preserves the block's own leading/trailing edge (whether it ends mid-document or is the
document's final unterminated line) exactly, normalizing only *internal* line breaks to the
document's own preferred ending — a deliberate, documented simplification for the (rare) mixed-line-
ending case. `TextInputView.sortSelectedLines(descending:)` sorts each contiguous block
independently (`contiguousRowGroups`, already existed for indent/duplicate), one undo step; a
single-row block is left alone. Public `TextView.sortSelectedLinesAscending()` /
`sortSelectedLinesDescending()`.

**Files changed:** new `LineSortService.swift`, `TextInputView.swift`, `TextView.swift`,
`EditorActionID.swift`, `TextInputView+MouseKeyboard.swift`.

**Verified:** new `LineSortServiceTests.swift` (9 pure-function tests: ascending/descending,
case-sensitivity, single-row no-op, trailing-newline preservation in both directions,
out-of-bounds handling) and 4 integration tests in `LineCommentAndInsertLineTests.swift`
(ascending/descending, single-line no-op, one-undo-step). All pass.

## Editing improvements (summary)

| Command | Shortcut | Multi-caret | Notes |
|---|---|---|---|
| Toggle line comment | ⌘/ | Yes | Per-language `lineCommentPrefix`; no-op without one configured |
| Insert line above | ⌘⇧⏎ | Yes | Indent-matched |
| Insert line below | ⌘⏎ | Yes | Indent-matched; handles final-line-with-no-delimiter |
| Sort lines ascending | — (palette) | Per contiguous block | Case-sensitive |
| Sort lines descending | — (palette) | Per contiguous block | Case-sensitive |

## Rendering / parsing / editing-latency improvements (summary)

- **Correctness:** typed characters no longer go stale/invisible during a background tree-sitter
  parse; a highlights-query-less language no longer holds glyphs stuck forever.
- **Latency:** two confirmed O(document-size) synchronous main-thread operations on the per-keystroke
  path are now O(1)/bounded on large (piece-tree) documents — occurrence highlighting no longer
  scales with file size, and the post-cancelled-parse restart no longer materializes a document it
  was going to discard unused. Both proven via `PieceTree.materializeCount` staying exactly 0 across
  repeated keystrokes on a real >256 KiB document, not inferred from timing.
- **Rendering:** the Metal renderer's per-keystroke instance-buffer rebuild is now skipped for
  visually-unchanged fragments (most of the 90–200 typically-visible fragments, on any edit touching
  one line), rather than unconditionally re-bucketing and pixel-aligning every visible glyph on every
  layout pass.
- **Dead code removed:** an entire second, unreachable tree-sitter whole-text parse path
  (`TreeSitterLanguageLayer.parse(_:NSString)` / `parse(ranges:from:)`) that this pass's own fix made
  unreachable — deleted rather than left as a landmine, per the existing precedent in
  `PERFORMANCE_AUDIT.md` for the same class of issue.

## Large file performance

Not re-measured in this pass — none of the six changes above touch the storage/load/parse-scheduling
architecture that `PERFORMANCE_AUDIT.md`'s own large-file numbers (piece-tree mmap load, 10 MB/100 MB/
500 MB/2 GB open+RSS+keystroke tables) already cover, and re-running those specific benchmarks would
only reproduce numbers that document already has. What *is* new here — the two O(document-size)
per-keystroke materializations (occurrence highlighting, cancelled-parse restart) — would have shown
up as exactly the kind of "small file invisible, huge file catastrophic" latency spike
`PERFORMANCE_AUDIT.md`'s own methodology warns about, on any file large enough to be piece-tree-backed
(≥256 KiB) with occurrence highlighting on; both are now confirmed at 0 materializations regardless of
file size (see Fix 2's verification).

## Remaining bottlenecks (explicitly not fixed in this pass)

- **`OccurrenceHighlightController.runSearch`'s off-main path still materializes for `.contiguous`
  (small/untitled, <256 KiB) storage** — a small, bounded cost, matching `TextView.makeFindTextSource()`'s
  own equivalent fallback; not a piece-tree/large-file concern.
- **`selectNextOccurrence`'s continuation (non-empty-selection) path, `selectAllOccurrences`, and
  `skipCurrentOccurrence` still materialize the full document.** These are explicit, user-triggered,
  non-per-keystroke actions (⌘⇧D / ⌘⇧L / ⌘K⌘D), so lower severity than Fixes 1–3, and genuinely need
  bounded content search (not just length) to fix properly — `SelectNextOccurrence.nextMatch`/
  `allMatches` would need to move onto `FindSearchEngine`'s windowed, piece-tree-aware search
  machinery, which risks a behavior change (that engine's `anchorLocation` resolution wraps around
  the document; these three currently don't) that needs a deliberate product decision, not a
  drive-by fix. `selectNextOccurrence`'s own empty-selection (word-under-caret) path — its most
  common invocation — *was* fixed as a side effect of Fix 2a's `wordRange` signature change.
- **`Tools/PerfHarness` has no metric for the two fixes in this pass.** `keystroke` doesn't wire up
  `OccurrenceHighlightController` at all (occurrence highlighting is off by default on a bare
  `TextView`), so the *old* bug wouldn't have shown up in the harness's own numbers even before this
  fix — a real, notable gap in the harness's coverage, not just a missing convenience flag. Verified
  instead via a direct `materializeCount` regression test (see Fix 2). The harness also still has no
  frame-time/FPS, glyph-cache-hit-rate, highlight-latency, undo/redo-latency, or multi-cursor-edit-
  latency metrics — all pre-existing gaps, unchanged by this pass (not attempted; out of scope for a
  latency-fix pass, and the user declined restoring CI/the perf gate that would motivate building them
  out further).
- **No dedicated pixel-level regression test for the stale-glyph fix (Fix 1).** The existing
  `TreeSitterHighlightReadinessTests` case covers the underlying `isSyntaxHighlightPending` state
  machine correctly (and needed a fixture fix to keep testing what it always intended to), but
  nothing in `TextViewMetalSmokeTests` forces a slow/in-flight parse and asserts the *painted* glyph
  for the just-typed character is the new one, not the old one, on the very next frame.
- **CI / the deleted perf gate (`Scripts/perf-ci-gate.sh`, removed in commit `5aaea53`) were not
  restored** — explicit user decision for this pass (benchmarks recorded here by hand instead).
- **Metal PR 10 (opaque canvas / line-selection + page-guide fills in Metal)** — not attempted; user
  did not select this tier of work.
- **No manual `Umbra` smoke pass was run.** The plan's own verification checklist called for
  launching `./run-metal.sh`, typing rapidly in a large highlighted file to visually confirm no
  stale/invisible-glyph lag, and exercising toggle comment / insert line / sort lines through the
  real app's command palette and default keybindings. This was not done — automated test coverage
  (968 pre-existing + 51 new tests, full suite run twice, 0 failures) stands in its place, but a
  real GUI walkthrough is a different, complementary kind of check (e.g. it's the only way the
  `findActionIDs` gap above would have been *visually* obvious) and remains outstanding.
- **No `PerfHarness` before/after benchmark run for Fixes 2/3**, despite the plan calling for one.
  Substituted with the `materializeCount`-based regression tests (Fix 2) once it became clear the
  harness's headless `TextView` doesn't wire up `OccurrenceHighlightController` at all (see above) —
  a deliberate, disclosed substitution, not an oversight, but real wall-clock keystroke-latency
  numbers for these two fixes were never actually captured.
- Everything else already flagged as open in `PERFORMANCE_AUDIT.md`/`audit.md`'s own "Needs
  verification" sections (catastrophic regex with no timeout, `pendingContentChanges` being
  adapter-global, `FileMapping.remapPages` double-failure, overlapping multi-cursor completion,
  invalid-UTF-8-on-disk host behavior) — unchanged by this pass, see those documents for detail.

## Metal roadmap completion — 2026-09-15

The follow-up Metal pass completed the outstanding renderer roadmap:

- `captureMetalPresentedLayer()` now returns the readback from the actual drawable command buffer;
  AppKit `cacheDisplay` had returned a zeroed image for `CAMetalLayer`, so it could not prove that
  an internally correct renderer state reached the screen.
- Fixed-window regressions now cover Return plus following text with no explicit layout/resize,
  pending-highlight edits to an existing line, and host detach/reattach. All compare presented
  pixels; renderer origins/colors remain supplementary diagnostics.
- Dirty atlas pages are rebuilt independently. Triple-buffer slots are not reused until every
  command buffer reading the slot completes.
- The canvas is opaque and Metal paints the editor background, current-line band, and page-guide
  hairline/shading. AppKit keeps caret and selection overlays above the canvas.
- The layer follows its window/screen color space; theme and decoration colors resolve directly to
  sRGB or Display P3. At 1×, coverage glyphs use three horizontal subpixel phases; 2× remains a
  single atlas entry.
- `.github/workflows/metal.yml` adds required-Metal focused tests plus nightly parity artifacts for
  a self-hosted macOS runner labelled `metal`. Runner registration remains an external operation.

### Measurements

| Probe | Result |
|---|---:|
| Highlighted `Package.swift`, 5 keystrokes, 64-raster budget | 5.12 ms p95; 62 cumulative cap skips |
| Highlighted `Package.swift`, 5 keystrokes, 128-raster budget | 5.82 ms p95; 18 cumulative cap skips |
| 500 MB short-line fixture, middle keystroke | 1.97 ms p95; 0 cap skips; 0.447 ms instance rebuild |
| Synthetic scroll, 240 frames | 0.053 ms layout p95; 0.599 ms Metal draw p95 |
| Synthetic Metal/CG snapshot | 78.7% Metal ink on CG ink; MAD 17.51; mismatch fraction 0.239 |

The highlighted wall-clock difference is within run-to-run noise; the raster-cap reduction is the
actionable signal. The 128 ceiling remains bounded for cold CJK/emoji scrolls.

### Umbra smoke

`./run-metal.sh` is executable and launches the Metal configuration. The live SwiftUI-hosted app
accepted scripted ordinary typing and repeated Return/new-line input. Automated presented-drawable
tests cover the same fixed-size path plus split views and tab-host reattachment. OS screen capture
permission was unavailable to the command-line smoke session, so visual evidence comes from the
drawable readback tests rather than a desktop screenshot.

Physical Display P3 and 1× A/B checks, and execution on the registered self-hosted CI runner, remain
hardware acceptance steps; code paths and deterministic unit/pixel coverage are present locally.

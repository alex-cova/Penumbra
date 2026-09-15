# Runestone: typing-latency fixes + missing line/comment commands

## Context

The `/plan` brief asks for a from-scratch performance audit and a Zed/VS-Code-class
editing pass on a "custom Swift + Metal + Core Text" editor. Direct inspection shows
that brief describes a starting point this repo left behind weeks ago: piece-tree
storage (mmap load, order-statistics RB-tree, fat-leaf line index), a viewport-scoped
incremental tree-sitter parser with generation gating, a full 10-PR Metal glyph-atlas
renderer (shipped, default-on outside XCTest), async cancellable find, delta-based
undo, a save path, a `Tools/PerfHarness` benchmark tool, and 968 passing tests. Two
prior audits (`PERFORMANCE_AUDIT.md`, `audit.md`) already exist; I independently
verified their claimed fixes are real (19 of 20 `audit.md` findings confirmed fixed by
direct code reading, not by trusting the doc) and traced the current typing/render hot
path line-by-line to find what's still actually slow or missing today, rather than
redoing work already done.

That trace surfaced a real, user-visible regression the repo's own WIP commit
(`665f59b`, "fix Metal syntax-highlight white flash on typing") introduced: typed
characters can now sit invisible/stale on screen until a background tree-sitter parse
completes, and for any language with no highlights query, a fragment can get stuck
that way permanently. It also surfaced two confirmed O(document-size) synchronous
allocations still sitting in the per-keystroke path on file-backed (piece-tree)
documents, a wasteful per-keystroke Metal instance rebuild, and several genuinely
absent VS Code/Zed-table-stakes commands (toggle comment, sort lines, insert
line above/below) that no amount of searching found anywhere in the codebase.

This plan fixes the confirmed regressions and gaps, leaves alone everything already
working, and refreshes the two audit docs plus adds a benchmarked report — it does
not redo the Metal renderer, storage, or parser architecture, and does not restore
CI/perf-gate automation (user declined).

## What's already done (do not re-implement)

- Piece-tree storage for file-backed *and* large in-memory (≥256 KiB) documents
  (`Sources/Runestone/TextView/Core/StringView.swift`, `PieceTree.swift`).
- mmap load, fat-leaf `PackedLineIndex`, viewport/eager parse policy with
  `syntaxParseGeneration` staleness gating (`TextInputView.swift:855-1476`).
- Metal glyph-atlas renderer, PRs 1–9 of `plan.md` (atlas, extractor, decoration
  builder, run-level fallback, retina/appearance handling) — shipped and default-on
  outside XCTest (`Sources/Runestone/TextView/Metal/*`).
- Async, debounced, cancellable find (`FindSearchEngine`/`FindSession`), delta-based
  undo (`TextEditHelper.apply`), a real save path (`DocumentWriter`,
  `WorkbenchDocument.save`).
- 19/20 `audit.md` P0–P2 bugs fixed and tested; the one residual (LSP `utf16Offset`
  root conversion) is EIP/LSP-adapter scope, not the text engine — out of scope here.
- `Tools/PerfHarness` with `open`/`scroll`/`keystroke`/`goto`/`search`/`save`/
  `scroll-frames`/`snapshot-metal` subcommands.

## Fix 1 — Stale/invisible glyphs while typing (regression from 665f59b)

**Where:** `Sources/Runestone/TextView/Metal/MetalRenderer.swift:246-252`,
`Sources/Runestone/TextView/LineController/LineController.swift:143-145`,
`Sources/Runestone/TextView/SyntaxHighlighting/Internal/TreeSitter/TreeSitterSyntaxHighlighter.swift`,
`Sources/Runestone/TextView/SyntaxHighlighting/Internal/PlainText/PlainTextSyntaxHighlighter.swift:10-12`.

**Problem:** `MetalRenderer.upsertFragment` holds the *pre-edit* glyph instances
whenever `spec.isSyntaxHighlightPending` is true and the fragment already has glyphs
(the fix for the old white-flash bug). `isSyntaxHighlightPending` is
`isSyntaxHighlightingInvalid && canEventuallyHighlight`. `canEventuallyHighlight` is a
`LineSyntaxHighlighter` protocol requirement with a default of `true`
(`LineSyntaxHighlighter.swift:40`); only `PlainTextSyntaxHighlighter` overrides it to
`false`. `TreeSitterSyntaxHighlighter` never overrides it, so it's always `true` —
meaning: (a) every keystroke that lands while a tree-sitter parse is in flight
(routine — `textDidChange` sets exactly this state) now shows stale pre-edit text
until that parse's synchronous highlight finishes, and (b) a tree-sitter language with
no `highlightsQuery` (or one whose parse permanently fails) is stuck holding stale
glyphs forever, since `isSyntaxHighlightPending` can never become false.

**Fix:**
- Add `var canEventuallyHighlight: Bool { languageMode.highlightsQueryAvailable }` to
  `TreeSitterSyntaxHighlighter` (a query-less language mode can never eventually
  highlight, so hold-previous-glyphs should not apply to it — extract immediately).
  Thread the underlying check to `TreeSitterLanguageLayer` (`:266` already tests
  `highlightsQuery != nil` for a related purpose — reuse that path).
- For the still-pending case (a query does exist, parse just hasn't finished): don't
  silently hold stale glyphs with no recovery signal. Confirm/fix that
  `handleSyntaxParseFinished` (`TextInputView.swift:1490-1501`) calls
  `scheduleDeferredLayoutIfNeeded()` (it currently only sets `needsLayout` flags,
  unlike every sibling invalidation path) so a layer-backed host's freshly-parsed
  colors are guaranteed to present without depending on an unrelated future layout
  trigger.
- Coalesce `refreshMetalGlyphsAfterSyntaxHighlight` (`LayoutManager.swift:302-308`)
  through `withCoalescedPresent` like `redisplayLines`/`layoutIfNeeded` already do, so
  N visible lines finishing async highlight in one parse round produce one present,
  not N `encode+waitUntilScheduled` cycles.

**Verify:** a new `TextViewMetalSmokeTests` case: type into a large-enough document to
force `syntaxParsePolicy == .eager` off the sync path (or force a slow parse), assert
the typed character's glyph is present on the *next* frame, not held from the prior
`CTLine`. Add a case using a `TreeSitterLanguage` built with `highlightsQuery: nil`
and confirm its fragments extract immediately rather than pinning
`isSyntaxHighlightPending` forever.

## Fix 2 — Two confirmed per-keystroke O(document) allocations

**2a. `OccurrenceHighlightController.term(for:)`**
(`Sources/Runestone/TextView/Highlight/OccurrenceHighlightController.swift:95-96`)

Called synchronously from `selectionDidChange` (`:56-67`), which fires on every
`_selectedRange.didSet` — i.e. every keystroke, *before* the controller's own 120 ms
debounce work item is scheduled. Line 96 does `let string = stringView.string`, which
on a piece-tree document is a full `materializeNSString()` (`PieceTree.swift:602-609`)
— builds the entire `[unichar]` array and a new `NSMutableString` for the whole file,
synchronously, on the main thread, on every character typed, whenever occurrence
highlighting is enabled (a default-on feature — `EditorActionID.toggleOccurrenceHighlighting`
exists specifically to turn it off).

**Fix:** `term(for:)` only needs (a) `selectedRange.location <= stringView.length` and
(b) a bounded substring around the caret for the word-boundary walk (already available
via `stringView.substring(in:)`) and the explicit-selection text (already
`stringView.substring(in: selectedRange)` two lines later — the full-string
materialization is used *only* for the `<=` length check and the `SelectNextOccurrence.wordRange`
call). Change the length check to `stringView.length` and see whether
`SelectNextOccurrence.wordRange(at:in:tokenizer:)` can take a `StringView`/bounded
window instead of a full `String` (mirror the ±16-doubling-window pattern already used
for grapheme walks, `PieceTree.swift:531-547`, cited as the audit's P1 fix #9).

**2b. `restartSyntaxParseAfterCancelledEdit` → `startFullParse(of: string, …)`**
(`Sources/Runestone/TextView/Core/TextInputView.swift:1437-1451`)

`string` here is `stringView.string` (full materialization, `TextInputView.swift:613-616`).
`startFullParse` calls `languageMode.parse(text) { … }`
(`TreeSitterInternalLanguageMode.swift:101-120`), whose implementation **never reads
its `text` argument** — it calls `parseUsingReader(coveringUTF16Range:)`, which walks
the piece tree in 4 KiB chunks. So today every time a keystroke lands mid-parse (the
exact condition that triggers this path) the document is fully materialized and then
the materialized copy is thrown away unused.

**Fix:** either drop the now-dead `NSString` parameter from
`startFullParse`/`languageMode.parse(_:completion:)` (it's unused downstream — confirm
no other call site relies on the passed string before removing), or if signature
stability matters, pass a lazily-materialized value only for callers that still need
it, not eagerly at the `restartSyntaxParseAfterCancelledEdit` call site. Prefer
removing the parameter — cleaner and removes the temptation for a future caller to
materialize needlessly.

**Verify:** extend `Tools/PerfHarness`'s `keystroke` command (see harness section
below) to report on a piece-tree-backed fixture with occurrence highlighting enabled;
p95 should drop from an O(file-size) number to microseconds. Add a unit test asserting
`materializeCount` (already tracked per `PERFORMANCE_AUDIT.md`'s own testing notes;
confirm/add a counter on `PieceTree.materializeNSString()` if one doesn't already
exist) stays 0 across N keystrokes with occurrence highlighting on and a parse
deliberately kept in-flight.

## Fix 3 — Per-keystroke Metal instance-buffer full rebuild

**Where:** `Sources/Runestone/TextView/Metal/MetalRenderer.swift:454-482` (`rebuildInstanceBuffers`),
`:500-540` (`rebuildGlyphBuckets`), and the unconditional `MetalDecorationBuilder.build`
call inside `upsertFragment` (`:280-286`).

**Problem:** `upsertFragment` sets `needsInstanceRebuild = true` on essentially every
call (glyph cache hit or miss), and `encode()` responds by re-bucketing *every*
tracked fragment's glyph instances into fresh dictionaries, then `.map`-copying every
instance again for pixel alignment — a full-viewport-sized allocation/copy for a
single-character edit. Decorations are also unconditionally rebuilt on every upsert
even when nothing about that fragment's decorations changed (confirmed by the design
doc itself, which calls this "no ID-only decoration invalidate" and treats it as a
known, intentional PR-6 gap, not something ever revisited by a partial-rebuild).

**Fix:** narrow `needsInstanceRebuild` to a per-fragment dirty range instead of a
boolean, and change `rebuildInstanceBuffers` to patch only the changed fragments'
instance ranges into the persistent triple-buffered storage rather than rebuilding the
whole bucket map. This is exactly the "partial rebuild optimization" `plan.md`
Key Decision 4 / PR 6 description already names as deferred ("skip the CTRun walk when
both `ctLineID` and `emitRect` match... is then a *partial* rebuild optimization... not
the correctness split") — do that optimization now that correctness is settled. Keep
`MetalDecorationBuilder.build` unconditional per upsert (correctness-load-bearing per
the design doc) but skip the *instance bucket* rebuild for untouched fragments.

**Verify:** `Tools/PerfHarness scroll-frames`/a new lightweight keystroke-frame-time
probe; assert p95 keystroke-to-present drops on a file with many visible fragments
(e.g. 200-fragment viewport per `plan.md`'s own sizing table). `MetalRenderer`-level
unit test asserting only the edited fragment's bucket entries are replaced (object
identity or a version counter on unaffected buckets).

## Fix 4 — Residual full-document materialization on explicit multi-cursor actions

**Where:** `TextInputView.swift:1874, 1909, 1935` — `selectNextOccurrence`,
`selectAllOccurrences`, `skipCurrentOccurrence` all open with
`let string = stringView.string`.

These are not per-keystroke (user-triggered, ⌘⇧D/⌘K⌘D/⌘⇧L), so lower urgency than Fixes
1–3, but they're a straightforward extension of the P0 fix already applied everywhere
else in this file (`endOfDocument`, `hasText`, `selectAll`, delete, grapheme walks —
all already converted to bounded/`stringView.length` calls per the verified audit).
Route these three through `SelectNextOccurrence`'s existing search helpers using a
bounded/windowed read instead of full materialization, matching the pattern used for
Find.

**Verify:** add these three actions to the existing `materializeCount == 0` regression
style the audit's own "Test gaps" section flagged as missing for find/save — extend it
to cover this trio too.

## Feature gap 1 — Toggle comment

**Confirmed absent:** no `toggleComment`, `lineCommentPrefix`, `blockComment`, or
comment-token concept exists anywhere in `Sources/Runestone` or the language packs
(`RunestoneLanguages`, `RunestoneMarkdownLanguage`, `RunestoneGraphQLLanguage`) —
verified by exhaustive grep, not assumed. This is a Phase-27/VS-Code-parity item the
brief explicitly calls out and it's a real, user-facing gap, not a documentation
artifact like most of the brief's other asks.

**Design, mirroring `JoinLinesService`/`MoveLinesService`'s existing shape** (pure
computation struct, no mutation, `TextInputView` applies the edit under one undo
group):

- Add comment-token metadata. Simplest integration point: extend
  `TreeSitterLanguage` (`Sources/Runestone/TextView/Language/TreeSitterLanguage.swift`)
  with an optional `lineCommentPrefix: String?` (block-comment pairs are a stretch
  goal, not required for v1 — line comments cover the overwhelming majority of
  toggle-comment usage and every bundled language in `RunestoneLanguages`).
  `JoinLinesService.swift:41` already hardcodes `"//"` for its own comment-merge
  special case — this is the second place that logic is needed, which is the signal
  a shared per-language token is worth adding now rather than than hardcoding again.
- New `CommentToggleService` (new file, same directory as `JoinLinesService`): given
  selected line range(s) + the language's line-comment prefix, decides toggle
  direction (comment if any selected line is uncommented, matching VS Code/Zed
  behavior) and returns a list of per-line insert/remove-prefix edits.
- New `EditorActionID.toggleComment` in `EditorActionID.swift`'s "Line & block editing"
  group, `builtInTitles` entry, default keymap binding (⌘/ in `Keymap.default_`, ⌘/ in
  `Keymap.intelliJ` too — check both presets in `Sources/Runestone/TextView/Keymap/Keymap.swift`
  for the existing ⌘/ status before assigning, avoid a collision).
  `TextInputView.toggleComment()` applies all edits from `CommentToggleService` under
  one `beginIsolatedUndoGrouping()`/`endUndoGrouping()` pair (mirroring
  `joinLines`'s multi-caret handling at `TextInputView.swift:3702-3735`), multi-caret
  aware. Public `TextView.toggleComment()` wrapper alongside `moveSelectedLinesUp()`
  etc.

**Verify:** new `CommentToggleServiceTests.swift` (pure-function unit tests: toggle
on/off, mixed commented/uncommented selection, multi-caret, indented lines, language
with no comment prefix configured → no-op). Extend `EditorFeatureTests.swift` or
similar for the `TextView.toggleComment()` integration + undo round-trip.

## Feature gap 2 — Sort lines, insert line above/below

**Confirmed absent:** exhaustive grep for `sortLines`, `insertLineAbove`,
`insertLineBelow` returns nothing.

- **Insert line above/below** — smallest addition. New `EditorActionID.insertLineAbove`/
  `.insertLineBelow`. Implementation is a thin wrapper: compute the target line's
  start/end location via `lineManager`, insert a line-ending + (for "above") reindent
  at the new caret using existing `IndentController`/`detectIndentStrategy` machinery,
  move caret there. Default keymap: ⌘⏎ / ⌘⇧⏎ (check for collisions in both presets
  first — IntelliJ's keymap likely already uses one of these for something else, per
  the "IntelliJ-style keymap" changelog entry — resolve conflicts by asking rather than
  guessing if one is found).
- **Sort lines** — new `LineSortService` (same pattern as `JoinLinesService`): given a
  selection spanning N lines, returns the reordered line content as a single
  replacement edit (default: ascending, case-sensitive `String` comparison; consider a
  `SortOrder` enum with `.ascending`/`.descending` and a `caseInsensitive` flag,
  exposed as two command-palette actions "Sort Lines Ascending"/"Sort Lines Descending"
  rather than one, matching how VS Code exposes it — simpler than inventing a picker
  UI). `EditorActionID.sortLinesAscending`/`.sortLinesDescending`, no default keybinding
  (command-palette/Find-Action only, like `reformatCode`).

**Verify:** `LineSortServiceTests.swift` (stability on ties, single-line no-op,
trailing-newline edge cases, multi-caret — sort operates independently per
contiguous selected block). `LineOperationsTests.swift` already covers
duplicate/delete/move lines in this exact style — extend it or add a sibling file for
insert-above/below.

## Wiring for all new actions

- `EditorActionID.swift`: add the 5 new IDs + `builtInTitles` entries (mirrors
  existing pattern exactly).
- `Keymap.swift`: default bindings where a natural one exists and doesn't collide;
  leave unbound otherwise (still reachable via Find Action).
- `CommandRegistry.registerBuiltInActions(for:)` picks up every `EditorActionID`
  automatically per the existing mechanism (per CLAUDE.md) — confirm no per-action
  registration is actually needed beyond adding the ID.
- `TextInputView.performKeymapAction`/`TextView.perform(_:)`: add the new action
  cases alongside the existing `joinLines`/`duplicateLines`/etc. dispatch.

## Documentation

- **Refresh `PERFORMANCE_AUDIT.md` and `audit.md` in place** (user's choice) rather
  than writing new files: update stale claims (e.g. `audit.md`'s "Swift 5 mode"
  framing is now `swift-tools-version: 6.0` with `swiftLanguageMode(.v6)` per
  `Package.swift` — a straightforwardly outdated claim), mark the 19/20 fixed findings
  as confirmed-fixed with citations (not just "fixed" from a prior session's own
  say-so), note the 1 partial (LSP offset) and its actual current scope, and add this
  pass's four Fix sections + two Feature-gap sections in the same before/after,
  cited-evidence style the docs already use.
- **New `EDITOR_PERFORMANCE_REPORT.md`**: Before/After/Changes format per the brief,
  but scoped honestly to what this pass actually touched (not a re-narration of
  already-shipped Metal/piece-tree/parser work — link to the relevant existing
  `plan.md`/`PERFORMANCE_AUDIT.md` sections for that instead of duplicating it).
  Include real `PerfHarness` numbers, before/after, for: occurrence-highlight
  keystroke latency on a piece-tree fixture, keystroke-to-Metal-present latency,
  stale-glyph repro (qualitative pass/fail + smoke test name). No fabricated numbers —
  every figure must come from an actual `swift run -c release PerfHarness` run
  recorded during this work.

## Out of scope (per user's answers + evidence-based judgment)

- CI/GitHub Actions restoration — user explicitly declined (Q2: "No gate at all").
  `Scripts/perf-ci-gate.sh` stays deleted; benchmarks in the report are run and
  recorded by hand.
- Metal PR 10 (opaque canvas / line-selection + page-guide fills in Metal) — user
  did not select this tier.
- Full Swift 6 language-mode migration — already flagged in `PERFORMANCE_AUDIT.md`
  Phase 3 as a deliberately separate, multi-week project; nothing in this pass
  depends on it.
- Rewriting/second-guessing the shipped Metal renderer, piece tree, or tree-sitter
  scheduling architecture — all measured working (968 tests green, 0 build errors)
  and outside what the two confirmed regressions/gaps require touching.
- Block-comment (`/* */`) toggling — stretch goal only if line-comment lands cleanly
  with time remaining; not required for the core deliverable.

## Verification plan

1. `swift build` clean (currently 0 errors, 2 warnings — don't introduce new ones).
2. `swift test` full suite green (currently 968/968) plus every new test file listed
   above.
3. `swift run -c release PerfHarness keystroke <piece-tree fixture> --at middle
   --mmap --viewport --samples 40` before/after Fix 2a/2b, with occurrence
   highlighting forced on, recorded in `EDITOR_PERFORMANCE_REPORT.md`.
4. Manual MacExample smoke pass (`./run-metal.sh`): type rapidly in a large
   tree-sitter-highlighted file and confirm no stale/invisible-glyph lag; toggle
   comment, insert line above/below, sort lines via the command palette and default
   keybindings.
5. `git diff --stat` reviewed to confirm no unrelated files touched.

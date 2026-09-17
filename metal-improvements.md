# Metal renderer — prioritized fix roadmap

Prioritized by user impact first, then performance, then polish. Paths are relative to the repo root.

**Verified against** `30190ef` (branch `editor-latency-and-commands`), working tree as of 2026-09-15. Every claim below was checked against the source; items whose premise no longer holds were moved to the "already fixed" table or corrected in place (see [Corrections](#corrections-from-the-previous-revision)).

**Scope:** issues from `plan.md` (the design doc), `editor-improvements.md`, `EDITOR_PERFORMANCE_REPORT.md`, `audit.md`, and direct source reading.

**Item format:** each item states the user-visible **symptom**, the **evidence** in code, the **fix**, and an **acceptance** check that must fail before the fix and pass after. Code is referenced by symbol name — line numbers rot, so they appear only as a hint. Effort is S (<½ day), M (1–2 days), L (>2 days).

## Completion update — 2026-09-15

The roadmap implementation is now present in the working tree:

- P0: actual presented-drawable capture replaces unreliable `NSView.cacheDisplay` capture; Return + following text, pending-highlight edits, and host reattachment have fixed-window pixel regressions. Umbra was launched through `./run-metal.sh` and exercised with scripted typing/Return input.
- P1: deterministic fragment/page ordering, exhaustive decoration cache inputs, GPU-free stats, Metal PerfHarness metrics, dirty-page rebuilds, and command-buffer-completion-fenced triple buffers are enabled. The raster budget is 128 after a five-sample highlighted run recorded 62 capped fragments at 64 and 18 at 128. A 500 MB fixture recorded 1.97 ms keystroke p95, 0 raster-cap skips, and 0.447 ms instance rebuild. Synthetic scroll layout p95 was 0.053 ms.
- P2-1: the Metal pass paints the opaque editor background, selected-line band, and page-guide hairline/shading; AppKit selection/caret overlays remain above it.
- P2-2: presented-frame/parity metrics use ink rather than alpha for the opaque canvas, and `.github/workflows/metal.yml` targets a required self-hosted macOS Metal runner. Local synthetic parity measured 78.7% of Metal ink on CG ink (MAD 17.51; mismatch fraction 0.239).
- P2-3: the layer follows the attached window/screen color space and theme/decorative colors are converted directly into sRGB or Display P3 output space, with color-bearing instances invalidated on display changes.
- P2-4: 1× glyphs use three horizontal coverage phases; Retina remains bucket zero. Whole-run fallback reserves `UInt8.max`.
- P2-5: fallback reasons reach the host, update Umbra status, and produce a one-time user-visible warning.

Hardware acceptance remains explicit: the workflow needs a registered runner labelled `self-hosted`, `macOS`, and `metal`; visual A/B checks require physical P3 and 1× displays.

---

## Already fixed or mitigated (context)

These were real bugs. Most have fixes on the current branch; the remaining tradeoffs are tracked as P0 items below.

| Issue | What happened | Status |
|---|---|---|
| **White flash on typing** | Edits during an outstanding tree-sitter reparse typeset lines in `theme.textColor`; Metal baked that default color over syntax colors. | Mitigated via **hold-previous-glyphs** when `isSyntaxHighlightPending`. Residual cost tracked as P0-1. |
| **Stale/invisible glyphs (regression from `665f59b`)** | The hold-previous-glyphs fix made *every* keystroke during a background parse show pre-edit glyphs (or nothing) until the parse finished. | **Fixed** — `TreeSitterSyntaxHighlighter.canEventuallyHighlight` reads `highlightsQueryAvailable`; query-less languages extract immediately |
| **Permanent stale glyphs (no highlights query)** | Languages with no `highlights.scm` could never leave `isSyntaxHighlightPending`, holding old glyphs forever. | **Fixed** — same `highlightsQueryAvailable` wiring (`TreeSitterLanguageLayer.highlightsQueryAvailable` recurses into injected layers) |
| **N encode cycles per highlight round** | `refreshMetalGlyphsAfterSyntaxHighlight` could trigger N separate `encode + waitUntilScheduled` when many lines finished highlighting at once. | **Fixed** — coalesced via `MetalTextCanvasView.withCoalescedPresent`; removed direct `presentMetalCanvasIfNeeded()` |
| **`handleSyntaxParseFinished` layout gap** | Parse completion didn't call `scheduleDeferredLayoutIfNeeded()` like other invalidation paths. | **Fixed** |
| **Full-viewport instance-buffer rebuild every upsert** | `needsInstanceRebuild = true` on every visible fragment touch → re-bucket all ~90–200 fragments and pixel-align every instance. | **Partially fixed** — `upsertFragment` compares `glyphs`/`decorations` against the previous values and only then sets the flag. Rebuild is still whole-viewport when it does fire (P1-2). |
| **Blank editor / clear canvas** | AppKit drawing into `CAMetalLayer`, or `presentsWithTransaction = true` inside `setDisableActions(true)` transactions, cleared the drawable. | **Fixed** — `layerContentsRedrawPolicy = .never`, `presentsWithTransaction = false`, present via `updateLayer`/`presentIfDirty` |
| **GPU fragment leak on scroll** | Using `lineFragmentViewReuseQueue.visibleViews` for eviction when Metal is active (always empty) → fragments never removed. | **Fixed in PR 4** — eviction reads `paintBackend.trackedFragmentIDs` |
| **Display-only invalidation no-op** | Marked text / invisible chars / `unmarkText` needed fresh specs, not ID-only invalidates. | **Fixed in PR 4** — `LayoutManager` re-upserts visible controllers |
| **Fold placeholder colors not threaded** | Design doc flagged `foldPlaceholderColor` / `foldPlaceholderBackgroundColor` as possibly stuck on renderer defaults. | **Fixed** — `LayoutManager` copies both from `lineFragmentController` into `LineFragmentDecorations`; `MetalDecorationBuilder` uses them for both the fold chip and the fold text. Was P2-6. |

---

## P0 — Correctness / user-visible bugs

### P0-1: Held glyphs go stale in *content* and *position* during a background parse

**Symptom:** two distinct visible defects while `isSyntaxHighlightPending` is true for a line that already has glyphs:

1. **Stale text.** Typing into an existing line shows the *previous* string until the parse lands — not just the previous colors.
2. **Stale positions.** If the fragment moves (a line inserted above, wrap reflow, gutter width change), the held glyphs keep the origins they were extracted with, so text sits at the old y/x while caret, selection, and decorations are already at the new frame. Text visibly detaches from its highlight until the parse completes.

**Evidence:**

- `MetalRenderer.upsertFragment` (~254): when `spec.isSyntaxHighlightPending && !fragment.glyphs.isEmpty` it clears `cacheKey` and returns without extracting — `fragment.glyphs` is untouched, so both the characters and their origins are whatever the last highlighted extract produced.
- `fragment.frame = spec.frame` *is* updated on the same path, and decorations are rebuilt from the new spec every upsert, so frame-derived geometry moves while glyphs do not.
- Glyph origins are canvas-absolute, not fragment-relative: `GlyphRunExtractor` adds `request.fragmentFrame.minX/minY` into every emitted origin (~325, ~413, ~520). Holding instances across a frame change therefore holds *stale absolute positions*.

**Tradeoff today:** avoids the white flash (`theme.textColor` baked over syntax colors) at the cost of text freshness and positional correctness.

**Fix direction:** stop holding whole glyph sets. Extract on every content/geometry change and hold only *color*:

1. Always extract when `spec.lineRevision` or `emitRect` changed, regardless of pending state.
2. Carry a per-line snapshot of the last resolved run colors (offset range → color) on the line controller or the renderer, and have `GlyphRunExtractor` resolve `fallbackColor` runs against that snapshot instead of `theme.textColor`.
3. Glyphs with no prior color (newly typed characters) inherit the color of the run they extend, which is what a real highlighter would produce anyway.

Cheaper interim fix if (2) is too large: keep the hold, but re-extract whenever `spec.frame != fragment.frame` even while pending. Kills defect 2 only.

**Acceptance:** two new tests in `Tests/PenumbraTests/TextViewMetalSmokeTests.swift`:

- `testMetalPaintsEditedCharacterOnExistingLineWhileHighlightIsPending` — with a forced-slow highlighter, type into an existing highlighted line and assert the new character's glyph is present (instance count / `metalDebugGlyphColors` at that location) rather than the pre-edit set.
- `testMetalMovesHeldGlyphsWhenFragmentFrameChangesWhileHighlightPending` — insert a line above a highlighted line mid-parse; assert the held glyph origins moved by one line height.

**Files:** `Sources/Penumbra/TextView/Metal/MetalRenderer.swift`, `Sources/Penumbra/TextView/Metal/GlyphRunExtractor.swift`, `Sources/Penumbra/TextView/LineController/LineController.swift` (`isSyntaxHighlightPending`), `Sources/Penumbra/TextView/Metal/LinePaintBackend.swift` (`LineFragmentPaintSpec`), `Sources/Penumbra/TextView/Core/LayoutManager.swift` (spec assembly ~913–942).

**Effort:** M (full fix) / S (interim positional fix). **Risk:** medium — this is the code path the white-flash regression lives on; land it behind the acceptance tests above plus the existing `testMetalHoldsSyntaxColorsInsteadOfDefaultWhenEditOutrunsHighlight`.

---

### P0-2: Blank text after a cached host returns to the window (new)

**Symptom:** suspected blank editor (chrome, gutter, and caret present; no glyphs) after a workbench tab switch away and back, until something forces a real change — a keystroke, scroll, or resize.

**Evidence:**

- `MetalTextCanvasView.viewDidMoveToWindow` calls `glyphEncoder?.hostDidLeaveWindow()` when `window == nil`, which calls `MetalRenderer.compactInstanceBuffers()`.
- `compactInstanceBuffers` empties every `GlyphInstanceBuffer` (`compact()` sets `count`/`primaryCount` to 0 and drops overflow buffers) and every `DecorationBuffer`, but **does not set `needsInstanceRebuild = true`**.
- On return, `viewDidMoveToWindow` calls `setNeedsDisplay()` + a deferred `presentIfDirty()`. `encode(into:)` only rebuilds when `needsInstanceRebuild` is set, so it draws the emptied buffers. `drawGlyphBuckets` skips any bucket with `primaryCount == 0` and no overflow, and `drawSolids`/`drawLines` bail on `count == 0` — nothing is drawn.
- The layout pass that follows does not save it: `fragments` still holds the same `GPUFragment`s, so `upsertFragment`'s `glyphs != previousGlyphs || decorations != previousDecorations` comparison is false and the flag stays clear.
- Not covered: `testCanvasLeavingWindowDoesNotCrash` only asserts `isMetalRenderingActive` after the host is detached; nothing re-attaches and inspects pixels or instance counts.

**Fix:** set `needsInstanceRebuild = true` at the end of `compactInstanceBuffers()` (one line). Any future caller that frees GPU buffers then gets a rebuild for free.

**Acceptance:** `testMetalRepaintsGlyphsAfterHostReturnsToWindow` in `TextViewMetalSmokeTests` — lay out, detach (`window.contentView = NSView()`), re-attach the text view, `layoutIfNeeded()`, then assert `metalTotalInstanceCount > 0` and `captureSnapshot()` has painted pixels.

**Effort:** S. **Risk:** low.

---

### P0-3: Pixel-level regression coverage for the pending-highlight path

**Symptom:** none directly; this is the test gap that let the `665f59b` regression ship.

**What exists already** (the previous revision of this doc understated it): `TextViewMetalSmokeTests` covers `testMetalHoldsSyntaxColorsInsteadOfDefaultWhenEditOutrunsHighlight` and `testMetalPaintsNewlyInsertedLineImmediatelyWhileHighlightIsPending`; scheduling-state coverage is in `Tests/PenumbraTests/LineSyntaxHighlightSchedulingTests.swift` (`isSyntaxHighlightPending` assertions ~145–158).

**What is missing:**

1. The **edit-to-existing-line** case (P0-1 defect 1) and the **fragment-moved** case (P0-1 defect 2).
2. A reusable slow-parse harness. Both existing tests hand-roll their pending state; a shared `withForcedPendingHighlight { }` helper (or a `HighlightProviding` mock that never completes) would make P0-1's tests cheap to write and keep them honest.
3. Assertions on the **presented** frame rather than renderer-internal state, for at least one case — `capturePresentedLayer()` + `debugPresentedAlphaPixels` exist for this and require `MetalContext.allowsDrawableCapture` before layer creation.

**Note:** `TreeSitterHighlightReadinessTests.swift` (cited by the previous revision) does not exist. Do not go looking for it.

**Files:** `Tests/PenumbraTests/TextViewMetalSmokeTests.swift`, `Tests/PenumbraTests/LineSyntaxHighlightSchedulingTests.swift`, `Sources/Penumbra/TextView/Core/TextView.swift` (`metalDebugGlyphColors(atLocation:)` ~957).

**Effort:** M. **Risk:** low. Do this together with P0-1 — the harness is what makes P0-1 verifiable.

---

### P0-4: Manual Umbra smoke pass (still outstanding)

**Symptom:** GUI-only failures (palette wiring, visual lag, compositing artifacts against SwiftUI hosts) cannot appear in the headless suite, and Metal is **off by default under XCTest** (`MetalActivation.defaultPropertyValue` returns `!isRunningUnderXCTest`), so the default suite exercises CG.

**Fix direction:** run `./run-metal.sh`, then work a large highlighted file: rapid typing, flick scroll, split panes, tab switch away and back (this is also the P0-2 repro), theme/appearance switch, font size change, window move between displays of different backing scale. Record results in `EDITOR_PERFORMANCE_REPORT.md` and file what you find.

**Files:** `run-metal.sh`, `Example/Umbra/IDEWorkspace.swift`, `Example/Umbra/IDEEditorViews.swift` (`textView.isMetalRenderingEnabled`), `Example/Umbra/IDEStatusBarPanel.swift` (shows renderer mode).

**Effort:** S. **Risk:** none.

---

## P1 — Performance and determinism (typing / scroll feel)

### P1-1: Nondeterministic instance and draw order (new)

**Symptom:** frame-to-frame instability where translucent decorations overlap (search highlight under selection under marked-text fill), and — more concretely — snapshot goldens that cannot be trusted, which blocks P2-2.

**Evidence:** `rebuildInstanceBuffers` iterates `fragments.values` (unordered `Dictionary`) to accumulate `underlaySolids` / `overlaySolids` / `underlayTriangles`, and `rebuildGlyphBuckets` builds `order` by iterating `instancesByPage` (also unordered). Blending is premultiplied source-over (`makePipeline`), which is **not** commutative, so two overlapping translucent solids composite to different results depending on emission order. Dictionary iteration order is unspecified and changes as the dictionary is mutated across scroll and edits.

**Fix:** sort deterministically before writing buffers — fragments by `(frame.minY, frame.minX, id)`, page order by `pageID`. Both are ~200-element sorts once per rebuild, negligible next to the pixel-align map already there.

**Acceptance:** `testInstanceOrderIsStableAcrossRebuilds` in `Tests/PenumbraTests/MetalDecorationTests.swift` — rebuild twice with identical fragment state (insert them in different orders) and assert byte-identical instance arrays. Also unblocks byte-comparable `snapshot-metal` goldens.

**Effort:** S. **Risk:** low. Do this before P2-2 and before any golden-image work.

---

### P1-2: Skip decoration rebuild when decoration inputs are unchanged

**Symptom:** CPU cost on every layout pass proportional to visible fragment count, even when nothing changed.

**Evidence:** `MetalRenderer.upsertFragment` (~289) calls `MetalDecorationBuilder.build` unconditionally, with the comment "Decorations rebuild every upsert (display-only invalidation re-upserts a fresh spec)". Glyph extraction is cache-keyed and the instance rebuild is `Equatable`-gated, so this is the only unbounded per-upsert work left. `LayoutManager` re-upserts *every* visible fragment on *every* pass, so this runs ~90–200 times per pass during scroll.

**Fix:** make `LineFragmentDecorations` `Equatable` (it is a value type; `foldPlaceholder`, `invisibles`, and the colors all compare fine) plus the few frame/size fields `build` reads, cache the last inputs on `GPUFragment`, and skip the call when equal. Keep the atlas/budget interaction in mind: `build` also rasterizes invisible-character and fold-text glyphs, so skipping must not skip a needed raster — gate on "inputs equal **and** previous build produced no capped rasters".

**Acceptance:** `MetalDecorationTests` case asserting `build` is not re-entered for an unchanged upsert (inject a counting builder or assert via a `didRebuildDecorations` debug counter), plus no change to existing decoration goldens.

**Files:** `Sources/Penumbra/TextView/Metal/MetalRenderer.swift`, `Sources/Penumbra/TextView/Metal/MetalDecorationBuilder.swift`, `Sources/Penumbra/TextView/Metal/LinePaintBackend.swift`, `Tests/PenumbraTests/MetalDecorationTests.swift`.

**Effort:** M. **Risk:** medium — a missed field in the equality check means stale decorations, which is exactly the class of bug PR 4 fixed. Enumerate `MetalDecorationBuilder.build`'s reads exhaustively rather than deriving equality from `LineFragmentPaintSpec` wholesale.

---

### P1-3: Per-fragment instance-buffer patch instead of full rebucket

**Symptom:** one edited line costs a whole-viewport rebuild: re-bucket every visible fragment's instances by atlas page, pixel-align every instance, and rewrite every buffer.

**Evidence:** `rebuildInstanceBuffers` walks all `fragments.values` and `rebuildGlyphBuckets` re-writes each page bucket wholesale, including the `MetalProjection.pixelAligned` map over every instance. Any single dirty fragment sets `needsInstanceRebuild`, and `encode` then rebuilds everything.

**Fix direction:** track a `dirtyFragmentIDs: Set<LineFragmentID>` alongside the flag. Keep per-page instance arrays with per-fragment ranges so a dirty fragment can be patched in place when its instance count is unchanged, and fall back to a full rebuild when counts shift or pages are added/evicted. Pixel-align at extract time rather than at bucket time so the align map disappears from the hot path entirely.

**Acceptance:** `Tools/PerfHarness` keystroke-frame probe (needs P1-5) showing reduced per-keystroke rebuild time on a 500 MB fixture; correctness held by the existing smoke tests plus P1-1's order-stability test.

**Files:** `Sources/Penumbra/TextView/Metal/MetalRenderer.swift` (`rebuildInstanceBuffers` ~464, `rebuildGlyphBuckets` ~510), `plan.md` §"PR 6 — Partial invalidation, shared atlas, off-screen pause".

**Effort:** L. **Risk:** medium. Sequence after P1-1 (deterministic order makes patching tractable) and P1-2 (cheaper win first).

---

### P1-4: `TextView.metal*` debug accessors stall the GPU (new)

**Symptom:** any consumer polling Metal stats — PerfHarness, Umbra's status bar, a future HUD — pays a synchronous GPU round-trip per property read. This silently corrupts exactly the measurements P1-5 wants to collect.

**Evidence:** `MetalRenderer.debugStats` unconditionally calls `atlas.debugCoverageTexelCensus()`, which blits the **entire first 2048×2048 coverage page** (`GlyphAtlas.coveragePageSize = 2048`, r8 → 4 MB) into a shared buffer, `commandBuffer.waitUntilCompleted()`, copies it into a `Data`, and then loops every byte counting non-zeros. Every `TextView.metal*` accessor (`metalGlyphAtlasBytes`, `metalFragmentCount`, `metalDrawNanosP95`, …) builds a fresh `DebugStats`, so each read pays that cost; `metalTotalInstanceCount` reads `metalDebugStats` twice and pays it **twice**. `debugStats` also sorts the 120-sample `recentDrawNanos` array per read.

**Fix:** split the census out of `DebugStats` into an explicit opt-in (`TextView.metalAtlasCensus()` / `MetalRenderer.atlasCensus()`), leave `debugStats` allocation- and GPU-free, and have callers that want several values read `metalDebugStats` once. Keep the census available for the atlas-coverage assertions that need it.

**Acceptance:** `MetalActivationTests` / `GlyphAtlasTests` case asserting `debugStats` performs no blit (e.g. census fields default to 0 / a `nil` sentinel), and PerfHarness output showing stable `metalDrawNanosP95` under repeated polling.

**Files:** `Sources/Penumbra/TextView/Metal/MetalRenderer.swift` (`DebugStats`, `debugStats`), `Sources/Penumbra/TextView/Metal/GlyphAtlas.swift` (`debugCoverageTexelCensus`, `copyPixels`), `Sources/Penumbra/TextView/Core/TextView.swift` (~942–989).

**Effort:** S. **Risk:** low, but it is a prerequisite for P1-5 being meaningful.

---

### P1-5: PerfHarness coverage for the Metal keystroke path

**Symptom:** no numbers to defend any of P1-2/P1-3 with, and no regression gate.

**Evidence (corrected):** `Tools/PerfHarness` already has `occurrence-keystroke` and a `--highlighted` flag, so "keystroke doesn't enable occurrence highlighting" is stale. What is actually missing: `Tools/PerfHarness/Sources/Commands.swift` contains **zero** references to Metal — `keystroke`/`occurrence-keystroke` report only wall-clock p95 (`ResultLog.row("keystroke_..._p95", …)`), never `metalDrawNanosP95`, instance counts, atlas bytes, or fragment counts. Only `scroll-frames` and `snapshot-metal` (wired in `main.swift`) host an `NSWindow` and drive Metal at all.

**Fix direction:**

1. Have `keystroke`/`occurrence-keystroke` optionally host a window (`--metal`) so the Metal path is actually exercised, and emit `metalDrawNanosP95`, `metalTotalInstanceCount`, `metalFragmentCount`, `metalGlyphAtlasBytes` per sample.
2. Read stats once per sample via a single `metalDebugStats` snapshot (depends on P1-4).
3. Record a baseline CSV for the fixtures in `EDITOR_PERFORMANCE_REPORT.md` so before/after numbers for P1-2 and P1-3 are comparable.

**Update:** `.github/workflows/metal.yml` now defines focused and nightly jobs for a self-hosted macOS Metal runner, with required-Metal mode so missing GPU support fails instead of silently skipping.

**Files:** `Tools/PerfHarness/Sources/Commands.swift`, `Tools/PerfHarness/Sources/main.swift`, `Sources/Penumbra/TextView/Core/TextView.swift` (debug stats), `EDITOR_PERFORMANCE_REPORT.md` (§benchmark gaps).

**Effort:** M. **Risk:** low.

---

### P1-6: Atlas-miss / raster budget stutter

**Symptom:** during fast scroll into unrasterized text (CJK, emoji, an unusual face), a fragment can present partially filled for a frame or two.

**Evidence (updated):** the per-pass cap is **128** rasters — `GlyphRasterBudget.perFrameLimit = 128`; a five-sample highlighted `Package.swift` run recorded 62 capped fragments at 64 and 18 at 128, while the 500 MB plain-text fixture recorded none. Overflow marks the skip `.rasterCap`, leaves `cacheKey` unset, sets `pendingRasterRetry`, and `LayoutManager` re-drives layout via `consumePendingRasterRetry()`. The budget resets both in `setViewport` (top of every layout pass) and after a successful `encode`.

**Fix direction:** measure the actual miss rate first (add a `rasterCap` skip counter to `DebugStats` — cheap, and P1-4 makes stats safe to poll). Only then tune `perFrameLimit`, widen `MetalProjection.atlasWarmRect`, or extend `prewarm` to the ranges the document actually uses. Moving the CPU bitmap build off-main is permitted by the design doc for prewarm and is the real fix if misses are common.

**Files:** `Sources/Penumbra/TextView/Metal/GlyphRunExtractor.swift` (budget, `pendingRasterRetry`, run fallback ~146–191), `Sources/Penumbra/TextView/Metal/GlyphAtlas.swift` (LRU, `lruBudgetBytes = 32 MB`), `Sources/Penumbra/TextView/Metal/MetalRenderer.swift` (`rasterBudget`, `prewarm`), `Sources/Penumbra/TextView/Metal/GlyphRasterizer.swift`, `Tests/PenumbraTests/GlyphRunExtractorTests.swift`.

**Effort:** M. **Risk:** low.

---

### P1-7: Scroll-path layout and present cost

**Symptom:** wheel-tick cost is dominated by layout and typesetting, not by Metal.

**Evidence:** every `contentOffset` change forces `layoutIfNeeded()` → `layoutLinesInViewport` → an upsert for every visible fragment. Present coalescing (`withCoalescedPresent`, `scheduleDeferredPresentIfNeeded`) removes redundant presents but does nothing about the layout/typeset work, and `presentIfDirty` ends in `waitUntilScheduled()` (or `waitUntilCompleted()` when drawable capture is on — make sure capture is off when measuring).

**Fix direction:** measure with `scroll-frames` first. Then consider deferring typeset for fragments outside the viewport but inside the emit band, and batching upserts during fast scroll (velocity-gated).

**Files:** `Sources/Penumbra/TextView/Core/TextView.swift` (forced layout on `contentOffset`), `Sources/Penumbra/TextView/Core/LayoutManager.swift` (`layoutLinesInViewport`), `Sources/Penumbra/TextView/Metal/MetalTextCanvasView.swift`, `Tools/PerfHarness/Sources/main.swift` (`scroll-frames`).

**Effort:** L. **Risk:** medium — touches the shared CG path too.

---

## P2 — Architecture / polish / unshipped design

### P2-1: PR 10 — opaque canvas + line-selection + page-guide in Metal

**Symptom:** the transparent canvas pays per-pixel compositing against the AppKit views below it on every frame.

**Constraint:** the page guide and current-line fill are AppKit views showing *through* the transparent canvas. Flipping `isOpaque = true` before those fills exist in Metal hides them. Ship the fills first, the flag second, in that order, and keep caret/selection z-order intact (`plan.md` §G, §"Alternatives — E").

**Files:** `plan.md` §G and §"PR 10", `Sources/Penumbra/TextView/Metal/MetalRenderer.swift`, `Sources/Penumbra/TextView/Metal/MetalDecorationBuilder.swift`, `Sources/Penumbra/TextView/Core/LayoutManager.swift` (`layoutLineSelection`, page guide), `Sources/Penumbra/TextView/Metal/MetalTextCanvasView.swift` (`isOpaque`), `Tests/PenumbraTests/MetalTextCanvasViewTests.swift`.

**Effort:** L. **Risk:** high (visual regressions in chrome). Gate on P1-1 + working goldens.

---

### P2-2: Metal vs CG fallback drift

**Symptom:** Metal-only visual bugs ship because the default suite runs CG.

**Evidence:** `MetalActivation.defaultPropertyValue` is `!isRunningUnderXCTest`, and every Metal test opens with `skipUnlessMetalActivatable()`, so a GPU-less host silently skips them. `TextViewMetalSmokeTests` has 15 tests against a much larger CG-path surface.

**Fix direction:** (a) enumerate the `TextViewSmokeTests` / `AppearanceChangeSmokeTests` cases with no Metal counterpart and port the visually meaningful ones; (b) make `snapshot-metal` goldens byte-comparable — **requires P1-1**; (c) stand up CI with a GPU-capable runner, which does not exist yet, and only then add a nightly golden job. Treat (c) as its own infrastructure task, not a test-writing task.

**Files:** `Tests/PenumbraTests/TextViewMetalSmokeTests.swift`, `Tests/PenumbraTests/TextViewSmokeTests.swift`, `Tests/PenumbraTests/AppearanceChangeSmokeTests.swift`, `Tools/PerfHarness/Sources/main.swift` (`snapshot-metal`), `Sources/Penumbra/TextView/Metal/MetalActivation.swift`.

**Effort:** L. **Risk:** low.

---

### P2-3: Display P3 / wide-gamut support

**Symptom:** saturated theme colors render duller than the CG path on P3 displays.

**Evidence:** `MetalTextCanvasView.makeBackingLayer` pins `colorspace = CGColorSpace(name: .sRGB)` and `pixelFormat = .bgra8Unorm`; `MetalColor` converts through sRGB components. v1 locked this deliberately (`plan.md` §5).

**Fix direction:** resolve the window's colorspace, and if it is P3, use `.displayP3` plus a matching pixel format. Keep `GlyphKey` unaffected (coverage masks are colorspace-independent; only the color pages and instance colors change).

**Effort:** M. **Risk:** medium (needs A/B against CG on a P3 display; not verifiable headless).

---

### P2-4: Subpixel positioning on 1× displays

**Symptom:** text may look softer than CG on non-Retina displays.

**Evidence:** `GlyphKey` buckets by scale but v1 always uses subpixel bucket 0 (`plan.md` §"Resolved Questions" Q2). At 2× the half-pixel error is invisible; at 1× it is not.

**Fix direction:** add 2–3 horizontal subpixel buckets to `GlyphKey`, keyed only when `scale < 2`, so Retina atlas occupancy is unchanged.

**Effort:** M. **Risk:** low, but it multiplies atlas pressure on the one class of machine with the least GPU headroom — measure against `lruBudgetBytes`.

---

### P2-5: Device loss / permanent CG fallback observability

**Symptom:** a shader compile failure or lost device drops the whole process to CG for its lifetime, announced only by one `NSLog`.

**Evidence:** `MetalContext.markUnavailable(reason:)` is called from `MetalTextCanvasView.encodePass` on command-buffer/encoder failure and is process-wide and one-way; `onRenderingFailure` notifies the view but nothing surfaces to the host.

**Fix direction:** publish `isMetalRenderingActive` changes to the host (delegate callback or notification), and show a one-time notice in Umbra. `Example/Umbra/IDEStatusBarPanel.swift` already displays renderer mode, so the display surface exists.

**Effort:** S. **Risk:** low.

---

## Suggested execution order

Two independent tracks. The correctness track should land first; the perf track has a hard prerequisite chain.

**Correctness track**

1. **P0-2** (blank canvas after re-attach) — one line plus a test; do it first regardless of anything else.
2. **P0-3** slow-parse harness, then **P0-1** behind it — the harness is what makes P0-1 provable, so build it first even though P0-1 is the bug users feel.
3. **P0-4** Umbra pass — also the natural repro for P0-2, so run it after step 1 lands.

**Perf track** (strict ordering; each step depends on the previous)

4. **P1-4** (stats without GPU stalls) → **P1-5** (harness emits Metal metrics). Without these, every later number is unmeasurable or wrong.
5. **P1-1** (deterministic order) — small, and a prerequisite for both P1-3 and any golden image work.
6. **P1-2** (skip unchanged decorations) — biggest measurable typing win for the effort.
7. **P1-3** (partial instance patch) — large; only worth it if P1-5's numbers say the rebuild is still hot after P1-2.
8. **P1-6** (raster budget) and **P1-7** (scroll path) — measure before changing either.

**P2** after Metal is default-on and stable everywhere. P2-1 and P2-2 both depend on P1-1; P2-2's CI half depends on CI existing.

---

## Quick reference: where Metal lives

| Component | Path | Lines |
|---|---|---|
| Renderer core | `Sources/Penumbra/TextView/Metal/MetalRenderer.swift` | 625 |
| Canvas / present | `Sources/Penumbra/TextView/Metal/MetalTextCanvasView.swift` | 397 |
| Glyph extract | `Sources/Penumbra/TextView/Metal/GlyphRunExtractor.swift` | 640 |
| Atlas (LRU, 32 MB, 2048² coverage / 1024² color pages) | `Sources/Penumbra/TextView/Metal/GlyphAtlas.swift` | 748 |
| Rasterizer | `Sources/Penumbra/TextView/Metal/GlyphRasterizer.swift` | 368 |
| Decorations | `Sources/Penumbra/TextView/Metal/MetalDecorationBuilder.swift` | 406 |
| Device / library / kill switch | `MetalContext.swift`, `MetalActivation.swift` | 298 / 42 |
| Projection & pixel align | `Sources/Penumbra/TextView/Metal/MetalProjection.swift` | 62 |
| Instance & key types | `GlyphInstance.swift`, `GlyphKey.swift`, `DecorationInstance.swift`, `MetalColor.swift` | 126 / 77 / 48 / 30 |
| Backend protocol + CG backend | `Sources/Penumbra/TextView/Metal/LinePaintBackend.swift` | 113 |
| Layout integration | `Sources/Penumbra/TextView/Core/LayoutManager.swift` | — |
| Pending-highlight signal | `Sources/Penumbra/TextView/LineController/LineController.swift` | — |
| Tests | `TextViewMetalSmokeTests`, `GlyphAtlasTests`, `GlyphRunExtractorTests`, `MetalDecorationTests`, `MetalProjectionTests`, `MetalTextCanvasViewTests`, `MetalActivationTests` | — |
| Design doc / audit trail | `plan.md`; `EDITOR_PERFORMANCE_REPORT.md`, `editor-improvements.md` | — |

Local verification:

```bash
swift build
swift test --filter TextViewMetalSmokeTests   # skips entirely without a GPU
swift test --filter MetalDecorationTests
./run-metal.sh                                # Umbra with Metal on
swift run -c release PerfHarness scroll-frames synthetic --frames 240
swift run -c release PerfHarness snapshot-metal synthetic --out /tmp/metal-goldens
```

---

## Known risks (monitor, not necessarily fix now)

| Risk | Severity | Notes |
|---|---|---|
| Glyph incorrectness (kerning, ligatures, emoji ZWJ, combining marks, italic shear) | High | Mitigated by extractor tests + run-level fallback (PR 8) |
| `nextDrawable` stall on wheel-flick | High | Mitigated — only `encodePass` (inside `presentIfDirty`) acquires a drawable; layout never does |
| Caret / page guide covered by opaque canvas | High | Mitigated in v1 by transparent canvas + z-order; re-opens with P2-1 |
| Triple-buffered instance writes have no in-flight fence | Med | `PageBucket`/`DecorationBuffer` advance a 3-slot cursor with no semaphore or completion handler. Safe while ≤1 write per encode and ≤3 frames outstanding — which holds today, since writes only happen inside `encode`. `encodeForCapture` forcing a rebuild during an in-flight present is the case to watch |
| Nondeterministic instance order | Med | Tracked as P1-1; affects translucent overlap and golden stability |
| Fallback drift (Metal-only bugs) | Med | CG is the XCTest default; Umbra A/B toggle; no GPU coverage anywhere automated |
| Memory pressure / 32 MB atlas cap | Med | LRU eviction + `DispatchSource` memory-pressure handler; P2-4 would increase pressure |
| Malicious font huge bounds | Med | Per-glyph cap 256×256 px → run-level fallback |
| Discrete GPU shared-texture sampling (Intel 2019) | Med | `hasUnifiedMemory` chooses Private+blit vs Shared |
| Live resize + wrapping + drawable churn | Med | `drawableSize` updates on resize; full fragment rebuild |
| GPU runner provisioning | Med | Workflow is checked in; a machine labelled `self-hosted`, `macOS`, and `metal` must be registered externally. |

---

## Corrections from the previous revision

Kept for reviewers who read the earlier draft.

| Previous claim | Reality |
|---|---|
| P2-6: fold placeholder colors may still use renderer defaults | Done — threaded through `LineFragmentDecorations` and used by `MetalDecorationBuilder`. Moved to the fixed table. |
| "≤8 main-thread rasters per layout pass" | `GlyphRasterBudget.perFrameLimit` was 32, then 64; it is now 128 after measured cap pressure. |
| State-machine coverage lives in `TreeSitterHighlightReadinessTests` | That file does not exist. Coverage is in `LineSyntaxHighlightSchedulingTests` and `TextViewMetalSmokeTests`. |
| PerfHarness `keystroke` doesn't enable occurrence highlighting | `occurrence-keystroke` and `--highlighted` already exist. The real gap: `Commands.swift` reports no Metal metrics at all. |
| "Restore the deleted CI perf gate" | There is no CI in the repo; this needs CI to exist first (noted under P2-2). |
| P0-1 was about stale colors/characters only | Held glyphs also hold **stale absolute positions**, because `GlyphRunExtractor` bakes `fragmentFrame` origins into every instance. |
| — | New: P0-2 blank canvas after host re-attach (`compactInstanceBuffers` doesn't set `needsInstanceRebuild`). |
| — | New: P1-1 nondeterministic instance/draw order from `Dictionary` iteration under non-commutative blending. |
| — | New: P1-4 every `TextView.metal*` accessor triggers a 4 MB blit + `waitUntilCompleted` atlas census. |

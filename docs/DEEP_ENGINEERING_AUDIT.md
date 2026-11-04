# Deep Engineering Audit — Penumbra / Umbra

Date: 2026-11-03 (merged revision). Read-only audit. No code modified. No harness runs in either source audit.
This file is the **executive index**. Each finding has a delegation-ready brief in [docs/audit/findings/](/Users/alex/Developer/Penumbra/docs/audit/findings/).
Provenance: **A** = independent workflow audit (2026-11-03), **B** = prior version of this document, **A+B** = both found it independently.

Labels: **Confirmed** = inspected source or doc-cited number. **Strongly suspected** = code-supported, Foundation/corpus effect unproven. **Requires-measurement** = shape confirmed, duration unknown.
All wall-clock magnitudes are Requires-measurement unless cited from `docs/EDITOR_PERFORMANCE_REPORT.md` / `docs/PERFORMANCE_AUDIT.md` (2026-09, ~2× day-to-day drift per `docs/PERFORMANCE_RULES.md:141`).

Status: **partial** — no fresh PerfHarness/Instruments run; unexamined scope listed in §10.

## 1. Brutal executive assessment

1. **Fundamentally sound?** Yes at the core, no at the edges. Piece tree, packed line index, viewport-bounded layout, incremental tree-sitter editor path, and generation-token stale guards are the right shapes. No rope/gap-buffer/SwiftUI-surface rewrite is justified. **[A+B]**
2. **Biggest technical weakness?** Java semantic depth: no nominal attributor, no inheritor/reference index, no usage statistics. Completion corpus 214/253 = 84.6% is the ceiling of the current design, not a tuning problem. **[A+B]**
3. **Biggest performance risk?** Confirmed `O(doc)/O(piece)/O(handles)` leaks on the keystroke/caret path (F02–F05 in findings numbering: F02–F04, F07) compounded by the 6,065-line `@MainActor` `IDEWorkspace`, with zero CI enforcement. The prior draft ranked discrete-GPU `waitUntilCompleted` first; re-inspection shows it is a non-default, unified-memory-bypassed path — demoted to F10 pending an isolated discrete bench. **[A, correcting B]**
4. **What prevents Zed feel?** Unproven latency. Defaults are sane (sync keystroke parse off, Metal deferred present on, viewport layout). Proof and regression enforcement are missing (F06).
5. **What prevents IntelliJ autocomplete?** Four missing layers: Phase-4 attributor, inheritor + reference indexes, module-aware visibility, ERROR-node attribution. **[A+B]**
6. **Unnecessarily complicated?** 20-slot `LanguageProviders` + 18 `*Providing` protocols, three perf-observability systems, and four files of 3,400–6,100 lines. Over-abstracted at language plug-in; under-abstracted in Java semantics. **[A+B]**
7. **Fix before more languages?** P0 below. Adding Python via LSP is one registry entry + host server definition, zero EditorIntelligence edits — wiring is not the cost; semantics is (Java 49,422 LOC vs TypeScript 2,520 LOC). **[A]**
8. **Leave alone?** Hybrid storage, viewport layout + skip-fast-path + eviction, Metal primary + CG fallback, AppKit host, one-way EditorIntelligence→Penumbra layering, explicit registration, single file watcher, Metal deferred present. **[A+B]**

## 2. Findings index (merged, deduplicated, re-ranked)

Priority is sequencing advice, not severity alone. Full briefs are linked per row.

### P0 — blockers before expansion

- [F01 — No Java attributor](/Users/alex/Developer/Penumbra/docs/audit/findings/F01-java-attributor.md) — **✅ Done for what completion needs (2026-11-04); nominal type, capture conversion, intersections and signature IDs decided against** — Critical / Confirmed / A+B
- [F02 — refreshStructure copies whole document per caret move](/Users/alex/Developer/Penumbra/docs/audit/findings/F02-refresh-structure-copy.md) — **✅ Done (2026-11-03)** — Critical / Confirmed / A
- [F03 — PieceTree.split O(file-offset) on first edit](/Users/alex/Developer/Penumbra/docs/audit/findings/F03-piece-tree-split.md) — **✅ Done (2026-11-03)** — High / Confirmed / A
- [F04 — Sequential typing rescans up to 64 KiB per keystroke](/Users/alex/Developer/Penumbra/docs/audit/findings/F04-checkpoint-rescan.md) — **✅ Done (2026-11-03)** — High / Confirmed / A
- [F05 — Hover head-of-line blocking](/Users/alex/Developer/Penumbra/docs/audit/findings/F05-hover-head-of-line.md) — **✅ Done (2026-11-03)** — High / Confirmed / B
- [F06 — No CI performance gate; variance unmeasured](/Users/alex/Developer/Penumbra/docs/audit/findings/F06-ci-perf-gate.md) — **✅ Done (2026-11-03)** — High / Confirmed / A+B

### P1 — performance and editing experience

- [F07 — Line-handle shifting O(H) per line, O(N·H) per paste](/Users/alex/Developer/Penumbra/docs/audit/findings/F07-line-handle-shift.md) — **✅ Done (2026-11-03)** — High / Confirmed / A
- [F08 — utf16Unit single-char allocation chain](/Users/alex/Developer/Penumbra/docs/audit/findings/F08-utf16-unit-alloc.md) — **✅ Done (2026-11-03)** — Medium / Confirmed / A
- [F09 — TypeScript index rebuilds whole project per file change](/Users/alex/Developer/Penumbra/docs/audit/findings/F09-typescript-index-rebuild.md) — **✅ Done (2026-11-03)** — High / Confirmed / A
- [F10 — Metal/GPU blocking waits (non-default paths)](/Users/alex/Developer/Penumbra/docs/audit/findings/F10-metal-gpu-waits.md) — **✅ Done as far as this hardware goes (2026-11-03): default path zero waits; non-unified atlas fixed, unverified on a discrete GPU** — Medium / Strongly suspected / A+B
- [F11 — Synchronous highlight/typeset on edited lines; long-token typesetter](/Users/alex/Developer/Penumbra/docs/audit/findings/F11-sync-highlight-typeset.md) — **✅ Done (2026-11-03)** — Medium / Confirmed / A+B
- [F12 — Teardown cancellation gaps](/Users/alex/Developer/Penumbra/docs/audit/findings/F12-teardown-cancellation.md) — **✅ Done (2026-11-04)** — Medium / Confirmed / B
- [F13 — Single-event amplification through the adapter](/Users/alex/Developer/Penumbra/docs/audit/findings/F13-event-amplification.md) — **✅ Closed by measurement (2026-11-04)** — Medium / Confirmed / B

### P2 — code intelligence and language support

- [F14 — JavaScopeTree unwired; ERROR-node local loss](/Users/alex/Developer/Penumbra/docs/audit/findings/F14-scope-tree-error-recovery.md) — **✅ Done (2026-11-03)** — High / Confirmed / A+B
- [F15 — No inheritor/member index for `new` completion](/Users/alex/Developer/Penumbra/docs/audit/findings/F15-inheritor-index.md) — **✅ Done for project sources (2026-11-03)** — High / Confirmed / A+B
- [F16 — No module-aware (JPMS) visibility](/Users/alex/Developer/Penumbra/docs/audit/findings/F16-module-visibility.md) — **✅ Done for project modules + Lombok (2026-11-04): both claims proved by failing probes first; exports narrow name listings, Lombok accessors/constructors synthesized; jar/JDK modules open** — Medium / Confirmed / A+B
- [F17 — No persistent reference index](/Users/alex/Developer/Penumbra/docs/audit/findings/F17-reference-index.md) — **✅ Closed: premise stale, verified (2026-11-03)** — High / Confirmed / B
- [F18 — Completion ranking has no statistics](/Users/alex/Developer/Penumbra/docs/audit/findings/F18-ranking-statistics.md) — **✅ Done for types (2026-11-03)** — Medium / Confirmed / A+B
- [F19 — EditorIntelligence indexing parser is full-parse only](/Users/alex/Developer/Penumbra/docs/audit/findings/F19-ei-full-parse.md) — **✅ Done (2026-11-04)** — Medium / Confirmed / A
- [F20 — Whole-document materialization on ordinary commands](/Users/alex/Developer/Penumbra/docs/audit/findings/F20-document-materialization.md) — **✅ Done (2026-11-04): occurrence commands, palette `#` search and fold updates read snapshots; legacy `search(for:)` kept, no PerfHarness run** — Medium / Confirmed / A+B
- [F21 — IDEWorkspace god object and forced root recompute](/Users/alex/Developer/Penumbra/docs/audit/findings/F21-ideworkspace-god-object.md) — **✅ Done as far as the evidence goes (2026-11-03): runtime premise refuted, two clean seams extracted, unhandled keys observable** — High / Confirmed / A
- [F22 — Watcher batch synchronous 9-way fan-out](/Users/alex/Developer/Penumbra/docs/audit/findings/F22-watcher-fanout.md) — **✅ Done (2026-11-04): seven of nine handlers already async; per-path `stat` and `standardizedFileURL` removed, no checkout trace yet** — Medium / Confirmed shape / A
- [F23 — Generated-source staleness and index double-truth](/Users/alex/Developer/Penumbra/docs/audit/findings/F23-index-staleness.md) — **✅ Done (2026-11-03)** — Medium / Confirmed / B
- [F24 — Navigation awaits before caret move; breadcrumb QoS](/Users/alex/Developer/Penumbra/docs/audit/findings/F24-navigation-qos.md) — **✅ Done (2026-11-04): late answers no longer move the caret, newer request supersedes, main-thread copy removed; optimistic caret declined, no signpost run** — Medium / Confirmed / B
- [F25 — No large-file safe mode](/Users/alex/Developer/Penumbra/docs/audit/findings/F25-large-file-safe-mode.md) — **✅ Done (2026-11-04): 50 MB degrades / 500 MB read-only, banner with Enable Anyway, oversized-file notice; 520 MB plain open 1.8 s / 331 MB (release)** — Medium

### P3 — simplification, scale, and workflow

- [F26 — Closed-enum vocabulary and Java defaults leak](/Users/alex/Developer/Penumbra/docs/audit/findings/F26-language-vocabulary-leaks.md) — **✅ Done (2026-11-04): function/module/struct kinds, LSP outline + hierarchy kinds, per-language inline validators, no Java default; the `"java"` checks are not leaks** — Medium / Confirmed / A+B
- [F27 — Parse-cache caps and linear symbol scans at scale](/Users/alex/Developer/Penumbra/docs/audit/findings/F27-scale-caps.md) — **✅ Done (2026-11-04): measured; parse-cache cap 64→256 (200 tabs: 0% → 67% hits, passes 11× cheaper); lookups prefiltered losslessly (20k files: 16→3 ms worst, 9→0.3 ms no-match); 100k-file claim and global tunables left** — Low / Confirmed / A
- [F28 — Keyboard gaps: presets, folding bindings, rebinding UI](/Users/alex/Developer/Penumbra/docs/audit/findings/F28-keyboard-gaps.md) — **✅ Done (2026-11-04): gaps filled in Default/Sublime, VS Code preset + menu column, chord/menu collisions guarded, unhandled keys give a hint; no rebinding UI, hard-wired ⌘A/⌘Z kept** — Medium / Confirmed / A+B
- [F29 — Duplicate signposts and single-implementation protocols](/Users/alex/Developer/Penumbra/docs/audit/findings/F29-simplification.md) — Low / Confirmed / A+B

**Execution status (2026-11-04):** F02, F03, F04, F05, F06, F14 (complete: `JavaLocalScope` retired), F15 (project sources), F17 (verified, no change needed), F23 (generated-source staleness fixed; `docs/INDEX_STALENESS.md`), F18 (project usage counts rank types; no substring tier), F07 (lazy handle rows), F08 (single-unit reads allocate nothing), F10 (default path has no GPU waits; non-unified atlas no longer blocks), F11 (typesetter fit search and word-wrap lookback; sync highlight measured, unchanged), F12 (workspace, index and editor-controller leaks, post-teardown open, Explorer refresh ordering), F13 (measured: already coalesced at the adapter, regression tests added), F19 (incremental reparse in the workspace-index parser), F09 (incremental TypeScript index), F21 (runtime premise refuted, two seams extracted, tab-click churn removed), F01 (generic inference order, lub, method references, conditionals, interface Object members, inner classes of generic classes; on top of wildcard reads, diamond, scope-tree locals, anonymous classes) done — see each brief's *Implementation notes* for what was and was not verified. F22 (two per-path main-actor costs fixed, rest cleared by inspection). F24 (stale-answer guard found and fixed; optimistic caret declined). F20 (occurrence commands, palette text search, fold updates). F25 (tiers, banner, Enable Anyway, oversized notice, measured). F16 (project-module exports and Lombok members; jar and JDK modules open). F26 (vocabulary, LSP outline, inline validators). F28 (VS Code preset, preset gap-fills, menu/keymap collision tests). F27 (parse-cache cap, signature-prefiltered Swift/TypeScript lookups). F29 is not started. F01 closed with its design items decided against (see its brief). F05 deviates from its sketch (priority kept, bounded grace) because provider order is priority.

## 3. Text buffer summary

Storage design is sound: contiguous `NSMutableString` under 256K UTF-16 units, otherwise a VS Code-style piece tree (mmap original + append-only add buffer) with 64-record packed line leaves. Lookup is `O(log(L/64)+64)`; undo is `O(replaced range)` capped at 100 groups / 64 MiB; load streams in `O(bytes)`; save streams piece bytes without materializing. The defects are four missing checkpoint/cursor fast paths inside that design (F03, F04, F08) plus eager handle shifting (F07) and host-side materialization (F02, F20). No storage rewrite. Full operation table is in the F03/F04/F07 briefs.

## 4. Rendering summary

Viewport-bounded layout `O(padded viewport)`, skip-fast-path per line, line-controller eviction, one instanced draw per atlas page, fragment-relative glyph-extract cache keys, 32 MiB LRU atlas, 128-glyph raster budget per frame. Defaults verified by re-inspection: Metal deferred present defaults on; sync keystroke tree-sitter parse defaults off. Remaining risks are CPU-side and upstream of the GPU: synchronous atlas-miss raster on `@MainActor`, full instance-buffer rebuild `O(F log F)` on structure change, edited-line sync highlight/typeset (F11), and the non-default blocking waits in F10. Core Graphics fallback redraws full fragments with no dirty-rect subdivision — keep as fallback only, do not invest in a CG glyph cache.

## 5. Architecture summary

EditorIntelligence is genuinely language-agnostic in control flow (string-keyed registry, single `EditorAdapter`, generic LSP tier, zero Java imports outside comments) and Java-shaped only in vocabulary (F26). Umbra diagram in text: SwiftUI `IDERootView` → `IDEWorkspace` (`@MainActor`) → { EditorHostCache → Penumbra `TextView` → `TextInputView` → `StringView`/`PieceTree` + `LineManager` → `LayoutManager` → Metal/CG; `IDEProjectWatcher` → 9-way fan-out; `IDELanguageServerHost`; Java/Swift/TypeScript services via the EditorIntelligence registry }. The one-way layering is the best decision in the codebase; protect it.

## 6. Roadmap

- **P0:** F01 foundations start, F02, F03, F04, F05, F06. Acceptance per brief: counters (`pieceTreeMaterializeCount`, `handleShiftVisits`) plus Release PerfHarness `enter-session` 20k/120k with the display on.
- **P1:** F07–F13. Acceptance: paste/Enter profiles flat in document size; teardown Leaks-clean; hover first-wins unit test.
- **P2:** F14–F25. Acceptance: completion corpus above 214/253 with no regressions; completion p95 measured; rename/call-hierarchy latency on a fixture project.
- **P3:** F26–F29 plus Python-via-LSP only after F26. Acceptance: new-language wiring touches registry + host only.

## 7. Decisions

- **Keep:** hybrid storage, `PackedLineIndex`, viewport layout, Metal + atlas, AppKit host, registry/LSP tier, single watcher, deferred present, `DocumentParseCache`, `RefactoringEngine` (prior draft's removal claim was falsified by its own tests — do not delete unmigrated).
- **Optimize:** F02–F04, F07–F09, F11, F18, F24.
- **Simplify:** F21 (extract seams only), F29.
- **Replace:** Java typer + per-query scope walk with attributor + scope tree (F01, F14); legacy `stringView.string` searches with the snapshot source (F20).
- **Investigate:** F10 (discrete-GPU isolated bench), F16/F23 corpus fixtures, TSan on ~10 `nonisolated(unsafe)` statics, atlas CJK miss rate, typesetter long-token docs, hundreds-open and 100k-file fixtures.
- **Defer:** new native languages, vim/emacs modes, CG glyph cache, workspace-symbol fuzzy beyond prefix narrowing.

## 8. Latency targets vs architecture

Doc-cited (2026-09, stale): keystroke ~1–3 ms vs <4 ms budget; mid-file Enter fixed 20.661→1.918 ms, flat ~2.023 ms at 120k lines; scroll ~3.1–6.7 ms; 10 MB open 37 ms, 100 MB 253 ms (pre-mmap-fix figures for 500 MB/2 GB are stale). The 50 ms completion debounce alone consumes a <50 ms first-response target before any provider runs; phased fast/slow delivery meets <100 ms interactive updates by design. Cached symbol lookup <10 ms fails structurally for Swift/TypeScript linear name scans at monorepo scale (F27). Instruments strategy: Time Profiler + Metal System Trace gated by PerfHarness; Allocations for F08; Thread Sanitizer for the statics; SwiftUI Instruments for `IDERootView`/`IDEFileTreeView` body counts. Never Debug timings.

## 9. Feature and keyboard summary

Present and confirmed: multi-cursor with selection history, geometric block selection, folding (tree-sitter + indentation fallback), soft wrap, viewport inlay hints, three-layer diagnostics UI, definition/implementation/usages navigation, 1,017-line command palette (search-everywhere, quick-open, recent files/locations, symbols, go-to-line, file structure), back/forward history (64 entries). Gaps are additive, none architecture-blocked: no VS Code preset, no rebinding UI, folding keys only in the IntelliJ preset, next/previous-problem host-dependent and swallowed when unwired, no large-file safe mode (F25). Detail in F28.

## 10. Unexamined / unmeasured

No fresh measurement of any hot path. Markdown preview and minimap renderers, Umbra `EditorHostCache` bridge internals, vendored tree-sitter grammar versions, exhaustive-switch impact of new enum cases, JPMS/Lombok corpus proof, hundreds-open and 100k-file behaviour, discrete-GPU isolation, shader source cost. Each brief names its own validation method; findings marked Requires-measurement must not be quoted as bottlenecks until their brief's benchmark has run.

## 11. How to delegate from here

Pick one brief from §2. Each is self-contained: evidence with file/symbol citations, root cause, fix sketch, complexity, dependencies, acceptance criteria, tests/benchmarks, and out-of-scope. Do P0 in order F06 first (so every later fix is measurable), then F02–F05 in parallel, F01 as the long pole.

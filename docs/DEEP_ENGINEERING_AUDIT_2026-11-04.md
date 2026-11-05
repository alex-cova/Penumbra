# Deep Engineering Audit — Penumbra / Umbra (2026-11-04 session)

> Read-only audit. No files modified (except this report), no tests or `PerfHarness` run.
> Evidence from 8 parallel code inspections + 1 adversarial verification pass.
> Every finding is labelled **Confirmed** (code body read, `path:line`) or **Suspected** (search-negative, partial read, or unmeasured). No latency number below is a measurement.
> This is this session's independent audit. It does not replace the merged revision in `docs/DEEP_ENGINEERING_AUDIT.md` (2026-11-03).

**Unread / unverified gaps that limit this report:** `LayoutManager.swift` (2,021 lines) visible-row guarantee, `PenumbraWorkbenchEditorAdapter` (shipped multi-doc adapter), Gradle/Maven/JDK bodies, Java ranking/hover/refactoring bodies, per-language `.scm` queries, all 505 `Task{}` cancellation sites, RTL/IME (search-negative only). Severity ranking below is consequence-ranked, not cost-measured.

---

## 1. Brutal Executive Assessment

- **Is the architecture fundamentally sound?** Yes, at the module level. The dependency graph is an acyclic DAG: `TreeSitter/LanguageSyntax → EditorIntelligence (Foundation only) → {Java,Swift,TypeScript}Intelligence + EditorIntelligenceLSP → Penumbra → PenumbraLanguages → Umbra`. `Package.swift:161` — Penumbra never imports an intelligence implementation; intelligence never imports Penumbra; the only bridge is `Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift:10`. This is the strongest part of the system. Do not rewrite it.
- **Biggest technical weakness:** the generic (non-Java) intelligence tier is syntax dressed as semantics. `Sources/Penumbra/LanguageParser/TreeSitterSyntaxTree.swift:59` emits every identifier as `.variable` regardless of declaration/reference/scope, with no `ERROR`/`MISSING` gating. That pollutes the index, find-references, and duplicate-symbol diagnostics for 29 syntax-only languages.
- **Biggest performance risk:** everything that matters for feel is CPU work on the main actor — CoreText shaping, glyph raster, glyph extraction, instance-buffer rebuilds. Metal only composites. See §4.
- **What prevents Zed feel?** Not the buffer (the buffer is good). It is main-thread shaping/raster on cache misses, full instance-buffer rebuilds on structure changes, triple-buffer slot waits that can block main, and an eager `O(n)` project-tree build on `MainActor` at open.
- **What prevents IntelliJ completion?** Not the pipeline (it is well-built). It is Java semantic correctness gaps (JLS name resolution, capture/intersection types, Lombok, generated sources, JPMS) and a generic-tier pre-filter that defeats the ranker. Diagnostics parity vs `javac` is near zero on measured categories.
- **What is unnecessarily complicated?** Triple language registration, the double LSP adapter layer, and the 6,139-line `IDEWorkspace` god object.
- **Fix before more languages:** index pollution, `O(document)` indexing path, generic completion pre-filter, navigation timeout. Adding Python/Rust/Kotlin today multiplies the pollution.
- **Leave alone:** PieceTree buffer, `PackedLineIndex`, `LanguageServiceRegistry` + Tiered/Routed dispatch, `DocumentParseCache`, tree-sitter highlight path, `SubprocessKit`, test corpus scale (~7,600 test functions).

---

## 2. Critical Findings (20, consequence-ranked)

Severity: Critical / High / Medium / Low. Confidence: Confirmed / Suspected / Requires measurement.

### F-01 — Semantic index pollution from syntax tree
- Severity: Critical. Confidence: Confirmed.
- Evidence: `Sources/Penumbra/LanguageParser/TreeSitterSyntaxTree.swift:59` walk emits every `identifier` as `.variable`, `type_identifier` as `.type`, no decl/ref/scope distinction; no `ERROR`/`MISSING` check anywhere except `Sources/Penumbra/TextView/SyntaxHighlighting/Internal/TreeSitter/TreeSitterFoldingProvider.swift:159`.
- Root cause: syntax node types treated as semantic symbol kinds to feed `Sources/EditorIntelligence/Indexing/SymbolIndex.swift:9`.
- Consequence: broken code and mere references enter the index; `Sources/EditorIntelligence/Indexing/DuplicateSymbolDiagnosticProvider.swift:22` can warn on repeated references.
- Fix: gate `ERROR`/`MISSING` subtrees; emit declarations only via `DeclarationScanner` config; tag syntax-derived symbols as non-semantic tier. Complexity: Medium. Validation: new test asserting identifiers inside an `ERROR` node produce no index entries.

### F-02 — Indexing is `O(document)` despite incremental reparse
- Severity: Critical. Confidence: Confirmed.
- Evidence: `Sources/Penumbra/LanguageParser/TextChangeRegion.swift:23` prefix/suffix scan is `O(old+new)` bytes per edit; `Sources/Penumbra/LanguageParser/TreeSitterLanguageParser.swift:53` then re-extracts symbols/words/imports over the whole tree.
- Consequence: native `ts_tree_edit` incrementality is thrown away on the indexing path. A 1-char edit in a 100k-line file costs a full-document pass.
- Fix: consume the editor's `TextChange`/`TSInputEdit` directly; extract symbols only from changed node ranges. Complexity: High. Validation: `checkpointScanByteCount`-style bounded-scan test on the indexing path.

### F-03 — Generic completion pre-filter defeats the ranker
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/EditorIntelligence/Indexing/Trie.swift:56` + `Sources/EditorIntelligence/Indexing/SymbolIndex.swift:39` are prefix-only; `Sources/EditorIntelligence/Ranking/DefaultRanker.swift:19` supports camelHump/wordStart tiers that can never be reached. `Sources/EditorIntelligence/Completion/WordCompletionProvider.swift:8` caps at 500 by BFS with nondeterministic `children.values` order (`Sources/EditorIntelligence/Indexing/Trie.swift:102`).
- Consequence: `fb` never finds `FooBar`; with a 1-char prefix the 500 shortest names win arbitrarily before ranking.
- Fix: subsequence/camelHump-aware candidate generation, deterministic ordering, rank before cap. Complexity: Medium. Validation: matcher tests for camelHump recall at cap.

### F-04 — Java diagnostics far below `javac`
- Severity: High. Confidence: Confirmed (from project docs, not re-run).
- Evidence: `docs/JAVA_PARITY.md:20` — `cant.apply.symbol` recall 0%, `cant.resolve.location` 17%, `missing.ret.stmt` 0%, `prob.found.req` 0%, `unreported.exception` 0%. The 419-completion + 172-navigation corpus passes, but that is not diagnostics parity.
- Fix: do not chase full `javac` parity; either lean on `javac`/LSP diagnostics as primary or scope native diagnostics to the measured categories. Complexity: High. Validation: parity baseline re-run per release.

### F-05 — Java name resolution violates JLS shadowing
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/JavaIntelligence/Semantics/JavaTypeResolver.swift:104` on-demand imports are first-match-wins (JLS 6.4.2 ambiguity never diagnosed); `Sources/JavaIntelligence/Semantics/JavaTypeResolver.swift:116` checks inherited nested types last, contrary to JLS 6.4.1 (comment admits it).
- Consequence: silently wrong type → wrong members, wrong completion, no error shown.
- Fix: implement JLS 6.4.1/6.4.2 order + ambiguity diagnostic. Complexity: Medium. Validation: corpus cases for import-vs-inherited-nested collisions.

### F-06 — Java type system cannot represent capture/intersection
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/JavaIntelligence/Semantics/Model/JavaTypeSystem.swift:8` no capture conversion, no intersection, `lub` erased/raw; `Sources/JavaIntelligence/Stubs/JavaTypeRef.swift:10` has no such cases; `Sources/JavaIntelligence/Semantics/JavaResolutionContext.swift:71` keeps only `bounds.first`; `Sources/JavaIntelligence/Semantics/JavaMemberLookup.swift:64` returns Object members for type variables.
- Consequence: `T extends A & B`, conditionals and multi-catch over generics lose type arguments; completion on bounded `T` under-completes.
- Fix: add capture/intersection cases to `JavaTypeRef`; bound-aware member lookup. Complexity: High. Validation: generic-bound completion corpus.

### F-07 — Lombok and annotation-processor gap
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/JavaIntelligence/Syntax/JavaLombokMembers.swift:10` models only Getter/Setter/Data/Value/constructors — `@Builder`, `@With`, `@SneakyThrows`, `val` explicitly not modelled. `Sources/JavaIntelligence/Diagnostics/JavacInvocationBuilder.swift:150` puts only Lombok on `-processorpath`, else `-proc:none`.
- Consequence: `builder()`/`withX()` invisible; MapStruct/Dagger/QueryDSL generated types unresolved until a real build. This is the single most visible IntelliJ gap in typical enterprise Java.
- Fix: model `@Builder`/`@With`; discover processors from the project model. Complexity: Medium. Validation: Lombok corpus project.

### F-08 — Find Usages is per-file brute force
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/JavaIntelligence/References/JavaFileUsageResolver.swift:20` full parse per file, new session per candidate, `.ambiguous` on unknown receiver — `O(candidates × resolution)` per file, no global reference index.
- Consequence: slow and false-positive on large workspaces; library-intermediate subtypes also missed by `Sources/JavaIntelligence/Index/JavaInheritorIndex.swift:6` (project shards only, simple-name keyed).
- Fix: persistent reference index keyed by resolved symbol, not spelling. Complexity: High. Validation: usage-search benchmark on a multi-module fixture.

### F-09 — `IDEWorkspace` god object
- Severity: High. Confidence: Confirmed.
- Evidence: `Umbra/Sources/Umbra/Workspace/IDEWorkspace.swift:87` `@MainActor @Observable`, 6,139 lines, ~545 members, ~50 `@ObservationIgnored`.
- Consequence: coarse SwiftUI invalidation risk (mitigated, not eliminated, by per-property tracking), untestable in isolation, every feature change touches one file.
- Fix: extract per-pane/per-domain stores behind the existing per-window ownership; do not rewrite wholesale. Complexity: High, incremental. Validation: `IDEBodyDiagnostics` recompute counts before/after.

### F-10 — Eager project-tree build blocks main actor at open
- Severity: High. Confidence: Confirmed code, Suspected jank (unmeasured).
- Evidence: `Umbra/Sources/Umbra/Explorer/IDEProjectModel.swift:100` `setRoot → buildNode` recursive synchronous `contentsOfDirectory` walk on `@MainActor`. The refresh path (`Umbra/Sources/Umbra/Explorer/IDEProjectModel.swift:233`) is correctly detached/generation-guarded — only the first build is eager.
- Fix: lazy/detached first build with first paint from root level only. Complexity: Medium. Validation: 10k-file fixture open time in `PerfHarness`-style profile.

### F-11 — Metal accelerates only compositing
- Severity: High. Confidence: Confirmed.
- Evidence: `Sources/Penumbra/TextView/Metal/MetalContext.swift:155` shaders are instanced-quad atlas sampling + SDF solids. Shaping is `Sources/Penumbra/TextView/LineController/LineTypesetter.swift:282` `CTTypesetterCreateLine` on CPU; raster is `Sources/Penumbra/TextView/Metal/GlyphRasterizer.swift:56` `CGContext` per glyph; `Sources/Penumbra/TextView/Metal/GlyphAtlas.swift:45` is `@MainActor`.
- Consequence: GPU spend does not reduce the typing/scroll hot path. Cold CJK/emoji is budgeted at 128 rasters/pass (`Sources/Penumbra/TextView/Metal/GlyphRunExtractor.swift:66`) with up to 40 main-queue retry passes.
- Fix: none structural — invest in shaping/extraction caching, not more GPU work. Complexity: Medium. Validation: Instruments Time Profiler + Metal System Trace frame split (Requires measurement).

### F-12 — Triple-buffer slot wait can block main
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/Penumbra/TextView/Metal/MetalRenderer.swift:71` `PageBucket.advanceForWrite` blocks on `NSCondition.wait` when all 3 slots are in flight; only the display-link path avoids it.
- Consequence: a GPU stall becomes a main-thread stall on the synchronous scroll/resize present path.
- Fix: drop-frame instead of wait on the sync path. Complexity: Low–Medium. Validation: `MetalWaitStats` slot-wait counter under GPU load.

### F-13 — Full instance-buffer rebuild on structure change
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/Penumbra/TextView/Metal/MetalRenderer.swift:1035` full path sorts all fragments `O(F log F)` and regroups every glyph; triggered by line-structure/scale/colorspace/font changes.
- Fix: extend the existing dirty-page partial path. Complexity: Medium. Validation: enter-session 120k profile, scroll during theme/font change.

### F-14 — Navigation has no timeout; hover does
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/EditorIntelligence/Navigation/NavigationEngine.swift:21` sequential first-non-nil, no grace; `Sources/EditorIntelligence/Hover/HoverEngine.swift:29` has 250 ms priority grace.
- Consequence: one hung provider blocks Go-to-Definition indefinitely.
- Fix: copy the hover grace/cancellation pattern. Complexity: Low. Validation: hung-provider stub test.

### F-15 — LSP offset conversion bug (suspected consequence)
- Severity: Medium. Confidence: Confirmed code, Suspected impact.
- Evidence: `Sources/EditorIntelligence/LSP/LSPConversion.swift:15` sets `utf16Offset = position.character` (line-local) as if global.
- Consequence: wrong ranges on line > 0 wherever consumers trust `utf16Offset`.
- Fix: recompute global offset or remove the field. Complexity: Low. Validation: multi-line LSP fixture test.

### F-16 — AI completion in popup is dead code
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/EditorIntelligence/AI/AICompletionProvider.swift:17` single item whose `matchText` is its label, dropped for any typed prefix by the matcher. The real AI path is the separate inline ghost engine.
- Fix: remove from popup or give it explicit non-filtered presentation. Complexity: Low.

### F-17 — `sortText` silently ignored; ranking is provider-trusting
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/EditorIntelligence/Completion/CompletionItem.swift:74` stores `sortText`; `Sources/EditorIntelligence/Ranking/DefaultRanker.swift:50` never reads it. No expected-type relevance except provider-supplied `priority`/`preselect`.
- Consequence: LSP ordering lost; ranking quality is entirely delegated to each provider with no shared contextual signal.
- Fix: honour `sortText` as a tier input; pass expected type into ranker context. Complexity: Medium.

### F-18 — Bundled query failure asymmetry: crash vs silent loss
- Severity: Medium. Confidence: Confirmed.
- Evidence: `Sources/PenumbraLanguages/QueryResources.swift:5` missing `.scm` is `fatalError` + force-unwrap; `Sources/Penumbra/TextView/TreeSitter/TreeSitterLanguage.swift:150` invalid query is swallowed to `nil` (DEBUG print only), silently disabling highlighting.
- Fix: one policy — degrade + log + surface in diagnostics, never crash, never silent. Complexity: Low.

### F-19 — Undo byte-cap may not evict; add-buffer never reclaimed
- Severity: Medium. Confidence: Confirmed code pattern, Suspected effect.
- Evidence: `Sources/Penumbra/TextView/Core/TimedUndoManager.swift:101` sets `levelsOfUndo` twice (`:104` then `:106` overwrites); removing payload bookkeeping does not prove `UndoManager` actions are dropped. `Sources/Penumbra/TextView/Core/PieceTree.swift:281` add-buffer is append-only until save-compact.
- Consequence: long heavy-churn sessions grow memory `O(total bytes ever typed)`.
- Fix: test actual eviction; periodic compaction threshold. Complexity: Low–Medium. Validation: undo-cap eviction test, churn-session allocation profile.

### F-20 — 505 fire-and-forget tasks; single-root only
- Severity: Medium. Confidence: Confirmed counts, Suspected per-site risk.
- Evidence: grep count 505 `Task {` + 69 `Task.detached` in `Umbra/Sources/Umbra`, many unstored in `Umbra/Sources/Umbra/Workspace/IDEWorkspace.swift:1099`; no `multiRoot`/`workspaceFolders` hits — one project root per window.
- Consequence: run-after-close risk where cancellation/weak-self checks are absent (sampled only); monorepo multi-root workflows impossible.
- Fix: audit unstored tasks by lifetime class; multi-root is a product decision, defer until demanded. Complexity: Medium (audit), High (multi-root).

**Also confirmed, lower severity:** multi-caret caret remap is `O(C²)` (`Sources/Penumbra/TextView/Core/TextInputView.swift:3766`); `TextView.text` materializes `O(n)` per read (`Sources/Penumbra/TextView/Core/PieceTree.swift:691`); Java index rebuild is `O(N log N)` on source-set change (`Sources/JavaIntelligence/Index/JavaIndex.swift:237`); file-usage shards go stale until overlay/force (`Sources/JavaIntelligence/Scanning/JavaIndexScheduler.swift:66`); method-body locals absent from the Java index (`Sources/JavaIntelligence/Syntax/JavaSourceStubBuilder.swift:53`); JPMS visibility fails open (`Sources/JavaIntelligence/Modules/JavaModuleVisibility.swift:116`).

---

## 3. Text Buffer Table (asymptotic only — no measurements taken)

Notation: `L` lines, `P` pieces, `C` carets, `n` UTF-16 length.

| Operation | Current implementation | Complexity | Risk / recommendation |
|---|---|---|---|
| Single-char insert | PieceTree tail-extend / `NSMutableString` <256 KiB | Amortized `O(edit + log P)` | Low — keep |
| Backspace | PieceTree delete, 2 splits | `O(pieces removed × log P)` | Low — keep |
| Multi-line paste | Chunked >64 KiB on scalar/CRLF bounds | `O(paste + lines × log L)` | Low — keep |
| Selection replace | Same mutation path via `TextEditHelper` | `O(edit + log L)` | Low — keep |
| Line deletion | `PackedLineIndex` leaf shift | `O(log L + 64)` | Low — keep |
| Cursor movement | Selection `didSet` triggers bracket/occurrence/layout work | Not free; unmeasured | Medium — profile caret-move path |
| Line lookup | `PackedLineIndex.locate` | `O(log(L/64) + 64)` | Low — keep |
| Undo / redo | Replaced-range text only, caps 100 groups / 64 MiB | `O(edit sizes)` | Medium — verify byte-cap eviction (F-19) |
| Large-file edit | PieceTree + checkpoints (64 KiB / 4 KiB) | Checkpoint-bounded, test-asserted | Low — keep |
| Full-text read (`TextView.text`) | Materializes `[unichar]` + `String` | `O(n)` alloc per read | High if on hot path — audit callers |

**Verdict on data structure:** do not replace the buffer. A VS Code-style piece tree with an order-statistics red-black tree (`Sources/Penumbra/TextView/Core/PieceTree.swift:246`, `Sources/Penumbra/RedBlackTree/RedBlackTree.swift:36`) plus a packed line index is the right architecture, and bounded-scan behaviour is test-asserted (`Tests/PenumbraTests/PieceTreeTests.swift:432`). A rope/gap-buffer rewrite would be speculative. The only structural debt is append-only growth until save-compact.

---

## 4. Performance Bottleneck Matrix

All entries are code-proven paths; magnitude is **Requires measurement** unless stated.

| Component | Bottleneck | Impact | Priority |
|---|---|---|---|
| Indexing path | `O(document)` diff + extraction per parse (F-02) | Every keystroke, large files | P0 |
| Main thread | CoreText shaping + glyph raster on atlas miss (F-11) | Typing/scroll feel | P0 |
| Metal present | Slot wait blocks main (F-12); full rebuild `O(F log F)` (F-13) | Scroll/resize jank | P1 |
| Project open | Eager `O(n)` tree on `MainActor` (F-10) | Open latency, big repos | P1 |
| Completion | Per-snapshot full re-rank; per-candidate UTF-16 arrays in matcher | Completion latency at scale | P1 |
| Java usages | `O(candidates × resolution)` per file (F-08) | Find Usages on workspaces | P1 |
| Caret move | `didSet` fan-out (bracket/occurrence/layout) | Cursor latency | P2, profile first |

**Latency budget:** the targets in the brief (<1 ms insert, <2 ms main-thread input, 16.67/8.33 ms frame, <50 ms completion, <10 ms cached lookup) are reasonable as *budgets*, but this audit measured nothing. Publishing them as current status would be fabrication. The harness to measure them already exists: `Tools/PerfHarness/Sources/EnterSessionProfile.swift:51` (enter-session 20k/120k, keystroke-budget). The defect is gating: `Scripts/perf-gate.py:34` gates only 3 scenarios and `.github/workflows/perf-gate.yml:9` runs nightly, not per-PR.

**Required profiling before any optimization claim:**
- Release `PerfHarness enter-session` at 20k and 120k lines, parent vs change (per repo rules, never Debug timings).
- Instruments Time Profiler on the keystroke path; Allocations on a churn session (F-19).
- Metal System Trace + Core Animation for the frame split shaping/extract/raster/composite.
- SwiftUI Instruments on `IDERootView` invalidation breadth (F-09).
- Signposts around indexing extraction (F-02) and completion re-rank.

---

## 5. Architecture Risk Matrix

| Risk | Type | Long-term cost |
|---|---|---|
| Syntax-as-semantics index (F-01/F-02) | Fundamental | Blocks every new language |
| Java semantic gaps (F-05/F-06/F-07) | Language integration | Caps completion quality |
| `IDEWorkspace` god object (F-09) | Maintainability | Slows all app work |
| Triple language registration | Maintainability | Per-language friction |
| Double LSP adapter layer (`LSP*Provider` + `LSPReady*`) | Simplification | Confusion, dead surface |
| Single-root windows (F-20) | Scalability | Monorepo ceiling |
| 4 coexisting indexes (generic + Java/Swift/TS) | Duplicate truth | By design; keep generic as fallback |

Rendering and concurrency are **not** fundamental risks: layout is viewport-bounded (viewport + 350 pt band, `Sources/Penumbra/TextView/Core/LayoutManager.swift:1446`), highlight queries are line/window-bounded with epoch-checked stale discard, and engines use actors with generation guards (`Sources/Penumbra/EditorIntelligenceAdapter/EditorIntelligenceController.swift:1879`).

---

## 6. Feature Gap Matrix

The audit's most surprising result: **the requested feature list is essentially complete.** All of these are implemented and mostly tested: multiple cursors, column/block selection, line move/duplicate/delete, bracket matching, folding, sticky scroll, inlay hints, inline ghost completion, go-to-definition/implementation/type, find usages, workspace symbol/file search, nav back/forward + last-edit, rename/refactors, hierarchies, command palette (⌘⇧P).

Real gaps, in priority order:
- **Worth doing now:** bracket-match and column-selection keys exist only in some presets (see §7); RTL/bidi and IME composition end-to-end (Suspected missing, search-negative).
- **Blocked by architecture:** multi-root workspaces (F-20); library-chain subtypes (F-08).
- **Not worth building:** a second rendering backend strategy, OT/collaborative editing, recreating IntelliJ's full inspection suite. The CG backend (`Sources/Penumbra/TextView/Metal/LinePaintBackend.swift:133`) is a fallback/test path (Metal is default in production, off under XCTest, `Sources/Penumbra/TextView/Metal/MetalActivation.swift:10`) — keep it as fallback, stop investing in parity.

**IntelliJ comparison — minimum foundational set for a step change:** (1) JLS-correct name resolution, (2) capture/intersection types, (3) Lombok `@Builder`/`@With` + processor discovery, (4) a real reference index, (5) expected-type-aware ranking. That is the list. Everything else is incremental.

---

## 7. Keyboard Shortcut Matrix

Presets exist (Default/Sublime-like, VS Code, IntelliJ) and collisions are systematically tested (`Umbra/Tests/UmbraTests/IDEMenuShortcutsTests.swift:42`). Confirmed gaps:

| Action | Existing | Recommended | Priority |
|---|---|---|---|
| Go to matching bracket | IntelliJ ⌃M only | Add Default/VSCode binding | P1 |
| Column selection toggle | IntelliJ ⌘⇧8 only | Add Default binding | P1 |
| Go to definition | F12 (+ host handling) | Keep; add ⌘-click audit | P2 |
| Command palette | ⌘⇧P | Keep | — |
| Go to file / symbol | ⌘P / ⌘R (preset-varied) | Keep per-preset | — |

Full per-preset enumeration was sampled, not exhaustive — a complete conflict matrix remains unproduced.

---

## 8. Umbra Architecture Recommendations

**Assessment:** genuinely language-agnostic in routing, Java-shaped in vocabulary. Routing by `languageIdentifier` through `Sources/EditorIntelligence/Languages/LanguageServiceRegistry.swift:141` with tiered syntactic→semantic replacement is real. The Java flavour lives in core *types* (`Sources/EditorIntelligence/Completion/CompletionContext.swift:16` `invocationCount`/smart mode, hierarchy/line-marker kinds) — tolerable, not worth a purge.

**Smallest viable language boundary (confirmed from code):**
- Syntax only: grammar pack trio + 1 `LanguageDefinition` + 1 bundled line. 32 definitions already exist; Python/Rust/Kotlin grammars are present.
- Intelligence: 1 `BasicLanguageService` in `Umbra/Sources/Umbra/Intelligence/IDEIntelligenceServices.swift:97`, optionally + `LSPLanguageService`. No new engine, no new module.
- Blocked only by: native index/model per language (≈11 files mirroring TypeScriptIntelligence) **or** LSP server lifecycle in the Umbra host (pyright / rust-analyzer / kotlin-lsp). Swift additionally drags swift-syntax.

**Remove/merge:** triple registration (syntax registry + service registry + `IDELanguageModules`) → generate stubs from `LanguageDefinition`; double LSP wrapper layer → one locus. **Keep:** `LanguageProviders` 20-slot value struct (mostly-nil is fine, do not split), generic `SymbolIndex` as fallback, all leaf singletons.

```
TreeSitter / LanguageSyntax        (parse, DocumentParseCache)
        ↓
EditorIntelligence                 (engines, ranking, SymbolIndex)
        ↓  LanguageServiceRegistry (tiered: syntactic → semantic / LSP)
{Java,Swift,TypeScript}Intelligence · EditorIntelligenceLSP
        ↓  EditorAdapter (sole seam)
Penumbra engine  →  PenumbraLanguages  →  Umbra app
```

Migration risk: low. None of this requires touching the engine.

---

## 9. Prioritized Roadmap

### P0 — Correctness blockers
- **F-01/F-02** Gate `ERROR` subtrees; changed-range-only symbol extraction. Tests: ERROR-pollution test, bounded-scan indexing test.
- **F-14** Navigation timeout/grace. Test: hung-provider stub.
- **F-15** Fix or remove global `utf16Offset`. Test: multi-line LSP fixture.
- **F-18** Unify bundled-query failure policy. Test: missing/invalid query degrades, never crashes.

### P1 — Performance and editing experience
- Run the profiling programme in §4 first; then **F-12** (drop-frame), **F-13** (dirty-page rebuild), **F-10** (lazy project build), **F-03** (matcher pre-filter).
- Move `perf-gate` to per-PR for the 3 gated scenarios; add scroll/search profiles.
- Acceptance: pairwise PerfHarness medians, no regression beyond gate ratios.

### P2 — Code intelligence
- **F-05, F-06, F-07, F-08, F-17** in that order. Acceptance: parity/corpus baselines extended per item; diagnostics categories re-measured, not assumed.

### P3 — Advanced capabilities
- LSP lifecycle for Python/Rust/Kotlin (cheapest breadth win), multi-root workspaces, IDEWorkspace decomposition (incremental, alongside other work).

---

## 10. Engineering Decisions by Subsystem

| Subsystem | Decision | Rationale (one line) |
|---|---|---|
| PieceTree + PackedLineIndex | Keep | Right structure, test-asserted bounds |
| Layout/highlight incrementality | Keep | Viewport/line-bounded, epoch-guarded |
| Metal backend | Optimize | Compositing only; fix slot-wait/rebuild |
| CG backend | Keep as fallback | Test/default-off path; stop parity work |
| Tree-sitter layer | Keep | Correct syntax role; fix index misuse |
| EditorIntelligence pipeline | Optimize | Fix pre-filter, `sortText`, nav timeout |
| JavaIntelligence | Optimize | JLS/types/Lombok/reference index |
| LSP layer | Simplify | Merge double wrapper |
| Language registration | Simplify | Generate from `LanguageDefinition` |
| IDEWorkspace | Simplify (incremental) | Extract stores; no rewrite |
| SwiftUI app shell | Keep | AppKit-hosted editor; `@Observable` per-property |
| Perf gating | Replace process | Nightly-only → per-PR |

**Bottom line:** you are not held back by the wrong architecture, weak text storage, or SwiftUI. You are held back by (a) one wrong assumption — syntax treated as semantics — replicated across the generic intelligence tier, (b) Java semantic depth that stops before the JLS corners enterprise code lives in, and (c) unmeasured main-thread CPU work that no GPU backend can hide. Fix P0, measure, then spend on Java depth. Do not rewrite the engine, the buffer, or the module graph.



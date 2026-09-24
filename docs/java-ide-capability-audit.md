# Java IDE Capability Audit

> Gap analysis for bringing Umbra's Java development experience closer to IntelliJ IDEA.
> Based on repository inspection (Penumbra, EditorIntelligence, JavaIntelligence, Example/Umbra).
> Last updated: 2026-09-24.

---

## Executive Summary

Umbra + Penumbra + JavaIntelligence form a **credible lightweight Java editor**, not yet a professional IntelliJ-class IDE. The stack is strongest where it was deliberately invested: **native text editing**, **EditorIntelligence provider architecture**, and **Java completion/navigation on a cached class-stub index with Gradle classpath sync**.

| Layer | Maturity | Notes |
|---|---|---|
| Text engine (Penumbra) | **High** | Multi-cursor, folding, palette, workbench — production-grade |
| IDE platform (EditorIntelligence) | **High (generic)** | Engines/protocols exist; LSP adapters unused in Umbra |
| Java intelligence (JavaIntelligence) | **Medium** | Strong completion; weak diagnostics/refactoring/navigation depth |
| IDE shell (Umbra) | **Medium** | Real Gradle/Git/terminal; no debugger, problems panel, or run configs |

The largest gap is not UI polish — it is **missing semantic analysis infrastructure**: no compiler-backed diagnostics, no reference index, no Java-aware rename/refactor, and no debugger. IntelliJ's day-to-day feel depends on a persistent PSI + stub-index model; this editor has **class stubs + on-demand tree-sitter parsing**, which is enough for smart completion but not for inspections, usages, or safe refactorings.

---

## Current Capabilities

### Editor (Penumbra + Umbra)

| Capability | State |
|---|---|
| Multi-cursor editing | **Implemented** |
| Selection manipulation | **Implemented** — semantic expand/shrink, column mode, occurrences |
| Code folding | **Implemented** — indent + tree-sitter |
| Sticky/structure headers | **Missing** |
| Inline diagnostics | **Implemented** — squiggles for duplicate symbols and `javac` errors |
| Inlay hints | **Missing** |
| Code actions | **Partial** — ⌥↩ menu with Java import fixes and remove-unused-imports; no other quick fixes |
| Formatting | **Implemented (Java)** — built-in whitespace-only formatter (⌥⌘L, selection or file); other languages use the bracket reindent |
| Imports management | **Partial** — auto-import on accept, Optimize Imports (⌃⌥O), optional on save; no reordering |
| Comment/uncomment | **Implemented** |
| Surround-with | **Implemented** — generic templates |
| Live templates | **Partial** — snippets (Java excluded); `@Override` stub snippets in completion |
| Structural selection | **Implemented** — tree-sitter semantic selection |
| Breadcrumbs | **Implemented** — Java-aware labels (`Outer<T> › put(String, int)`) |
| Split editors | **Implemented** |
| Tabs | **Implemented** — preview tabs, pin, tab history |
| Preview/editor modes | **Implemented** |

### Java Intelligence

| Capability | State |
|---|---|
| Syntax highlighting | **Implemented** — tree-sitter-java |
| Semantic highlighting | **Missing** |
| Completion | **Strong** — site classification, expected types, auto-import, classpath scoping |
| Parameter hints / signature help | **Partial** — arity-matching overload list |
| Go to definition | **Implemented** — sources, attached JAR sources, gated decompilation |
| Go to declaration | **Partial** — folded into definition provider |
| Go to implementation | **Implemented (basic)** — subtypes and overrides in project sources; scans every project class per request |
| Find usages | **Not available for Java** — the name-matching provider is disabled for `.java`; needs the reference index |
| Symbol search | **Partial** — palette class search via `JavaIndex` |
| Type / call hierarchy | **Missing** |
| Override navigation | **Partial** — `@Override` completion stubs only |
| Error diagnostics | **Partial** — `javac` per open file (idle, save, post-sync) plus Gradle build errors in Problems; no inspections |
| Quick fixes / code actions | **Partial** — import a class, remove unused imports |
| Rename / extract / inline / change signature | **Missing** |
| Import optimization | **Implemented** — removes unused, duplicate and redundant imports and sorts the rest (other, `javax`/`java`, static); no `*` collapsing |
| Type inference / generics | **Partial** — erased assignability; documented simplifications |
| Annotation awareness | **Partial** — completion at `@` sites |
| Javadoc | **Implemented** — hover and Quick Documentation (F1 / ⌃J), from sources, `src.zip` and `*-sources.jar` |
| Decompiled classes | **Implemented** — Fernflower, consent-gated |
| External library source nav | **Implemented** — `src.zip`, `*-sources.jar` |

### Project / Gradle

| Capability | State |
|---|---|
| Gradle discovery & sync | **Implemented** — trust gate, fingerprint cache, init script |
| Multi-module / source sets | **Implemented** |
| Compile classpath / dependencies | **Implemented** — `lenient(true)` resolution |
| Runtime classpath / `runtimeOnly` | **Model only** — synced per source set with output dirs; `runtimeClasspath(forFile:)` builds the `-cp` order; nothing launches with it yet |
| Generated sources / annotation processors | **Partial** |
| Java toolchains | **Partial** — language level only |
| Kotlin interoperability | **Missing** |
| Gradle tasks & console | **Implemented** |
| Dependency caching (shard stamps) | **Implemented** |

### Navigation, Refactoring, Build/Run/Test/Debug

| Area | State |
|---|---|
| File/class/symbol search, recent files, palette | **Implemented** |
| Module navigation | **Partial** — Gradle sidebar only |
| All semantic refactorings | **Missing** |
| Run configurations | **Partial** — last run per project, argument sheet, Run Last Configuration (⌃⌥R); no named or multiple configurations |
| Application / Gradle execution | **Partial** — terminal-injected commands, with saved program args, VM options and environment |
| Test discovery / JUnit / results | **Missing** |
| Debugging | **Missing** |

### Developer Experience

| Capability | State |
|---|---|
| Git (status, stage, commit, diff, history) | **Implemented** — no push/pull/branch UI |
| Terminal | **Implemented** |
| Problems panel | **Implemented** — bottom-panel tab, ⌘⇧M, status-bar counts |
| Build output | **Implemented** — Build Project runs through the Gradle console; compiler errors land in Problems |
| Background indexing & progress | **Implemented** |
| Command palette, keymaps, settings | **Implemented** |

---

## Major Gaps

1. **No inspections** — compiler errors (`javac`, Gradle builds) are listed, but there are no unresolved-symbol or style inspections beyond what `javac` reports.
2. **No semantic Find Usages** — the name-matching provider is switched off for Java, so Find Usages says it is unavailable rather than guessing.
3. **No Java refactoring** — rename/move/extract require a reference graph.
4. **No debugger or test runner** — run is terminal-injected commands only.
5. **Navigation depth** — go to implementation scans project classes per request; no type hierarchy, call hierarchy, or override markers.
6. **Import handling stops at sorting** — no `*` collapsing, and the layout is fixed rather than configurable.
7. **Run configurations are minimal** — last run per project with arguments; no named, multiple, or debug configurations.
8. **LSP unused** — formatting, semantic tokens, LSP diagnostics/rename exist in EditorIntelligence but Umbra connects none.

---

## Architectural Gaps

### Missing infrastructure (unlocks many features)

| Infrastructure | Current state | Unlocks |
|---|---|---|
| **Reference / usage index** | None | Find usages, safe rename, inline, move, call hierarchy |
| **Compiler or analysis frontend** | None | Diagnostics, quick fixes, compile errors |
| **Persistent cross-file semantic model** | Class stubs only | Refactoring, dataflow, inspections |
| **Incremental Java parse** | Whole-document tree-sitter per request | Completion latency at scale |
| **JPMS / module-path model** | ct.sym tags only | Java 9+ module projects |
| **Annotation processor pipeline** | Not modeled | Lombok, MapStruct, etc. |
| **Runtime classpath model** | Compile-only Gradle sync | Run/debug classpath accuracy |
| **Refactoring transaction engine** | EIP shell only | All semantic refactorings |

### Implemented but architecturally weak

| Area | Weakness |
|---|---|
| **Dual index** (`SymbolIndex` + `JavaIndex`) | Find references, breadcrumbs, rename use wrong index for Java |
| **`JavaIndex.rebuildIndexes()`** | Full rebuild on every overlay mutation — hot path for typing |
| **Whole-file reparse** for completion | No incremental tree |
| **Type system** | Erased names, simplified nested types, no generic method binding |
| **`FindReferencesProvider`** | `wordAtCursor` + exact symbol name — false positives/negatives |
| **File watching** | Java FSEvents separate from EIP `Workspace` watcher |

### Feature vs infrastructure

- **Missing feature:** Problems panel, debugger UI, run configurations.
- **Missing infrastructure:** Reference index + compiler integration — without these, Problems panel stays empty, rename stays unsafe, Find Usages stays broken regardless of UI work.

---

## Performance Risks

| Risk | Evidence | Scale impact |
|---|---|---|
| **Java index name-table rebuild** | `JavaIndex.updateOverlay` → `rebuildIndexes()` on every debounced edit (300ms) | Large dep graphs make overlay updates expensive |
| **Whole-document Java parse per completion** | `JavaSyntaxTree` one-shot; cached by text hash | Costly with rapid typing + large files |
| **JDK + JAR initial indexing** | `JavaIndexScheduler` — bounded concurrency, stamp skip | First open: minutes; mitigated by persistent shards |
| **Gradle sync** | Full `:umbraProjectModel` per sync | Hundreds of modules → slow sync |
| **Dual indexing** | `IndexingService` + `JavaOverlayService` both react | Redundant work per `.java` change |
| **Tree-sitter eager parse** | `TextViewState.prepare` parses entire document | Mitigated by piece-tree for display; Java layer still full-parse |

**Scales well today:** viewport rendering, persistent shard cache, parallel root indexing, lazy stub decode, generation tokens on project switch.

**Does not yet scale:** overlay-triggered full index rebuilds, no reference index, no incremental Java semantic analysis.

---

## Existing Strengths

**Reuse, don't replace:**

- **Penumbra text engine** — multi-cursor, piece-tree, viewport rendering, command palette.
- **EditorIntelligence provider pattern** — engines with primary-provider model; Java plugs in cleanly.
- **JavaIntelligence completion** — ~70–80% of IntelliJ completion value for everyday typing.
- **Gradle sync** — trust gate, fingerprint cache, per-source-set classpath scoping.
- **Persistent Java shard cache** — stamp-based skip, lazy decode, parallel scheduler.
- **Attached sources + decompiler** — practical library navigation with consent UX.
- **Umbra shell** — Gradle sidebar, Git panel, terminal, session restore, class search.
- **App Store–safe layering** — tooling in host app; core libraries sandbox-compatible.
- **Test coverage** — 30 JavaIntelligence test files (~300+ methods).

**Keep these architectural decisions:**

- JavaIntelligence independent of Penumbra.
- Stub index (not full PSI) as storage — extend, don't replace with LSP.
- Gradle init-script model extraction.
- Dual completion primary/fallback model.

---

## Incremental Implementation Roadmap

Features ordered in **difficulty chunks**. Complete each chunk (or individual items within it) before moving to the next. Items within a chunk are roughly ordered easiest-first.

---

### Chunk 1 — Low difficulty (UI wiring & small providers)

*No new foundational infrastructure. Mostly Umbra UI + thin JavaIntelligence providers using existing stubs/index.*

| # | Feature | Current state | Work required | Complexity | Unlocks |
|---|---|---|---|---|---|
| 1.1 | **Problems panel** ✅ done | Missing | AppKit list view; aggregate `DiagnosticEngine` results; click-to-navigate | Low | Error navigation UX |
| 1.2 | **Java hover + Javadoc** ✅ done | Missing | `JavaHoverProvider` reading stub Javadoc + attached sources | Low | API discovery |
| 1.3 | **Disable misleading Find References for Java** ✅ done | Weak | Skip `FindReferencesProvider` for `.java` until semantic provider exists | Low | Avoid false confidence |
| 1.4 | **Go to implementation (basic)** ✅ done | Missing | Walk `JavaClassStub` supertype/subtype lists; wire `NavigationProvider` for `.implementation` | Low | Interface → class nav |
| 1.5 | **Parse Gradle compile output → Problems** ✅ done | Partial | Regex `javac` output from existing Gradle console into diagnostics | Low | Build failure UX |
| 1.6 | **Run configuration persistence** ✅ done | Missing | Store last module/main/VM args in `IDESessionStore` | Low | Repeatable launch |
| 1.7 | **Wire code actions menu (LSP optional)** ✅ done | Partial | Connect existing `CodeActionView` in Umbra; optional external formatter LSP | Low | Quick-fix shell |
| 1.8 | **Breadcrumb type labels** ✅ done | Partial | Prefer Java qualified names from overlay stubs where available | Low | Better context |

**Chunk exit criteria:** User can see diagnostics in a list, hover for Javadoc, navigate interface→impl, and relaunch last run config.

---

### Chunk 2 — Low–medium difficulty (performance fixes & compiler diagnostics)

*Prerequisite work for everything semantic. Fixes hot-path performance and establishes the analysis pipeline.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 2.1 | **Incremental overlay index rebuild** ✅ done | Weak | Delta-update `JavaIndex` name table on overlay change; don't scan entire classpath | Low–Medium | None |
| 2.2 | **Java diagnostic provider (`javac`)** ✅ done | Missing | `JavaDiagnosticProvider`: invoke `javac` with synced classpath; map to `Diagnostic` | Medium | Gradle sync |
| 2.3 | **Idle analysis with cancellation** ✅ done | Missing | Debounced post-edit analysis; cancel superseded runs; respect `Task.isCancelled` | Medium | 2.2 |
| 2.4 | **Trigger analysis on save / post-sync** ✅ done | Missing | Wire save handler + Gradle sync completion to refresh diagnostics | Low | 2.2, 1.1 |
| 2.5 | **Import cleanup on save (basic)** ✅ done | Missing | Remove unused imports via existing `JavaTypeResolver` + import AST | Medium | 2.2 (or resolver only) |
| 2.6 | **Route Java navigation exclusively through JavaIntelligence** ✅ done | Weak | Ensure `.definition`/`.implementation` never fall through to generic `GoToDefinitionProvider` for `.java` | Low | 1.4 |

**Chunk exit criteria:** Red squiggles from real compiler errors; Problems panel populated; typing stays responsive on large classpaths.

---

### Chunk 3 — Medium difficulty (core IDE polish)

*Builds on compiler diagnostics and existing index. Substantial daily-use improvements.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 3.1 | **Java formatter** ✅ done | Missing | Wire Google/Eclipse formatter via CLI subprocess, or optional LSP formatting provider | Medium | None |
| 3.2 | **Import optimization** ✅ done | Missing | Organize imports, remove unused, static import ordering | Medium | 2.2 or resolver |
| 3.3 | **Go to implementation (full)** | Partial | Handle generics, abstract classes, multiple implementations picker | Medium | 1.4 |
| 3.4 | **Type hierarchy (basic)** | Missing | Supertype/subtype tree panel from stub inheritance | Medium | JavaIndex |
| 3.5 | **Runtime classpath in Gradle model** ✅ done | Missing | Extend init script for `runtimeClasspath`; expose in model | Medium | Gradle sync |
| 3.6 | **Run configurations UI** | Missing | `RunConfiguration` model: main class, module, VM args, env; persist + execute | Medium | 3.5, 1.6 |
| 3.7 | **Semantic highlighting (optional)** | Missing | Wire LSP semantic tokens or stub-based kind coloring | Medium | Optional LSP |
| 3.8 | **Inlay hints (parameter names)** | Missing | Render parameter names at call sites from stub signatures | Medium | JavaIndex |

**Chunk exit criteria:** Formatted code, organized imports, type hierarchy view, saved run configs with correct runtime classpath.

---

### Chunk 4 — Medium–high difficulty (semantic navigation & rename)

*Requires reference index — the first major infrastructure investment beyond class stubs.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 4.1 | **Reference index (design + storage)** | Missing | Persistent shard format for symbol→usage mappings; build from parse pass | High | Chunk 2 analysis |
| 4.2 | **Reference index (build pipeline)** | Missing | Background indexer: scan sources, record references per classpath scope | High | 4.1 |
| 4.3 | **Semantic Find Usages** | Missing | `JavaFindReferencesProvider` on reference index | High | 4.2 |
| 4.4 | **Safe rename (classes)** | Missing | `JavaRenameOperation`: preview, reference rewrite, import updates | High | 4.2 |
| 4.5 | **Safe rename (methods/fields)** | Missing | Extend rename to members with overload disambiguation | High | 4.4 |
| 4.6 | **Override / super method navigation** | Missing | Walk inheritance for `@Override` targets | Medium | JavaIndex |
| 4.7 | **Annotation processor / generated sources** | Missing | Extend Gradle model for processor output dirs; index as source roots | High | Gradle sync |

**Chunk exit criteria:** Find Usages returns type-accurate results; rename class/method/field safely across project.

---

### Chunk 5 — High difficulty (test & build integration)

*Host-app features using Gradle runner infrastructure already in place.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 5.1 | **JUnit test discovery** | Missing | Parse test sources / Gradle `test` task output for test classes | High | Gradle sync |
| 5.2 | **Test runner + results panel** | Missing | Run `:test`, parse XML/text output, results tree with pass/fail/navigate | High | 5.1, 1.1 |
| 5.3 | **Test gutter icons** | Missing | Run/debug single test from editor gutter | High | 5.1 |
| 5.4 | **Gradle build problem integration** | Partial | Structured problem matcher for all Gradle tasks → Problems panel | Medium | 1.1, 2.2 |
| 5.5 | **Incremental Gradle sync** | Missing | Diff model changes instead of full re-index on every sync | High | Gradle sync |

**Chunk exit criteria:** Run tests from IDE, see results, navigate to failures.

---

### Chunk 6 — High difficulty (refactoring engine)

*Requires reference index + method-body AST manipulation.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 6.1 | **Refactoring transaction framework** | Missing | Preview diff, multi-file edit application, undo grouping in JavaIntelligence | High | 4.2 |
| 6.2 | **Extract variable** | Missing | Analyze selection expression, introduce local with correct type | High | 6.1 |
| 6.3 | **Extract method** | Missing | Pull selection into new method, update call sites | Very High | 6.1, 4.2 |
| 6.4 | **Extract constant / field** | Missing | Promote expression to constant or field | High | 6.1 |
| 6.5 | **Inline variable / method** | Missing | Replace usages with body; remove declaration | Very High | 4.2 |
| 6.6 | **Change signature** | Missing | Alter method params/return; update all call sites | Very High | 4.2, 6.1 |
| 6.7 | **Move class / safe delete** | Missing | Move file + update references; delete with usage check | High | 4.2, 6.1 |
| 6.8 | **Encapsulate fields / generate getters** | Missing | Refactor field access to accessor methods | Medium | 6.1 |

**Chunk exit criteria:** Core refactoring menu (extract, inline, change signature, move) works safely with preview.

---

### Chunk 7 — Very high difficulty (debugger & advanced analysis)

*Largest architectural investments. Defer until Chunks 1–5 deliver daily IDE value.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 7.1 | **JDWP debugger adapter** | Missing | Breakpoint model, attach to JVM, session management in Umbra | Very High | 3.5, 3.6 |
| 7.2 | **Breakpoints & conditional breakpoints** | Missing | Editor gutter, condition evaluation | Very High | 7.1 |
| 7.3 | **Variables / call stack / watches** | Missing | Debug tool window panels | Very High | 7.1 |
| 7.4 | **Call hierarchy** | Missing | Call graph index (bytecode or AST) | Very High | 4.2 |
| 7.5 | **Inspections & quick fixes** | Missing | Rule engine on semantic model; intention actions | Very High | 2.2, 4.2 |
| 7.6 | **JPMS / module-path support** | Missing | `module-info.java` index + module resolution | High | Gradle model |
| 7.7 | **Kotlin interoperability** | Missing | Kotlin indexer or LSP for mixed projects | Very High | Optional LSP |
| 7.8 | **Incremental Java parse** | Missing | Tree-sitter incremental edits for completion hot path | High | JavaSyntaxTree |

**Chunk exit criteria:** Debug Java apps with breakpoints; call hierarchy; basic inspections.

---

### Chunk 8 — Differentiators (native macOS advantages)

*Can be pursued in parallel with any chunk. Low competition with IntelliJ.*

| # | Feature | Notes | Complexity |
|---|---|---|---|
| 8.1 | **Large-file editing performance** | Market Penumbra piece-tree + viewport rendering | Low (existing) |
| 8.2 | **Lightweight Gradle sync** | Trust-gated, no import wizard — already implemented | Low (existing) |
| 8.3 | **Native Git panel** | Fast diff, lane graph — extend with branch/push | Medium |
| 8.4 | **Integrated HTTP client** | Already in Umbra bottom panel | Low (existing) |
| 8.5 | **Sandbox-safe architecture** | App Store distribution vs IntelliJ filesystem access | Low (existing) |
| 8.6 | **Palette-first UX** | Search Everywhere + minimal chrome | Low (existing) |
| 8.7 | **Session restore** | Layout, tabs, terminals — already implemented | Low (existing) |

---

## Recommended Architecture

Keep the three-library split (Penumbra / EditorIntelligence / JavaIntelligence). Do not replace Penumbra or EditorIntelligence.

```
┌─────────────────────────────────────────────────────────────┐
│  Umbra (shell, Gradle/Git/terminal, Problems, Run/Debug UI) │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  EditorIntelligence — engines, Workspace, palette, LSP hooks   │
└──────────────────────────┬──────────────────────────────────┘
                           │ EditorAdapter / provider protocols
┌──────────────────────────▼──────────────────────────────────┐
│  JavaIntelligence 2.0                                        │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐ │
│  │ JavaIndex    │  │ JavaAnalysis │  │ JavaReferenceIndex  │ │
│  │ (stubs)      │  │ (javac/ECJ)  │  │ (usages, calls)     │ │
│  └──────┬──────┘  └──────┬───────┘  └──────────┬──────────┘ │
│         └────────────────┼─────────────────────┘            │
│                          ▼                                   │
│              Providers: Completion, Navigation, Diagnostics, │
│              Hover, Rename, Refactoring, SignatureHelp       │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  Gradle sync model — compile + runtime + generated + processor │
│  outputs; incremental model diff; toolchain provisioning     │
└──────────────────────────────────────────────────────────────┘
```

**Key decisions:**

1. **Diagnostics via compiler, not tree-sitter** — invoke `javac` with classpath from sync model.
2. **Reference index as second persistent shard family** — separate from class-name index.
3. **Route all Java navigation/refactor through JavaIntelligence** — stop using `SymbolIndex` for `.java`.
4. **Incremental overlay updates** — delta-update `JavaIndex` name table.
5. **LSP as optional accelerator** — Java stays native for App Store safety and performance control.
6. **Debugger as Umbra host feature** — JDWP outside Penumbra library.

---

## Suggested Next Step

Chunks 1 and 2 are complete. The next foundational investment is **Chunk 4** (reference index + semantic Find Usages + rename), which also replaces the per-request project scan behind Go to Implementation with an index.

The cheaper **Chunk 3** items (formatter 3.1, import sorting 3.2, runtime classpath 3.5) are done. Left in Chunk 3: full go to implementation (3.3), type hierarchy (3.4), a run configurations UI over the runtime classpath (3.6), semantic highlighting (3.7) and parameter-name inlay hints (3.8).

---

## Key Source Files

| Area | Path |
|---|---|
| Java orchestration (Umbra) | `Example/Umbra/IDEJavaSupport.swift` |
| EIP wiring (Umbra) | `Example/Umbra/IDEIntelligenceServices.swift` |
| Java completion | `Sources/JavaIntelligence/Completion/JavaCompletionProvider.swift` |
| Java navigation | `Sources/JavaIntelligence/Navigation/JavaGoToDefinitionProvider.swift` |
| Java index | `Sources/JavaIntelligence/Index/JavaIndex.swift` |
| Index scheduler | `Sources/JavaIntelligence/Scanning/JavaIndexScheduler.swift` |
| Gradle sync | `Sources/JavaIntelligence/Gradle/` |
| Generic find references (weak for Java) | `Sources/EditorIntelligence/Navigation/FindReferencesProvider.swift` |
| Diagnostic engine | `Sources/EditorIntelligence/Diagnostics/DiagnosticEngine.swift` |
| Editor orchestration | `Sources/Penumbra/EditorIntelligenceAdapter/EditorIntelligenceController.swift` |

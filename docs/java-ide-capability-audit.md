# Java IDE Capability Audit

> Gap analysis for bringing Umbra's Java development experience closer to IntelliJ IDEA.
> Based on repository inspection (Penumbra, EditorIntelligence, JavaIntelligence, Packages/GitIntelligence, Example/Umbra).
> Last updated: 2026-09-24 (Chunk 8).

---

## Executive Summary

Umbra + Penumbra + JavaIntelligence form a **credible lightweight Java editor**, not yet a professional IntelliJ-class IDE. The stack is strongest where it was deliberately invested: **native text editing**, **EditorIntelligence provider architecture**, and **Java completion/navigation on a cached class-stub index with Gradle classpath sync**.

| Layer | Maturity | Notes |
|---|---|---|
| Text engine (Penumbra) | **High** | Multi-cursor, folding, palette, workbench — production-grade |
| IDE platform (EditorIntelligence) | **High (generic)** | Engines/protocols exist; LSP adapters unused in Umbra |
| Java intelligence (JavaIntelligence) | **Medium** | Strong completion; weak diagnostics/refactoring/navigation depth |
| IDE shell (Umbra) | **Medium–High** | Gradle, terminal, Problems, run configs, test runner, minimal debugger, in-app `.http` client |
| Git (GitIntelligence package) | **Medium** | Status, stage, commit, diff, history, lane graph, local branch switch, push, fast-forward pull |

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
| Inlay hints | **Partial** — parameter-name hints (off by default); nothing for JAR/JDK calls, no scroll refresh |
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
| Semantic highlighting | **Implemented** — scope-aware token classification on the tree-sitter tree, painted over syntax colours; inherited members left uncoloured |
| Completion | **Strong** — site classification, expected types, auto-import, classpath scoping |
| Parameter hints / signature help | **Partial** — arity-matching overload list |
| Go to definition | **Implemented** — sources, attached JAR sources, gated decompilation |
| Go to declaration | **Partial** — folded into definition provider |
| Go to implementation | **Implemented** — subtypes and overrides (generic overrides, anonymous classes, enum constant bodies) in project sources; scans project classes per request, no persistent index |
| Find usages | **Implemented** — identifier index plus on-demand resolution (`JavaFindUsagesProvider`), override families for methods, Usages tab; ambiguous overload/receiver cases are flagged, anonymous-class members are not covered |
| Symbol search | **Partial** — palette class search via `JavaIndex` |
| Type / call hierarchy | **Partial** — type hierarchy implemented (⌃H); call hierarchy MVP (⌃⌥H, callers via find-usages, callees via method-body walk) |
| Override navigation | **Implemented** — Go to Super Method (⌘U in the IntelliJ keymap) for methods and types; no gutter override markers |
| Error diagnostics | **Partial** — `javac` plus Gradle build errors; inspection engine (unused/duplicate/unresolved import, missing `@Override`, unresolved type, class/file name mismatch) |
| Quick fixes / code actions | **Partial** — import a class, remove unused imports, add `@Override`, optimize imports |
| Rename | **Implemented** — types (imports, Javadoc, file rename), locals, parameters, methods (whole override family), fields, enum constants, record components; preview with ambiguous/read-only entries; blocked for library and generated declarations |
| Extract / inline / change signature | **Implemented** — extract variable/method/field/constant, inline variable/method, change signature, move class, safe delete, encapsulate field (preview + multi-file edits) |
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
| Runtime classpath / `runtimeOnly` | **Implemented** — synced per source set with output dirs; `runtimeClasspath(forFile:)` builds the `-cp` order used by the classpath run target |
| Generated sources / annotation processors | **Implemented (indexing)** — generated source dirs indexed as read-only roots, Lombok taken from `annotationProcessor` jars; other processors are not run |
| Java toolchains | **Partial** — language level only |
| Kotlin interoperability | **Missing** |
| Gradle tasks & console | **Implemented** |
| Dependency caching (shard stamps) | **Implemented** |

### Navigation, Refactoring, Build/Run/Test/Debug

| Area | State |
|---|---|
| File/class/symbol search, recent files, palette | **Implemented** |
| Module navigation | **Partial** — Gradle sidebar only |
| Semantic refactorings | **Partial** — rename plus extract, inline, change signature, move, safe delete, encapsulate |
| Run configurations | **Implemented** — named/multiple configurations, toolbar picker, Gradle run / single file / class with runtime classpath; debug mode for classpath-main launches |
| Application / Gradle execution | **Partial** — terminal-injected commands for run; managed JDWP debug session for classpath-main targets |
| Test discovery / JUnit / results | **Implemented** — JUnit 4/5 discovery, `:test` runner, results tree, gutter run icons |
| Debugging | **Partial** — classpath-main managed launch + Gradle `run --debug-jvm` attach; no conditional breakpoints, watches, or attach-to-running-process |

### Developer Experience

| Capability | State |
|---|---|
| Git (status, stage, commit, diff, history, branch, push, pull) | **Implemented** — local branch switch and create, push, fast-forward pull (`--ff-only`). No force-push, merge, or remote-branch checkout |
| Terminal | **Implemented** |
| Problems panel | **Implemented** — bottom-panel tab, ⌘⇧M, status-bar counts |
| Build output | **Implemented** — Build Project runs through the Gradle console; compiler errors land in Problems |
| Background indexing & progress | **Implemented** |
| Command palette, keymaps, settings | **Implemented** |

---

## Major Gaps

1. **Inspections are file-local** — six rules with quick fixes; no project-wide unused-private-member analysis or style rule packs yet.
2. **Find Usages resolution gaps** — usages are resolved on demand over an identifier index, so members of anonymous classes are not covered and unresolvable overloads or untyped receivers are shown as ambiguous.
3. **Refactoring coverage** — core extract/inline/change-signature/move/delete/encapsulate exist; no introduce parameter, pull up/push down, or migration refactorings.
4. **Debugger gaps** — Gradle debug uses fixed port 5005 (`--debug-jvm`); no conditional breakpoints, watches, test gutter debug, or attach-to-process.
5. **Navigation depth** — go to implementation and type/call hierarchy scan or resolve on demand (no persistent call graph); no override gutter markers.
6. **Import handling stops at sorting** — no `*` collapsing, and the layout is fixed rather than configurable.
7. **LSP unused** — formatting, semantic tokens, LSP diagnostics/rename exist in EditorIntelligence but Umbra connects none.

---

## Architectural Gaps

### Missing infrastructure (unlocks many features)

| Infrastructure | Current state | Unlocks |
|---|---|---|
| **Reference / usage index** | Identifier index (`refs.idx`) with on-demand verification; call hierarchy reuses usage search + AST walk | Find usages done; inline/move done; persistent call graph still missing |
| **Compiler or analysis frontend** | `javac` subprocess for open files; three static inspections | Diagnostics + basic quick fixes; not a full analyzer |
| **Persistent cross-file semantic model** | Class stubs only | Refactoring, dataflow, inspections |
| Incremental Java parse | **Partial** — `JavaDocumentParseCache` for overlay + inspections via `ts_tree_edit`; completion still full-parses repaired text |
| **JPMS / module-path model** | ct.sym tags only | Java 9+ module projects |
| **Annotation processor pipeline** | Not modeled | Lombok, MapStruct, etc. |
| **Runtime classpath model** | Compile-only Gradle sync | Run/debug classpath accuracy |
| **Refactoring transaction engine** | JavaIntelligence preview + multi-file edits | Core refactorings implemented; advanced migrations still missing |

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

- **Missing feature:** Conditional breakpoints, watches, attach debug, full inspection rule set, incremental Gradle sync.
- **Missing infrastructure:** Persistent call graph + full semantic model — call hierarchy and some callees resolve on demand only.

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
| 3.3 | **Go to implementation (full)** ✅ done | Partial | Handle generics, abstract classes, multiple implementations picker | Medium | 1.4 |
| 3.4 | **Type hierarchy (basic)** ✅ done | Missing | Supertype/subtype tree panel from stub inheritance | Medium | JavaIndex |
| 3.5 | **Runtime classpath in Gradle model** ✅ done | Missing | Extend init script for `runtimeClasspath`; expose in model | Medium | Gradle sync |
| 3.6 | **Run configurations UI** ✅ done | Missing | `RunConfiguration` model: main class, module, VM args, env; persist + execute | Medium | 3.5, 1.6 |
| 3.7 | **Semantic highlighting (optional)** ✅ done | Missing | Wire LSP semantic tokens or stub-based kind coloring | Medium | Optional LSP |
| 3.8 | **Inlay hints (parameter names)** ✅ done | Missing | Render parameter names at call sites from stub signatures | Medium | JavaIndex |

**Chunk exit criteria:** Formatted code, organized imports, type hierarchy view, saved run configs with correct runtime classpath.

---

### Chunk 4 — Medium–high difficulty (semantic navigation & rename)

*Requires reference index — the first major infrastructure investment beyond class stubs.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 4.1 | **Reference index (design + storage)** ✅ done | Missing | Persistent shard format for symbol→usage mappings; build from parse pass | High | Chunk 2 analysis |
| 4.2 | **Reference index (build pipeline)** ✅ done | Missing | Background indexer: scan sources, record references per classpath scope | High | 4.1 |
| 4.3 | **Semantic Find Usages** ✅ done | Missing | `JavaFindReferencesProvider` on reference index | High | 4.2 |
| 4.4 | **Safe rename (classes)** ✅ done | Missing | `JavaRenameOperation`: preview, reference rewrite, import updates | High | 4.2 |
| 4.5 | **Safe rename (methods/fields)** ✅ done | Missing | Extend rename to members with overload disambiguation | High | 4.4 |
| 4.6 | **Override / super method navigation** ✅ done | Missing | Walk inheritance for `@Override` targets | Medium | JavaIndex |
| 4.7 | **Annotation processor / generated sources** ✅ done | Missing | Extend Gradle model for processor output dirs; index as source roots | High | Gradle sync |

**Chunk exit criteria:** Find Usages returns type-accurate results; rename class/method/field safely across project.

---

### Chunk 5 — High difficulty (test & build integration)

*Host-app features using Gradle runner infrastructure already in place.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 5.1 | **JUnit test discovery** | ✅ done | Parse test sources / Gradle `test` task output for test classes | High | Gradle sync |
| 5.2 | **Test runner + results panel** | ✅ done | Run `:test`, parse XML/text output, results tree with pass/fail/navigate | High | 5.1, 1.1 |
| 5.3 | **Test gutter icons** | ✅ done | Run single test from editor gutter | High | 5.1 |
| 5.4 | **Gradle build problem integration** | ✅ done | Structured problem matcher for all Gradle tasks → Problems panel | Medium | 1.1, 2.2 |
| 5.5 | **Incremental Gradle sync** | Missing | Diff model changes instead of full re-index on every sync | High | Gradle sync |

**Chunk exit criteria:** Run tests from IDE, see results, navigate to failures.

---

### Chunk 6 — High difficulty (refactoring engine)

*Requires reference index + method-body AST manipulation.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 6.1 | **Refactoring transaction framework** | ✅ done | Preview diff, multi-file edit application, undo grouping in JavaIntelligence | High | 4.2 |
| 6.2 | **Extract variable** | ✅ done | Analyze selection expression, introduce local with correct type | High | 6.1 |
| 6.3 | **Extract method** | ✅ done | Pull selection into new method, update call sites | Very High | 6.1, 4.2 |
| 6.4 | **Extract constant / field** | ✅ done | Promote expression to constant or field | High | 6.1 |
| 6.5 | **Inline variable / method** | ✅ done | Replace usages with body; remove declaration | Very High | 4.2 |
| 6.6 | **Change signature** | ✅ done | Alter method params/return; update all call sites | Very High | 4.2, 6.1 |
| 6.7 | **Move class / safe delete** | ✅ done | Move file + update references; delete with usage check | High | 4.2, 6.1 |
| 6.8 | **Encapsulate fields / generate getters** | ✅ done | Refactor field access to accessor methods | Medium | 6.1 |

**Chunk exit criteria:** Core refactoring menu (extract, inline, change signature, move) works safely with preview.

---

### Chunk 7 — Very high difficulty (debugger & advanced analysis)

*Largest architectural investments. Defer until Chunks 1–5 deliver daily IDE value.*

| # | Feature | Current state | Work required | Complexity | Dependencies |
|---|---|---|---|---|---|
| 7.1 | **JDWP debugger adapter** | **Partial** | JDI adapter + classpath-main launch + Gradle `--debug-jvm` attach | Very High | 3.5, 3.6 |
| 7.2 | **Breakpoints & conditional breakpoints** | **Partial (MVP)** | Gutter breakpoints + persistence; no conditions | Very High | 7.1 |
| 7.3 | **Variables / call stack / watches** | **Partial (MVP)** | Debug panel: stack + locals; no watches | Very High | 7.1 |
| 7.4 | **Call hierarchy** | **Partial (MVP)** | Callers via find-usages; callees via AST method_invocation walk | Very High | 4.2 |
| 7.5 | **Inspections & quick fixes** | **Partial** | Rule registry with six file-local rules + shared parse context | Very High | 2.2, 4.2 |
| 7.8 | **Incremental Java parse** | **Partial** | `JavaDocumentParseCache` with `ts_tree_edit` for overlay + inspections | High | JavaSyntaxTree |
| 7.6 | **JPMS / module-path support** | Missing | `module-info.java` index + module resolution | High | Gradle model |
| 7.7 | **Kotlin interoperability** | Missing | Kotlin indexer or LSP for mixed projects | Very High | Optional LSP |
| 7.8 | **Incremental Java parse** | Missing | Tree-sitter incremental edits for completion hot path | High | JavaSyntaxTree |

**Chunk 7 MVP notes:** Gradle debug uses `--debug-jvm` on port 5005. Incremental parse covers overlay and inspections (completion still full-parses repaired caret text). Deferred: conditional breakpoints, watches, attach-to-process, JPMS, Kotlin.

**Chunk exit criteria:** Debug Java apps with breakpoints; call hierarchy; basic inspections.

---

### Chunk 8 — Differentiators (native macOS advantages)

*Can be pursued in parallel with any chunk. Low competition with IntelliJ.*

| # | Feature | Notes | Complexity |
|---|---|---|---|
| 8.1 | **Large-file editing performance** ✅ done | Penumbra piece-tree + viewport rendering | Low (existing) |
| 8.2 | **Lightweight Gradle sync** ✅ done | Trust-gated, no import wizard | Low (existing) |
| 8.3 | **Native Git panel** ✅ done | Branch menu (switch and create), push, and fast-forward pull in the Changes tab. `Packages/GitIntelligence` via `IDEGitStatus` | Medium |
| 8.4 | **Integrated HTTP client** ✅ done | In the Umbra target (`Example/Umbra/HTTP/`), shown in the bottom panel. Not a library and not part of JavaIntelligence | Low (existing) |
| 8.5 | **Sandbox-safe architecture** ✅ done | App Store distribution vs IntelliJ filesystem access | Low (existing) |
| 8.6 | **Palette-first UX** ✅ done | Search Everywhere + minimal chrome | Low (existing) |
| 8.7 | **Session restore** ✅ done | Layout, tabs, terminals | Low (existing) |

**Chunk 8 notes:** Switch and pull are refused while an editor in the repository has unsaved changes; clean buffers are then reloaded from disk. Pull is `git pull --ff-only`. Deferred: force-push, merge, rebase, delete/rename, and remote-tracking checkout.

**Chunk exit criteria:** User can create and switch local branches, push, and fast-forward pull from Source Control, with git's errors shown in the panel.

---

## Recommended Architecture

Keep Penumbra, EditorIntelligence, and JavaIntelligence in the root package. Do not replace Penumbra or EditorIntelligence. JavaIntelligence does not parse `.http` files or talk to git.

The `.http` parser and `URLSession` send live in the Umbra executable (`Example/Umbra/HTTP/`). Git is a separate package, `Packages/GitIntelligence`, with no dependencies. It cannot move into JavaIntelligence, and JavaIntelligence cannot become its own package without a cycle: it depends on `EditorIntelligence` and the Tree-sitter targets inside the root package.

```
┌─────────────────────────────────────────────────────────────┐
│  Umbra (shell, Gradle/terminal, Problems, Run/Debug, .http) │
│  Example/Umbra/HTTP/  — request parse + URLSession send     │
└────────────┬───────────────────────────────┬────────────────┘
             │                               │
┌────────────▼──────────────┐  ┌─────────────▼─────────────────┐
│ GitIntelligence package   │  │ EditorIntelligence            │
│ branch, push, pull, log,  │  │ engines, Workspace, palette,  │
│ GitGraphLayout            │  │ LSP hooks                     │
└───────────────────────────┘  └──────────────┬────────────────┘
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

Chunks 1–7 are largely complete, and chunk 8 is done. Remaining high-value work: conditional breakpoints, watches, attach-to-process, custom Gradle debug ports, project-wide inspections, 5.5 incremental Gradle sync, 7.6 JPMS, and completion-path incremental parse.

---

## Key Source Files

| Area | Path |
|---|---|
| HTTP client (Umbra) | `Example/Umbra/HTTP/` (`HTTPRequestParser`, `HTTPClient`), `IDEHTTPSupport.swift` |
| Git package | `Packages/GitIntelligence/` (`GitRepository`, `GitGraphLayout`) |
| Git panel (Umbra) | `Example/Umbra/IDEGitStatus.swift` |
| Java orchestration (Umbra) | `Example/Umbra/IDEJavaSupport.swift` |
| EIP wiring (Umbra) | `Example/Umbra/IDEIntelligenceServices.swift` |
| Java completion | `Sources/JavaIntelligence/Completion/JavaCompletionProvider.swift` |
| Java navigation | `Sources/JavaIntelligence/Navigation/JavaGoToDefinitionProvider.swift` |
| Java index | `Sources/JavaIntelligence/Index/JavaIndex.swift` |
| Index scheduler | `Sources/JavaIntelligence/Scanning/JavaIndexScheduler.swift` |
| Java call hierarchy | `Sources/JavaIntelligence/Hierarchy/JavaCallHierarchy.swift` |
| Java inspections | `Sources/JavaIntelligence/Inspections/` |
| Debug session (Umbra) | `Example/Umbra/JavaDebugSession.swift` |
| JDI adapter JAR | `Example/Umbra/Tools/JavaDebugAdapter/` |
| Gradle sync | `Sources/JavaIntelligence/Gradle/` |
| Generic find references (weak for Java) | `Sources/EditorIntelligence/Navigation/FindReferencesProvider.swift` |
| Diagnostic engine | `Sources/EditorIntelligence/Diagnostics/DiagnosticEngine.swift` |
| Editor orchestration | `Sources/Penumbra/EditorIntelligenceAdapter/EditorIntelligenceController.swift` |

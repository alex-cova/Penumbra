# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Penumbra is a Swift Package Manager library: a high-performance plain text/code editor engine for **macOS** (AppKit), forked from simonbs/Runestone (originally iOS/UIKit) and ported natively to macOS. It combines two layers:

- **`Penumbra`** — the text rendering/editing engine itself (line layout, gutter, tree-sitter syntax highlighting, selection, undo, search & replace).
- **`EditorIntelligence`** — a separate, editor-agnostic IDE-intelligence platform (completion, indexing, hover, navigation, diagnostics, refactoring, LSP/AI adapters) that has **no dependency on `Penumbra`**. The two are connected only through `Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`.
- **`JavaIntelligence`** — native Java indexing and completion (JDK discovery, source and JAR stubs, type resolution, completion) with **no dependency on `Penumbra`**. Umbra wires it through `Example/Umbra/IDEJavaSupport.swift`. Completion (`Sources/JavaIntelligence/Completion/`) parses with a dummy identifier at the caret (`JavaCompletionProvider.dummyIdentifier`), types lambdas and method references through the target parameter's functional interface, resolves source members against their declaring file's imports, classifies the site (`JavaCompletionContextClassifier`: member access, `::`, import/package, `@`, `new`, type-only, `case`, class body, statement), ranks by expected type (`JavaExpectedType`, `JavaAssignability`), auto-imports classes (`JavaImportInserter`), offers `@Override` stubs in class bodies, and doubles as parameter info (`JavaSignatureHelp.swift`). For a Gradle project, a trusted sync (`GradleCommandRunner` plus an init script) replaces the whole-folder `.java` walk with per-module source sets and resolved dependency JARs. Go to Definition (`Sources/JavaIntelligence/Navigation/`) resolves into attached sources when present (a JDK `lib/src.zip` or a dependency's adjacent `*-sources.jar`, via `JavaAttachedSources`) and otherwise falls back to decompiling the `.class` file with [Sunflower](https://github.com/alex-cova/sunflower) (`FernflowerKit`, `JavaClassDecompiler`) — gated by a one-time user agreement (`JavaDecompilerAgreement`) that only a manual navigation (never Cmd-hover) can trigger, via `JavaGoToDefinitionProvider.setDecompilerConsent(accepted:request:)`. Compiler diagnostics (`Sources/JavaIntelligence/Diagnostics/`): `JavaCompilerDiagnosticsService` is a `DiagnosticProvider` that runs the JDK's `javac` (`JDKInstallation.javac`) over the editor's text — `JavacInvocationBuilder` builds the command (Gradle source-set classpath/sourcepath, `--release` capped at the JDK, `-proc:none` except a project's own Lombok jar; a plain folder infers its package root), `JavacOutputParser` parses stderr — and returns the last result while a debounced (600 ms idle), cancellable, 2-at-a-time compile runs, pushing finished results through `setResultHandler`. It stays off until Umbra configures it (`IDEJavaSupport.refreshCompilerDiagnostics()`: a plain folder, or a Gradle project that has synced; the `javaCompilerDiagnostics` preference), and `compileNow(_:force:)` backs the recheck after save and after sync. Go to Implementation (`JavaGoToImplementation`) lists the project classes that extend or implement a type, or override a method (a scan of `JavaIndex.projectClassStubs()`, scoped to the file's Gradle source set). Hover (`Sources/JavaIntelligence/Hover/`): `JavaHoverProvider` shows the declaration (`JavaSignatureText`) and Javadoc (`JavadocMarkdown`) of the symbol at the caret, from source stubs or from an attached `src.zip` / `*-sources.jar` (never decompiled); a resting caret (`.idle`) only pops up when there is documentation, an explicit request (`.manual`) always does. `JavaCodeActionProvider` offers "Import `a.b.X`" for a `cannot find symbol … class X` error on the caret's line and a remove-unused-imports action (`JavaUnusedImports`, conservative: syntax errors yield no edits, Javadoc references keep their imports, `*` imports stay). `JavaBreadcrumbProvider` labels the caret's enclosing declarations (`Outer<T> › put(String, int)`). `JavacDiagnosticsMapper` turns a whole Gradle build's `javac` output into diagnostics per file, and `JavaRunConfiguration` / `JavaRunConfigurationStore` (`Sources/JavaIntelligence/Launch/`) hold the last launch (program arguments, VM options for single-file runs, environment) per project. `JavaFormatter` (`Sources/JavaIntelligence/Formatting/`) is a whitespace-only formatter over the tree-sitter tree — indentation (blocks, `case` labels, brace-less bodies, two-level continuation), spacing between tokens, trailing spaces, blank-line runs; it never joins, splits or moves lines, refuses a file that doesn't parse cleanly and any result whose non-whitespace changed. `JavaFormattingProvider` wraps it as a `FormattingProviding` (whole file, or only the selected lines with every line break kept), and `JavaFormatEdits` turns the result into minimal per-line edits so carets stay put. `JavaImportOrganizer` sorts and prunes imports (other, `javax`/`java`, static; a comment inside the block limits it to removal). The Gradle model (format version 4) records each source set's runtime jars, runtime project dependencies and output directories; `JavaGradleProjectModel.runtimeClasspath(forFile:)` returns them in `java -cp` order (used by the classpath run target). Go to Implementation also finds generic overrides (`compareTo(Foo)` for `Comparable<T>`), anonymous classes and enum constant bodies, and labels/sorts its picker results. `JavaTypeHierarchyProvider` (`Sources/JavaIntelligence/Hierarchy/`) builds the supertype tree (superclass, then interfaces, cycle-safe) and lazily expanded project subtypes; Umbra shows it in the Hierarchy bottom-panel tab (`EditorActionID.typeHierarchy`, ⌃H in the IntelliJ keymap, `EditorIntelligenceController.onRequestTypeHierarchy`). `JavaSemanticTokenProvider` (`Sources/JavaIntelligence/Semantic/`) classifies identifiers (types by kind, methods, fields, enum constants, parameters, locals; locals shadow fields) in one scope-aware pass, and `TextView.setSemanticHighlights(_:)` (`SemanticHighlightStore`) paints them over the tree-sitter colours, colour only, following edits until the next set (Umbra: `semanticHighlighting` preference, on by default). `JavaInlayHintProvider` (`Sources/JavaIntelligence/Inlay/`) produces parameter-name hints for calls that bind to exactly one method; `TextView.inlayHints` (`InlayHint`) renders them by widening the preceding character, so they are display-only (Umbra: `javaInlayHints`, off by default; hints refresh after edits, not on scroll). `JavaRunConfiguration` is now named and kept in a per-project list with a selected entry (`JavaRunConfigurationStore`, old files still load); a `.classpathMain` target launches `java -cp <runtime classpath> pkg.Main`, building the module's `classes` task first when its outputs are missing, and Umbra shows a run configuration picker in the toolbar. References (`Sources/JavaIntelligence/References/`): a persistent identifier index (`JavaNameIndex`, `JavaIdentifierScanner`, `refs.idx` shards via `JavaNameIndexShardWriter/Reader`, beside `sources.idx`; per-file stamps, incremental, open-buffer overlay; Umbra refreshes it and force re-indexes stubs when `IDEProjectWatcher` reports `.java` changes on disk) lists the candidate files for an identifier, and usages are then verified on demand instead of stored: `JavaSymbolIdentity` maps the caret to a `JavaSymbolID` (type, method with parameter keys, constructor, field, local by declaration range), `JavaFileUsageResolver` resolves every same-named identifier in a file (one parse and reusable context per file; unresolvable overloads or receivers are `.ambiguous`), `JavaLocalUsages` handles locals without the index, and `JavaUsageSearch` fans out over the roots that can see the declaration. `JavaFindUsagesProvider` answers `.references` for Java (methods search every member of `JavaMethodFamily`, which is built from the index only, so unsaved buffers and anonymous classes are not in it); `JavaGoToSuperMethod` answers `.superMethod`. `JavaRenameProvider` (`Sources/JavaIntelligence/Refactoring/`, a `RenameProviding`) renames types (with imports, static imports, Javadoc links and the `Old.java` file), locals, parameters (`JavaRenameProvider`), and methods (the whole override family), fields, enum constants and record components (`JavaMemberRename`); a family member in a JAR, the JDK or a generated root blocks the rename, ambiguous or read-only usages are left out of the edit unless the user ticks them in the preview, and Umbra deliberately gives it a text-scan candidate source (always correct) rather than the name index. Gradle model format 5 adds per-source-set `generatedSourceDirs` (indexed as read-only `SourceRoot.isGenerated` roots, re-indexed after Build Project) and `annotationProcessorJars` (`JavacInvocationBuilder` takes Lombok from them first).
- **HTTP client** — `.http` parsing and sending live in the Umbra target (`Example/Umbra/HTTP/`: `HTTPRequestParser`, `HTTPClient`), called from `IDEHTTPSupport`. There is no `HTTPClient` library, and JavaIntelligence does not depend on it.
- **`GitIntelligence`** (`Packages/GitIntelligence`) — its own Swift package, no dependencies. `GitRepository` wraps the git CLI (status including ignored paths, stage, commit, staged and unstaged diff, log, `GitGraphLayout`). Umbra wires it through `IDEGitStatus` for explorer colors and the source-control panel. `GitRepository.push()` exists; the panel does not call it.
- **`Umbra`** (`Example/Umbra`) — the macOS editor app shipped with this repo, intended as a **Sublime Text alternative**: lightweight, fast editing with project folders, split panes, symbol-aware navigation, session restore, a Problems panel (⌘⇧M; `IDEProblemsStore`/`IDEProblemsPanel`, a bottom-panel tab selected through `IDEBottomPanelTab`), and Java completion with Gradle module and dependency sync, hover with Javadoc, go to implementation, quick fixes, and saved run configurations (Java menu: Run Last Configuration ⌃⌥R, Edit Run Configuration…, Reformat Code ⌥⌘L, Optimize Imports, Show Context Actions ⌥↩; an "Optimize Imports on Save" preference, off by default). Build Project runs through the Gradle runner (asking for trust first) so its compiler errors land in the Problems panel (Sublime keymap by default). Find Usages results go to a Usages bottom-panel tab (`IDEUsagesPanel`, `IDEBottomPanelTab.usages`); Rename… (⇧F6 in the IntelliJ keymap) prompts for a name, shows a preview sheet (`IDERenamePreviewSheet`) and applies through `IDEWorkspaceEditApplier` (live buffers via `TextEditApplicator`, closed files written atomically inside the project folder). Built on `Penumbra`, `EditorIntelligence`, and `JavaIntelligence`.

Requires macOS 14+, Swift 5.5+/Xcode 13+. Tree-sitter (v0.26.12) is vendored in `Packages/TreeSitter` as a local SPM package.

## App Store safety

**`Penumbra` must stay App Store–safe.** Umbra and other apps built on this framework are intended for Mac App Store distribution (Runestone ships the same engine on the App Store). Treat this as a hard constraint on every change to `Sources/Penumbra`, `Sources/EditorIntelligence`, and shared dependencies:

- **Public APIs only** — no private Apple SPI, no undocumented runtime hooks, no entitlement bypasses.
- **Sandbox-compatible** — do not assume disabled App Sandbox, arbitrary filesystem access, or elevated privileges. Use standard security-scoped bookmarks, open/save panels, and user-granted folder access patterns.
- **Hardened Runtime** — avoid JIT, dynamic code loading, or `NSTask`/`Process` usage inside the library targets; host apps may spawn tools (e.g. Gradle, JDK) only with explicit user consent and outside the core editor engine where possible.
- **Licensed dependencies** — vendored code must be App Store–compatible (see `THIRD_PARTY_NOTICES.md`). Do not add GPL or otherwise incompatible libraries to `Penumbra` itself.
- **Review-friendly behavior** — no hidden network calls, telemetry, or background activity from the framework; optional features (LSP, AI, Java sync) stay opt-in and clearly user-initiated in the host app.

When a feature cannot be implemented in an App Store–safe way inside `Penumbra`, keep it in the host app layer (`Example/Umbra`) or behind an explicit, user-controlled capability.

## Features

### Penumbra text engine (`TextView`)

**Editing & input**
- Full `NSTextInputClient` / `UITextInput` compatibility for native macOS text input, IME, and accessibility.
- Undo/redo with timed grouping (`TimedUndoManager`) so rapid typing coalesces into one undo step.
- Character-pair auto-insertion and skip-over-trailing (`CharacterPair`, delegate hooks).
- TextFormation integration for tab expansion, bracket pairing, and whitespace cleanup (`TextFormationController`).
- Language-aware indent on line break, block indent/unindent (`shiftLeft`/`shiftRight`), and auto-detect tab vs. spaces (`detectIndentStrategy`).
- Move selected lines up/down (`moveSelectedLinesUp`/`moveSelectedLinesDown`).
- Move statement up/down respecting syntax (`EditorActionID.moveStatementUp`/`Down`, `StatementRangeService` walks the tree-sitter node then reuses `MoveLinesService`; falls back to line movement without a tree).
- Duplicate lines (`duplicateSelectedLines`/⌘D) and delete lines (`deleteSelectedLines`/⌘⌫) — multi-caret aware, one undo step each.
- Join lines (`EditorActionID.joinLines`, `JoinLinesService`) — collapses the line break + next line's indent to one space, comment-aware, multi-line aware, multi-caret aware (each caret ends at its own join point), one undo step.
- **Enter key** (`Sources/Penumbra/TextView/Enter/`): `IndentController.insertLineBreak` delegates to `EnterController`, which asks host `TextView.enterHandlerDelegates` (`EnterHandlerDelegate` → `EnterEdit`, a single replacement so undo stays one step and multi-caret works) and then the built-ins: block comments (`/**` generates ` * ` + `*/`, continues the ` * ` prefix), string-literal splitting (`"abc" +`), and bracket splitting (`{|}`). Otherwise it indents: structure-aware for languages whose `TreeSitterLanguage.enterBehavior` sets `cStyleIndent` (`CStyleLineIndentProvider` — block indent in `{}`, continuation indent (2 levels) in `()`/after an unfinished expression, +1 after brace-less `if/for/while/else/do`, `case` bodies; on for Java via `EnterBehavior.java`), tree-sitter indentation scopes where defined, else a literal copy of the current line's leading whitespace (plain text included).
- Surround selection with a template (`TextView.surroundSelection(with:)`, `SurroundTemplate` — if/while/for/try-catch/brackets/quotes, per-language + registerable, expanded via `EditorIntelligence`'s `SnippetExpander` with `$TM_SELECTED_TEXT`).
- Reindent fallback (`TextView.reindentSelectedLines()`) — bracket-depth reindent used for `EditorActionID.reformatCode` when no LSP formatter is wired.
- **Keymap layer** (`Sources/Penumbra/TextView/Keymap/`): `TextView.keymap` holds `[KeyStroke: EditorActionID]` bindings resolved by `KeymapDispatcher` (generic two-step chords like ⌘K ⌘D, plus double-⇧ via `DoubleModifierDetector` on `flagsChanged`). Presets `Keymap.default_` (historical shortcuts) and `Keymap.intelliJ`. Actions the core doesn't own return `false` from `TextInputView.performKeymapAction` and fall through to `TextView.editorActionHandler` / registered `addKeyDownInterceptor`s. Invoke any action directly with `TextView.perform(_:)`.
- Configurable `keyDownHandler` (single) or `addKeyDownInterceptor` (composable) for custom keybindings, both run before the keymap.
- Floating caret (long-press drag) for precise cursor placement on touch/trackpad.
- Smart text substitutions: autocorrection, smart quotes/dashes, spell checking (via UIKit-compat properties).

**Selection**
- Single and multiple cursors (`selectedRanges`, Option-click to add cursors, ⌥⌘↑/↓ to clone a caret vertically, `undoLastCaretChange()`/⌘U to step back).
- Column/block (rectangular) selection: Option-drag or ⌃⇧-arrows (`beginBlockSelection(at:)`/`extendBlockSelection(to:)`/`extendBlockSelection(in:)`), with multi-caret-aware copy/cut/paste. Sticky column mode (`TextView.isColumnSelectionModeEnabled` / `EditorActionID.toggleColumnSelectionMode` / ⌘⇧8): the rectangle survives ordinary selection assignment and grows with plain arrows until toggled off.
- Progressive semantic selection (`EditorActionID.expandSelection`/`shrinkSelection`, ⌥↑/⌥↓ in the IntelliJ keymap): `SemanticSelectionController` walks a ladder of word → enclosing tree-sitter node ancestors (injection-aware via `TreeSitterInternalLanguageMode.treeSitterNode(at:)`); without a tree it degrades to word → line → paragraph → document.
- Select word (double-click), paragraph (triple-click), and line selections (`addSelectionsOnEachLine`).
- Select whole line(s) touched by each caret (`selectLines`/⌘L), including the trailing break.
- Select next occurrence (`selectNextOccurrence`/⌘⇧D), skip the current one (`skipCurrentOccurrence`/⌘K ⌘D), or select all occurrences (`selectAllOccurrences`/⌘⇧L).
- Selection handles and caret rendering with customizable colors.
- Shift-click range extension; column-aware line movement.
- Multi-cursor-aware indent/outdent, move-line, newline, and undo (the whole caret set is restored, not just the primary caret).

**Layout & display**
- Red-black-tree-backed `LineManager` for O(log n) line lookups on large documents.
- Line wrapping with configurable break mode; optional right-margin ruler at a configurable column (hairline-only by default, with optional reformatting-guide shading).
- Gutter with dynamic-width line numbers, leading/trailing padding, and line-selection highlights.
- Customizable themes (`Theme`, `DefaultTheme`, `HighlightName`) with font trait overrides, line height, and kern.
- Invisible-character rendering (tabs, spaces, non-breaking spaces, line breaks, soft line breaks) with custom symbols.
- Minimap with viewport indicator and click/drag scrolling (`showMinimap`).
- Floating overlay scrollers (`showsScrollers`, `Sources/Penumbra/TextView/Scroller/`): `TextView` is a clip-view-backed `UIScrollView` shim, not an `NSScrollView`, so AppKit provides no scrollers — `ScrollerOverlayController` owns a vertical and a horizontal `OverlayScrollerView` (geometry in the pure `ScrollerGeometry`) that fade with scrolling, widen on hover, and honor the system "Show scroll bars: Always" style. The vertical scroller is suppressed while the minimap is shown (its viewport indicator serves that role); the horizontal one is independent. Umbra exposes it as the `showScrollbars` preference.
- Background document preparation via `TextViewState` (parse + highlight off main thread before `setState`).

**Syntax highlighting**
- Incremental Tree-sitter parsing with language layers and injected-language support (e.g. CSS in HTML).
- Pluggable highlight providers (`HighlightProviding`): Tree-sitter queries + LSP semantic tokens (`SemanticTokenHighlightProvider`).
- `EmphasisManager` for transient highlights (search matches, bracket pairs, diagnostics).
- Bracket-pair matching with flash/emphasis at caret (`BracketMatchingController`).
- `syntaxNode(at:)` for querying the AST at a byte offset.

**Code folding**
- Indentation-based fold regions with gutter fold ribbons (`FoldingController`, `isLineFoldingEnabled`).
- Tree-sitter node-based folding via `TreeSitterLineFoldProvider` (auto-selected when a Tree-sitter language mode is active).
- Collapse/expand by hiding line heights in the line manager (no separate scroll model).

**Search & replace**
- Programmatic search API (`SearchQuery`) with contains, full-word, starts/ends-with, and regex modes; case sensitivity and scoped range.
- Regex capture-group replacements (`$0`, `$1`, …) and batch replace (`BatchReplaceSet`).
- Built-in find/replace panel (`FindPanelController`, `showFindPanel`/`hideFindPanel`/`toggleFindPanel`).
- `UIFindInteraction` integration for system find UI.
- Highlighted-range navigation (`selectNextHighlightedRange`, looping modes).

**Navigation**
- Go to line (`goToLine`) with selection-at-beginning/end options.
- `TextLocation` ↔ byte-offset conversion for line/column addressing.
- Cursor history (`TextView.navigationHistory`, `NavigationHistory`, `EditorActionID.navigateBack`/`navigateForward`, ⌘[ / ⌘]): a bounded back/forward stack of `NavigationEntry` (documentID/url/`TextLocation`) fed by significant cursor moves and `recordNavigationCheckpoint()` before programmatic jumps (`goToLine`, `selectHighlightedRange`). `TextView.navigationHistory` is settable, so `EditorWorkbench.navigationHistory` (one shared instance) + `PenumbraWorkbenchEditorAdapter.bindNavigationHistory(to:document:)` + `onOpenHistoryEntry` give cross-document ⌘[ end-to-end (wired in `Example/Umbra`).
- Command palette (`CommandPaletteController` in `Sources/Penumbra/TextView/CommandPalette/`; model/engine in `Sources/Penumbra/Workbench/CommandPalette/`; `Sources/Penumbra/UIBridge/CommandPaletteView.swift`): Search Everywhere (⇧⇧), Find Action (⌘⇧A), Recent Files (⌘E), Go to File, Go to Line (⌘G, `EditorActionID.goToLine`), Find in Files (⌘⇧F, `EditorActionID.findInFiles`, backed by `EditorIntelligence.ProjectSearchEngine` when `CommandPaletteController.projectSearchEngine`/`workspaceRoot` are set) — a `SearchEverywhereEngine` fans a debounced query to concurrent `SearchEverywhereProvider`s (built-ins: commands/files/recent/symbols/go-to-line/in-buffer-text/project-search; host-extensible) and renders grouped results with `FuzzyMatcher.rankedWithMatches`-driven character highlighting. A leading sigil narrows the sources per keystroke in every palette mode, not just Search Everywhere (`PaletteQueryScope`: `>` commands, `@` symbols, `/` files, `#` in-buffer text, `:` go-to-line — Sublime's Goto Anything). `CommandRegistry.registerBuiltInActions(for:)` populates Find Action with every `EditorActionID` + its current shortcut.

**Diagnostics (rendering)**
- Squiggle underlines for `TextViewDiagnostic` values by severity (`DiagnosticEmphasisController`).

### Editor Intelligence Platform (`EditorIntelligence`)

**Core**
- Editor-agnostic `Document`, `Cursor`, `Selection`, `TextEdit`/`TextRange` types.
- `EditorAdapter` protocol + `AsyncStream<EditorEvent>` for decoupled editor integration.
- `DependencyContainer`, `EventBus`, `EditorContext`, typed `Request`/`Response`.

**Parsing & indexing**
- `LanguageParser` / `SyntaxTree` abstraction over Tree-sitter.
- Incremental `SymbolIndex` (Trie-backed) updated by `IndexingService` on document changes.
- `SymbolSearchEngine` for prefix and exact symbol lookup.

**Completion**
- `CompletionEngine` runs multiple `CompletionProvider`s concurrently and ranks results (`DefaultRanker`). A provider that returns `true` from `isPrimary(for:)` (e.g. `JavaCompletionProvider` for `.java`) turns the others into fallbacks: their items only show when the primary has none, and never after a member-access `.`.
- IntelliJ-style matching and ranking: `CompletionMatcher` (prefix, camel-hump `gN`→`getName`/`ArrLi`→`ArrayList`, word-start `Name`→`getName`, matched ranges for bold), `DefaultRanker` orders by match tier, then `CompletionItem.priority`/`preselect`, recency (`CompletionRecency`), kind, length. Providers set `priority`; they don't need to prefix-filter.
- `CompletionItem` carries `detail` (type column), `labelDetail` (signature tail), `isDeprecated`, `additionalEdits` (auto-import), `caretOffset`, `triggersSignatureHelp`, `insertTextIsSnippet`, `preselect`; `identityKey` keeps overloads distinct.
- `EditorIntelligenceController` auto-opens the popup from `TextView.addTypingObserver` (identifier characters, `.`, `@`, `::` — works with any adapter, including auto-paired characters), re-filters locally on every keystroke while re-querying with a live-text context, keeps the selection, and closes when the caret leaves the identifier. Ctrl+Space twice asks for broader results (`CompletionContext.invocationCount`); an explicit request with one result inserts it. Enter inserts, Tab replaces the identifier suffix, `.`/`(`/`;` commit a chosen item; methods land with the caret inside `(|)` and open parameter info (`SignatureHelpProviding`).
- Built-in providers: symbols (`SymbolCompletionProvider`), in-buffer words (`WordCompletionProvider`), snippets (`SnippetCompletionProvider`, `excludedLanguageIdentifiers`).
- LSP (`LSPCompletionProvider`) and AI (`AICompletionProvider`) backends.
- Ghost-text inline preview of the rest of the selected completion (`GhostTextModel`).
- Accepting a completion applies the same relative edit at every caret when multiple selections are active (`TextView.replaceAtAllSelections(relativeStartOffset:length:with:)`); snippet tab stops are single-site only (no tab-stop session exists yet).

**Snippets**
- TextMate-style snippet parsing with tab stops, placeholders, and transforms (`SnippetEngine`, `SnippetExpander`).

**Hover**
- `HoverEngine` with caching; symbol documentation (`SymbolHoverProvider`), LSP (`LSPHoverProvider`), and AI (`AIHoverProvider`) backends. `HoverContext.trigger` is `.idle` for the popup after a resting caret and `.manual` for Quick Documentation (F1 / ⌃J, `EditorActionID.quickDocumentation`). `HoverWindowView` renders the Markdown (`HoverMarkdownRenderer`: paragraphs, bullets, fenced code, inline bold/italic/code) in a scrollable view sized to its content.

**Navigation**
- `NavigationEngine` with Go to Definition (`GoToDefinitionProvider`), Find References (`FindReferencesProvider`), and breadcrumbs (`BreadcrumbProvider`). `NavigationContext.kind` (`.definition`/`.implementation`/`.references`) lets one engine hold providers for all three; providers ignore contexts whose `kind` they don't serve. A provider whose `isPrimary(for:)` is true for a context (e.g. `JavaGoToDefinitionProvider` for `.java`, every kind) makes the engine ask only primary providers, so a name-matching fallback never answers for a language that has a real resolver; an empty result shows a short hint next to the caret.
- LSP definition, implementation, references, rename, and signature-help providers (`LSPDefinitionProvider`, `LSPImplementationProvider`, `LSPReferencesProvider`, `LSPRenameProvider`, `LSPSignatureHelpProvider`); `LSPClient.requestImplementation` maps to `textDocument/implementation`.
- `EditorIntelligenceController` wires `EditorActionID.goToDefinition`/`goToImplementation`/`findUsages`/`reformatCode` to the engines via `editorActionHandler`; `navigate(kind:)` focuses a single result or hands multiple to `onPresentNavigationChoices` (e.g. the command palette). `onOpenLocationInOtherDocument` routes cross-file targets.
- `SymbolSearchEngine` for workspace symbol search.

**Diagnostics**
- `DiagnosticEngine` aggregating multiple `DiagnosticProvider`s.
- Built-in duplicate-symbol detection (`DuplicateSymbolDiagnosticProvider`).
- `EditorIntelligenceController.onDiagnosticsUpdated` hands the active document's `DiagnosticReport` to the host after each refresh (only the latest refresh is delivered — a superseded one is cancelled). `DiagnosticGrouping`/`ProblemRow` merge, dedupe, and sort per-file diagnostics for a Problems list, and `ProblemLocator.nsRange(for:in:)` resolves a diagnostic's line/column to a UTF-16 range (don't trust `utf16Offset`; LSP conversion stores the column there).
- LSP diagnostics (`LSPDiagnosticProvider`).

**Refactoring**
- `RefactoringEngine` holds generic `RefactoringOperation`s. Rename goes through `RenameProviding` (`prepareRename` → `RenamePlan` of `RenamePlanEntry`s with ambiguous/read-only flags, file renames, warnings, `blockingError`; `WorkspaceEdit` spans several files) and `EditorIntelligenceController.rename()` (`EditorActionID.rename`), which asks the host through `onRequestRename` (name prompt), `onPresentRenamePlan` (preview) and `onApplyWorkspaceEdit`. `EditorActionID.goToSuperMethod` (⌘U in the IntelliJ keymap, which no longer binds `undoLastCaretChange`) navigates with `NavigationKind.superMethod`.

**LSP integration**
- `LSPClient` protocol; `EditorIntelligenceLSP` target wraps ChimeHQ `LanguageClient`.
- Document sync (`LSPDocumentSyncService`), workspace sync bridge (`LSPWorkspaceSyncBridge`).
- Semantic token decode/storage/map for LSP-driven highlighting.
- Formatting (`FormattingProviding`; `LSPFormattingProvider` is one implementation, `JavaFormattingProvider` another) — document and selection formatting via `EditorIntelligenceController.formatDocument()` / `formatSelection()` (formats every range when multiple selections are active; `EditorActionID.reformatCode` uses the live selection and only claims a document its provider `supportsFormatting`, otherwise the text view's bracket reindent runs); edits applied through `TextEditApplicator` preserve the caret set instead of collapsing it.
- Code actions (`CodeActionProviding`; `LSPCodeActionProvider` is one implementation) — quick fixes via `EditorIntelligenceController.requestCodeActions()` (`EditorActionID.showContextActions`, ⌥↩; the popup takes ↑/↓/Return). `organizeImports()` applies the provider's `source.organizeImports` action (`EditorActionID.optimizeImports`, ⌃⌥O in the IntelliJ keymap).
- Signature help auto-trigger on `(` and `,` when `LSPSignatureHelpProvider` is configured.

**AI integration**
- `AITextModel` abstraction; AI completion and hover providers.

**Workspace**
- `Workspace` actor for multi-document project state.
- `WorkspaceSearchEngine` for searching across all open documents.
- `FileSystemWatcher` / `PollingFileSystemWatcher` for external file changes.
- `Project` model for workspace organization.

**Navigation & outline**
- `OutlineBuilder` builds a hierarchical symbol tree from `SymbolIndex` data.
- `BreadcrumbBarModel` / `BreadcrumbBarView` show enclosing symbols at the cursor. A `BreadcrumbProviding` in `EditorIntelligenceServices` supplies language-aware segments ahead of the symbol-index ones (`nil` means fall back).

**UI presentation (`UIBridge` + Penumbra views)**
- `CompletionPanelView`, `HoverWindowView`, `GhostTextView`, `ParameterHintsView`.
- `EditorIntelligenceController` wires engines to a live `TextView` (completion, hover, diagnostics, ghost text, parameter hints, formatting, code actions, outline, breadcrumbs, workspace search).
- `EditorIntelligenceServices` bundles optional LSP/workspace services (`LSPFormattingProvider`, `LSPSignatureHelpProvider`, `LSPCodeActionProvider`, `SymbolIndex`, `Workspace`).
- `TextEditApplicator` applies LSP `TextEdit` arrays to a `TextView` in reverse-offset order.
- `BreadcrumbBarView`, `OutlineSidebarView`, `CodeActionView`, `WorkspaceSearchPanelView` — AppKit accessory views.
- `JumpToDefinitionController` for Cmd+click / programmatic go-to-definition.
- `PenumbraEditorAdapter` bridges `TextView` ↔ EIP.

### Workbench (`Penumbra/Workbench`)

- Multi-pane editor layout with horizontal/vertical splits (`EditorWorkbench`, `EditorLayout`).
- Per-pane tab groups with preview (temporary) tabs, pin, and back/forward tab history (`EditorPane`, `EditorTabHistory`, `TabListEngine`).
- `WorkbenchDocument` holding editor state; `PenumbraStateBuilder` for `TextViewState` construction.
- Session restoration (`EditorRestorationState`, Codable layout/document snapshots).
- `PenumbraWorkbenchWorkspaceBridge` syncs open documents into EIP `Workspace`.
- `PenumbraWorkbenchEditorAdapter` implements `EditorAdapter` at workbench scope.

### Language packs

- `TestTreeSitterLanguages` — bundled grammars for tests (HTML, JavaScript, JSON, Python, YAML).
- `PenumbraGraphQLLanguage` — example SPM language target pattern (C grammar + `highlights.scm` + indentation scopes).

## Common commands

```bash
swift build                                   # build all targets
swift test                                    # run the full PenumbraTests suite
swift test --filter ClassName                 # run one test class
swift test --filter ClassName/testMethodName  # run one test method
```

There is no separate lint/format script wired into SPM; SwiftLint config lives at `.swiftlint.yml` (run `swiftlint` directly if installed). `swiftgen.yml` regenerates `Sources/Penumbra/Library/L10n.swift` from `Localizable.strings` — don't hand-edit that generated file.

**Umbra** (`swift run Umbra`, `Scripts/build-app.sh`) is the Sublime Text–style editor product; `Example/Umbra` is its SPM executable target and source tree (app shell, views, `IDEWorkspace`, and `UmbraApp.swift`/`@main`). `Example/Umbra.xcodeproj` is a thin, separately maintained Xcode app project that compiles the same source files directly as a native app target — needed because a SwiftPM executable target can't host SwiftUI Previews (`ENABLE_DEBUG_DYLIB`); it's a dev convenience for Previews/Run/Debug only and isn't used for release builds. See `Example/README.md` for details.

## Architecture

### Two independent targets, one adapter

`EditorIntelligence` is intentionally decoupled from any specific text-editing UI. It defines its own `Document`, `Cursor`, `Selection`, `TextEdit`/`TextRange` types and talks to an editor only through the `EditorAdapter` protocol (`Sources/EditorIntelligence/Core/EditorAdapter.swift`): a stable `id`, a `context`, a `currentDocument`/`openDocuments` snapshot, an `AsyncStream<EditorEvent>` of edits/selection changes, and async `applyEdit`/`focusRange` methods.

`PenumbraEditorAdapter` (`Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`) is the concrete bridge: it becomes a `TextView`'s `editorDelegate`, caches a `Document` snapshot behind a lock so EIP services can read it off the main actor, and marshals edits/focus changes onto `MainActor` since they touch UI. When adding a new EIP feature, implement it against `EditorAdapter`/`Document`/etc. generically — don't reach into `Penumbra` types from `EditorIntelligence` code.

### Penumbra engine internals

- **`TextView/Core`** — `TextView.swift` (public AppKit view, ~1.5k lines) and `TextInputView.swift` (~1.8k lines, implements `NSTextInputClient`/keyboard-mouse handling) are the two central classes; most other `TextView/*` subfolders (Gutter, Highlight, Indent, InvisibleCharacters, Navigation, PageGuide, SearchAndReplace, TextSelection, CharacterPairs, LineController, Appearance) are focused collaborators they own.
- **`LineManager`** — maintains document lines as a red-black tree (`RedBlackTree/`) keyed by line position, so line lookups/edits are O(log n) rather than O(n) array operations. `DocumentLineChildrenUpdater` and `LineChangeSet` propagate edits through the tree.
- **`LanguageParser` + `TreeSitter`** — `TreeSitterLanguageParser`/`TreeSitterSyntaxTree` wrap the C tree-sitter library (`TreeSitter*.swift` files) to provide incremental AST parsing; `TreeSitterInternalLanguageMode` and `TreeSitterSyntaxHighlighter` consume the tree to drive syntax highlighting, while `PlainTextInternalLanguageMode`/`PlainTextSyntaxHighlighter` are the no-highlighting fallback. `TextViewState` lets a document + tree-sitter parse be prepared off the main thread before being handed to a `TextView`.
- **`Library`** — cross-cutting helpers (byte/range conversions between UTF-16 and tree-sitter's UTF-8 byte offsets, string helpers, `UIKitCompatibility/` shims used to keep API shape close to the original iOS/UIKit-based upstream project).
- **`PenumbraGraphQLLanguage`** — an example of the pattern for adding a tree-sitter language as its own SPM target: a `TreeSitterGraphQL` C target (grammar) + a Swift target providing `highlights.scm` and indentation scopes, depending on both `Penumbra` and the C grammar target. Follow this structure when adding another language.

### EditorIntelligence internals

- **`Core`** — `DependencyContainer` (service locator/wiring), `EventBus` (typed pub/sub used by adapters and engines), `EditorContext`/`EditorEvent`/`EditorTypes`/`Request` — the shared vocabulary every other module builds on.
- **`Indexing`** — `SymbolIndex` backed by a `Trie` for prefix lookups, updated incrementally by `IndexingService` as documents change.
- **`Completion`** — `CompletionEngine` runs a list of `CompletionProvider`s (symbol/word/snippet/LSP/AI) concurrently and ranks results (`Ranking/`); `CompletionContextFactory` builds the request context from adapter/document state.
- **`Snippets`** — tab-stop/placeholder snippet expansion engine, driven through `UIBridge`'s `GhostTextModel`/`CompletionPanelModel`.
- **`Hover`**, **`Navigation`**, **`Diagnostics`**, **`Refactoring`** — each follows the same provider-engine pattern: an `*Engine` orchestrates one or more `*Provider`s (e.g. `DuplicateSymbolDiagnosticProvider`, `GoToDefinitionProvider`, `RenameProviding`) and returns typed results.
- **`AI`** and **`LSP`** — pluggable backends implementing the same provider protocols as native providers (`AICompletionProvider`, `LSPCompletionProvider`, etc.), so completion/hover/diagnostics can mix local, LSP, and AI sources transparently.
- **`UIBridge`** — AppKit-facing presentation models (`CompletionPanelModel`, `HoverWindowModel`, `ParameterHintsModel`, `GhostTextModel`) that translate engine output into view state; actual AppKit views live back in `Penumbra/TextView`.

### Tests

`Tests/PenumbraTests` is a single XCTest target covering both `Penumbra` and `EditorIntelligence` (798+ tests), plus `TestTreeSitterLanguages` (bundled grammars: html/javascript/json/python/yaml) and `PenumbraGraphQLLanguage` used as fixtures. Test files are one-class-per-file and named `<SubjectUnderTest>Tests.swift`; mocks live in `Tests/PenumbraTests/Mock` and `MockTextInput.swift`.

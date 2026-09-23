# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Penumbra is a Swift Package Manager library: a high-performance plain text/code editor engine for **macOS** (AppKit), forked from simonbs/Runestone (originally iOS/UIKit) and ported natively to macOS. It combines two layers:

- **`Penumbra`** — the text rendering/editing engine itself (line layout, gutter, tree-sitter syntax highlighting, selection, undo, search & replace).
- **`EditorIntelligence`** — a separate, editor-agnostic IDE-intelligence platform (completion, indexing, hover, navigation, diagnostics, refactoring, LSP/AI adapters) that has **no dependency on `Penumbra`**. The two are connected only through `Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`.
- **`JavaIntelligence`** — native Java indexing and completion (JDK discovery, source and JAR stubs, type resolution, completion) with **no dependency on `Penumbra`**. Umbra wires it through `Example/Umbra/IDEJavaSupport.swift`. Completion (`Sources/JavaIntelligence/Completion/`) parses with a dummy identifier at the caret (`JavaCompletionProvider.dummyIdentifier`), types lambdas and method references through the target parameter's functional interface, resolves source members against their declaring file's imports, classifies the site (`JavaCompletionContextClassifier`: member access, `::`, import/package, `@`, `new`, type-only, `case`, class body, statement), ranks by expected type (`JavaExpectedType`, `JavaAssignability`), auto-imports classes (`JavaImportInserter`), offers `@Override` stubs in class bodies, and doubles as parameter info (`JavaSignatureHelp.swift`). For a Gradle project, a trusted sync (`GradleCommandRunner` plus an init script) replaces the whole-folder `.java` walk with per-module source sets and resolved dependency JARs. Go to Definition (`Sources/JavaIntelligence/Navigation/`) resolves into attached sources when present (a JDK `lib/src.zip` or a dependency's adjacent `*-sources.jar`, via `JavaAttachedSources`) and otherwise falls back to decompiling the `.class` file with [Sunflower](https://github.com/alex-cova/sunflower) (`FernflowerKit`, `JavaClassDecompiler`) — gated by a one-time user agreement (`JavaDecompilerAgreement`) that only a manual navigation (never Cmd-hover) can trigger, via `JavaGoToDefinitionProvider.setDecompilerConsent(accepted:request:)`.
- **`Umbra`** (`Example/Umbra`) — the macOS editor app shipped with this repo, intended as a **Sublime Text alternative**: lightweight, fast editing with project folders, split panes, symbol-aware navigation, session restore, and Java completion with Gradle module and dependency sync (Sublime keymap by default). Built on `Penumbra`, `EditorIntelligence`, and `JavaIntelligence`.

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
- `HoverEngine` with caching; symbol documentation (`SymbolHoverProvider`), LSP (`LSPHoverProvider`), and AI (`AIHoverProvider`) backends.

**Navigation**
- `NavigationEngine` with Go to Definition (`GoToDefinitionProvider`), Find References (`FindReferencesProvider`), and breadcrumbs (`BreadcrumbProvider`). `NavigationContext.kind` (`.definition`/`.implementation`/`.references`) lets one engine hold providers for all three; providers ignore contexts whose `kind` they don't serve.
- LSP definition, implementation, references, rename, and signature-help providers (`LSPDefinitionProvider`, `LSPImplementationProvider`, `LSPReferencesProvider`, `LSPRenameProvider`, `LSPSignatureHelpProvider`); `LSPClient.requestImplementation` maps to `textDocument/implementation`.
- `EditorIntelligenceController` wires `EditorActionID.goToDefinition`/`goToImplementation`/`findUsages`/`reformatCode` to the engines via `editorActionHandler`; `navigate(kind:)` focuses a single result or hands multiple to `onPresentNavigationChoices` (e.g. the command palette). `onOpenLocationInOtherDocument` routes cross-file targets.
- `SymbolSearchEngine` for workspace symbol search.

**Diagnostics**
- `DiagnosticEngine` aggregating multiple `DiagnosticProvider`s.
- Built-in duplicate-symbol detection (`DuplicateSymbolDiagnosticProvider`).
- LSP diagnostics (`LSPDiagnosticProvider`).

**Refactoring**
- `RefactoringEngine` with rename operations (`RenameOperation`); LSP rename provider.

**LSP integration**
- `LSPClient` protocol; `EditorIntelligenceLSP` target wraps ChimeHQ `LanguageClient`.
- Document sync (`LSPDocumentSyncService`), workspace sync bridge (`LSPWorkspaceSyncBridge`).
- Semantic token decode/storage/map for LSP-driven highlighting.
- Formatting (`LSPFormattingProvider`) — document and selection formatting via `EditorIntelligenceController.formatDocument()` / `formatSelection()` (formats every range when multiple selections are active); edits applied through `TextEditApplicator` preserve the caret set instead of collapsing it.
- Code actions (`LSPCodeActionProvider`) — quick fixes via `EditorIntelligenceController.requestCodeActions()`.
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
- `BreadcrumbBarModel` / `BreadcrumbBarView` show enclosing symbols at the cursor.

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
- **`Hover`**, **`Navigation`**, **`Diagnostics`**, **`Refactoring`** — each follows the same provider-engine pattern: an `*Engine` orchestrates one or more `*Provider`s (e.g. `DuplicateSymbolDiagnosticProvider`, `GoToDefinitionProvider`, `RenameOperation`) and returns typed results.
- **`AI`** and **`LSP`** — pluggable backends implementing the same provider protocols as native providers (`AICompletionProvider`, `LSPCompletionProvider`, etc.), so completion/hover/diagnostics can mix local, LSP, and AI sources transparently.
- **`UIBridge`** — AppKit-facing presentation models (`CompletionPanelModel`, `HoverWindowModel`, `ParameterHintsModel`, `GhostTextModel`) that translate engine output into view state; actual AppKit views live back in `Penumbra/TextView`.

### Tests

`Tests/PenumbraTests` is a single XCTest target covering both `Penumbra` and `EditorIntelligence` (798+ tests), plus `TestTreeSitterLanguages` (bundled grammars: html/javascript/json/python/yaml) and `PenumbraGraphQLLanguage` used as fixtures. Test files are one-class-per-file and named `<SubjectUnderTest>Tests.swift`; mocks live in `Tests/PenumbraTests/Mock` and `MockTextInput.swift`.

# Editor Intelligence Platform (`EditorIntelligence`)

Loaded when working under `Sources/EditorIntelligence`. Feature catalog moved out of the root CLAUDE.md.

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
- Pointer hover (`EditorIntelligenceController.tooltipDelay`, `showsDocumentationOnMouseHover`, `showsDiagnosticTooltips`): after the pointer rests on a diagnostic's squiggle its message shows (`diagnosticMarkdown`); on an identifier (opt-in) the hover engine is asked with `.manual` at that offset (`liveDocument(caretAt:)`). Identifier lookup reads a 128-unit window, never `textView.text`, because it runs on every mouse move. ⌘-hover stays with `JumpToDefinitionController`. `EditorActionID.showErrorDescription` (⌘F1 — ⌃F1 is taken by macOS full keyboard access) shows the messages at the caret. `tooltipDelay` also paces the caret-rest popup.

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
- In-place mode (`EditorIntelligenceController.appliesRefactoringsInPlace`, off by default): while the name prompt of Rename or an Extract is open the code it will change is outlined (`EmphasisGroup.refactoring`; for rename a throwaway plan to `<name>Renamed` finds the occurrences in this document), and a plan with nothing ambiguous, read-only, deleted or warned about (`needsNoJudgment`) is applied without the host's preview, then `onWorkspaceEditApplied` lets the host refresh. `confirmsInlineVariable` (default `true`) decides whether Inline Variable is previewed. `ProblemNavigationScope` (`.all`/`.highestSeverity`, `ProblemNavigator.severities(for:in:)`) picks what Next/Previous Problem stops at.

**LSP integration**
- `LSPClient` protocol; `EditorIntelligenceLSP` target wraps ChimeHQ `LanguageClient`.
- Document sync (`LSPDocumentSyncService`), workspace sync bridge (`LSPWorkspaceSyncBridge`).
- Semantic token decode/storage/map for LSP-driven highlighting.
- Formatting (`FormattingProviding`; `LSPFormattingProvider` is one implementation, `JavaFormattingProvider` another) — document and selection formatting via `EditorIntelligenceController.formatDocument()` / `formatSelection()` (formats every range when multiple selections are active; `EditorActionID.reformatCode` uses the live selection and only claims a document its provider `supportsFormatting`, otherwise the text view's bracket reindent runs); edits applied through `TextEditApplicator` preserve the caret set instead of collapsing it.
- Code actions (`CodeActionProviding`; `LSPCodeActionProvider` is one implementation) — quick fixes via `EditorIntelligenceController.requestCodeActions()` (`EditorActionID.showContextActions`, ⌥↩; the popup takes ↑/↓/Return). A `CodeAction` may carry a `CodeActionCommand` (id and arguments) instead of, or after, its edits: choosing it calls `EditorIntelligenceController.onCodeActionCommand`, so a host can offer actions only it can perform (Umbra's Run / Debug). `organizeImports()` applies the provider's `source.organizeImports` action (`EditorActionID.optimizeImports`, ⌃⌥O in the IntelliJ keymap).
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

**UI presentation (`EditorChrome` + Penumbra views)**
- `CompletionPanelView`, `HoverWindowView`, `GhostTextView`, `ParameterHintsView`.
- `EditorIntelligenceController` wires engines to a live `TextView` (completion, hover, diagnostics, ghost text, parameter hints, formatting, code actions, outline, breadcrumbs, workspace search).
- `EditorIntelligenceServices` bundles optional LSP/workspace services (`LSPFormattingProvider`, `LSPSignatureHelpProvider`, `LSPCodeActionProvider`, `SymbolIndex`, `Workspace`).
- `TextEditApplicator` applies LSP `TextEdit` arrays to a `TextView` in reverse-offset order.
- `BreadcrumbBarView`, `OutlineSidebarView`, `CodeActionView`, `WorkspaceSearchPanelView` — AppKit accessory views.
- `JumpToDefinitionController` for Cmd+click / programmatic go-to-definition.
- `PenumbraEditorAdapter` bridges `TextView` ↔ EIP.

**Language services** (`Languages/`)
- `LanguageService` is one language's (or one contribution's) intelligence: `languageIdentifiers`, `LanguageProviders` (completion/hover/diagnostics/navigation arrays for the engines; formatting, signature help, code actions, rename, refactoring, code generation, breadcrumbs, inlay hints, code vision for the controller) and a `LanguagePolicy` naming the `GenericFeature`s it replaces (`snippets`, `duplicateSymbolDiagnostics`, `symbolHover`, `symbolNavigation`). `BasicLanguageService` is the value form; `JavaLanguageService` (in `JavaIntelligence`) is the Java one.
- `LanguageServiceRegistry` (immutable, identifier → services) feeds the engines' provider lists, tells the generic providers which languages to skip (`identifiers(disabling:)`), and exposes the single-slot features as routed providers (`formatting`, `codeActions`, …; `Languages/LanguageRouting.swift`) for `EditorIntelligenceServices(languages:)`. Services sharing a language combine: code actions concatenate, formatting takes the first that supports the document, signature help the first non-nil, the stateful features (rename, refactoring, code generation, breadcrumbs, inlay hints, code vision) the first that has one. A language nobody claims gets empty answers (a routing error for rename/refactor plans). Plan: `docs/LANGUAGE_SUPPORT_PLAN.md`; guide: `docs/ADDING_A_LANGUAGE.md`. Tests: `LanguageServiceRegistryTests`.
- Host-driven features (`Languages/LanguageFeatures.swift`): `SemanticTokenProviding` (`SemanticHighlight`), `LineMarkerProviding` (`LineMarker`, `LineMarkerKind`), `StructureProviding` (`StructureNode`), `TypeHierarchyProviding` / `CallHierarchyProviding` (`HierarchyItem`, `HierarchyLocation`). They are not in `EditorIntelligenceServices`: the host asks `LanguageServiceRegistry.semanticTokens(for:)` / `lineMarkers(for:)` / `structure(for:)` / `typeHierarchy(for:)` / `callHierarchy(for:)` for the active language's provider (nil = the language has none). Offsets are UTF-16; `HierarchyItem` and `LineMarker` carry a provider-owned `payload`. Java's conformances: `Sources/JavaIntelligence/JavaLanguageFeatures.swift`.
- `LanguageEnvironment` (`Languages/LanguageEnvironment.swift`) is what a service reads from the host: `openBufferText`, `indentUnit`, `hasConsent` / `requestConsent` (`ConsentTopic`). `LanguageService.start(environment:)` receives it once when the window starts and `stop()` drops it (`LanguageServiceRegistry.start` in order, `stop` in reverse). Umbra builds it in `IDEWorkspace.languageEnvironment()` with weak captures. Project-root and file-change hooks are planned with the project system (plan, phase 5).

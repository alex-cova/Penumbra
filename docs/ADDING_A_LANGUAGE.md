# Adding a language

How to add a language to Penumbra and Umbra **as the code stands today**. Three levels, each optional on top of the one before:

1. **Syntax**: highlighting, comments, indentation, file-type detection, the Set Syntax menu.
2. **Intelligence**: completion, hover, navigation, diagnostics, formatting and so on, without any UI of its own.
3. **IDE features**: commands, tool windows, preferences, run buttons, project model.

`docs/LANGUAGE_SUPPORT_PLAN.md` replaces most of the manual steps below with a single registration. Each section ends with what changes when that phase lands, so a PR written now is easy to port.

Read first: the root `CLAUDE.md` (App Store safety, performance rules), `docs/PERFORMANCE_RULES.md`, and for level 2 `Sources/EditorIntelligence/CLAUDE.md`.

---

## 1. Syntax

### 1.1 The grammar target

Follow `PenumbraGraphQLLanguage` (root `CLAUDE.md` names it as the pattern): a C target for the generated parser, and a Swift target that supplies the query and the `TreeSitterLanguage`.

1. `Sources/TreeSitter<Name>/`: the generated `src/` (`parser.c`, optionally `scanner.c`, `tree_sitter/parser.h`) and `include/public.h` declaring `tree_sitter_<name>()`. Copy the layout of `Sources/TreeSitterGraphQL/`.
2. `Sources/Penumbra<Name>Language/` (or `TreeSitter<Name>Penumbra` if you follow the older three-target layout most bundled languages use: C target, `...Queries`, `...Penumbra`):
   - `highlights.scm`, from the grammar's repository, adjusted to Penumbra's capture names (compare with `Sources/TreeSitterRustQueries/highlights.scm`).
   - `TreeSitterLanguage.swift` with `static var <name>: TreeSitterLanguage`, setting `lineCommentPrefix` and, for block comments, `blockCommentDelimiters` (`.cStyle` and `.html` exist in `BlockCommentDelimiters.swift`). Optional `indentationScopes` (see `IndentationScopes.swift` in `PenumbraGraphQLLanguage`) and `injectionsQuery`.
3. `Package.swift`: declare both targets (C target with `cSettings: [.headerSearchPath("src")]`, Swift target with `resources: [.copy("highlights.scm")]` and `swiftSettings: swift6`) and add the Swift target to `PenumbraLanguages`' dependencies.
4. `THIRD_PARTY_NOTICES.md`: the grammar's licence. Only App Store compatible licences (MIT, Apache 2.0, BSD); no GPL.

### 1.2 Register the language

Everything about the language except its grammar is one `LanguageDefinition` (`Sources/Penumbra/Workbench/LanguageDefinition.swift`): identifier, display name, file extensions, extensionless file names, other identifiers, Markdown fence tags, an optional `LanguageConfiguration`, and whether the Set Syntax menu lists it. File detection (`LanguageIdentifier`), fence normalization (`FenceLanguageName`), the grammar lookup (`BundledLanguages`), `LanguageConfigurationRegistry.builtIns` and Umbra's Set Syntax menu all read the registry these go into.

**In this repository, a bundled language (three edits plus the targets):**

| File | Edit |
|---|---|
| `Sources/Penumbra/Workbench/LanguageDefinition+BuiltIns.swift` | one `LanguageDefinition(...)` in `builtIns`, with `isSelectable: true` so it appears in Set Syntax; add `fenceAliases` only for tags people write that differ from the identifier (`rs` for `rust`), and `configuration:` only if it needs method separators or breadcrumb rules |
| `Sources/PenumbraLanguages/TreeSitterLanguage+Bundled.swift` | one `(identifier, { .yourLanguage })` line in `BundledGrammars.grammars` |
| `Sources/PenumbraLanguages/Exports.swift` | `@_exported import <your target>` |

Optional: `SurroundTemplate.swift`: add the identifier to `cFamilyLanguages` (or the Python family) so Surround With offers `if`, `for`, `try`. It is not part of the definition yet.

**In an app that uses Penumbra, a language of its own (no edit to this repository):** register at launch, before documents open, because prepared grammars are cached on first use.

```swift
LanguageDefinitionRegistry.shared.register(LanguageDefinition(
    id: "zig", displayName: "Zig", fileExtensions: ["zig"], fenceAliases: [],
    isSelectable: true, grammar: { .zig }      // your TreeSitterLanguage
))
```

The identifier is a lowercase string, the same one everywhere (`"rust"`, `"graphql"`). Aliases are other identifiers that mean the language (`"bash"` for `"shell"`); they resolve to its definition and grammar but are not what file detection returns. A later registration wins an extension, and registering an identifier again replaces it.

### 1.3 Check by hand

Build and run Umbra (`swift run Umbra`), open a file of the new type, and check: colors, comment toggling, Enter indentation, Set Syntax in the status bar, and a fenced block of the language in a Markdown file.

### 1.4 Tests

- Add your extensions to the table in `Tests/PenumbraTests/LanguageMappingCompatibilityTests.swift` (extensions, fence tags, grammar identifiers) and the Set Syntax list there. The test is written out by hand on purpose so that a mapping cannot change silently.
- Grammar resolves: `Tests/PenumbraTests/BundledLanguagesTests.swift`, `LanguagePackTests.swift`.
- Surround: `SurroundTemplateTests.swift` if you touched it.

> **Later** (`docs/LANGUAGE_SUPPORT_PLAN.md`, open questions): a bundled language may become one file exposing its own definition. Step 1.1 is unchanged.

---

## 2. Intelligence

Without a UI of your own. A language gets: completion, hover, go to definition, find usages, diagnostics, formatting, signature help, code actions, rename, refactoring, inlay hints, code vision, breadcrumbs.

### 2.1 The target

Create `Sources/<Name>Intelligence/`, depending **only on `EditorIntelligence`**, never on `Penumbra` (`JavaIntelligence` is the reference; its `CLAUDE.md` describes the layers). Declare the target and a library product in `Package.swift`, and make `Umbra` depend on it.

Implement the protocols you need (all `Sendable`, usually `actor`s):

| Feature | Protocol | Notes |
|---|---|---|
| Completion | `CompletionProvider` | `isPrimary(for:)` true for your language turns the generic providers into fallbacks; `provideUpdates` can yield a fast batch, then a slow one |
| Hover | `HoverProvider` | |
| Go to definition, implementation, usages | `NavigationProvider` | one provider can serve all kinds; check `context.kind`; `isPrimary(for:)` as above |
| Diagnostics | `DiagnosticProvider` | for push-style results (a compiler run), keep a result handler as `JavaCompilerDiagnosticsService` does |
| Formatting | `FormattingProviding` | |
| Signature help | `SignatureHelpProviding` | |
| Code actions | `CodeActionProviding` | |
| Rename, refactoring, code generation | `RenameProviding`, `RefactoringProviding`, `CodeGenerationProviding` | rename returns a `RenamePlan` the host previews |
| Breadcrumbs, inlay hints, code vision | `BreadcrumbProviding`, `InlayHintProviding`, `CodeVisionProviding` | |
| Semantic colours | `SemanticTokenProviding` | highlight names are the theme's (`"type.class"`, `"function.call"`); computed off the main actor, dropped if the text moved |
| Gutter markers (↑ ↓) | `LineMarkerProviding` | the host maps `LineMarkerKind` to icons and click actions; put your own record in `payload` |
| Structure outline, File Structure, breadcrumb member menu | `StructureProviding` | UTF-16 ranges; a file of ASCII needs no conversion |
| Type hierarchy, call hierarchy | `TypeHierarchyProviding`, `CallHierarchyProviding` | `HierarchyItem`s with a `payload` your provider gets back when the host expands or opens one |

Start with completion and diagnostics; they carry most of the value. For an external language server, use `EditorIntelligenceLSP` and the `LSP*Provider` types instead of writing providers (the server process is started by the app, not by the library; see `docs/SWIFT_SOURCEKIT_LSP_PLAN.md`).

### 2.2 Rules your providers must follow

- **Guard on the language**: return nothing unless `document.languageIdentifier` is yours. Every Java provider does this.
- **Never block typing.** Completion, diagnostics, parsing and indexing are scheduled from a keystroke, never awaited on it; drop a result when the document moved on (`docs/PERFORMANCE_RULES.md`).
- **Work is bounded** by visible rows or edit size, never by document size. Measure with `swift run -c release PerfHarness enter-session synthetic --lines 20000` (and `120000`).
- **No `Process`, no network, no telemetry** in a library target (root `CLAUDE.md` ▸ App Store safety). A tool you need to run (a compiler, a language server) is started by the app in `Example/Umbra`, through `SubprocessKit`, with explicit user consent, the way Gradle and the JDK are.
- **Read other files through an injected lookup**, not the disk, so unsaved buffers are seen (`setOpenBufferLookup` on the Java providers).

### 2.3 Wire it into Umbra

Return your providers as a `LanguageService` and register it; the router does the rest.

```swift
// In your XIntelligence target (see JavaLanguageService), or inline with BasicLanguageService:
BasicLanguageService(
    name: "zig", languageIdentifiers: ["zig"],
    providers: LanguageProviders(completion: [zigCompletion], diagnostics: [zigDiagnostics], formatting: zigFormatter),
    policy: LanguagePolicy(disabling: [.snippets])    // generic features your language replaces
)
```

Add it to the `LanguageServiceRegistry(services:)` list in `Example/Umbra/IDEIntelligenceServices.swift`. Then:
- `completion`, `hover`, `diagnostics`, `navigation` are fed to the engines. Every provider is asked about every document, so it must answer only for its own language (guard on the identifier) and, for completion and navigation, claim it with `isPrimary(for:)`.
- `formatting`, `signatureHelp`, `codeActions`, `rename`, `refactoring`, `codeGeneration`, `breadcrumbs`, `inlayHints` and `codeVision` are routed by `document.languageIdentifier`, so they only see your language's documents. No dispatcher to write. Two services may claim one language (Java's providers and the app's Run actions); `LanguageServiceRegistry` documents how each feature combines them. Features that keep state between calls (rename, refactoring, code generation, breadcrumbs, inlay hints, code vision) take the first service that has one.
- `policy` replaces the old hand-kept `skippingLanguages` lists: name the generic features (`snippets`, `duplicateSymbolDiagnostics`, `symbolHover`, `symbolNavigation`) your language does better itself. Symbol and word completion stay as fallbacks through `isPrimary`.
- Order matters only within an engine: services are asked in the order registered.
- Anything that needs the host (open buffers, the indent unit, the user's agreement to something) comes from the `LanguageEnvironment` handed to `start(environment:)`: read it there, and drop what you took in `stop()`. Declare a `ConsentTopic` for each thing the user must agree to and handle it in `IDEWorkspace.requestConsent(to:)` / `hasConsent(to:)`. Do not add setter calls to `bootstrap()`.

### 2.4 Tests

An actor test per provider, plus a "returns nothing for a foreign language" test. Add the mapping to `PerfHarness` if the language has an indexer.

- The window's folder and the files that changed on disk reach a service through two synchronous `@MainActor` hooks, `projectDidChange(root:)` and `filesDidChange(_:)` (defaults do nothing). They are synchronous on purpose: the host reads the result straight after (the next service's decision, the status bar), so a service with slow work starts a task and returns. Umbra's project systems have already seen the folder when the hook runs, so a service can read what they decided.

---

## 3. IDE features

Everything that is UI or project state. A language adds its chrome as an `IDELanguageModule` (`Example/Umbra/Languages/`), a stateless value; `IDEHTTPModule` is the small worked example (two palette commands, a menu, one tool window), `IDEJavaModule` the large one. Register it in `IDELanguageModules.all`.

| Feature | How |
|---|---|
| Palette commands | `commands(for: workspace)`: `EditorCommand`s whose closures capture the workspace weakly (`[weak workspace]`) |
| Menu-bar menu | `menu(for: workspace)` returns an `IDEModuleMenu` (title and SwiftUI content built from an `IDEWorkspaceRef`) while the language applies, nil otherwise. Add one line for it in `IDEAppCommands.swift`: SwiftUI cannot build a menu bar from a list |
| Settings page | `preferencePanes`: an `IDEPreferencesPane` with an `IDEPreferencesDomain` (id, title, SF Symbol, search terms) and the page's view. It appears between Project and Agent |
| Tool window (stripe entry) | `toolWindows(for: workspace)`: `workspace.bottomToolWindow(.tab, …, order:)` for a built-in bottom tab, or an `IDEToolWindow` of your own; `order` places it among the others (`IDEToolWindow.Order`) |
| Bottom-panel tab | `bottomTabs(for: workspace)` returns an `IDEBottomTabContribution` while the tab has something to show: `tab` (a new `IDEBottomPanelTab("id")`, declared as a static member in your module file), `order` among the strip items (`IDEBottomPanelTab.Order`), the strip `item` and the `content` panel. Select it with `workspace.selectedBottomTab = tab`, toggle it from the stripe with `toggleBottomToolWindow(tab)` |
| Left sidebar tab | `sidebarTabs`: an `IDESidebarTabDescriptor` (a new `IDESidebarTab(rawValue: "id")`; the raw value is saved in sessions, so never rename it), title, symbol, `order`, availability, badge, `onShow` and `content`; it appears in the tab bar, the `+` menu and the stripe |
| Status bar item, toolbar button | `IDEStatusBarPanel.swift`, `IDEToolbarPanel.swift` (by hand) |
| Gutter run buttons | `IDEWorkspace+Debugger.swift` (`applyJavaGutter`); the line-marker column is reserved by `reservedLineMarkerSlots` |
| Run, Debug, Run in Context, Stop | an `IDERunProvider` (`Run/IDERunProvider.swift`) returned from your module's `makeRunProvider(for:)`: `canRun`, `runHelp`, `run`, `runInContext`, `rerun`, `stop`, `runnableLocations`. Start a program with `IDERunSessions.start(IDERunRequest(…))`: your `prepare` closure does the checks and the build, then calls `session.start(IDEProcessLaunch(…))` or `session.fail(…)`; the Run tab, the console, rerun-in-place and Stop come with it. Hold the window weakly, through a small host protocol of your own (`IDEJavaRunHost` is the example). Debugging stays Java's |
| Project model (Gradle-like) | an `IDEProjectSystem` (`Projects/IDEProjectSystem.swift`), added to `IDEIntelligenceServices.projectSystems`: `isActive` once it recognizes the folder, `syncState` and `console`, `tasks`, `runTasks`/`build`, trust through `IDEProjectEnvironment.requestTrust`, and its tool window (`toolWindows`, `bottomTabs`, `makeSidebar`). `IDEGradleProjectSystem` is the example; it hands its model to Java through `IDEGradleModelConsumer`, so a system whose model a language indexes does the same |
| Semantic highlighting, gutter markers, Structure outline, type and call hierarchy | return a `SemanticTokenProviding`, `LineMarkerProviding`, `StructureProviding`, `TypeHierarchyProviding` or `CallHierarchyProviding` in your `LanguageProviders`; the workspace asks the registry for the active language's provider (`IDEWorkspace.scheduleSemanticHighlighting`, `scheduleLineMarkers`, `refreshStructure`, `showTypeHierarchy`), so there is nothing to wire. A language with no provider gets no gutter column, tab content or outline |
| Agent tools | `Example/Umbra/Agent/` (`IDEAgentNavigationTools.swift` for navigation) |

Rules for this layer:
- A module holds no workspace and no per-window state; take the workspace from the call, capture it weakly in closures, and keep per-window state on the workspace.
- Every split in the app is a `SplitPanes`; do not add `HSplitView` or `NSSplitView`.
- App-wide state (trust decisions, selections, stores) goes in `IDESharedServices`; do not construct a per-window copy.
- Nothing may retain the workspace past `IDEWorkspace.teardown()` (menu closures, callbacks owned by long-lived views).
- Tests that create a workspace set `IDEWorkspace.isSessionPersistenceEnabled = false`.
- Document the feature in `Example/Umbra/CLAUDE.md`.

---

## Checklist for a pull request

- [ ] Grammar licence added to `THIRD_PARTY_NOTICES.md` and App Store compatible
- [ ] One `LanguageDefinition` (identifier, extensions, fence tags, `isSelectable`) and its grammar entry
- [ ] Highlighting, comment toggle, indentation, Set Syntax and Markdown fence checked by hand
- [ ] Providers guard on language, never block typing, drop stale results
- [ ] No `Process`/network in library targets
- [ ] `PerfHarness enter-session` unchanged if you touched a hot path
- [ ] Tests added; `swift test` passes
- [ ] Feature documented in the matching `CLAUDE.md`

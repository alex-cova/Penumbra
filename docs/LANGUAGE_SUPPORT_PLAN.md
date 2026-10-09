# Language support plan

How a contributor adds a language to Umbra, from syntax colors up to a Java-class IDE experience, without editing `IDEWorkspace`. Companion guide for what to do **today**: `docs/ADDING_A_LANGUAGE.md`.

## Status

**Phases 0 to 5 are implemented** (see their sections for what shipped and how it differs from the sketch; phase 4 lists what it left out). Phase 6 is a proposal. The measurements in Motivation were taken on branch `java-run-configurations` (October 2026), before phase 0.

## Motivation

The library layers are already well separated. `JavaIntelligence` and `EditorIntelligence` do not depend on `Penumbra`, the completion, hover, diagnostics and navigation engines take provider arrays, and `EditorIntelligenceLSP` covers much of the generic LSP surface. The blockers are elsewhere.

**1. Routing is by string, in every provider.**
- `JavaIntelligence` has 28 `languageIdentifier == "java"` guards, one per provider.
- The generic fallbacks are told by hand to keep out: `skippingLanguages: ["java"]`, `excludedLanguageIdentifiers: ["java", "http"]` (5 sites in `Example/Umbra/IDEIntelligenceServices.swift`). A second language means editing every list.

**2. One slot per feature.**
- `EditorIntelligenceServices` (`Sources/Penumbra/EditorIntelligenceAdapter/EditorIntelligenceController.swift`) holds one formatting, signature-help, code-action, rename, refactoring, code-generation, breadcrumb, inlay and code-vision provider.
- Umbra hand-rolled `IDECompositeFormattingProvider` and `IDECompositeCodeActionProvider` to share a slot. `docs/SWIFT_SOURCEKIT_LSP_PLAN.md` phase 4 already calls the language-dispatching wrapper "the one design decision with some weight".

**3. Features with no generic protocol.**
- Semantic tokens, line markers, structure, and type and call hierarchy exist only as concrete Java actors (`JavaSemanticTokenProvider`, `JavaLineMarkerProvider`, `JavaStructureProvider`, `JavaTypeHierarchyProvider`, `JavaCallHierarchyProvider`).
- `IDEWorkspace` calls them directly (`javaSupport.semanticTokenProvider.tokens(for:)`).

**4. The app layer is Java-shaped.**

| Measure | Value |
|---|---|
| Umbra files importing `JavaIntelligence` | 47 of 239 |
| Java/Gradle mentions in `IDEWorkspace.swift` | 494, in 6,465 lines |
| Java/Gradle mentions in `IDEJavaSupport.swift` | 441, in 1,506 lines |
| `"java"` string checks in Umbra | 30 |
| `app.java.*` commands registered by hand | 11 |
| `setOpenBufferLookup` calls in `bootstrap()` | 9, one per actor |

- `IDEJavaSupport` is four things: a provider container, the Gradle project model, JDK selection and index orchestration.
- `IDEWorkspace.bootstrap()` wires about 10 of its callbacks by hand.
- `IDEBottomPanelTab`, `IDESidebarTab` (persisted in sessions) and `IDEPreferencesDomain` are closed enums with a Java or Gradle case each.

**5. Even a syntax-only language is wide.** Rust is wired through three new targets, `Package.swift`, and six files in three modules: `PenumbraLanguages/Exports.swift`, `TreeSitterLanguage+Bundled.swift`, `Penumbra/Workbench/LanguageIdentifier.swift`, `FenceLanguageName.swift`, `Example/Umbra/IDELanguageSupport.swift`, and optionally `SurroundTemplate`, `LanguageConfiguration+BuiltIns` and `IndentationScopes`. Forget one and the language half-works (no fence highlighting in Markdown, missing from the Set Syntax menu).

## Goals

| Goal | How |
|---|---|
| A syntax-only language is one declaration | `LanguageDefinition` (tier 0) |
| An LSP-backed language is one small module | `LSPLanguageService` + `IDELanguageModule` (tiers 1 and 2) |
| A native deep language (Java) uses the same seams | `LanguageService` conformances; no private wiring |
| No per-language checks in shared code | A router decides by identifier; `IDEWorkspace` never names a language |
| No new cost on the typing path | Routing is a dictionary lookup; nothing is awaited on a keystroke |

**Success metrics**
- Grammar-only language: its grammar target, one definition file and one registration line. No other edit.
- LSP language: one module file of the order of 50 lines, plus server discovery.
- `IDEWorkspace.swift` has no `"java"` literal and no `javaSupport.` provider call. Stretch: no `import JavaIntelligence`.
- `PerfHarness enter-session` (20,000 and 120,000 lines) unchanged against the parent commit after phases 1 and 2.

## Rules

- **Compile-time registration only.** A language is an SPM target plus one registration line. No dynamic plugin loading (Hardened Runtime, App Store; root `CLAUDE.md` ▸ App Store safety).
- **Library tiers stay process-free.** Starting a language server or toolchain, discovering it, and asking for consent live in Umbra (via SubprocessKit), as Gradle and the JDK do today. A `LanguageService` is handed a ready transport.
- **Performance rules apply** (`docs/PERFORMANCE_RULES.md`). The router adds one dictionary lookup per request. Intelligence is scheduled from a keystroke, never awaited on it, and stale results are dropped (`contentGeneration`).
- **New protocols are shaped after LSP** (hierarchy items, semantic tokens, document symbols), so an LSP-backed service fills them almost for free.
- **No behavior change in phases 0 to 5.** Each phase lands on its own with the existing suites green. The first user-visible change is the proof phase.
- **Introduce a contribution point when a second language needs it**, not before. Debugging, for instance, stays Java-only until another debugger exists.

## Design

Three tiers. A contributor picks the depth they want; each tier works without the next.

### Tier 0: `LanguageDefinition` (syntax)

Lives in `Penumbra`, which has no grammar dependency. `TreeSitterLanguage` already carries the highlights query, line-comment prefix, block-comment delimiters and injection provider (see `Sources/TreeSitterRustPenumbra/TreeSitterLanguage+Helpers.swift`), so a definition adds identity and editor behavior around it. Implemented in `Sources/Penumbra/Workbench/LanguageDefinition*.swift`:

```swift
public struct LanguageDefinition: Sendable {
    public var id: String                       // "rust"
    public var displayName: String              // "Rust"
    public var fileExtensions: [String]         // ["rs"]; "" matches files without one
    public var fileNames: [String]              // [".zshrc"]
    public var aliases: [String]                // other identifiers: "bash", "sh" for "shell"
    public var fenceAliases: [String]           // ```rs in Markdown
    public var fenceName: String?               // what a fence tag normalizes to, if not `id`
    public var configuration: LanguageConfiguration?   // method separators, breadcrumbs, sticky lines
    public var isSelectable: Bool               // listed in the Set Syntax menu
    public var grammar: (@Sendable () -> TreeSitterLanguage?)?
}
LanguageDefinitionRegistry.shared.register(definition)
```

- `LanguageDefinitionRegistry` is thread-safe and reads from an immutable snapshot. `LanguageDefinition.builtIns` seeds it with the identity of every bundled language, so a host that links `Penumbra` alone still gets file-type detection.
- The grammars of the bundled languages are a table in `PenumbraLanguages` (`BundledGrammars`), installed on first use *without* replacing a grammar a host registered for the same identifier.
- A later registration wins an extension; re-registering an identifier replaces it and drops its old keys. Ambiguous `h` stays `c`.
- `LanguageIdentifier`, `FenceLanguageName`, `LanguageConfigurationRegistry.builtIns`, `TreeSitterLanguage.bundled(forIdentifier:)` / `BundledLanguages` and Umbra's `IDELanguageSupport.selectableSyntaxes` / `displayName(forIdentifier:)` all read the registry. Their public signatures are unchanged.

### Tier 1: `LanguageService` (intelligence)

Lives in `EditorIntelligence`. No `Penumbra` dependency; it may be implemented anywhere (a library target such as `JavaIntelligence`, or Umbra for app-specific ones like HTTP).

```swift
public protocol LanguageService: Sendable {
    var languageIdentifiers: Set<String> { get }
    var providers: LanguageProviders { get }
    var policy: LanguagePolicy { get }          // which generic fallbacks to switch off
    func start(environment: LanguageEnvironment) async
    @MainActor func projectDidChange(root: URL?)      // synchronous, see phase 5
    @MainActor func filesDidChange(_ urls: [URL])     // synchronous, see phase 5
    func stop() async
}
```

`LanguageProviders` is a struct of optionals: completion, hover, signatureHelp, formatting, codeActions, rename, refactoring, codeGeneration, breadcrumb, inlayHints, codeVision, semanticTokens, lineMarkers, structure, typeHierarchy, callHierarchy. `navigation` and `diagnostics` are arrays (Java has two of each).

**`LanguagePolicy`** exists because "claimed" and "opted out" are different. `excludedLanguageIdentifiers: ["java", "http"]` on snippets and `skippingLanguages: ["http"]` on duplicate symbols mean "this language does not want that generic feature", whether or not it has a service. A policy is a set of `GenericFeature` values to disable (snippets, duplicateSymbols, symbolCompletion, wordCompletion, symbolHover, symbolNavigation).

**`LanguageServiceRegistry`** is immutable after construction (identifier to service dictionary, built once per window). It builds what the controller already consumes, so `EditorIntelligenceController` is untouched:
- the provider arrays for `CompletionEngine`, `HoverEngine`, `DiagnosticEngine` and `NavigationEngine`;
- an `EditorIntelligenceServices` whose single slots are small per-protocol dispatchers (`Routing/`, about 20 lines each) choosing by `document.languageIdentifier`. They replace the two Umbra composites;
- the generic providers (symbol, word, snippet, duplicate-symbol) wrapped as fallbacks that ask the registry's policy first, which removes every `skippingLanguages` and `excludedLanguageIdentifiers` argument.

`HoverProvider` gains `isPrimary(for:)` (default `false`), matching completion and navigation, and `HoverEngine` asks only the primaries when any claim the context. Today hover relies on `SymbolHoverProvider(skippingLanguages: ["java"])` instead.

**Missing protocols (phase 2).**
- `SemanticTokenProviding`: tokens as range plus highlight name. The Java token type and the decoded LSP tokens (`SemanticTokenMap`) converge on one `SemanticHighlight`.
- `LineMarkerProviding`.
- `StructureProviding`: reuse or extend `OutlineItem` (`Sources/EditorIntelligence/Navigation/OutlineBuilder.swift`).
- `TypeHierarchyProviding` and `CallHierarchyProviding` with a generic `HierarchyItem` (LSP-shaped: name, detail, kind, location, opaque data).
- Java's actors conform. `IDETypeHierarchyPanel`, `IDECallHierarchyPanel` and the Structure panel take the generic items.
- The scheduling code in `IDEWorkspace` that debounces, computes off the main actor, and drops results when `contentGeneration` moved (`scheduleSemanticHighlighting`, `scheduleJavaLineMarkers`) is language-neutral. It becomes one decoration scheduler driven by the registry.

**`LanguageEnvironment` (phase 3)** is what a service reads from the host instead of the host pushing into each actor: `openBufferText(url)`, the indent unit, `requestConsent(_:)`, status and progress reporting, a logger, the project root. It replaces the 9 `setOpenBufferLookup` calls and the indent-unit closure in `bootstrap()`.

**`LSPLanguageService` (phase 6)** is declarative: identifiers, a policy, and a host-supplied transport. It maps an `LSPClient` (`Sources/EditorIntelligence/LSP/`, `Sources/EditorIntelligenceLSP/`) into `LanguageProviders`. The phases in `docs/SWIFT_SOURCEKIT_LSP_PLAN.md` that fix the LSP layer (diagnostics, document sync, capability negotiation) are prerequisites for it being useful, not for the router.

### Tier 2: `IDELanguageModule` (Umbra, `@MainActor`)

Wraps a `LanguageService` and contributes UI. Every member has a default, so a module overrides only what it has.

```swift
@MainActor protocol IDELanguageModule {
    var service: LanguageService { get }
    func commands(for workspace: IDEWorkspace) -> [EditorCommand]
    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow]
    func preferencePanes() -> [IDEPreferencesPane]
    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem]
    func gutterActions(for document: WorkbenchDocument) -> [GutterAction]   // run buttons
    func paletteSources() -> [IDEPaletteSource]
    func agentTools() -> [AgentTool]
    var projectSystem: IDEProjectSystem? { get }
    var runProvider: IDERunProvider? { get }
}
```

Reuse what exists: `EditorCommand` (`Sources/Penumbra/Workbench/CommandPalette/EditorCommand.swift`) and `IDEToolWindow` (`Example/Umbra/IDEToolWindows.swift`) are already plain structs.

**Opening the closed enums** (as built; see phase 4).
- `IDEBottomPanelTab` is an id value and `IDEPreferencesDomain` a value type with static built-ins, not `.contributed(id)` cases: a module declares its tabs and pages as static members and contributes descriptors.
- `IDESidebarTab` is `Codable` and saved in `IDEWindowSession`. It is a `RawRepresentable` string, which `Codable` encodes as the plain string, so existing sessions keep restoring with no custom coding.
- `IDEPreferencesDomain.searchTerms` (which includes `JavaInspectionRule.allCases.map(\.title)`) is a property of the page, declared by the Java module.

**Menu bar limit.** SwiftUI `Commands` cannot be built from a runtime list of menus. `IDEAppCommands` keeps one menu per built-in module and fills its items from the module; an externally registered module gets palette commands and tool windows, not a top-level menu. Stated as a known limit.

**Lifecycle.** App-shared state is made once (as `IDESharedServices` does for the JDK shard hub, trust, run configurations and breakpoints); one module instance per window (as `IDEIntelligenceServices` is today). `IDEWorkspace.teardown()` stops every module and nothing may retain the workspace (`IDERetentionGuardTests` pattern).

**`IDEProjectSystem` (phase 5, implemented)**: detect(root), a generic sync state (generalized from `IDEJavaSupport.GradleSyncState`), trust through the environment, a console log, a task list. Gradle is the first implementation, and the Gradle sidebar becomes its tool window. SwiftPM, Cargo or npm would be others.

**`IDERunProvider` (phase 5, implemented)**: runnable locations in a document and a process launch. `IDERunSession` (`Example/Umbra/Run/IDERunSession.swift`) is already generic in behavior (own process group, interactive stdin, coalesced output); it is generalized off `JavaRunConfiguration` and `JavaProcessLaunch`. The debugger stays Java-only.

**Agent.** `IDEAgentJavaNavigating` (`Example/Umbra/Agent/IDEAgentNavigationTools.swift`) is replaced by an implementation over `NavigationEngine`, so any language with navigation gets `go_to_definition` and `find_usages`.

## Phases

Each phase lists files, what "done" means, and tests. All keep existing suites green.

### Phase 0: language definitions (implemented)

- Added `LanguageDefinition`, `LanguageDefinitionRegistry` and `LanguageDefinition.builtIns` in `Sources/Penumbra/Workbench/`; `PenumbraLanguages` installs its grammars from `BundledGrammars` (`TreeSitterLanguage+Bundled.swift`).
- `LanguageIdentifier`, `FenceLanguageName`, `LanguageConfigurationRegistry.builtIns`, `TreeSitterLanguage.bundled(forIdentifier:)` and `IDELanguageSupport` now read the registry. The old extension switch, fence alias table, grammar switch, `LanguageConfiguration.builtIn(forIdentifier:)` and the hard-coded Set Syntax list are gone.
- **Tests:** `LanguageMappingCompatibilityTests` pins every old mapping (written against the old code first and passing there, then run unchanged against the new); `LanguageDefinitionRegistryTests` covers registration semantics and that one `register(_:)` on the shared registry reaches extension lookup, file names, fences, grammar, configuration and the Set Syntax list.
- **Differences from the sketch:**
  - `SurroundTemplate` is not registry-driven. Its `languages` sets are public, per-template and host-replaceable (`TextView.surroundTemplates`), and some name languages that have no definition (`objc`, `php`, `scala`, `dart`). Moving them is a public API change, so it is left for later.
  - `jsx`, `tsx` and `csharp` are identity-only definitions (no extensions, no grammar, not selectable). They keep the language configuration for `jsx`/`tsx` and the `cs` fence tag working exactly as before.
  - Adding a *bundled* language still means one `LanguageDefinition.builtIns` entry, one `BundledGrammars` entry and an `Exports.swift` line (plus its targets). A *host* language is one `register(_:)` call. Making a bundled language a single file needs either a per-language registration hook or grammar closures in the definition; see the open questions.
  - `IDELanguageSupport.displayName(forIdentifier: "plain")` now returns "Plain Text" (it returned "Plain"); the alias `bash` returns "Shell Script" (it returned "Bash").
  - `LanguageConfigurationRegistry.builtIns` is a computed property reading the shared registry, so a text view created after a registration sees it. A grammar registered after `BundledLanguages` has served that identifier is not picked up (the prepared language is cached); register at launch.

### Phase 1: registry, dispatchers, `JavaLanguageService` (implemented)

- **`EditorIntelligence/Languages/`:** `LanguageService` (name, `languageIdentifiers`, `providers`, `policy`), `LanguageProviders`, `LanguagePolicy` with `GenericFeature` (`snippets`, `duplicateSymbolDiagnostics`, `symbolHover`, `symbolNavigation`), `BasicLanguageService`, `LanguageServiceRegistry` and one dispatcher per single-slot feature (`LanguageRouting.swift`). `EditorIntelligenceServices(languages:…)` (Penumbra) builds the controller's services from the registry, so `EditorIntelligenceController` is untouched.
- **Java:** `JavaLanguageService` (in `JavaIntelligence`) bundles the provider instances `IDEJavaSupport` constructs, in the order each engine asks them, with Java's opt-outs (`snippets`, `symbolHover`, `symbolNavigation`). `IDEJavaSupport.languageService` hands it to the registry.
- **Umbra:** `IDEIntelligenceServices.languages` registers Java, the Run code actions (a second service for `java`, so they follow Java's), Markdown `@file` mentions, `.http` completion (opting out of snippets and duplicate-symbol warnings) and JSON formatting. The engines are built from it: the generic providers first for completion and diagnostics, last for hover and navigation (as before), each skipping `registry.identifiers(disabling:)`. `IDECompositeFormattingProvider` and `IDECompositeCodeActionProvider` are deleted.
- **Combining services that share a language:** engine providers all, in order; code actions concatenated; formatting the first that supports the document; signature help the first non-nil; rename, refactoring, code generation, breadcrumbs, inlay hints and code vision the first service that has one (they keep state across calls, so one owner).
- **Tests:** `LanguageServiceRegistryTests` (routing and every combining rule with fakes, "nobody claims it" answers, and Umbra's registry reproducing the old opt-out lists, provider order and formatting routing); `IDERunCodeActionTests` (Run actions come after Java's and only for Java).
- **Differences from the sketch:**
  - No `HoverProvider.isPrimary`. A language's opt-out of `symbolHover` already keeps the name-based hover away, so a second primary mechanism would have had no user; add it when a hover provider needs to claim a language without opting out.
  - The lifecycle members (`start`, `projectDidChange`, `filesDidChange`, `stop`) move to phase 3 with `LanguageEnvironment`, where they have something to receive.
  - `skippingLanguages` / `excludedLanguageIdentifiers` still exist on the generic providers, but nothing writes a list by hand any more: they are filled from the registry's policies.
  - The Run actions were keyed on the file's `.java` extension; as a service for `java` they are keyed on the document's language identifier. The two agree for every file Umbra opens (a `.java` file's language is locked to `java`).
  - This answers the open question about where `JavaLanguageService` lives: in `JavaIntelligence`, with the instances wired by Umbra.
  - `PerfHarness enter-session` was not re-measured: the harness builds its own engines and never touches the registry, and the router sits on explicit requests (format, actions, scroll-driven hints), not on typing or Enter.

### Phase 2: missing protocols (implemented)

- **Protocols** (`EditorIntelligence/Languages/LanguageFeatures.swift`), over plain values with UTF-16 offsets: `SemanticTokenProviding` (`SemanticHighlight`: range and theme name), `LineMarkerProviding` (`LineMarker`, `LineMarkerKind`), `StructureProviding` (`StructureNode`, `StructureKind`), `TypeHierarchyProviding` and `CallHierarchyProviding` (`HierarchyItem`, `HierarchyLocation`). Items carry an opaque `payload` that the provider gets back (Java stores its own node), so a provider can expand and open its own items without the host knowing the type; equality ignores it.
- **Registry:** `LanguageProviders` gained the five providers, and `LanguageServiceRegistry` answers `semanticTokens(for:)`, `lineMarkers(for:)`, `structure(for:)`, `typeHierarchy(for:)` and `callHierarchy(for:)` with the first service's provider for a language, or nil. They are not part of `EditorIntelligenceServices`: the host drives them (debounce, panels), and "the language has none" is how it decides not to reserve a gutter column or show a tab.
- **Java:** `JavaLanguageFeatures.swift` makes `JavaSemanticTokenProvider`, `JavaLineMarkerProvider`, `JavaStructureProvider`, `JavaTypeHierarchyProvider` and `JavaCallHierarchyProvider` conform by mapping their own types (byte offsets to UTF-16 for structure, with an ASCII fast path). `JavaLineMarkerKind` is now a typealias of `LineMarkerKind` (same cases and raw values, so saved gutter preferences keep working). The Java types stay for the providers' other callers and the tests.
- **Umbra:** the Structure sidebar (`IDEStructureStore`, `IDEStructurePanel`, renamed from the Java-prefixed names), the breadcrumb member menu, File Structure (⌘F12), the Type and Call Hierarchy panels, semantic highlighting and the gutter markers all ask `IDEWorkspace.languages` for the active document's provider. The two schedulers lost their `languageIdentifier == "java"` guards; a language without a provider clears its decoration and reserves no marker column.
- **Hierarchy tabs** remember the language they were asked for, because their items belong to it: expanding or opening one goes back to that language's provider even if the active editor has since switched.
- **Tests:** adapter tests next to the Java provider tests (generic output equals the native output, payload round trip, foreign items lead nowhere, non-ASCII structure ranges), `LanguageServiceRegistryTests` for the new lookups, `StructureNode` helpers and `HierarchyItem` equality, and that Umbra gives Java all five and Markdown, JSON, HTTP, Swift none.
- **Differences from the sketch:**
  - `IDEWorkspace` still names `javaSupport` in four places: three `setOpenBufferLookup` calls (phase 3, `LanguageEnvironment`) and `structureProvider.caretContext` for Run / Debug in Context (Java-only; phase 5, run providers). The "done when" holds for everything the five protocols cover.
  - The two decoration schedulers (semantic highlighting, line markers) are language-neutral but still two functions; merging them into one component was not needed to remove the Java coupling, so it is left until a third decoration wants the same debounce and stale-result rules.
  - The LSP semantic-token decoder (`SemanticTokenMap`) and `SemanticHighlight` are not unified; an LSP-backed service would map its tokens to highlights itself.
  - Wording: the hierarchy tabs say "Type Hierarchy is not available for <Language> files" and "No type at the caret" (they said "works in Java files" and "No Java type at the caret"); the Structure sidebar says "No outline for this file" for a language without one.
  - `HierarchyItem` has a `badge` (`"jar"`, `"JDK"`) chosen by the provider, so the panel no longer hardcodes Java's origin words.

### Phase 3: `LanguageEnvironment` (implemented)

- **`LanguageEnvironment`** (`EditorIntelligence/Languages/LanguageEnvironment.swift`): four closures a service reads from the host: `openBufferText(url)`, `indentUnit()`, `hasConsent(topic)` and `requestConsent(topic)`. A `ConsentTopic` is a string id (`ConsentTopic.javaDecompiler` is declared by `JavaIntelligence`); the host decides how to ask and remembers a yes. The defaults know nothing and agree to nothing.
- **Lifecycle:** `LanguageService` gained `start(environment:)` and `stop()` (default no-ops); `LanguageServiceRegistry.start(environment:)` runs services in registration order and `stop()` in reverse.
- **Java:** `JavaLanguageService.start` points the nine open-buffer lookups, the formatter's indent unit and the decompiler consent at the environment; `stop` clears them. `IDEWorkspace.bootstrap()` builds one environment (`languageEnvironment()`, closures over a weak bridge, so nothing retains the workspace) and starts the registry; `teardown()` stops it. The nine hand-written setter blocks are gone, and nothing in `Example/` calls `setOpenBufferLookup`, `setIndentUnitProvider` or `setDecompilerConsent` any more. The JSON formatter and the environment share `IDEPreferences.currentIndentUnit()`.
- **Tests:** lifecycle order with recording fakes, the default environment, Java formatting taking its indent unit from the environment and going back to its own default after `stop`, and the decompiler topic and indent helper.
- **Difference found on the way:** `JavaFormattingProvider` stored whatever unit its host last returned, so clearing the host's provider left that unit in place. It now uses a copy.
- **Differences from the sketch:**
  - `projectDidChange` and `filesDidChange` are not added yet. Java's project root and file-change handling are `IDEJavaSupport.setProjectRoot` and `projectFilesChanged`, called synchronously from `applyProjectRoot` and the project watcher; routing them through an `async` registry call would reorder them against code that reads the result straight after. They move with the project system in phase 5, where that is designed. *(Done in phase 5: synchronous `@MainActor` hooks.)*
  - No status, progress or logging closures: nothing uses them yet. `IDEJavaSupport` still owns its status message and Gradle trust prompt (`requestTrust`), which are project concerns for phase 5.
  - `hasConsent` is in the sketch's place of a single `requestConsent`, because the decompiler gate treats "already agreed" differently from "ask now": only a manual navigation may ask, but a hover may decompile once the user has agreed.

### Phase 4: modules and open enums (implemented)

**Implemented: the contribution points that are data or closures, with HTTP and Java as modules.**
- **`IDELanguageModule`** (`Example/Umbra/Languages/IDELanguageModule.swift`): a stateless value with `commands(for:)`, `toolWindows(for:)`, `menu(for:)` and `preferencePanes`, all defaulted. It takes the workspace as an argument and never keeps it, so a module cannot keep a window alive; per-window state (`IDEJavaSupport`, `IDEHTTPSupport`) stays on the workspace. `IDELanguageModules.all` lists the shipped ones (`IDEJavaModule`, `IDEHTTPModule`).
- **Palette commands:** the eleven `app.java.*` and two `app.http.*` entries left `IDEWorkspace`'s list; `configurePalette` registers `languageModuleCommands()` where Java's used to start, so the Java group keeps its place.
- **Menu bar:** `IDEJavaCommands` and `IDEHTTPCommands` moved into their modules. `IDEAppCommands` has one line per built-in module showing `languageModuleMenu(for:)`, which is nil while the module does not apply (Java for a Java file or Gradle project and not on the welcome screen; HTTP for an `.http` file). `showsJavaMenu` and `showsHTTPMenu` are gone.
- **Settings:** `IDEPreferencesDomain` is a value type with the built-in pages as static members, so `.editor` and `.agent` work as before. The Java and Inspections pages are the Java module's `IDEPreferencesPane`s and sit between Project and Agent (`IDEPreferencesDomain.ordered(with:)`); the Inspections search terms still include every rule title.
- **Tool windows:** `IDEToolWindow` has an `order` (constants in `IDEToolWindow.Order`, spaced so a module can slot between two). The Debug, Test Results, Hierarchy, Call Hierarchy, Gradle and HTTP Response entries come from their modules and the list is merged by `order`, which reproduces the old sequence.
- **Tests:** `IDELanguageModuleTests` (the module list, each module's command ids, titles and groups, each registered once, Java's group before Git, menu visibility rules, the settings order and search, the order constants).

- **Bottom-panel tabs are open.** `IDEBottomPanelTab` is a value (an id; `terminal`, `sourceControl`, `problems` and `usages` stay built in, and `"\(tab)"` still prints the old case names). A module returns `IDEBottomTabContribution`s from `bottomTabs(for:)`: the tab, its `order` in the strip (`IDEBottomPanelTab.Order`), the strip item and the panel. `IDETerminalTabsBar` merges its built-in items with the modules' by `order`, and `IDETerminalPanel` mounts each module panel next to the built-in ones, hidden rather than removed while another tab is selected, as before. Run, Gradle, Type Hierarchy, Test Results, Debug and Call Hierarchy are the Java module's; HTTP Response is the HTTP module's.
- **Sidebar tabs are open.** `IDESidebarTab` is a `RawRepresentable` string, so saved sessions decode exactly as before (an id no build ships decodes and is never offered). Everything else about a tab is its `IDESidebarTabDescriptor`: title, symbol, `order`, shortcut and tint for the stripe, availability, badge, an `onShow` action and its content. Explorer, Structure, Changes and History are `IDESidebarTabs.builtIn`; Breakpoints is the Java module's (`sidebarTabs`). The sidebar, tab bar, `+` menu, stripe and `showSidebarTab` read descriptors instead of switching on cases.
- **Tests:** `IDELanguageModuleTests` also covers the bottom tab names and strip order, module tabs appearing and disappearing with their content, the sidebar's five tabs in order with their shortcuts, availability without a repository, that a saved session round-trips and a vanished tab id is ignored, and that only Explorer cannot be closed.

**Still not done:**
- Status-bar items, toolbar buttons, gutter actions, palette sources and agent tools are not module contributions yet; each is wired by hand where it was.
- Markdown, JSON and CSV (previews, text tools) are not modules; their per-language switches in `IDEAppCommands` and the toolbar remain.
- Java's behavior (Gradle, run, debug, diagrams, the content of the Structure sidebar) still lives in `IDEWorkspace` extensions, called from the module's closures. Moving it is phase 5. *(Gradle and Run moved in phase 5; the debugger and the diagrams are still the window's.)*
- The per-tab `is…Selected` flags on `IDEWorkspace` (`isTypeHierarchySelected`, `isDebugSelected`, …) and the `select…Tab()` methods remain; they are views over `selectedBottomTab`. A new module's tab uses `selectedBottomTab = tab` and `toggleBottomToolWindow(tab)` directly.
- No test registers a third module end to end: `IDELanguageModules.all` is a static list, so openness is shown by Java and HTTP using only the public contribution types.
- **Differences:** the HTTP palette group is now registered with Java's rather than last, so with an empty query Find Action lists HTTP before Edit, Git, Run and View. `IDEToolWindow` has a stored `order`, so any new construction site must set it.

### Phase 5: project systems, run and test (implemented)

**Project systems.**
- **`IDEProjectSystem`** (`Example/Umbra/Projects/IDEProjectSystem.swift`) and `IDEProjectSystems`, the window's list (`IDEIntelligenceServices.projectSystems`; the first system that recognizes the folder is `active`). The protocol covers detection (`isActive`), `syncState` (`IDEProjectSyncState`: `notDetected`, `awaitingTrust`, `untrusted`, `syncing`, `synced(modules:dependencies:)`, `failed(summary:)`), `console` (`IDEProjectConsoleLog`, the old `IDEGradleConsoleLog` with a generic output line), `tasks` (`IDEProjectTask`), `runTasks`, `build`, `reload`, cancel, `sourceRootPaths`, `hasConfigurationChanges` (the build-file banner) and the tool window (`toolWindows`, `bottomTabs`, `makeSidebar`).
- **Trust and "tell the host"** go through `IDEProjectEnvironment`, a struct of closures the window sets in `bootstrap()` (`requestTrust`, `syncFailed`, `syncFinished`, `tasksFinished`), which replaced the seven `javaSupport.on…` assignments. `IDEProjectStatus` is the one shared status line, with clear-only-your-own-message semantics.
- **`IDEGradleProjectSystem`** (`Projects/IDEGradleProjectSystem.swift`) holds what was `IDEJavaSupport`'s Gradle half: trust gate, sync with the cached-model fast path, `runGradleTasks`, dependency graphs, the build-file watcher. The Gradle sidebar and the console tab are its `makeSidebar()` and `bottomTabs`, merged by `languageModuleToolWindows()` / `languageModuleBottomTabs()`; `IDEJavaModule` no longer lists them.
- **`IDEJavaSupport`** went from 1,531 to about 880 lines and is the Java index and provider container. It is the Gradle system's `IDEGradleModelConsumer` (held weakly): the system hands over every model it produces and the call that clears what came from it. `IDEJDKSelection` is created by `IDEIntelligenceServices` and shared by both.

**Lifecycle hooks (the deferral from phase 3).** `LanguageService` gained `@MainActor projectDidChange(root:)` and `filesDidChange(_:)`, **synchronous** and defaulted to no-ops, with `LanguageServiceRegistry` running them in registration order. They are not `async` like `start` and `stop`, because the window calls them from code that reads the result straight after (`applyProjectRoot` continues into the file tree, git, the picker; the next service decides from what the project system settled), and an `async` registry call would let those reads run first. A service with slow work starts a task and returns, as `IDEJavaSupport` does. Umbra's Java service is `IDEJavaLanguageService`, a wrapper over the library `JavaLanguageService` that forwards both hooks to `IDEJavaSupport` (the library has no host to forward to).
- `applyProjectRoot` calls `projectSystems.projectDidChange` first and `languages.projectDidChange` second. Java reads what Gradle settled: with a cached model it skips the whole-tree index (`isLoadingCachedModel`), and its compiler configuration waits on Gradle's model.

**Run providers.**
- **`IDERunProvider`** (`Run/IDERunProvider.swift`): `canRun`/`canDebug`/`runHelp`/`debugHelp` for the toolbar, `runnableLocations(in:)`, `run`, `runInContext`, `rerun`, `hasActiveWork`, `stop`, `projectTasksDidFinish`. A module returns one from `makeRunProvider(for:)`; `IDEWorkspace.runProviders` builds them once per window and `activeRunProvider` picks by the active document's language. The window's play, bug, Stop, Run in Context and "is something running" went generic (`runActiveFile`, `runInContext(debug:)`, `stopRunning`, `isRunActive`).
- **The process side is generic.** `IDEProcessLaunch` (the program, arguments, directory, environment, input file) replaces `JavaProcessLaunch` in `IDERunSession`; `IDERunRequest` and `IDERunSessions.start(_:replacing:)` hold the rule that a rerun takes the tab, stops the old process and waits for it. `IDERunSession` keeps a title, a provider id and an opaque payload. Java adds convenience initializers so existing callers and tests read the same.
- **`IDEJavaRunProvider`** (`Languages/IDEJavaRunProvider.swift`, `+Pipeline`, `+Tests`) is what was `IDEWorkspace+Run.swift` and the Run and Test parts of `IDEWorkspace`: derivation of the active file's launch, validation, before-launch steps, the build, the JDK, Gradle run and test tasks, Run in Context (`structureProvider.caretContext` is called here now), the ⌥↩ actions, and the compiler errors, test results and notification a finished task leaves. It reaches the window through `IDEJavaRunHost` only (weak). The debugger stays in the window and asks the provider for the launch, classpath, JDK and `launchEpoch`.
- **Done when**: `IDEWorkspace` has no `gradle.model` or `javaSupport.gradleModel` in run or test code. What still names a project system or `javaSupport` there is the Java intelligence wiring (diagnostics callbacks, `compileNow`, the name index), the Go to File module labels (`gradle.onModelChanged`), the console note for a launch that did not start, and `showsGradleConsoleTab`.

**Tests.**
- `IDEGradleProjectSystemTests` (21): a fake `gradlew` in a temporary project drives detection, the trust prompt (granted, declined, absent, auto-sync off), sync and its console, a failed sync, cancel, reload, the cached-model start, a root change, source roots, the task list, task runs (output, exit code, trust, busy, cancel), the build-file banner and the module graph. They were written against `IDEJavaSupport` first and passed there; moving the code changed only `GradleHarness`, the file that adapts the type under test.
- `IDEProjectAndRunProviderTests`: `IDEProjectSystems` and `IDERunProviders` with fakes (so a second language's system or provider is exercised through the public types), `IDERunSessions.start` (rerun takes the tab and waits, several instances, an explicit replacement), the generic launch, the Java provider's `canRun`, help strings and runnable places, the folder reaching Java through the registry, and that none of it retains the workspace (the same test fails with a strong `host`).
- `LanguageServiceRegistryTests`: the hooks run in order and are synchronous, and a service without them ignores them. `IDERunSessionTests`, `IDERunWorkspaceTests` (a real JDK), `IDEDiagramTabTests` and the retention tests pass unchanged.

**Differences from the sketch, and things found on the way.**
- **A crash in `FSEventsFileSystemWatcher`.** The new tests open a project and tear it down at once; the process crashed in `FSEventStreamStart`. `start()` and `stop()` are async and ran on different tasks over an unguarded `streamRef`, so `stop()` could release a stream `start()` was about to start. Both now take a lock, and a `stop()` that wins the race also prevents the late start and ends the event stream. This is a library change outside the move, made because a window closed right after opening a Gradle project could crash. The regression test (`testStoppingWhileStartingDoesNotCrash`) did not reproduce the crash on the old code on demand; the diagnosis rests on the crash report.
- **Trust is not a `ConsentTopic`.** Phase 3 said trust would go "through the environment". A consent topic is a string, and Gradle trust is per folder, so it travels through `IDEProjectEnvironment.requestTrust(url)` instead. The decompiler agreement stays a `ConsentTopic`.
- **Task creation order on open.** Java's whole-tree index and Gradle's first sync are both tasks started from `applyProjectRoot`; they were created Java-first and are now Gradle-first (the project systems run before the languages, which need their answer). Both start on the next main-actor turn. The one visible difference is a status line: the sync used to overwrite "Indexing project sources…" with "Resolving Gradle project…" a moment after it was set, and now the index finds the message already taken and leaves it alone, so the line a user sees is the same.
- **`IDEProjectSystem.tasks` is read by nothing yet.** The Gradle sidebar still builds its tree from the model. The property is tested and is what a palette "Run Project Task…" or another system's sidebar would use.
- **The process launch is built inside the request, not returned by a provider method.** What comes before a process (validation, before-launch steps, the build, picking a JDK) can fail, wait, or be stopped, and all of it reports into the session's console, so a provider supplies `IDERunRequest.prepare`, which ends in `session.start(IDEProcessLaunch)` or `session.fail(…)`. A `launch(for:) -> IDEProcessLaunch?` method would have had to carry the session and the progress anyway.
- **The gutter is still Java-typed.** `runnableLocations` is implemented and tested, but the gutter shares its column with breakpoints and `applyJavaGutter` reads `JavaMainMethodLocation` and `JavaTestClass`. Making the gutter generic needs the debugger's gutter split first.
- **Names that still say Java or Gradle**: the toolbar's parameters and the workspace flags that feed them (`javaFileCanRun`, `runActiveJava`), `IDEGradleReloadBanner`, the notification category `.gradle`, and the persisted `isGradleSidebarVisible` / `gradleSidebarWidth` (renaming them changes the session file). The menu item reads "Toggle Gradle Sidebar".
- **The configurations model is Java's.** `JavaRunConfiguration`, its picker and editor are unchanged; a second language gets its own, or the model generalizes when one needs it.
- `IDEGradleRunOutcome` and `GradleCommandResult` stay Gradle's: the agent's `gradle` and `run_tests` tools and the Java provider consume them. The generic outcome is `IDEProjectTaskReport`.

### Phase 6: proof
- (a) A grammar-only language that is not bundled yet (for example Ruby or PHP), added with its grammar target, a definition file and one registration line; the PR is the documentation.
- (b) Swift through `LSPLanguageService`, together with `docs/SWIFT_SOURCEKIT_LSP_PLAN.md` phases 1 to 4. Its "language-dispatching wrapper" is phase 1 here.
- **Done when:** both land without touching `IDEWorkspace`.

## Testing strategy

- **Conformance suite** every `LanguageService` runs: returns nothing for a foreign language; honours task cancellation; never blocks the main actor; `stop()` releases everything.
- **Dispatcher tests** per protocol, as in phase 1.
- **Retention test** per module that creates a workspace, starts and stops the module, and asserts the workspace deallocates (`IDERetentionGuardTests`).
- Tests that create a workspace set `IDEWorkspace.isSessionPersistenceEnabled = false`.
- Performance: `swift run -c release PerfHarness enter-session synthetic --lines 20000` and `--lines 120000` before and after phases 1 and 2. Release only; Debug timings are misleading.

## Risks

- **Phase 4 is long.** `IDEWorkspace` has 494 Java/Gradle references. Move per feature, with the existing tests as the net, and keep each PR to one feature.
- **`Codable` for `IDESidebarTab`** is a persisted format. Decode old raw strings, and test with a captured `last-window.json`.
- **Generic fallbacks must keep working** in comments and strings (completion) and for languages whose service returns nil. The policy and primary logic must be tested against that, not assumed.
- **Premature generality.** The tier-2 surface is large. Add a member only when the second language (HTTP, then Swift) uses it, and drop any that nothing uses by the end of phase 6.
- **Debugger coupling** (`JavaDebugSession`, `JavaBreakpointStore`, gutter code in `IDEWorkspace+Debugger.swift`) is untouched here; a second debuggable language needs its own plan.

## Out of scope

- Dynamic or third-party plugin loading.
- A DAP abstraction for debugging.
- Sharing language modules across windows beyond the existing shared services.
- Replacing the tree-sitter highlighting pipeline.

## Open questions

- Bundled languages: should each per-language target expose its own `LanguageDefinition` (identity plus grammar, e.g. `LanguageDefinition.rust` in `TreeSitterRustPenumbra`) and `PenumbraLanguages` just list them, removing the duplicate identity entry in `LanguageDefinition.builtIns`? It would make a bundled language one file, at the cost of `Penumbra` alone no longer detecting file types.
- Is a custom `Codable` for `IDESidebarTab` worth it, or does a `.contributed(id)` case suffice until a language needs a sidebar tab?
- Should the fallback policy be declared by the service (as sketched) or by the generic provider's own filter, given HTTP and Markdown have no service?

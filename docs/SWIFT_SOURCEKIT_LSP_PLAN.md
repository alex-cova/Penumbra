# SourceKit-LSP integration plan for Umbra

Status: proposal. Nothing here is implemented.

## Where Swift stands today

Swift is a syntax-highlighting-level language in Umbra; Java is a near-full IDE (`JavaIntelligence`).

- **Swift today:** bundled tree-sitter grammar plus a small SwiftUI overlay (`Sources/TreeSitterSwiftQueries/highlights-swiftui.scm`, hardcoded property-wrapper and view-type names). Indentation scopes, comment toggling and language configuration. The generic, name-based providers wired in `IDEIntelligenceServices.swift` (symbol/word completion, hover, go to definition, find references, duplicate-symbol diagnostics). No semantic highlighting, type-aware completion, compiler diagnostics, rename, hierarchy, project model, run/debug/test, formatter or previews.
- **Java today:** native indexing, type-aware completion and signature help, go to definition (JARs, decompiler), go to implementation, type/call hierarchy, find usages, rename and refactoring, `javac` diagnostics, Gradle project model, run configurations, JDI debugger, test runner, formatter, semantic highlighting and inlay hints.

## What exists and what's missing for LSP

- **Already there:** `Sources/EditorIntelligenceLSP/LanguageServerClient.swift` is an `LSPClient` on ChimeHQ's `InitializingServer`. It covers hover, completion, definition, references, implementation, type definition, rename, formatting, code actions, signature help and semantic tokens. `Sources/EditorIntelligence/LSP/` has `LSPCompletionProvider`, `LSPHoverProvider`, `LSPNavigationProviders`, `LSPDiagnosticProvider`, `LSPCodeActionProvider`, `LSPDocumentSyncService`, `LSPWorkspaceSyncBridge` and `SemanticTokenStorage`/`SemanticTokenMap`.
- **Not there:**
  - Umbra doesn't depend on `EditorIntelligenceLSP`, so nothing is linked.
  - Nothing launches a server process; the code assumes it is handed an `InitializingServer`.
  - `requestDiagnostics` returns `[]` ("most servers publish"), and nothing receives `textDocument/publishDiagnostics`. Swift diagnostics would be empty even with a server running.
  - No LSP result is applied through `TextView.setSemanticHighlights` (the decoder exists; whether anything feeds `SemanticTokenStorage` into it is unverified).

## Constraint from CLAUDE.md

`Penumbra` and `EditorIntelligence` must stay App Store–safe, and library targets must not use `Process`. `EditorIntelligenceLSP` should only take a ready transport. Process launch, toolchain discovery and consent live in Umbra, as Gradle and the JDK do today (`IDEJavaSupport`, `IDEJDKSelection`, `GradleTrustStore`).

## Phases

### 1. Toolchain discovery and consent (Umbra only)

- Add `IDESwiftSupport`, owned by `IDEIntelligenceServices` next to `javaSupport`.
- Add `IDESwiftToolchain`, which finds `sourcekit-lsp` in this order: a user-picked path, `xcrun --find sourcekit-lsp`, `/usr/bin`, the Xcode toolchain, swiftly-installed toolchains.
- Add a trust store modelled on `GradleTrustStore`, with a one-time per-project "Run SourceKit-LSP for this folder?" prompt.
- Add a "Swift" preference pane (like `IDEPreferencesJavaPane`) with a toolchain picker and an on/off switch. Default is off.
- **Sandbox risk to settle first.** A sandboxed child process inherits the sandbox. It can read the user-granted folder, but writing the index store and reading the Xcode toolchain may be blocked. Gradle already works under the same rule, so this probably works. A short spike (launch `sourcekit-lsp`, send `initialize`, request hover on a SwiftPM project) will confirm it. If it fails, the feature would be limited to unsandboxed builds.

### 2. Transport and lifecycle

- Spawn the server with `Process` and stdio pipes, then wrap it in ChimeHQ's `InitializingServer` / `JSONRPCServerConnection`.
- One server per window or project root; do not share across windows. This avoids the retention problems `IDEWorkspace.teardown()` already guards against.
- State machine like Gradle's `GradleSyncState`: `.off`, `.starting`, `.ready`, `.failed`, shown as a status bar item.
- Crash handling: restart with backoff. Kill the server in `teardown()`.
- Add a test that the workspace deallocates, like `IDERetentionGuardTests`.

### 3. Fix the LSP layer (the real code work)

- **Diagnostics:** subscribe to `publishDiagnostics` in `LanguageServerClient`; cache the latest set per URI and have `requestDiagnostics` return it. Add a result-handler push like `JavaCompilerDiagnosticsService.setResultHandler`, so the Problems panel updates without a keystroke. Use UTF-16 columns via `ProblemLocator`, as noted in `Sources/EditorIntelligence/CLAUDE.md`.
- **Document sync:** wire `LSPWorkspaceSyncBridge` to the Workspace so `didOpen` / `didChange` / `didClose` flow. Add `didSave` and `workspace/didChangeWatchedFiles`, since `Package.swift` edits and on-disk changes matter.
- **Capability negotiation:** read the server's `ServerCapabilities` and don't wire providers it doesn't support. Send `rootURI` / `workspaceFolders`.
- **Completion:** pass `triggerCharacter` and `triggerKind`, and honor `textEdit` / `additionalTextEdits` (auto-import). The current code passes `context: nil`.
- **Semantic tokens:** decode with the server's legend and paint through `TextView.setSemanticHighlights`. This gives SwiftUI property wrappers and types proper colors instead of the hardcoded name regex.
- **Rename:** the current mapping reads only `edit.changes`; SourceKit-LSP usually returns `documentChanges`, so handle both. Route through the existing `RenamePlan`, preview sheet and `IDEWorkspaceEditApplier`.

### 4. Wire into the engines (`IDEIntelligenceServices`)

- Add `LSPCompletionProvider` to `completionEngine`. Skip `SymbolCompletionProvider` and `WordCompletionProvider` for `swift` once the server is ready, the same way `skippingLanguages: ["java"]` works.
- Add LSP hover and navigation providers ahead of the generic ones, with `skippingLanguages: ["swift"]` on the fallbacks.
- Feed `signatureHelpProvider`, `codeActionProvider`, `renameProvider` and `formattingProvider` per language. Today these are single Java instances in `EditorIntelligenceServices`, so a small language-dispatching wrapper is needed. This is the one design decision with some weight.
- Add LSP diagnostics to `diagnosticEngine`. Keep `DuplicateSymbolDiagnosticProvider` off for Swift, since overloads cause false positives.
- Fall back to the current tree-sitter and symbol-index behavior while the server is `.starting` or `.failed`.

### 5. Project model and build

- **Detection:** `Package.swift` means SwiftPM; `.xcodeproj` / `.xcworkspace` means Xcode. `IDEProjectModel` already ignores `.build`, `DerivedData` and `.swiftpm` in the tree.
- **SwiftPM:** works with SourceKit-LSP directly; it builds the index store under `.build` on `swift build`.
- **Xcode projects:** SourceKit-LSP needs `xcode-build-server` or a BSP config. That is separate work; leave it out of the first release and say "SwiftPM only" in the UI.
- **Build and run:** run `swift build`, `swift test` and `swift run` through the console path Gradle uses (`IDEGradleConsoleLog`). Parse stderr for `file:line:col: error:` into Problems (the equivalent of `JavacOutputParser`). This gives diagnostics that match the real build even when the server lags.
- **Run gutter:** `@main` and `XCTest` / Swift Testing `@Test` gutter buttons, like the Java `main` and test gutter.

### 6. Later (separate efforts)

- Type and call hierarchy via LSP (`prepareTypeHierarchy`, `prepareCallHierarchy`), feeding the existing Hierarchy panels.
- Inlay hints (`textDocument/inlayHint`) via `TextView.inlayHints`.
- A debugger through `lldb-dap` (a different protocol from the JDI adapter).
- SwiftUI previews. Umbra can't host these and they need Xcode.

## Parity gaps (what the phases above do not cover)

The phases above give Swift the core LSP features. Full parity with Java in Umbra needs the items below. Sizes are rough: S is a few days, M about a week, L several weeks. They were not estimated against the code in detail.

### A. LSP surface and navigation UI (M)

- **Structure panel and breadcrumbs.** Add `textDocument/documentSymbol` to `LSPClient` and `LanguageServerClient`, then a Swift equivalent of `IDEJavaStructurePanel` / `JavaBreadcrumbProvider`.
- **Go to Class/Symbol palette and members palette.** Add `workspace/symbol` to `LSPClient`, then a Swift source for `IDEJavaClassesPaletteProvider` / `IDEJavaMembersPaletteSource`.
- **Go to Super Method.** LSP has no request for it. Needs a tree-sitter or index-based implementation.
- **Definition into SDK and dependency modules.** Verify that generated interfaces and `.build/checkouts` sources open correctly. Java has attached sources and a decompiler fallback; Swift has no equivalent yet.

### B. Editing features (M)

- **Generate…** (memberwise init, `Codable`, `Equatable`). Map SourceKit-LSP refactoring code actions onto the `CodeGenerationProviding` popover, or write a native `SwiftGenerateMembers` like `JavaGenerateMembers`.
- **Optimize Imports / unused imports.** SourceKit-LSP has no `source.organizeImports`. Needs a native, tree-sitter-based organizer like `JavaImportOrganizer`.
- **Inspections.** Decide on SwiftLint or swift-format lint as the source, then wire it into `diagnosticEngine` like `JavaInspectionService`.
- **Snippets and postfix templates.** Exclude the JavaScript-flavored built-ins for `swift` (as `excludedLanguageIdentifiers: ["java"]` does) and add Swift snippets and postfix templates.
- **Inlay hints.** `textDocument/inlayHint` through `TextView.inlayHints`, behind a preference (Java's is off by default).

### C. Project, run and test tooling (L)

- **Run configurations.** A `SwiftRunConfiguration` and store (executable target, arguments, environment) plus a toolbar picker, like `JavaRunConfigurationStore`.
- **Test runner and results.** XCTest and Swift Testing output parsing into `IDETestResultsPanel`, a test index, Rerun and Rerun Failed. The plan only has the gutter buttons.
- **Package tool window.** A SwiftPM equivalent of the Gradle panel: targets, products, dependencies, resolve and update.
- **Toolchain selection UI.** An equivalent of `IDEJDKSelection`: per-project and default toolchain, status bar item, Settings section. Phase 1 only covers discovery.
- **Project watcher.** Reindex and restart or resync on `Package.swift` / `Package.resolved` changes and on on-disk `.swift` changes.
- **Xcode projects.** BSP config or `xcode-build-server`. Excluded from the first release.

### D. Large, separate efforts (L each)

- **Debugger** via `lldb-dap`: breakpoints, stepping, variables, evaluate, and a new adapter plus Debug tool window plumbing. The Java debugger is JDI-based, so little of it carries over.
- **Type and call hierarchy** via LSP, feeding the existing Hierarchy panels.
- **Swift macros and build plugins.** Check how SourceKit-LSP and the build handle them.
- **SwiftUI previews.** Not feasible in Umbra.

### E. Quality and performance

- **Completion golden corpus** with a baseline ratchet, like `JavaCompletionCorpusTests` (`cases/*.swift` with a caret marker and expectations).
- **Release-latency benchmarks** for Swift completion, as `PerfHarness java-completion` does for Java.
- **Cold-start behavior.** SourceKit-LSP needs the index store built, which means a `swift build` first. Decide what the UI shows meanwhile (fallback to the generic providers, plus a progress or status message).

### Differences that parity cannot remove

- Java's engine is native, works on unsaved buffers and needs no external process. SourceKit-LSP depends on an external server, an index store and user consent, so latency and consistency will differ, especially at cold start.
- The per-language provider dispatch in Phase 4 is bigger than one decision: the Java providers are single instances wired into `EditorIntelligenceServices` (`formattingProvider`, `signatureHelpProvider`, `codeActionProvider`, `renameProvider`, `refactoringProvider`, `codeGenerationProvider`, `breadcrumbProvider`, `inlayHintProvider`), so several services change shape.
- Rename with `documentChanges`, semantic-token painting and `didSave` are listed in Phase 3 but are not verified against SourceKit-LSP's real behavior.

## Suggested order

1. Spike the sandbox and launch (small; decides everything).
2. Phases 1, 2 and 3: diagnostics, document sync and completion. Roughly a week, and yields working Swift completion, hover, go to definition and diagnostics.
3. Phase 4 wiring, then phase 5 SwiftPM build and run, then rename and semantic tokens.

## Tests

- `LanguageServerClient` against a scripted fake server (JSON-RPC over pipes), so CI doesn't need Xcode.
- A gated integration test that runs the real `sourcekit-lsp` against a small SwiftPM fixture when the binary is present.
- A `PerfHarness` check that LSP calls are scheduled from keystrokes and stale results are dropped, per `docs/PERFORMANCE_RULES.md`.

## First steps

The sandbox/launch spike and the `publishDiagnostics` fix in `LanguageServerClient`; the rest depends on both.

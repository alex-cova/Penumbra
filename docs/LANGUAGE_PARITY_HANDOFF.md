# Handoff: language parity (remaining work)

Read `docs/LANGUAGE_PARITY_PLAN.md` (the status block, then the original plan). Essential phases 0–7 are done, including the leftovers below. Do not redo finished work. Phases 8 and 9 are specified in `docs/PHASE_8_9_HANDOFF.md`. Phase 10 stays gated. Do not start the debugger abstraction before the lldb-dap spike in that handoff.

Decisions already made: TypeScript's semantic tier is LSP (typescript-language-server or vtsls driving the project's own tsserver). External servers are first-class. The App Sandbox spike stays in phase 10. Do not grow the native Swift or TypeScript engines into type checkers.

## Finished, leave it alone

- Tiered routers (`Sources/EditorIntelligence/Languages/TieredLanguageProviders.swift`). One provider per language. Completion yields the syntactic batch (`isFinished: false`) then replaces it with the semantic batch. Hover and navigation ask the top ready tier and fall back on nil. Diagnostics keep every ready tier. Readiness is the property `unavailableFeatures`, not `isReady(for:)`. No `replacesPrevious` flag.
- LSP capability gating, `completionItem/resolve`, call and type hierarchy on `LanguageServerClient`. Fake server: `Tests/PenumbraTests/LSPFakeServerTests.swift` (pipes, no Xcode, no Node).
- `IDELanguageServerHost` (`Example/Umbra/LanguageServers/`). SubprocessKit stdout is `.discard` (a 100 MB stream stays empty). Crash clears the connection and restarts with backoff. The workspace deallocates while a server is running.
- SourceKit-LSP and typescript-language-server are registered in `IDEIntelligenceServices` beside the native services. They stay unavailable until the folder is trusted **and** the host has installed a client.
- Native TypeScript claims `javascript` and indexes `.js`, `.jsx`, `.mjs`, `.cjs`. Generate writes Equatable and Hashable (`SwiftCodeGenerationProvider`).
- `LanguageServiceConformance` checks a foreign language, that the capability report skips unavailable features, that a cancelled request returns promptly and is not delivered, that `stop()` drops the environment (weak reference), and that request work stays off the main actor. The hooks are the exception.
- Swift organize imports (`SwiftImportOrganizer`, golden test in `SwiftImportOrganizerTests`). It sorts, drops duplicate lines, and groups `@testable` imports. It does not remove an import the file never spells.
- `.tsx` and `.jsx` highlight with `tree_sitter_tsx()` (`BundledLanguages.tsxHighlighting()`, chosen from the file URL in `IDELanguageSupport`). The identifier stays `typescript` or `javascript`.
- `enter-session` at 20k and 120k lines, measured against `20fad79` and recorded in `docs/EDITOR_PERF_PLAN.md`. Enter did not move.

## Landed in this effort

`LSPLanguageService` installs rename, signature help, code actions, semantic tokens, inlay hints, and both hierarchies (`LSPReadyProviders.swift`). A fake-server test renames and walks a call hierarchy through the service. A disconnected server leaves rename and call hierarchy on the native tier.

Trust: `IDELanguageServerHost.requestTrust`. The window wires it to `promptProjectTrust` and only asks when a window exists, so tests do not show a modal. Declining starts nothing. Settings ▸ Swift and Settings ▸ TypeScript set `umbra.languageServers.enabled`, `umbra.swift.sourcekitPath`, and `umbra.typescript.serverPath`.

npm facts (`IDENpmProjectFacts`): package manager from `packageManager` else the lockfile, workspace globs from `workspaces` or `pnpm-workspace.yaml`, vitest/jest, and tsconfig `baseUrl`/`paths`. `IDENpmProjectSystem` stores them and runs the chosen executable, falling back to npm when it is not on PATH.

`.tsx` and `.jsx` parse with `tree_sitter_tsx()` (`Sources/TreeSitterTypeScript/src/tsx/`, tree-sitter-typescript 0.20.2, the scanner header already matched). Other TypeScript and JavaScript files stay on `tree_sitter_typescript()`. `TypeScriptAnalysis.accepts` includes `javascript`.

Project claims: `IDEProjectClaim` and `IDEProjectSystem.claim(root:)`. The sidebar owner is the strongest claim, then registration order. `IDEProjectSystems.owner(of:)` is the deepest package root. A root claim beats a nested one. Gradle beside npm is unchanged while both claims are `.rootBuildFile`.

Phase 7 landed:

- `IDETestCaseResult` (`Example/Umbra/Run/IDETestCaseResult.swift`). `IDETestResultsStore.cases` stores it. `finishRun` maps `JavaTestCaseResult` through `init(_:)`.
- `go_to_definition` and `find_usages` take Java, Swift, TypeScript and JavaScript. The window uses `IDEEngineAgentNavigator` over `NavigationEngine`. `IDEJavaAgentNavigator` remains for the Java provider tests. `IDEAgentJavaNavigating` is a typealias of `IDEAgentNavigating`.
- `project_task` runs a task from the active project system when that system is not Gradle. `gradle` and `run_tests` are unchanged.
- Inlay and code-vision reads: `IDELanguageEditorPreferences`. Java still uses `com.umbra.editor.javaInlayHints` and the other Java keys. Swift and TypeScript use `com.umbra.editor.<language>.<name>` and do not inherit Java's values.
- npm `packages/*` (and a path with no wildcard) become nested `packageRoots`. `IDEProjectSystems.owner(of:)` returns the deepest one.

Native Swift and TypeScript engines stay the syntactic tier. Do not add a type checker.

## Out of scope unless the user asks

- Phase 8 and phase 9: `docs/PHASE_8_9_HANDOFF.md`.
- Phase 10: a Go or Rust module that is only an `IDELanguageServerDefinition`, and the sandbox spike.

## Traps

- In EditorIntelligence, a protocol method with a default is not dispatched on the existential. `tier`, `unavailableFeatures`, `cancellableRequest`, and `LSPConnectionBox.supportedFeatures` are properties and do dispatch.
- Do not name a new type `SyntaxTree` in a module that imports EditorIntelligence.
- `TextRange` in EditorIntelligenceLSP is `EditorIntelligence.TextRange`. `InlayHint` is `LanguageServerProtocol.InlayHint`.
- `*Intelligence` targets must not depend on Penumbra or SubprocessKit. Only Umbra spawns processes.
- Swift fixtures under `Tests/PenumbraTests/` are compiled unless excluded in `Package.swift`.
- Java call sites keep compiling against `JavaSyntaxParser`, `JavaSyntaxTree`, `JavaDocumentParseCache`, `JavaParseEdit`, and `SyntaxNode` via the aliases.
- The TypeScript completion baseline is the native `box.` completion on a 5000-line file: median 4.94 s, reparse 1.8 ms (`docs/EDITOR_PERF_PLAN.md`). Do not hide it.
- `caffeinate -u -d -i -s swift test` for the full suite. The display must stay on.

## Checks for the next change

```bash
swift test --filter 'SwiftImportOrganizerTests|testABasicServicePassesConformance|testADisconnectedServerLeavesTheNativeTierInFront|testTSX'
swift test --filter 'LanguageServiceRegistryTests|LSPLanguageServiceTests|LSPFakeServerTests|IDELanguageServerHostTests'
```

The full suite (`caffeinate -u -d -i -s swift test`) has not been run for this work.

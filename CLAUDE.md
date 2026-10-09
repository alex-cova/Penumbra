# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Penumbra is a Swift Package Manager library: a high-performance plain text/code editor engine for **macOS** (AppKit), forked from simonbs/Runestone (originally iOS/UIKit) and ported natively to macOS. It combines two layers:

- **`Penumbra`** — the text rendering/editing engine itself (line layout, gutter, tree-sitter syntax highlighting, selection, undo, search & replace).
- **`EditorIntelligence`** — a separate, editor-agnostic IDE-intelligence platform (completion, indexing, hover, navigation, diagnostics, refactoring, LSP/AI adapters) that has **no dependency on `Penumbra`**. The two are connected only through `Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`.
- **`JavaIntelligence`** — native Java indexing, completion, navigation, diagnostics, refactoring, with **no dependency on `Penumbra`**. Umbra wires it through `Example/Umbra/IDEJavaSupport.swift`. Details: `Sources/JavaIntelligence/CLAUDE.md`.
- **Adding a language** — how to add syntax, intelligence or IDE features today: `docs/ADDING_A_LANGUAGE.md`. Plan to replace the manual wiring with one registration (language definitions, a `LanguageService` router, Umbra language modules): `docs/LANGUAGE_SUPPORT_PLAN.md`.
- **HTTP client** — `.http` parsing and sending live in the Umbra target (`Example/Umbra/HTTP/`), not a library; JavaIntelligence does not depend on it.
- **`GitIntelligence`** (`Packages/GitIntelligence`) — its own Swift package wrapping the git CLI, depending only on `SubprocessKit`; Umbra wires it through `IDEGitStatus`.
- **`SubprocessKit`** (`Packages/SubprocessKit`) — the one place that spawns child processes (`posix_spawn` + pipes, no `Foundation.Process`), zero dependencies. `GitIntelligence`, `JavaIntelligence`, Umbra's agent command runner and AgentEval's `CheckRunner` run their children through it; `Penumbra`, `EditorIntelligence` and `AgentKit` never link it. Plan: `docs/SUBPROCESS_KIT_PLAN.md`. Details: `Packages/SubprocessKit/CLAUDE.md`.
- **`AgentKit`** (`Packages/AgentKit`) — the coding-agent harness core (LLM clients, loop, tools), pure Swift with no dependency on `Penumbra`; Umbra will wire it. Plan: `docs/AGENT_HARNESS_PLAN.md`. Details: `Packages/AgentKit/CLAUDE.md`, `Packages/AgentKitMLX/CLAUDE.md`.
- **`AgentKitMLX`** (`Packages/AgentKitMLX`) — on-device models for the agent: `LocalModelStore` (Hugging Face search, downloads, the installed-model catalog; Foundation only) and `AgentKitMLX` (MLX loading and the `LLMClient`). Only Umbra links it; `AgentKit` never does. Details: `Packages/AgentKitMLX/CLAUDE.md`.
- **Platform.** The root package targets **macOS 26** (tools 6.2) because the `Umbra` target depends on [DiagramKit](https://github.com/alex-cova/DiagramKit), which needs it; `Penumbra` and `EditorIntelligence` use no new API and gain nothing from it. The path packages under `Packages/` still declare macOS 14. `Example/Resources/Info.plist` (`LSMinimumSystemVersion`) and the Xcode project's deployment target follow the root package.
- **`Umbra`** (`Example/Umbra`) — the macOS editor app shipped with this repo, intended as a **Sublime Text alternative**, built on `Penumbra`, `EditorIntelligence` and `JavaIntelligence`. Every window is one project with its own `IDEWorkspace` (`IDEWindowRegistry` finds them; native tabs are merged windows). Every split in the app is a `SplitPanes` (`Example/Umbra/SplitView/`) — don't add `HSplitView`/`NSSplitView` or hand-rolled drag handles. Details: `Example/Umbra/CLAUDE.md`.

## App Store safety

**`Penumbra` must stay App Store–safe.** Umbra and other apps built on this framework are intended for Mac App Store distribution (Runestone ships the same engine on the App Store). Treat this as a hard constraint on every change to `Sources/Penumbra`, `Sources/EditorIntelligence`, and shared dependencies:

- **Public APIs only** — no private Apple SPI, no undocumented runtime hooks, no entitlement bypasses.
- **Sandbox-compatible** — do not assume disabled App Sandbox, arbitrary filesystem access, or elevated privileges. Use standard security-scoped bookmarks, open/save panels, and user-granted folder access patterns.
- **Hardened Runtime** — avoid JIT, dynamic code loading, or `NSTask`/`Process` usage inside the library targets; host apps may spawn tools (e.g. Gradle, JDK) only with explicit user consent and outside the core editor engine where possible.
- **Licensed dependencies** — vendored code must be App Store–compatible (see `THIRD_PARTY_NOTICES.md`). Do not add GPL or otherwise incompatible libraries to `Penumbra` itself.
- **Review-friendly behavior** — no hidden network calls, telemetry, or background activity from the framework; optional features (LSP, AI, Java sync) stay opt-in and clearly user-initiated in the host app.

When a feature cannot be implemented in an App Store–safe way inside `Penumbra`, keep it in the host app layer (`Example/Umbra`) or behind an explicit, user-controlled capability.

## Performance rules

**Read `docs/PERFORMANCE_RULES.md` before changing anything on the typing, layout, scrolling, rendering, selection, folding, highlighting or `LineManager` paths.** The short version:

- Work per keystroke, layout pass or scrolled frame is bounded by visible rows or edit size, never by document size.
- Read values with `lineID(atRow:)` / `lineInfo(atRow:)` / `location(ofRow:)`, not `line(atRow:)` handles; never `textView.text` on a hot path.
- Intelligence (completion, diagnostics, parsing, indexing) is scheduled from a keystroke, never awaited on it, and stale results are dropped.
- Caches stay bounded and are invalidated by row; moved lines keep their glyphs.
- Measure with `swift run -c release PerfHarness enter-session synthetic --lines 20000` (and 120000) on the parent commit and on the change; never draw conclusions from Debug timings.

## Feature reference

The feature catalog lives next to the code and loads when you work there:
- `Sources/Penumbra/CLAUDE.md` — `TextView` engine (editing, selection, keymap, layout, highlighting, folding, search, navigation, command palette).
- `Sources/EditorIntelligence/CLAUDE.md` — completion, hover, navigation, diagnostics, refactoring, LSP/AI, chrome.
- `Sources/Penumbra/Workbench/CLAUDE.md` — panes, tabs, session restoration.
- `Sources/JavaIntelligence/CLAUDE.md`, `Example/Umbra/CLAUDE.md`, `Packages/GitIntelligence/CLAUDE.md`, `Packages/AgentKit/CLAUDE.md`, `Tools/AgentEval/CLAUDE.md`.

## Common commands

```bash
swift run -c release PerfHarness enter-session synthetic --lines 20000  # Enter latency + line-handle growth
swift run AgentEval run --provider ollama --model <name> --trials 3     # agent eval: pass rate, turns, tokens (Tools/AgentEval/CLAUDE.md)
```

Performance work is measured in Release with `PerfHarness` (`Tools/PerfHarness`); `enter-session` opens a generated Java file with Umbra's defaults (folding, minimap, method separators, Metal) and reports Enter latency by caret position and `LineManager` handle counts (through `@_spi(Benchmarks) import Penumbra`). Plan, baselines and results: `docs/EDITOR_PERF_PLAN.md`. Debug-build timings are misleading for byte-scanning code.

There is no separate lint/format script wired into SPM; SwiftLint config lives at `.swiftlint.yml` (run `swiftlint` directly if installed). `swiftgen.yml` regenerates `Sources/Penumbra/Library/L10n.swift` from `Localizable.strings` — don't hand-edit that generated file.

**Umbra** is run with `swift run Umbra` or `Scripts/build-app.sh`; see `Example/Umbra/CLAUDE.md` for the Xcode project and layout notes.

## Architecture

### Two independent targets, one adapter

`EditorIntelligence` is intentionally decoupled from any specific text-editing UI. It defines its own `Document`, `Cursor`, `Selection`, `TextEdit`/`TextRange` types and talks to an editor only through the `EditorAdapter` protocol (`Sources/EditorIntelligence/Core/EditorAdapter.swift`): a stable `id`, a `context`, a `currentDocument`/`openDocuments` snapshot, an `AsyncStream<EditorEvent>` of edits/selection changes, and async `applyEdit`/`focusRange` methods.

`PenumbraEditorAdapter` (`Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`) is the concrete bridge: it becomes a `TextView`'s `editorDelegate`, caches a `Document` snapshot behind a lock so EIP services can read it off the main actor, and marshals edits/focus changes onto `MainActor` since they touch UI. When adding a new EIP feature, implement it against `EditorAdapter`/`Document`/etc. generically — don't reach into `Penumbra` types from `EditorIntelligence` code.

### Penumbra engine internals

- **`TextView/Core`** — `TextView.swift` (public AppKit view, ~1.5k lines) and `TextInputView.swift` (~1.8k lines, implements `NSTextInputClient`/keyboard-mouse handling) are the two central classes; most other `TextView/*` subfolders (Gutter, Highlight, Indent, InvisibleCharacters, Navigation, PageGuide, SearchAndReplace, TextSelection, CharacterPairs, LineController, Appearance) are focused collaborators they own.
- **`LineManager`** — maintains document lines as a red-black tree (`RedBlackTree/`) keyed by line position, so line lookups/edits are O(log n) rather than O(n) array operations. `DocumentLineChildrenUpdater` and `LineChangeSet` propagate edits through the tree. `line(atRow:)` returns a cached `DocumentLineNode` handle; handles nothing else references are released (`releaseUnreferencedHandles`, also run after layout evicts line controllers), a held handle keeps getting `row` updates, and a released one is recreated with the same ID. Every line insert/removal walks all live handles, so loops that only need an ID or position should use `lineID(atRow:)` / `lineInfo(atRow:)` / `location(ofRow:)` / `yPosition(ofRow:)` instead (a per-row handle walk in folding cost ~8 ms per keystroke). `LineControllerStorage` is bounded: layout evicts controllers far from the viewport (`LayoutManager.evictDistantLineControllers`), so code that reads a line's typesetting (fragments, caret rects) for a line that may be off-screen must lay it out on demand, as `LineMovementController.typesetLineController` does; a new or evicted controller reports "finished" with zero fragments until prepared.
- **`LanguageParser` + `TreeSitter`** — `TreeSitterLanguageParser`/`TreeSitterSyntaxTree` wrap the C tree-sitter library (`TreeSitter*.swift` files) to provide incremental AST parsing; `TreeSitterInternalLanguageMode` and `TreeSitterSyntaxHighlighter` consume the tree to drive syntax highlighting, while `PlainTextInternalLanguageMode`/`PlainTextSyntaxHighlighter` are the no-highlighting fallback. `TextViewState` lets a document + tree-sitter parse be prepared off the main thread before being handed to a `TextView`.
- **Threading rules** — a background parse reads the document through `StringView.bytes(in:)` while the main thread edits. Every `StringView` access to its storage must take its lock, reads included: piece-tree reads update lookup caches, and one unlocked read caused a use-after-free (`StringViewTests.testConcurrentByteReadsDuringEditsAndComposedCharacterQueries`). Main-thread code must not read a `TreeSitterLanguageLayer`'s `tree` directly, since a parse replaces it outside `parseLock`; use `TreeSitterInternalLanguageMode.rootSyntaxNode`, which returns a private `ts_tree_copy`. Check for races with `swift build --product PerfHarness --sanitize=thread --build-path .build-tsan` and then run `enter-session`.
- **`Library`** — cross-cutting helpers (byte/range conversions between UTF-16 and tree-sitter's UTF-8 byte offsets, string helpers, `EditorKit/` AppKit view/input abstractions with deprecated UIKit-shaped typealiases for API migration).
- **`PenumbraGraphQLLanguage`** — an example of the pattern for adding a tree-sitter language as its own SPM target: a `TreeSitterGraphQL` C target (grammar) + a Swift target providing `highlights.scm` and indentation scopes, depending on both `Penumbra` and the C grammar target. Follow this structure when adding another language.

### EditorIntelligence internals

- **`Core`** — `DependencyContainer` (service locator/wiring), `EventBus` (typed pub/sub used by adapters and engines), `EditorContext`/`EditorEvent`/`EditorTypes`/`Request` — the shared vocabulary every other module builds on.
- **`Indexing`** — `SymbolIndex` backed by a `Trie` for prefix lookups, updated incrementally by `IndexingService` as documents change.
- **`Completion`** — `CompletionEngine` runs a list of `CompletionProvider`s (symbol/word/snippet/LSP/AI) concurrently and ranks results (`Ranking/`); `CompletionContextFactory` builds the request context from adapter/document state.
- **`Snippets`** — tab-stop/placeholder snippet expansion engine, driven through `EditorChrome`'s `GhostTextModel`/`CompletionPanelModel`.
- **`Hover`**, **`Navigation`**, **`Diagnostics`**, **`Refactoring`** — each follows the same provider-engine pattern: an `*Engine` orchestrates one or more `*Provider`s (e.g. `DuplicateSymbolDiagnosticProvider`, `GoToDefinitionProvider`, `RenameProviding`) and returns typed results.
- **`AI`** and **`LSP`** — pluggable backends implementing the same provider protocols as native providers (`AICompletionProvider`, `LSPCompletionProvider`, etc.), so completion/hover/diagnostics can mix local, LSP, and AI sources transparently.
- **`EditorChrome`** — AppKit-facing presentation models (`CompletionPanelModel`, `HoverWindowModel`, `ParameterHintsModel`, `GhostTextModel`) that translate engine output into view state; actual AppKit views live back in `Penumbra/TextView`.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Penumbra is a Swift Package Manager library: a high-performance plain text/code editor engine for **macOS** (AppKit), forked from simonbs/Runestone (originally iOS/UIKit) and ported natively to macOS. It combines two layers:

- **`Penumbra`** — the text rendering/editing engine itself (line layout, gutter, tree-sitter syntax highlighting, selection, undo, search & replace).
- **`EditorIntelligence`** — a separate, editor-agnostic IDE-intelligence platform (completion, indexing, hover, navigation, diagnostics, refactoring, LSP/AI adapters) that has **no dependency on `Penumbra`**. The two are connected only through `Sources/Penumbra/EditorIntelligenceAdapter/PenumbraEditorAdapter.swift`: implement new EIP features against `EditorAdapter`/`Document`, and don't reach into `Penumbra` types from `EditorIntelligence` code.
- **`JavaIntelligence`** — native Java indexing, completion, navigation, diagnostics, refactoring, with **no dependency on `Penumbra`**. Umbra wires it through `Example/Umbra/IDEJavaSupport.swift` (the index), `Example/Umbra/Projects/IDEGradleProjectSystem.swift` and `IDEMavenProjectSystem.swift` (the Gradle and Maven models; Gradle wins when both are present) and `Example/Umbra/Languages/IDEJavaRunProvider.swift` (Run and Test). Details: `Sources/JavaIntelligence/CLAUDE.md`.
- **`HexKit`** — the hex editor's byte model, with **no dependency on `Penumbra` or AppKit**. Umbra's view is `Example/Umbra/HexEditor/`. Details: `Sources/HexKit/CLAUDE.md`.
- **Coverage and profiling** — Run with Coverage (JaCoCo, bundled by `Example/Umbra/Tools/JaCoCo/fetch.sh`) and Profile (Java Flight Recorder, read with the JDK's `jfr`): pure models in `Sources/JavaIntelligence/{Coverage,Profiling}`, UI in `Example/Umbra/{Coverage,Profiler}`.
- **AI mode** — a window mode in Umbra (Chat: any model, no project; Code: the agent in a project) that covers the editor like a chat app; details in `Example/Umbra/Agent/CLAUDE.md`.
- **Adding a language** — `docs/ADDING_A_LANGUAGE.md`.
- **HTTP client** — `.http` parsing and sending live in the Umbra target (`Example/Umbra/HTTP/`), not a library; JavaIntelligence does not depend on it.
- **`GitIntelligence`** (`Packages/GitIntelligence`) — its own Swift package wrapping the git CLI, depending only on `SubprocessKit`; Umbra wires it through `IDEGitStatus`.
- **`SubprocessKit`** (`Packages/SubprocessKit`) — the one place that spawns child processes (`posix_spawn` + pipes, no `Foundation.Process`), zero dependencies. `GitIntelligence`, `JavaIntelligence`, Umbra's agent command runner and AgentEval's `CheckRunner` run their children through it; `Penumbra`, `EditorIntelligence` and `AgentKit` never link it. Details: `Packages/SubprocessKit/CLAUDE.md`.
- **`AgentKit`** (`Packages/AgentKit`) — the coding-agent harness core (LLM clients, loop, tools), pure Swift with no dependency on `Penumbra`; Umbra will wire it. Details: `Packages/AgentKit/CLAUDE.md`.
- **`AgentKitMLX`** (`Packages/AgentKitMLX`) — on-device models for the agent (model store and MLX `LLMClient`). Only Umbra links it; `AgentKit` never does. Details: `Packages/AgentKitMLX/CLAUDE.md`.
- **`AgentKitApple`** (`Packages/AgentKitApple`) — Apple's foundation model (Apple Intelligence, on device) and Private Cloud Compute (macOS 27) as an `LLMClient`, with a bridge that lets AgentKit's loop approve and run the tools the framework would otherwise run itself. Only Umbra and AgentEval link it. Details: `Packages/AgentKitApple/CLAUDE.md`.
- **Platform.** The root package targets **macOS 26** (tools 6.2) because the `Umbra` target depends on [DiagramKit](https://github.com/alex-cova/DiagramKit), which needs it; `Penumbra` and `EditorIntelligence` use no new API and gain nothing from it. The path packages under `Packages/` still declare macOS 14. `Example/Resources/Info.plist` (`LSMinimumSystemVersion`) and the Xcode project's deployment target follow the root package.
- **`Umbra`** (`Example/Umbra`) — the macOS editor app shipped with this repo, intended as a **Sublime Text alternative**, built on `Penumbra`, `EditorIntelligence` and `JavaIntelligence`. Rules for working in it (windows, `SplitPanes`, the one file watcher) load from `Example/Umbra/CLAUDE.md`.

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

## Common commands

```bash
swift run -c release PerfHarness enter-session synthetic --lines 20000  # Enter latency + line-handle growth
caffeinate -u -d -i -s swift test                                      # the full suite needs a live display (see below)
```

**Run the full test suite with the display on.** Many tests drive AppKit views, wait a few seconds for background parses, and use animations. With the display off or the Mac idle-sleeping (a long run after you step away), parse waits time out in bulk (`MarkdownLanguageTests`, `TextViewStateParsePolicyTests`, `IncrementalHighlightConsistencyTests`…), blocked `NSAnimation` threads pile up, and the test process can hang or trap. `caffeinate -u -d -i -s swift test` turns the display on and keeps it and the system awake for the run. A failure that passes alone and appears only after the machine slept is this, not the change.

`PerfHarness` (`Tools/PerfHarness`) `enter-session` opens a generated Java file with Umbra's defaults (folding, minimap, method separators, Metal) and reports Enter latency by caret position and `LineManager` handle counts (through `@_spi(Benchmarks) import Penumbra`).

`swiftgen.yml` regenerates `Sources/Penumbra/Library/L10n.swift` from `Localizable.strings` — don't hand-edit that generated file.

**Umbra** is run with `swift run Umbra` or `Scripts/build-app.sh`; see `Example/Umbra/CLAUDE.md` for the Xcode project and layout notes.

## Architecture

Engine internals that matter when editing `Sources/Penumbra` (`LineManager` handles and eviction, threading rules for background parses, the language-target pattern) live in `Sources/Penumbra/CLAUDE.md` and load when you work there.

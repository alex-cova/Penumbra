# Penumbra

**Repository:** [github.com/alex-cova/Penumbra](https://github.com/alex-cova/Penumbra) · **Website:** [alex-cova.github.io/Penumbra](https://alex-cova.github.io/Penumbra)

This monorepo ships **Umbra**, a fast macOS code editor with a built-in coding agent, and **Penumbra**, the AppKit text engine and IDE-intelligence libraries underneath it. Use Umbra as your daily editor; embed Penumbra when you are building your own macOS editing surface.

| | |
| --- | --- |
| **Try the app** | [Download Umbra](https://github.com/alex-cova/Penumbra/releases) · `swift run Umbra` |
| **Use the framework** | [Installation](#installation) · [Quick start](#quick-start) |

---

## Table of contents

1. [Umbra — editor & AI harness](#umbra--editor--ai-harness)
2. [Penumbra — framework & libraries](#penumbra--framework--libraries)

---

# Umbra — editor & AI harness

**Umbra** is the macOS app in this repo: a **Sublime Text–style** editor that stays light, opens real project folders, and ships a **full coding-agent harness** beside your buffers—not a webview bolt-on.

Open a folder, edit with tree-sitter highlighting and multi-cursor power, run and debug Java (and more), review git diffs in-editor, and pair with an agent that can read the tree, edit files with approval, run Gradle, and revert whole runs when you change your mind.

### Screenshots

| Java editing | Class diagram blueprint |
| :---: | :---: |
| ![Umbra editing a Java file with syntax highlighting, minimap, and project explorer](Screenshots/editor.png) | ![Umbra Java class diagram blueprint view](Screenshots/diagram.png) |

### Why developers pick Umbra

- **Fast editing first** — Metal rendering, mmap-backed large files, minimap, folding, column selection, and a Sublime-style keymap out of the box.
- **Project-native** — Explorer, split panes, session restore, command palette, Problems panel, and git workflow (stage, commit, diff tabs, local history) without leaving the app.
- **Java & Gradle without a JVM IDE** — Sync, completion, inspections, run configurations, test gutter, JDI debugger, class and dependency diagrams when you need depth—not for every buffer.
- **Agent that respects the repo** — Plan mode, per-edit approval, permission rules (`AGENTS.md`, `.umbra/settings.json`), checkpoints with revert, rewind/fork, `@file` mentions, and tools wired to your real workspace (including unsaved buffers).
- **Your models** — OpenAI-compatible APIs, Ollama on localhost, or on-device models via MLX; keys in Keychain; explicit consent before data leaves the Mac.

### Editing & workbench

- Tree-sitter highlighting for Swift, Java, JS/TS, Python, JSON, YAML, HTML, Markdown, HTTP, and more
- Multi-cursor, semantic selection, find/replace with regex, sticky scroll, inlay hints, and code vision (optional)
- Horizontal/vertical splits, tabs, multiple windows (one project each), native tab merging
- Hex editor for binary files; CSV table preview; Markdown/JSON diagram preview
- Built-in `.http` client with variables, cookies, and response history
- Text tools (encode/decode, JSON format, case transforms, JWT decode, hashes) from the palette or context menu

### Project intelligence

- Symbol index completion, hover, go to definition, find usages, rename with preview
- LSP-ready stack in the libraries; Umbra emphasizes native Java, TypeScript, and Swift intelligence where bundled
- Diff viewer with stage/unstage hunks; change markers in the gutter; UML and Gradle dependency diagrams
- Integrated terminal, run tool window, and debug UI (Java JDI, Swift/JS via DAP)

### Coding agent (AgentKit)

Dock the chat beside the editor or expand it full-width. The agent can:

- **Explore** — `read_file`, `list_dir`, `glob`, `grep` (respecting git-visible files), `git_status` / `git_diff`, diagnostics
- **Change code** — `edit_file` / `write_file` with diffs, undo-friendly application to open tabs, and **Revert run** from checkpoint blobs
- **Execute** — Shell commands (with approval), Gradle and test tasks in Gradle projects, optional web search (Brave API)
- **Stay in control** — Permission modes (plan / ask / auto), slash commands and project skills, queued messages, context meter and `/compact`, conversation history and export

Project instructions load from `AGENTS.md` (or `CLAUDE.md`, `.cursorrules`) at the root and nested folders. See `docs/AGENT_HARNESS_PLAN.md` and `Packages/AgentKit/CLAUDE.md` for harness design.

### Get Umbra

**Download:** [GitHub Releases](https://github.com/alex-cova/Penumbra/releases) — `Umbra-<version>-macOS.zip`. Signing, notarization, and Sparkle updates: [Example/README.md](Example/README.md).

**From source:**

```bash
swift run Umbra              # debug
swift run Umbra --no-metal   # Core Graphics renderer (Metal is the default)
./Scripts/build-app.sh       # release app bundle
```

**Requirements:** macOS 14+ (Sonoma). Release builds target macOS 26 where DiagramKit requires it; see [Requirements](#requirements).

More shortcuts and day-to-day usage: [Example/README.md](Example/README.md).

---

# Penumbra — framework & libraries

**Penumbra** is a high-performance plain-text and code **editor framework for macOS (AppKit)**. It extends the [Runestone](https://github.com/simonbs/Runestone) lineage (originally iOS/UIKit) with native macOS porting, **Metal** glyph rendering, **piece-tree** storage for large files, a multi-pane **workbench**, and the **Editor Intelligence Platform (EIP)**—completion, tree-sitter parsing, indexing, navigation, diagnostics, refactoring, and LSP/AI hooks.

Umbra is the reference app; **Penumbra stays App Store–safe** (public APIs, sandbox-compatible patterns, no `Process` in library targets). Host apps spawn tools (Gradle, agents) at the app layer.

### What's in the package

| Module | Role |
| --- | --- |
| **Penumbra** | `TextView` engine, gutter, themes, folding, minimap, workbench, EditorChrome views |
| **EditorIntelligence** | Editor-agnostic EIP: completion, hover, navigation, diagnostics, snippets, workspace |
| **EditorIntelligenceLSP** | LSP client (ChimeHQ LanguageClient) |
| **PenumbraLanguages** + grammar targets | Tree-sitter factories for common languages |
| **JavaIntelligence** | Native Java index, completion, Gradle model (no Penumbra dependency) |
| **HexKit** | Hex editor byte model (used by Umbra) |
| **AgentKit** / **AgentKitMLX** | Agent loop and tools; MLX local models (Umbra-only wiring) |
| **GitIntelligence** / **SubprocessKit** | Git CLI and child-process spawning |

The engine and EIP connect only through `PenumbraEditorAdapter` (`EditorAdapter` protocol, `AsyncStream<EditorEvent>`).

### Key features

#### Text editor engine (`Penumbra`)

* **macOS-native AppKit** — `NSTextInputClient`, IME, smooth scrolling, configurable `Keymap` (`.default_`, `.sublime`, `.intelliJ`).
* **Metal rendering** — GPU glyphs via `TextView.isMetalRenderingEnabled` (on by default); Core Graphics fallback when Metal is unavailable or disabled.
* **Large files** — mmap-backed `PieceTree` for buffers over 256 KB and `TextViewState.load`.
* **Multi-cursor & column selection** — Option-click carets, occurrence selection, block selection, sticky column mode, semantic expand/shrink, synchronized typing and undo.
* **Tree-sitter highlighting** — Incremental, async, with language injection (e.g. CSS/JS in HTML).
* **Folding, minimap, focus mode, typewriter scrolling** — Ribbons, viewport overview, dimming, caret anchoring.
* **Editing** — Character pairs, smart indent, line/statement moves, surround-with, timed undo coalescing.
* **Gutter & display** — Line numbers, page guide, invisibles, `Theme` / `DefaultTheme`.
* **Search & replace** — `SearchQuery`, regex captures, batch replace, find panel.
* **Background prep** — `TextViewState` parses off the main thread.
* **Diagnostics & navigation history** — Squiggles, bounded back/forward (⌘[ / ⌘]).

#### Editor Intelligence Platform (`EditorIntelligence`)

* **Decoupled** — `EditorAdapter`, symbol `Trie` index, concurrent `CompletionEngine` with ranking.
* **Providers** — Symbols, words, snippets, LSP, AI; ghost text; multi-cursor apply.
* **Hover, navigation, outline, breadcrumbs** — Definition, references, implementations, rename.
* **Diagnostics & refactoring** — Built-in analyzers + LSP aggregation.
* **Workspace** — Multi-document actor, cross-file search, file watching.

#### LSP (`EditorIntelligenceLSP`)

Document sync, completion, hover, definition, references, rename, formatting, code actions, signature help, semantic tokens (ChimeHQ stack).

#### Workbench & chrome

Split layouts, tab groups (preview/pinned), session restoration, command palette (Search Everywhere), and AppKit views: completion panel, hover, ghost text, parameter hints, breadcrumbs, outline, code actions, workspace search.

#### Language packs

`PenumbraLanguages` (CSS, HTML, JS, JSON, Python, TypeScript, YAML, TOML, SQL, Swift, Java, Kotlin, Go, Bash, HTTP, Mermaid, …), plus dedicated GraphQL and Markdown packages. Attributions: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Architecture

```
Penumbra/
├── Sources/
│   ├── Penumbra/                  # TextView, Workbench, EditorChrome, Tree-sitter wrapper
│   ├── EditorIntelligence/        # EIP (no Penumbra dependency)
│   ├── JavaIntelligence/          # Java index & Gradle integration
│   ├── EditorIntelligenceLSP/
│   ├── PenumbraLanguages/         # TreeSitterLanguage factories
│   └── …                          # Per-language TreeSitter C/Swift targets
├── Example/Umbra/                 # Reference macOS app
├── Packages/                      # TreeSitter, AgentKit, GitIntelligence, SubprocessKit, …
├── Tools/PerfHarness/             # Release performance CLI
└── Tests/PenumbraTests/           # 1,050+ tests
```

Deeper internals: [CLAUDE.md](CLAUDE.md), [Sources/Penumbra/CLAUDE.md](Sources/Penumbra/CLAUDE.md), [Sources/EditorIntelligence/CLAUDE.md](Sources/EditorIntelligence/CLAUDE.md).

### Requirements

* **macOS:** 14.0 (Sonoma) or later for libraries; Umbra release line follows macOS 26 where required by DiagramKit
* **Swift:** 6.2+ / Xcode 26+ for the root package (Swift 6 language mode)
* **Dependencies:** vendored [Tree-sitter](https://github.com/tree-sitter/tree-sitter), [ChimeHQ/LanguageClient](https://github.com/ChimeHQ/LanguageClient), [TextFormation](https://github.com/ChimeHQ/TextFormation), and related ChimeHQ packages (see `Package.swift`)

### Installation

Add Penumbra to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/alex-cova/Penumbra.git", branch: "main")
]
```

```swift
.target(
    name: "YourAppTarget",
    dependencies: [
        .product(name: "Penumbra", package: "Penumbra"),
        .product(name: "EditorIntelligence", package: "Penumbra"),
        .product(name: "EditorIntelligenceLSP", package: "Penumbra"),       // optional
        .product(name: "PenumbraLanguages", package: "Penumbra"),             // optional
        .product(name: "PenumbraGraphQLLanguage", package: "Penumbra"),      // optional
        .product(name: "PenumbraMarkdownLanguage", package: "Penumbra")     // optional
    ]
)
```

### Quick start

#### Basic `TextView`

```swift
import AppKit
import Penumbra

class EditorViewController: NSViewController {
    private var textView: TextView!

    override func loadView() {
        textView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.isLineWrappingEnabled = true
        textView.showMinimap = true
        textView.isLineFoldingEnabled = true
        textView.isMetalRenderingEnabled = true
        textView.text = """
        // Welcome to Penumbra on macOS!
        func greet(name: String) {
            print("Hello, \(name)!")
        }
        """
        self.view = textView
    }
}
```

#### Async state with Tree-sitter

```swift
import Penumbra
import PenumbraLanguages

let jsLanguage = TreeSitterLanguage.javaScript

DispatchQueue.global(qos: .userInitiated).async {
    let state = TextViewState(
        text: largeJavaScriptCodeString,
        theme: DefaultTheme(),
        language: jsLanguage
    )
    DispatchQueue.main.async { textView.setState(state) }
}

// Or load from disk (mmap piece tree):
let state = try await TextViewState.load(
    contentsOf: fileURL,
    theme: DefaultTheme(),
    language: TreeSitterLanguage.swift
)
textView.setState(state)
```

#### Multi-cursor

```swift
textView.selectNextOccurrence()      // ⌘⇧D
textView.selectAllOccurrences()      // ⌘⇧L
textView.addCaretAbove()             // ⌥⌘↑
textView.duplicateSelectedLines()    // ⌘D
```

#### Editor intelligence controller

```swift
import Penumbra
import EditorIntelligence

let symbolIndex = SymbolIndex()
let intelligenceController = EditorIntelligenceController(
    textView: textView,
    completionEngine: CompletionEngine(providers: [
        SymbolCompletionProvider(index: symbolIndex),
        WordCompletionProvider(),
        SnippetCompletionProvider(snippets: mySnippets)
    ]),
    hoverEngine: HoverEngine(providers: [SymbolHoverProvider(index: symbolIndex)]),
    diagnosticEngine: DiagnosticEngine(providers: [DuplicateSymbolDiagnosticProvider()]),
    services: EditorIntelligenceServices(symbolIndex: symbolIndex)
)
```

#### Workbench

```swift
let workbench = EditorWorkbench()
workbench.openDocument(WorkbenchDocument(displayName: "main.swift", text: "print(\"Hello\")"))
let rightPane = workbench.splitActivePane(edge: .trailing)
let state = workbench.makeRestorationState()
```

### Keyboard shortcuts (`.default_` keymap)

Umbra defaults to **`.sublime`**. Three presets ship: `.default_`, `.sublime`, `.intelliJ`. Bindings map to `EditorActionID` and `textView.perform(_:)`.

| Shortcut | Action |
| :--- | :--- |
| **⌥ + Click** | Add caret |
| **⌘⇧D** / **⌘⇧L** | Next occurrence / all occurrences |
| **⌥ + Drag** / **⌃⇧ arrows** | Column selection |
| **⌘L** / **⌘D** / **⌘⌫** | Select / duplicate / delete line(s) |
| **⌘F** | Find / replace panel |
| **⌃Space** | Completion (with intelligence controller) |
| **⌘ + Click** | Go to definition |
| **⌘[ / ⌘]** | Navigation history |

#### `.intelliJ` keymap (differences from `.default_`)

| Shortcut | Action |
| :--- | :--- |
| **⇧⇧** / **⌘⇧A** | Search Everywhere / Find Action |
| **⌘E** | Recent files |
| **⌥↑ / ⌥↓** | Extend / shrink selection by syntax node |
| **⌘⇧↑ / ⌘⇧↓** | Move statement up / down |
| **⌘⇧8** | Toggle column selection mode |
| **⌥⌘T** | Surround with… |
| **⌥⌘L** | Reformat code (LSP or fallback) |
| **⌘B** / **⌥⌘B** | Go to definition / implementation |

Palette and LSP actions need `CommandPaletteController` and `EditorIntelligenceController` attached to the text view.

### Development

```bash
swift build
swift test                               # full suite (display on; see CLAUDE.md)
swift test --filter ClassName
swift run -c release PerfHarness enter-session synthetic --lines 20000
swift run PerfHarness --help
```

Performance rules: [docs/PERFORMANCE_RULES.md](docs/PERFORMANCE_RULES.md). SwiftLint: `.swiftlint.yml`.

### Testing

1,050+ unit and integration tests across line management, multi-cursor editing, tree-sitter, Metal, completion, workbench, LSP bridges, and more.

### License

Apache License 2.0 — see [LICENSE](LICENSE).

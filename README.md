# Runestone

A high-performance, feature-rich plain text and code editor framework for **macOS** with integrated IDE intelligence services, Language Server Protocol (LSP) support, and a multi-pane workbench layout system.

Based on [simonbs/Runestone](https://github.com/simonbs/Runestone) (originally for iOS/UIKit), this repository is natively ported and extended for **macOS (AppKit)**. It pairs a high-performance text rendering engine with the **Editor Intelligence Platform (EIP)** for code completion, tree-sitter AST parsing, indexing, navigation, hover documentation, diagnostics, refactoring, and AI/LSP integrations.

---

## Key Features

### 🎨 Native Text Editor Engine (`Runestone`)
* **macOS-Native AppKit Design**: Built with native text input handling (`NSTextInputClient` / `UITextInput`), full IME and accented character support, smooth scrolling, and customizable keybindings (`keyDownHandler`).
* **Multi-Cursor & Column Selection**:
  * **Multiple Carets**: Place carets with Option-click, clone carets vertically (⌥⌘↑ / ⌥⌘↓), or undo caret additions (⌘U).
  * **Occurrence Selection**: Select next occurrence (⌘⇧D), skip occurrence (⌘K ⌘D), or select all occurrences (⌘⇧L).
  * **Column / Block Selection**: Rectangular selection via Option-drag or ⌃⇧-arrow keys.
  * **Multi-Caret Operations**: Synchronized typing, multi-caret copy/cut/paste, line shifting, indent/outdent, and full caret set undo/redo restoration.
* **Tree-sitter Syntax Highlighting**: Fast, asynchronous incremental syntax highlighting with language layers and injected languages (e.g. JavaScript/CSS in HTML).
* **Code Folding**: Indentation-based fold ribbons and Tree-sitter AST-based folding (`isLineFoldingEnabled`, `TreeSitterLineFoldProvider`).
* **Minimap**: Trailing miniature document overview with real-time viewport indicator and interactive click/drag scrolling (`showMinimap`).
* **Focus Mode & Typewriter Scrolling**:
  * **Focus Mode**: Keeps active sentence or paragraph at full opacity while dimming surrounding text (`isFocusModeEnabled`).
  * **Typewriter Scrolling**: Keeps the active line pinned at a configurable vertical fraction of the viewport (`isTypewriterScrollingEnabled`, `typewriterAnchorFraction`; requires `isAutomaticScrollEnabled`). The document scrolls beneath the caret as you type or move lines. Manual scrolling suspends anchoring until the next key press.
* **Editing & Formatting**:
  * **TextFormation Integration**: Auto-closing bracket/character pairs (`CharacterPair`), skip-over closing delimiters, tab expansion, and whitespace cleanup.
  * **Smart Indentation**: Language-aware indent on newline, block indent/unindent (shift left/right), and automatic indentation strategy detection (tabs vs. spaces).
  * **Line Manipulation**: Select (⌘L), duplicate (⌘D), delete (⌘⌫), and move selected lines up/down (⌥↑ / ⌥↓).
  * **Timed Undo Coalescing**: `TimedUndoManager` groups rapid typing into single undo steps.
* **Gutter & Display Customization**: Dynamic-width line numbers, line selection highlights, page guide columns, invisible character rendering (spaces, tabs, line breaks), and custom themes (`Theme`, `DefaultTheme`).
* **Search & Replace**: Programmatic search API (`SearchQuery`) supporting plain text, full-word, and regular expressions with capture groups (`$0`, `$1`), batch replacement, built-in find/replace panel, and system `UIFindInteraction` integration.
* **Background Preparation**: Use `TextViewState` to parse ASTs, tokenize syntax, and prepare layout off the main thread for instant loading of large files.
* **Diagnostic Overlays**: Squiggly underline rendering for warnings, errors, and hints (`TextViewDiagnostic`, `DiagnosticEmphasisController`).

### 🧠 Editor Intelligence Platform (`EditorIntelligence`)
* **Decoupled Architecture**: Completely editor-agnostic platform connected via the `EditorAdapter` protocol and asynchronous event streams (`AsyncStream<EditorEvent>`).
* **Incremental Tree-sitter Parsing**: Asynchronous AST parsing (`TreeSitterLanguageParser`) with document state tracking.
* **Symbol Indexing**: Trie-backed incremental `SymbolIndex` and `IndexingService` for fast identifier lookups and workspace symbol search.
* **Async Code Completion Engine**:
  * Concurrent multi-provider completion engine (`CompletionEngine`) with intelligent ranking (`DefaultRanker`).
  * Built-in providers: Local symbol index (`SymbolCompletionProvider`), in-buffer words (`WordCompletionProvider`), snippets (`SnippetCompletionProvider`), LSP (`LSPCompletionProvider`), and AI models (`AICompletionProvider`).
  * Inline Ghost Text preview (`GhostTextModel`, `GhostTextView`).
  * Multi-cursor completion application (`replaceAtAllSelections`).
* **Interactive Snippet Engine**: Full TextMate-style snippet parsing with tab stops, default placeholders, and variable transformations (`SnippetEngine`, `SnippetExpander`).
* **Hover & Documentation**: Cached `HoverEngine` providing rich markdown tooltips from symbols (`SymbolHoverProvider`), LSP servers (`LSPHoverProvider`), and AI models (`AIHoverProvider`).
* **Code Navigation**: Go to Definition (`GoToDefinitionProvider`, `JumpToDefinitionController`, ⌘-click), Find References (`FindReferencesProvider`), and breadcrumb navigation.
* **Hierarchical Outlines & Breadcrumbs**: `OutlineBuilder` symbol trees and `BreadcrumbBarModel` tracking enclosing symbols at the cursor.
* **Diagnostics Engine**: Problem reporting and severity tracking with built-in analyzers (e.g. duplicate symbol detection) and LSP diagnostic aggregation.
* **Refactoring Framework**: AST-guided and LSP-powered symbol rename operations (`RefactoringEngine`, `RenameOperation`).
* **AI Integration**: Modular `AITextModel` protocol for custom LLM-powered completions and hover documentation.
* **Workspace Management**: `Workspace` actor managing multi-document project state, cross-file search (`WorkspaceSearchEngine`), and file system change monitoring.

### 🔌 Language Server Protocol (`EditorIntelligenceLSP`)
* **ChimeHQ Integration**: Built on top of `LanguageClient` and `LanguageServerProtocol`.
* **Document & Workspace Synchronization**: Real-time document lifecycle sync (`LSPDocumentSyncService`) and workspace sync bridge (`LSPWorkspaceSyncBridge`).
* **LSP Features**: Code completions, hover documentation, Go to Definition, Find References, and symbol rename.
* **Document & Selection Formatting**: Document and selection formatting (`LSPFormattingProvider`) with multi-caret preservation.
* **Code Actions**: Quick fixes and refactorings (`LSPCodeActionProvider`, `CodeActionView`).
* **Signature Help**: Parameter hints auto-triggered on `(` and `,` (`LSPSignatureHelpProvider`, `ParameterHintsView`).
* **Semantic Token Highlighting**: Semantic token decoding and delta synchronization for enhanced syntax highlighting.

### 🪟 Multi-Pane Workbench (`Runestone/Workbench`)
* **Split Editor Layouts**: Horizontal and vertical split-pane layouts (`EditorWorkbench`, `EditorLayout`, `EditorPane`).
* **Tab Management**: Per-pane tab groups with preview (transient) tabs, pinned tabs, and tab navigation history (`EditorTabHistory`, `TabListEngine`).
* **Session Restoration**: Codable layout and document snapshots for persistent editor sessions (`EditorRestorationState`).
* **Workspace Integration**: `RunestoneWorkbenchWorkspaceBridge` syncing open workbench documents directly into EIP `Workspace`.

### 🖥️ Ready-to-Use AppKit Views (`Runestone/UIBridge`)
* `CompletionPanelView`: Floating code completion panel with keyboard navigation.
* `HoverWindowView`: Rich markdown hover tooltip popover.
* `GhostTextView`: Inline ghost text completion preview.
* `ParameterHintsView`: Parameter hints and signature help popup.
* `BreadcrumbBarView`: Hierarchical symbol breadcrumb bar.
* `OutlineSidebarView`: Document symbol outline sidebar.
* `CodeActionView`: Quick-fix code action menu.
* `WorkspaceSearchPanelView`: Multi-file workspace search panel.
* `EditorIntelligenceController`: Unified controller coordinating all intelligence services and UI with `TextView`.

### 📦 Language Packs
* **`RunestoneLanguages`**: Ready-to-use `TreeSitterLanguage` factories for CSS, HTML, JavaScript, JSON, Python, TypeScript, YAML, plus TOML, SQL, Swift, Java, Kotlin, Go, and Bash. Re-exports GraphQL from `RunestoneGraphQLLanguage`.
* **`RunestoneGraphQLLanguage`**: Ready-to-use Tree-sitter GraphQL grammar, highlight queries, and indentation scopes.
* **`RunestoneMarkdownLanguage`**: Ready-to-use Tree-sitter Markdown grammar, highlight queries, and indentation scopes.
* **`TestTreeSitterLanguages`**: Bundled C grammars for HTML, JavaScript, JSON, Python, and YAML backing `RunestoneLanguages`.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for grammar attributions.

---

## Requirements

* **macOS**: 12.0 (Monterey) or later
* **Swift**: 5.5+ / Xcode 13+
* **Dependencies**:
  * [Tree-sitter](https://github.com/tree-sitter/tree-sitter) (v0.26.12, vendored in `Packages/TreeSitter`)
  * [ChimeHQ/LanguageClient](https://github.com/ChimeHQ/LanguageClient) (v0.8.0+)
  * [ChimeHQ/LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) (v0.14.0+)
  * [ChimeHQ/TextFormation](https://github.com/ChimeHQ/TextFormation) (v0.9.0+)

---

## Project Architecture

```
Runestone/
├── Sources/
│   ├── Runestone/                  # Core text editor engine, Workbench, and AppKit UI
│   │   ├── TextView/               # Text layout, gutter, themes, multi-selection, folding, minimap
│   │   ├── Workbench/              # Multi-pane split layouts, tab groups, and session restoration
│   │   ├── UIBridge/               # AppKit accessory views (completions, hover, breadcrumbs, outline)
│   │   ├── EditorIntelligenceAdapter/# Adapter connecting TextView to EditorIntelligence
│   │   ├── TreeSitter/             # Tree-sitter Swift wrapper and queries
│   │   └── Library/                # AppKit compatibility shims and utilities
│   │
│   ├── EditorIntelligence/         # Editor-agnostic intelligence platform (EIP)
│   │   ├── Core/                   # Documents, cursors, selections, event bus, container
│   │   ├── Parsing/ & Indexing/    # Tree-sitter parsing & trie symbol index
│   │   ├── Completion/ & Snippets/ # Multi-provider completion engine, ranking & TextMate snippets
│   │   ├── Hover/ & Navigation/    # Documentation tooltips, definitions, references, breadcrumbs
│   │   ├── Diagnostics/ & Refactoring/# Issue tracking & AST symbol rename
│   │   ├── AI/ & LSP/              # AI text model protocols & LSP interfaces
│   │   └── Workspace/              # Multi-document workspace & cross-file search
│   │
│   ├── EditorIntelligenceLSP/      # Concrete LSP client backed by ChimeHQ LanguageClient
│   ├── RunestoneLanguages/         # TreeSitterLanguage factories for the full language set
│   ├── RunestoneGraphQLLanguage/   # Tree-sitter GraphQL grammar + queries
│   ├── TreeSitter{TOML,SQL,Swift,Java,Kotlin,Go,Bash}{,Queries,Runestone}/  # migrated grammar trios
│   ├── SmokeTest/                  # Minimal runtime executable target
│   └── TestTreeSitterLanguages/    # Bundled C grammars (HTML, JS, JSON, Python, YAML)
│
├── Example/
│   └── MacExample/                 # Multi-tab, split-pane macOS demo application
└── Tests/
    └── RunestoneTests/             # Comprehensive unit and integration test suite
```

---

## Installation

Add Runestone to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/alex-cova/Runestone.git", branch: "main")
]
```

Then add the required products to your target dependencies:

```swift
.target(
    name: "YourAppTarget",
    dependencies: [
        .product(name: "Runestone", package: "Runestone"),
        .product(name: "EditorIntelligence", package: "Runestone"),
        .product(name: "EditorIntelligenceLSP", package: "Runestone"), // Optional: LSP support
        .product(name: "RunestoneGraphQLLanguage", package: "Runestone") // Optional: GraphQL support
    ]
)
```

---

## Quick Start

### 1. Basic `TextView` Setup

```swift
import AppKit
import Runestone

class EditorViewController: NSViewController {
    private var textView: TextView!

    override func loadView() {
        textView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.isLineWrappingEnabled = true
        textView.showMinimap = true
        textView.isLineFoldingEnabled = true
        textView.text = """
        // Welcome to Runestone on macOS!
        func greet(name: String) {
            print("Hello, \(name)!")
        }
        """
        self.view = textView
    }
}
```

### 2. Loading State Asynchronously with Tree-sitter Highlighting

For smooth performance on large files, initialize the editor state on a background thread:

```swift
import Runestone
import TestTreeSitterLanguages

let jsLanguage = TreeSitterLanguage(tree_sitter_javascript())

DispatchQueue.global(qos: .userInitiated).async {
    let state = TextViewState(
        text: largeJavaScriptCodeString,
        theme: DefaultTheme(),
        language: jsLanguage
    )
    DispatchQueue.main.async {
        textView.setState(state)
    }
}
```

### 3. Multi-Cursor & Advanced Selection

`TextView` natively supports multi-cursor and column selection:

```swift
// Select next occurrence of current word (⌘⇧D)
textView.selectNextOccurrence()

// Skip current occurrence and move to next (⌘K ⌘D)
textView.skipCurrentOccurrence()

// Select all occurrences across document (⌘⇧L)
textView.selectAllOccurrences()

// Add a cursor above or below (⌥⌘↑ / ⌥⌘↓)
textView.addCaretAbove()
textView.addCaretBelow()

// Undo the last caret addition (⌘U)
textView.undoLastCaretChange()

// Access all active selection ranges
for range in textView.selectedRanges {
    print("Caret at: \(range.location)")
}

// Line operations — all multi-caret aware, each a single undo step
textView.selectLines()            // ⌘L  — snap every selection out to whole lines
textView.duplicateSelectedLines() // ⌘D  — copy each line below, caret follows the copy
textView.deleteSelectedLines()    // ⌘⌫  — remove every line the selection touches
```

### 4. Wiring the Editor Intelligence Controller

Coordinate code completion, hover tooltips, diagnostics, and UI overlays using `EditorIntelligenceController`:

```swift
import Runestone
import EditorIntelligence

// 1. Setup symbol index and providers
let symbolIndex = SymbolIndex()
let completionEngine = CompletionEngine(providers: [
    SymbolCompletionProvider(index: symbolIndex),
    WordCompletionProvider(),
    SnippetCompletionProvider(snippets: mySnippets)
])
let hoverEngine = HoverEngine(providers: [
    SymbolHoverProvider(index: symbolIndex)
])
let diagnosticEngine = DiagnosticEngine(providers: [
    DuplicateSymbolDiagnosticProvider()
])

// 2. Initialize controller
let intelligenceController = EditorIntelligenceController(
    textView: textView,
    completionEngine: completionEngine,
    hoverEngine: hoverEngine,
    diagnosticEngine: diagnosticEngine,
    services: EditorIntelligenceServices(symbolIndex: symbolIndex)
)

// 3. Trigger features
intelligenceController.triggerCompletion()
intelligenceController.requestHover()
intelligenceController.refreshDiagnostics()
```

### 5. Multi-Pane Workbench Setup

Create a multi-tab, split-pane editing environment:

```swift
import Runestone

let workbench = EditorWorkbench()

// Open documents in the active pane
let docA = WorkbenchDocument(displayName: "main.swift", text: "print(\"Hello\")")
let docB = WorkbenchDocument(displayName: "notes.txt", text: "Some notes...")
workbench.openDocument(docA)
workbench.openDocument(docB)

// Split the active pane horizontally or vertically
let rightPane = workbench.splitActivePane(edge: .trailing)

// Sync with EIP workspace
let workspaceBridge = RunestoneWorkbenchWorkspaceBridge()
Task {
    await workspaceBridge.syncWorkbench(workbench)
}

// Save and restore sessions
let state = workbench.makeRestorationState()
// Later...
workbench.restore(from: state)
```

---

## Keyboard Shortcuts Reference

Key bindings are driven by a `Keymap` assigned to `textView.keymap`. Two presets ship:
`.default_` (below) and `.intelliJ` (an IntelliJ IDEA–style layout). `Keymap` values are
editable (`bind(_:to:)` / `unbind(_:)`), and every binding maps to an `EditorActionID` you can
also invoke directly with `textView.perform(_:)`.

### `.default_` keymap

| Shortcut | Action |
| :--- | :--- |
| **⌥ + Click** | Add caret at click position |
| **⌥⌘↑ / ⌥⌘↓** | Clone caret one line above / below |
| **⌘⇧D** | Select next occurrence of current word |
| **⌘K ⌘D** | Skip current occurrence and select next |
| **⌘⇧L** | Select all occurrences in document |
| **⌘U** | Undo last caret change |
| **⌥ + Drag** / **⌃⇧↑↓←→** | Rectangular column / block selection |
| **⌘L** | Select current line(s) |
| **⌘D** | Duplicate current line(s) |
| **⌘⌫** | Delete current line(s) |
| **⌥⇧↑ / ⌥⇧↓** | Move selected line(s) up / down |
| **⌘F** / **⌥⌘F** | Open Find / Replace panel |
| **⌃Space** / **Esc** | Trigger / dismiss code completion (with `EditorIntelligence`) |
| **⌘ + Click** | Go to definition (with `EditorIntelligence`) |

### `.intelliJ` keymap (differences from `.default_`)

| Shortcut | Action |
| :--- | :--- |
| **⇧⇧** (double tap) / **⌘⇧A** | Search Everywhere / Find Action |
| **⌘E** | Recent files |
| **⌥↑ / ⌥↓** | Extend / shrink selection by syntax node |
| **⌥⇧↑ / ⌥⇧↓** | Move line up / down |
| **⌘⇧↑ / ⌘⇧↓** | Move statement up / down (syntax-aware) |
| **⌃G** / **⌃⌘G** | Add caret at next occurrence / select all occurrences |
| **⌘⇧8** | Toggle column (block) selection mode |
| **⌃⇧J** | Join lines |
| **⌥⌘T** | Surround with… |
| **⌥⌘L** | Reformat code (LSP, or a bracket-depth reindent fallback) |
| **⌘L** | Go to line |
| **⌘B** / **⌥⌘B** / **⌥⇧⌘B** | Go to definition / implementation(s) / find usages |
| **⌘[ / ⌘]** | Navigate back / forward through cursor history |

Palette actions (Search Everywhere, Find Action, Recent Files, Surround With…) need a
`CommandPaletteController` attached to the text view; LSP navigation and Reformat Code need an
`EditorIntelligenceController`. Cursor-history back/forward (`⌘[` / `⌘]`) works on a bare
`TextView`.

---

## Testing

The project includes a comprehensive unit and integration test suite covering line management, multi-cursor editing, block selection, syntax highlighting, tree-sitter parsing, completion ranking, hover tooltips, diagnostics, workbench layout, and LSP bridges.

Run the test suite using Swift Package Manager:

```bash
swift test
```

---

## License

Runestone is available under the Apache License 2.0. See the [LICENSE](LICENSE) file for more information.

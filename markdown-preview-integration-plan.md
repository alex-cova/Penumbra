# Markdown Preview Integration Plan

Integrate vendored [Textual](https://github.com/gonzalezreal/textual) (markdown) and [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift) (diagrams) into Penumbra so Umbra can preview the current buffer when it is Markdown. Preview painting must follow the same Metal / Core Graphics split as `TextView`. Toggle the preview with **⌘B**; rebind the existing ⌘B action.

This document is the implementation plan. The libraries are already copied into `Vendor/` (not added as SPM git dependencies). Audit findings and proposed fixes are in [§9](#9-audit-findings-and-proposed-fixes).

---

## 1. Goal

- **⌘B** toggles a rendered Markdown preview of the active editor.
- The preview is offered **only** when `TextView.languageIdentifier == "markdown"` (`.md` / `.markdown` / `.mdown` via `LanguageIdentifier`). Other languages, including standalone `.mmd` / `.mermaid` files, do not get this action.
- Fenced ```` ```mermaid ```` / ```` ```mmd ```` blocks inside that Markdown document render as native diagrams (BeautifulMermaid), not as plaintext code.
- Painting uses **Metal when `TextView.isMetalRenderingActive` is true**, otherwise **Core Graphics**, with the same kill-switch / device-loss fallback as the editor (`MetalActivation`, `onMetalRenderingFailure`).
- Libraries live in-tree under `Vendor/`. Do not add GitHub package URLs to `Package.swift`.

---

## 2. Current state (Penumbra)

| Piece | Today |
| --- | --- |
| Markdown | Syntax highlighting only (`PenumbraMarkdownLanguage` + tree-sitter block/inline grammars). No rendered preview. |
| Language id | `WorkbenchDocument.languageIdentifier` / `TextView.languageIdentifier` is `"markdown"` for `.md` files (`Example/Umbra/IDELanguageSupport.swift`). |
| Metal | `TextView.isMetalRenderingEnabled` → `MetalActivation.resolved` → `isMetalRenderingActive`. Glyphs go through `MetalRenderer` + `GlyphRunExtractor` into `MetalTextCanvasView` (`CAMetalLayer`). Off → existing CG `LineFragmentView` path. |
| Keymap | Umbra defaults to `Keymap.sublime`. **⌘B is already `goToDefinition`** on both `Keymap.sublime` and `Keymap.intelliJ`. `Keymap.default_` leaves ⌘B unbound. |
| Host UI | Each pane is an AppKit `TextView` inside `IDEEditorPaneHost` / `EditorHostContainer`. Splits (`EditorWorkbench.splitActivePane`) create more *editor* panes, not accessory views. |
| Action routing | Core-owned actions run in `TextInputView.performKeymapAction`. Host actions (`goToDefinition`, palettes, …) return `false` and hit `TextView.editorActionHandler` (`EditorIntelligenceController`, `CommandPaletteController`). |

There is no existing preview surface to hang these libraries on. The work is a new preview controller + paint backends, not a flag on `TextView` itself.

---

## 3. Vendored sources (done)

Copied as source trees. **No git SPM dependencies.** Transitive compile deps are vendored too, otherwise the copies cannot build.

| Folder | Upstream | Commit | Why |
| --- | --- | --- | --- |
| `Vendor/Textual` | [gonzalezreal/textual](https://github.com/gonzalezreal/textual) | `01b51875` (2026-06-15) | Markdown parse + (upstream) SwiftUI render |
| `Vendor/BeautifulMermaid` | [lukilabs/beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) | `6a23a29e` (2026-04-27) | Parse / ELK layout / CG `DiagramRenderer` |
| `Vendor/ElkSwift` | [lukilabs/elk-swift](https://github.com/lukilabs/elk-swift) | `32f8042e` (2026-04-20) | Graph layout required by BeautifulMermaid |
| `Vendor/ConcurrencyExtras` | [pointfreeco/swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | `5fa25342` | `LockIsolated` used by Textual font reflection |
| `Vendor/SwiftUIMath` | [gonzalezreal/swiftui-math](https://github.com/gonzalezreal/swiftui-math) | `cf7c7015` | Textual math attachments (~7.5 MB fonts) |

Each folder has `LICENSE` plus `VENDOR.md` with origin and SHA. **Do not treat `Vendor/ElkSwift` as MIT** — it is Eclipse Public License 2.0 (see [§8](#8-licensing)).

Examples, tests, and `.git` were not copied. Upstream tests can be cherry-picked later if we keep a given module’s public API.

---

## 4. Architecture

### 4.1 Do not use Textual’s SwiftUI views as the preview renderer

Textual’s public API (`StructuredText`, `InlineText`) is a SwiftUI `Text` pipeline (`Text.Layout`, `@Observable`, `@Entry` environment keys). That cannot be routed through Penumbra’s `MetalRenderer` / CG fragment views, and the package declares **macOS 15** while Penumbra is **macOS 12**.

Use Textual as a **parser and block model**:

1. `AttributedStringMarkdownParser` → `AttributedString` with `PresentationIntent`.
2. A new Penumbra type, `MarkdownPreviewDocument`, walks presentation intents into blocks (heading, paragraph, list, quote, table, thematic break, **code**, **mermaid**).
3. A new AppKit view, `MarkdownPreviewView`, lays those blocks out and paints them with a CG or Metal backend selected from the host `TextView`’s Metal flag.

Keep the SwiftUI sources in `Vendor/Textual` for reference and a possible later “native Textual chrome” mode, but they are **not** on the preview paint path.

BeautifulMermaid already draws with `CGContext` (`DiagramRenderer`, `MermaidLayer`, `MermaidView`). That is the CG backend. Metal is a new adapter (see [§6](#6-metal-vs-core-graphics)).

### 4.2 New types (Penumbra)

Suggested location: `Sources/Penumbra/TextView/MarkdownPreview/`.

```
MarkdownPreviewController     // toggle, gating, debounce, backend choice
MarkdownPreviewView           // NSView host, scroll view
MarkdownPreviewDocument       // parsed blocks
MarkdownPreviewLayout         // block frames in preview coordinates
MarkdownPreviewCGRenderer     // Core Text + CG
MarkdownPreviewMetalRenderer  // glyph atlas + mermaid textures
MermaidFenceExtractor         // ```mermaid / ```mmd bodies
MermaidPaintAdapter           // CG draw vs Metal blit
```

`MarkdownPreviewController` is owned by the pane host (Umbra: `IDEEditorPaneHost`), not by `TextView`. It observes the active document’s text and `languageIdentifier`.

### 4.3 Gating

`EditorActionID.toggleMarkdownPreview` must:

1. No-op (return `false` / ignore) unless `textView.languageIdentifier == "markdown"`.
2. Close the preview if the user switches the buffer to a non-markdown document.
3. Not open for `"mermaid"` (standalone diagrams). Those stay in the source editor; mermaid is only rendered as a *fence inside markdown*.

Do not key off `TreeSitterLanguage` identity. Hosts can highlight markdown without setting the identifier; Umbra already sets `"markdown"` for `.md` files. Tests should set the identifier explicitly.

### 4.4 UI placement (Umbra)

Do **not** use `EditorWorkbench.splitActivePane` — that creates a second editor with tabs.

Split **inside** `IDEEditorPaneHost`: source `TextView` on the leading side, `MarkdownPreviewView` on the trailing side (resizable `NSSplitView`). Hidden when the preview is off. Source remains editable; preview is read-only, selectable text is phase 2.

Live update: debounce buffer changes (~150–250 ms), reparse off the main actor, swap the document on the main actor. Scroll position: keep independent from the source for v1 (no scroll-sync).

### 4.5 Action routing

`toggleMarkdownPreview` is a host action (like `goToDefinition`):

- `TextInputView.performKeymapAction` returns `false`.
- `TextView.editorActionHandler` (Umbra / `CommandPaletteController` chain) shows or hides the split.
- Register it in `CommandRegistry.findActionIDs` so Find Action lists “Markdown Preview” with the ⌘B shortcut.

---

## 5. Keymap: ⌘B

**Bind preview to ⌘B on every shipped preset.** Where ⌘B is already taken, move that action to **F12** (`kVK_F12` = `0x6F`), which is Sublime Text / VS Code “Go to Definition”.

| Preset | Today ⌘B | After |
| --- | --- | --- |
| `Keymap.default_` | unbound | `toggleMarkdownPreview` |
| `Keymap.sublime` (Umbra default) | `goToDefinition` | `toggleMarkdownPreview`; `goToDefinition` → **F12** |
| `Keymap.intelliJ` | `goToDefinition` | same as sublime (⌘⌥B / ⌘⌥⇧B stay implementation / usages) |

⌘B is also AppKit’s standard **Bold** in a text-system Edit menu. Umbra does not use `NSTextView`’s font panel that way; do not add a Bold menu item bound to ⌘B.

IntelliJ users who expect ⌘B = definition get F12 instead. Document it in the action title / Find Action list. Cmd-click go-to-definition is unchanged.

Touch:

- `EditorActionID.toggleMarkdownPreview` + title `"Markdown Preview"`
- `Keymap.default_`, `.sublime`, `.intelliJ`
- `CommandRegistry.findActionIDs`
- `KeymapTests` (⌘B and F12 per preset)
- `IntelliJKeymapIntegrationTests` if any test sends ⌘B for definition

---

## 6. Metal vs Core Graphics

Reuse the **resolved** flag, not the preference bit:

```
let useMetal = textView.isMetalRenderingActive
```

If Metal fails mid-session, `isMetalRenderingActive` becomes false and the preview must switch to CG on the same notification path as the editor (`onMetalRenderingFailure`).

### 6.1 Markdown body

| Backend | Paint |
| --- | --- |
| CG | Core Text framesetters per block (headings, paragraphs, lists, tables, quotes). Decorations (rules, list markers, code-block chrome) via `CGContext`. |
| Metal | Same `CTLine`s → existing `GlyphRunExtractor` + glyph atlas. Block chrome as `MetalDecorationBuilder`-style solids. One preview `CAMetalLayer` (same present rules as `MetalTextCanvasView`: no AppKit `draw(_:)` into the metal layer). |

Do not snapshot SwiftUI `ImageRenderer` into a bitmap as the “Metal path”. That still runs SwiftUI and ignores the editor atlas / vsync contract.

### 6.2 Mermaid fences

`DiagramRenderer` is entirely CG path + Core Text. A full Metal port of shapes/edges is out of scope for v1.

| Backend | Paint |
| --- | --- |
| CG | `MermaidRenderer.render(source:in:bounds:theme:)` (or `PreparedDiagram.render`) into the preview context. **Flip Y** on AppKit contexts (`y=0` at top is what the renderer expects). |
| Metal | Parse + layout once, rasterize with a bitmap `CGContext` (the CG pipeline), upload `MTLTexture`, blit in the preview pass. Cache the texture by `(source hash, theme, scale)`. Invalidate on edit / appearance change. |

Theme: map Umbra’s editor background / foreground into `DiagramTheme` two-color init so diagrams match the buffer (dark/light).

### 6.3 What not to do

- Host `NSHostingView { StructuredText(...) }` and call that Metal because SwiftUI might use Metal internally.
- Host `MermaidView` (CG `draw(_:)`) inside the Metal editor canvas.
- Parse or layout mermaid on the main thread (ELK is expensive).

---

## 7. Package.swift wiring

Add **local path targets** only. Suggested products stay internal unless a host needs them:

```swift
.target(name: "ElkSwift", path: "Vendor/ElkSwift/Sources/ElkSwift", swiftSettings: swift6),
.target(
    name: "BeautifulMermaid",
    dependencies: ["ElkSwift"],
    path: "Vendor/BeautifulMermaid/Sources/BeautifulMermaidSwift",
    swiftSettings: swift6
),
```

Do **not** add a `Textual` target that compiles the full SwiftUI module on macOS 12. Instead:

1. **v1:** A thin `PenumbraMarkdownPreview` (or code inside `Penumbra`) that copies/adapts only `AttributedStringMarkdownParser`, `MarkupParser`, `PatternProcessor`, and presentation-intent block walking. Exclude SwiftUI views, Prism.js, math, emoji loaders.
2. **Optional later:** `Textual` + `ConcurrencyExtras` + `SwiftUIMath` as a macOS 15+ example target. Not required for Umbra preview.

`Penumbra` then depends on `BeautifulMermaid` (and the parser slice). `Umbra` picks it up through `Penumbra`.

Swift 6: BeautifulMermaid and ElkSwift are Swift 5.9-style (`[String: Any]` ELK graphs). Expect a compatibility pass (`@unchecked Sendable`, typed ELK dictionaries, or `.unsafeFlags` isolated to those targets — prefer fixing the adapter, not silencing the whole module).

`Vendor/SwiftUIMath` stays on disk but **unwired** until math is in scope (fonts dominate binary size).

---

## 8. Licensing

Penumbra is **Apache 2.0**.

| Tree | License | Action |
| --- | --- | --- |
| Textual, BeautifulMermaid, ConcurrencyExtras, SwiftUIMath | MIT | Keep `LICENSE` files; NOTICE / VENDOR.md is enough |
| ElkSwift | **EPL-2.0** | Keep `Vendor/ElkSwift/LICENSE`. Do not relicense. Source of ElkSwift must remain available. Combining with Apache-2.0 is OK if the EPL tree stays EPL. Call this out in any third-party notices. |

BeautifulMermaid’s README implies MIT for the Swift port; its **layout engine is not MIT**. Treat ElkSwift as a separate third-party component in shipping builds.

---

## 9. Audit findings and proposed fixes

Audited the copies in `Vendor/` after import. Prioritize fixes that affect the preview path; leave UIKit-only and SwiftUI-only issues until that code is compiled.

### 9.1 Textual

**Blockers for using the library as-is**

1. **Platform mismatch.** `Package.swift` is macOS 15 / iOS 18. `@Observable`, `@Entry`, `Text.Layout` need macOS 14+ at minimum. Penumbra’s package is macOS 12. **Fix:** do not compile the SwiftUI target into Penumbra. Extract the Foundation parser.
2. **Wrong renderer for this product.** Design center is SwiftUI `Text`, not AppKit/Metal. **Fix:** `MarkdownPreviewView` as in [§4](#4-architecture).
3. **Prism.js via JavaScriptCore** (`Internal/Highlighter/CodeTokenizer.swift` + `prism-bundle.js`). Extra attack surface, first-highlight latency, and it ignores languages Penumbra already highlights with tree-sitter. **Fix:** preview code fences with Penumbra’s highlighter (or uncolored Core Text in v1). Do not load Prism in Umbra.
4. **SwiftUIMath (~7.5 MB)** pulled for `$math$` attachments. **Fix:** omit math from v1; leave the vendor tree unused. If math ships later, load fonts lazily.
5. **`ConcurrencyExtras` + `private import SwiftUIMath`** assume Textual’s own Swift settings (`InternalImportsByDefault`). **Fix:** irrelevant if the SwiftUI module is not a target.

**Improvements if the parser slice is kept**

6. Parser is Foundation `AttributedString(markdown:)` — CommonMark, not GFM tables/task lists unless options enable them. **Verify** table/task-list options and add tests against a fixture README.
7. Fenced language hints already reach `CodeBlockStyleConfiguration.languageHint`. Hook mermaid there in the *preview* block walker (not in Textual’s `DefaultCodeBlockStyle`).
8. Image attachments fetch URLs (`URLAttachmentLoader`). A local editor should resolve relative paths against the document directory and should not hit the network without a host policy. **Fix:** `AttachmentLoader` that reads `file://` relative to `WorkbenchDocument.url`, blocks `http(s)` by default or gates it on a preference.
9. `fatalError("init(coder:)")` on interaction views — fine if unused; don’t instantiate from nibs.

### 9.2 BeautifulMermaid

**Bugs to fix in the vendor tree (preview depends on them)**

1. **AppKit image path missing Y-flip.** `DiagramRenderer` documents top-left origin. `MermaidView.draw` and `MermaidLayer.renderImage` flip. `MermaidImageRenderer._renderPrepared` / `_renderPreparedFitted` on AppKit **do not**, despite `MermaidRenderer.render` saying `_renderPrepared()` flips automatically. Bitmaps from `renderImage` can appear vertically inverted. **Fix:** apply the same `translate(0, height) + scale(1, -1)` as `MermaidView` before `prepared.render`. Add a snapshot test.
2. **Deprecated `NSImage.lockFocus()`** in `MermaidLayer.renderImage`. **Fix:** draw into a `CGContext` bitmap (as `ImageRenderer` already does on AppKit) so Retina / color space match Metal uploads.
3. **Invalid regex fallback.** `_regex` in `src_parser.swift` / `src_text_metrics.swift` returns `NSRegularExpression()` (bare `NSObject.init`) after `assertionFailure`. In release that object is not a compiled regex. **Fix:** `preconditionFailure` or cache a known-good pattern; never return a dummy instance.
4. **Layout on the caller’s thread.** `MermaidLayer.prepareDiagram()` parses + ELK-layouts in `source`/`theme` `didSet`. Setting source on the main thread will hitch. **Fix:** async `layout` (the library already has `renderImageAsync`); preview controller must use that, not `MermaidLayer`’s sync path.
5. **Swift 6 / Sendable.** `ElkNode = [String: Any]`, untyped dictionaries through `src_layout.swift` / `src_elk_instance.swift`. **Fix:** typed ELK graph structs at the bridge, or isolate the adapter; required before depending from `Penumbra` (swift 6).
6. **Shared `ELK()` singleton** (`_ElkBridgeRuntime`) behind `NSLock`. Confirm re-entrancy under concurrent markdown docs; if ELK is not reentrant, serialize layouts on one actor.

**Improvements**

7. **Theme from editor colors.** Two-color `DiagramTheme(background:foreground:)` is enough; wire Umbra appearance instead of Tokyo Night defaults.
8. **Parse errors.** Show the fence source plus `parseError.localizedDescription` in the preview rather than a blank hole.
9. **Unsupported diagram types.** Library covers flowchart, state, sequence, class, ER, XY. GitHub-flavored mermaid also has gantt, pie, mindmap, etc. Unknown headers should fall back to a fenced code block, not crash.
10. **`contentsScale = NSScreen.main`** in `MermaidLayer` — wrong on multi-display. Use the view’s window screen / `backingScaleFactor`.
11. Strip iOS/Catalyst `#if` noise only if it hurts maintenance; not required for v1.

### 9.3 ElkSwift

1. **EPL-2.0** (see [§8](#8-licensing)).
2. **~410 Swift files**, Java-style names (`org_eclipse_elk_…`). Do not reformat wholesale; treat as frozen third-party.
3. Version constant `ElkSwift.version = "1.0.0"` while BeautifulMermaid probes `_ElkBridge.version`. Keep the probe compiling.
4. Prefer not to expose `ElkSwift` as a public Penumbra product.

### 9.4 Integration-level (Penumbra / Umbra)

1. Preview must track `isMetalRenderingActive`, not `isMetalRenderingEnabled` (XCTest forces CG; GPU-less hosts fall back).
2. Large markdown: cap mermaid raster size (max dimension / downscale) so a huge flowchart cannot allocate a 16k texture.
3. Debounce + generation tokens so stale layouts cannot paint over a newer buffer.
4. Accessibility: preview as a read-only group; mermaid images need a description (the fence source).
5. Do not steal first responder from `TextView` when toggling the split (`EditorHostContainer` already defends this).

---

## 10. Implementation phases

### Phase 0 — Vendor (complete)

Sources in `Vendor/` with licenses and SHAs. No `Package.swift` git URLs.

### Phase 1 — Keymap and action plumbing

- Add `EditorActionID.toggleMarkdownPreview`.
- Rebind ⌘B / F12 as in [§5](#5-keymap-b).
- Handler no-ops unless `languageIdentifier == "markdown"`.
- Tests: keymap + “ignored on non-markdown”.

### Phase 2 — Parser slice + CG preview

- Extract / wrap Textual’s Markdown parser for macOS 12.
- `MarkdownPreviewDocument` + `MarkdownPreviewCGRenderer` + split in `IDEEditorPaneHost`.
- Debounced live update, GitHub-ish typography using the editor font size.
- Code fences as monospaced blocks (no Prism).
- Tests: parse headings/lists/fences; toggle open/close; language gate.

### Phase 3 — Mermaid fences (CG)

- Detect `mermaid`/`mmd` fences.
- Off-main parse/layout; CG paint into the preview; error fallback.
- Fix Y-flip + regex dummy in the vendor tree first.
- Tests: fixture graphs; inverted-bitmap regression; unsupported type fallback.

### Phase 4 — Metal preview backend

- `MarkdownPreviewMetalRenderer` using `GlyphRunExtractor` + atlas.
- Mermaid as cached `MTLTexture` blits.
- Switch backend when `isMetalRenderingActive` changes.
- PerfHarness or snapshot: CG vs Metal preview of a small markdown+mermaid fixture.

### Phase 5 — Polish

- Theme-linked `DiagramTheme`.
- Relative image paths for markdown images.
- Optional scroll-sync, text selection in preview, math (would then wire `SwiftUIMath`).
- NOTICE for EPL ElkSwift in shipping app metadata.

Do not start Phase 4 until Phase 2 paints correctly on CG. Do not compile full Textual/SwiftUIMath until a macOS 15+ experiment is explicitly wanted.

---

## 11. Tests

| Area | Cases |
| --- | --- |
| Keymap | `default_` / `sublime` / `intelliJ`: ⌘B → preview; sublime+intelliJ F12 → `goToDefinition`; ⌘⌥B still implementation on intelliJ |
| Gate | Preview action false for `languageIdentifier == "swift"` / `nil` / `"mermaid"` |
| Parse | CommonMark fixture: headings, emphasis, lists, quotes, thematic breaks, mermaid fence extraction |
| Mermaid | Known flowchart fixture bounds > 0; bad input → error block; AppKit image not vertically flipped |
| Metal | With Metal forced on, preview layer is `CAMetalLayer` and `isMetalRenderingActive` matches the text view; with flag off, no metal layer |
| Live update | Edit buffer, after debounce preview text/diagram matches |

Prefer `swift test --filter MarkdownPreview` plus existing `KeymapTests`.

---

## 12. Non-goals (v1)

- WYSIWYG editing inside the preview.
- Scroll-sync / click-in-preview-to-source.
- Rendering standalone `.mmd` files.
- Gantt / pie / mindmap mermaid types the library does not implement.
- Shipping Textual’s SwiftUI demo UI inside Umbra.
- Adding the GitHub packages as SPM dependencies.

---

## 13. Suggested first PR slice

One PR that only: (1) keeps `Vendor/` + licenses, (2) adds `toggleMarkdownPreview` and the ⌘B/F12 keymap change, (3) Umbra no-op handler gated on `"markdown"`. Parser, mermaid, and Metal backends follow in subsequent PRs so keymap/docs land without waiting on ELK/Swift 6.

# Required Runestone changes

Umbra implements Find in Files, Go to Line, and a Sublime-accurate keymap overlay **without** modifying `Sources/Runestone`, `Sources/EditorIntelligence`, `Sources/EditorIntelligenceLSP`, or `Packages/`. The items below are engine/API gaps that still belong in Runestone if Umbra is to stop carrying workarounds.

## Stock `Keymap.sublime` does not match Sublime Text for ⌘D / ⌘⇧D

**Missing behavior.** Sublime Text on macOS binds ⌘D to *Find / Select Next Occurrence* and ⌘⇧D to *Duplicate Line*. Runestone’s `Keymap.sublime` (`Sources/Runestone/TextView/Keymap/Keymap.swift`) starts from `Keymap.default_`, which is the opposite: ⌘D → `duplicateLines`, ⌘⇧D → `selectNextOccurrence`. Umbra copies that preset and rebinds those two strokes locally (`UmbraKeymap.sublime`).

**Why Umbra cannot fix it in-engine.** Editing `Keymap.sublime` would change the library preset for every host, which this work is not allowed to do.

**Suggested engine change.** In `Keymap.sublime`, unbind both actions and bind:

- `KeyStroke(KeyChord("d", .command))` → `.selectNextOccurrence`
- `KeyStroke(KeyChord("d", [.command, .shift]))` → `.duplicateLines`

Umbra can then assign `Keymap.sublime` as-is.

## `CommandPaletteController` does not handle `.goToLine`

**Missing behavior.** `Keymap.sublime` already binds ⌘G to `EditorActionID.goToLine`, and Find Action lists “Go to Line…”. `CommandPaletteController.handle` (`Sources/Runestone/TextView/CommandPalette/CommandPaletteController.swift`) only presents palettes for `.searchEverywhere`, `.findAction`, `.recentFiles`, `.quickOpenFile`, `.goToSymbol`, and `.surroundWith`. `.goToLine` falls through as unhandled, so the advertised shortcut does nothing unless the host installs its own `editorActionHandler`.

**Why Umbra cannot fix it in-engine.** The handler chain is owned by Runestone (`CommandPaletteController` then `EditorIntelligenceController`). Umbra wraps that chain after both controllers are installed and prompts/applies Go to Line itself.

**Suggested engine change.** Handle `.goToLine` in `CommandPaletteController` (or a small `GoToLineController`) by prompting for a 1-based line number and calling `TextView.goToLine(_:)`. Hosts that already wrap `editorActionHandler` should still be able to intercept first.

## No disk-wide Find in Files API

**Missing behavior.** `WorkspaceSearchEngine` searches **open documents only**. There is no engine API to enumerate a folder on disk, search file contents, and return `(url, line, range)` hits. There is also no `EditorActionID` for Find in Files, so ⌘⇧F cannot be bound in a shipped keymap.

**Why Umbra cannot fix it in-engine.** Disk I/O and project-file policy are host concerns today; Umbra implements `FindInFilesService` and a custom `EditorActionID("findInFiles")`.

**Suggested engine change.**

- Add `EditorActionID.findInFiles` (and bind ⌘⇧F on `Keymap.sublime`).
- Either extend `WorkspaceSearchEngine` with a disk enumerator + include/exclude policy, or add a `ProjectSearchProviding` protocol the host implements and the palette/panel can call.
- Return hits as file URL + UTF-16 range so `TextView.selectedRange` can select the match after the host opens the file.

## Unified Goto Anything operators (`@` / `#` / `:`) on one ⌘P field

**Missing behavior.** Sublime’s Goto Anything (⌘P) is a single field: unprefixed queries open files, `@` jumps to a symbol, `#` searches buffer text, `:` goes to a line. Runestone’s palette is mode-split (Go to File / Go to Symbol / Find Action). `PaletteQueryScope` maps `>` → commands, `@` → symbols, and **both** `/` and `#` → **files**. There is no `:` → go-to-line scope.

**Why Umbra cannot fix it in-engine.** Scope resolution and Search Everywhere providers live in `Sources/Runestone/Workbench/CommandPalette/`. Umbra can only present the existing modes (`presentQuickOpen` / `presentSymbols` / `presentFindAction`).

**Suggested engine change.**

- Add a `.line(String)` (or equivalent) case to `PaletteQueryScope` for a leading `:`.
- Treat `#` as in-buffer / project text search (Sublime), not as a second file sigil.
- Teach `CommandPaletteController.presentQuickOpen` / Search Everywhere to honor those prefixes in one field, and to apply `:N` via `TextView.goToLine`.

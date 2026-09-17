# Required Penumbra changes — resolved

The four engine/API gaps this file used to describe (Sublime-accurate ⌘D/⌘⇧D, `.goToLine`
handling in the command palette, a disk-wide Find in Files API, and unified Goto Anything
sigils on one ⌘P field) have been closed in the engine:

- `Keymap.sublime` (`Sources/Penumbra/TextView/Keymap/Keymap.swift`) now binds ⌘D to
  `.selectNextOccurrence`, ⌘⇧D to `.duplicateLines`, and ⌘⇧F to the new
  `EditorActionID.findInFiles`.
- `CommandPaletteController` (`Sources/Penumbra/TextView/CommandPalette/`) handles both
  `.goToLine` (presents the palette seeded with `:`) and `.findInFiles` (presents a
  `ProjectSearchPaletteProvider` when `projectSearchEngine`/`workspaceRoot` are set).
- `EditorIntelligence.ProjectSearchEngine` (`Sources/EditorIntelligence/Search/`) is the
  disk-wide counterpart to `WorkspaceSearchEngine` (which only sees open documents), with a
  `FileEnumerationPolicy` for ignored directories/extensions/size caps. Reachable from a host's
  own UI via `EditorIntelligenceController.searchProject(_:in:)` /
  `onRequestProjectSearch`, or from the built-in palette via `CommandPaletteController`.
- `PaletteQueryScope` gained `.text` (Sublime's `#`, in-buffer search) and `.line` (`:`,
  go-to-line) cases, and every palette mode — not just Search Everywhere — now honors a
  leading sigil for one keystroke (`CommandPaletteController.runQuery`).

`Example/Umbra` (and the `UmbraCore` target it used to carry these workarounds in) has been
updated to use the engine APIs directly; see `Tests/PenumbraTests/ProjectSearchEngineTests.swift`,
`KeymapTests.swift`, `CommandPaletteTests.swift`, `CommandPaletteControllerTests.swift`, and
`GoToLinePaletteProviderTests.swift` for coverage.

# F28 — Keyboard gaps: presets, folding bindings, rebinding UI

- **Priority:** P3 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** ✅ Done (2026-11-04) — preset gaps filled, VS Code preset added, unhandled keys give feedback; rebinding UI and vim/emacs not done (out of scope) · **Owner:** Unassigned

## Evidence

- Three presets only (`Keymap.swift:57-227`): `default_` (~22 bindings), `intelliJ` (superset), `sublime` (Umbra's default). No VS Code preset (double-checked: preset enum + grep), no vim/emacs.
- Folding keys exist only in the IntelliJ preset (:185-191); `default_` and `sublime` have none. Next/previous problem is host-owned (`EditorActionID:149-153`); when the host does not wire it, the key is silently swallowed by the 4-layer dispatch fallthrough.
- No custom keybinding editor: `Keymap.bind/unbind` is a programmatic API; the settings pane offers only a preset picker + go-to-file picker.
- Hardcoded non-remappable keys in `TextInputView+MouseKeyboard.swift`: Cmd-A, Cmd-Z/Shift-Cmd-Z, Ctrl-Shift arrows (block selection), double-Shift, Cmd-click jump.

## Root cause

Keymap started as presets; user customization and preset parity were deferred, and a few keys bypass the keymap entirely.

## Fix sketch

Add folding + back/forward + rename bindings to all presets; add a VS Code preset (the keymap struct is open and actions are extensible — purely additive); move hardcoded keys into the keymap; only then consider a rebinding UI.

## Complexity / Dependencies

S for bindings/preset; M for moving hardcoded keys; rebinding UI is a separate product decision.

## Acceptance criteria

- Every documented action reachable by keyboard in every preset; no swallowed keys (unhandled actions fall through to the system instead of vanishing).

## Tests / benchmarks

- KeymapTests + IntelliJKeymapIntegrationTests extended per preset; Umbra menu-shortcut tests.

## Out of scope

Vim/emacs emulation; rebinding UI unless separately approved.

## Implementation notes (2026-11-04)

**Measured first.** A throwaway matrix of the unbound actions per preset: `default_` had 25 bindings (80 actions with no key), Sublime (Umbra's default) 34 (72 unbound, including Rename, all folding, Find Next/Previous, both problem-navigation actions), IntelliJ 83 (25 unbound, all deliberate). `default_` also had no command-palette key at all, so a host on that preset could not reach the other actions by keyboard.

**Done.**
- **`default_` and Sublime** (`Keymap.swift`): Find Action ⇧⌘P, Go to File ⌘P, Go to Definition F12, Back/Forward ⌘[ / ⌘], Rename ⇧F6, Next/Previous Problem F4 / ⇧F4, Find Next/Previous (⌘G / ⇧⌘G in Default; ⌥⌘G / ⇧⌥⌘G in Sublime, whose ⌘G is Go to Line), and folding: ⌥⌘[ / ⌥⌘] at the caret, ⌘K ⌘1 fold all, ⌘K ⌘J unfold all. IntelliJ now starts from a private `historical` set (the original 25), so none of this reaches it (a test pins its 83 bindings and that ⌘K is still not a chord prefix there).
- **VS Code preset** (`Keymap.vsCode`, `KeymapPreset.vsCode` "Visual Studio Code", its own menu column `vsCodeOverrides`): VS Code's macOS keys for the actions Penumbra implements. Find/replace/next ⌘F ⌥⌘F ⌘G, Quick Open ⌘P, Palette ⇧⌘P, Go to Line ⌃G, Go to Symbol ⌘T, file outline ⇧⌘O, F12 / ⌘F12 / ⇧F12 definition, implementation, usages, Rename F2, ⌘. quick fixes, F8 / ⇧F8 problems, ⌃- / ⌃⇧- Back and Forward, ⌥↑/↓ move line, ⇧⌥↓ duplicate, ⇧⌘K delete line, ⌘D / ⌘K ⌘D / ⇧⌘L occurrences, ⌘[ / ⌘] outdent and indent, folding (⌥⌘[ ⌥⌘], ⌘K ⌘0 ⌘K ⌘J ⌘K ⌘[ ⌘K ⌘]). Menu moves it needed: Open Folder loses ⇧⌘O, sidebar ⌘B (so the Markdown preview is ⇧⌘V), bookmark stepping ⌃⌥↓/↑ (F2 is Rename), Split Down loses ⇧⌘\ (Go to Matching Bracket).
- **Chords and menus.** A chord's second key is a ⌘ key, and a menu key equivalent is handled before the editor, so a chord ending in a menu shortcut can never complete (⌘K ⌘0 would toggle the sidebar). Hence the per-preset fold chords above, and `IDEKeymapPresetTests.testNoChordEndsInAKeyAMenuHandlesFirst` for every preset.
- **Found by the new generic test, fixed:** the VS Code column first collided twice (bookmark F2 over Rename, Split Down over matching bracket). `testNoMenuShortcutShadowsADifferentKeymapActionInAnyPreset` checks every menu command in every preset against its keymap (with a list of the menu commands that mirror an editor action).
- **A latent bug F26 would have exposed.** `IDESourceKitServer` and `IDETypeScriptServer` listed `.structure` in their features; harmless while the LSP service built no outline, but with F26's `documentSymbol` outline the connected server would have replaced `SwiftStructureProvider` / `TypeScriptStructureProvider`. Removed from both, with a test.
- **Swallowed keys.** A bound key nobody handles is still swallowed (letting it fall through is unsafe: ⌃J would insert a newline through Cocoa's key bindings), but it was silent and Umbra never set `onUnhandledKeymapAction`. It now shows a caret hint, "<Action>: nothing to do here" (it cannot tell "no handler" from "nothing to do", so the wording fits both).
- Updated three older tests that pinned the old gaps (`testRenameIsBoundOnlyInIntelliJKeymap`, `testCommandPIsBoundOnlyInTheIntelliJKeymap`, `testOtherPresetsKeepTheirFindKeys`) and `testFileStructureMenuUsesCommandF12InEveryPreset` (VS Code uses ⌘F12 for Go to Implementation). New: `KeymapPresetParityTests` (7), `IDEKeymapPresetTests` (5). Library 812 and Umbra 147 related tests pass.

**Left on purpose.**
- **Hard-wired keys** (`TextInputView+MouseKeyboard.swift`): ⌘A and ⌘Z / ⇧⌘Z stay out of the keymap, as the code already explains (standard Select All, and the Edit menu consumes undo under SwiftUI); ⌃⇧-arrows block selection, double-⇧ (already configurable as Go to File through `GoToFileShortcut`) and ⌘-click are input gestures, not actions. Moving them into `Keymap` would make Select All and Undo remappable to nothing: a product call, not done.
- **No rebinding UI, no vim/emacs** (out of scope in the brief). `Keymap.bind/unbind` and the new presets are the extension point.
- **Not VS Code-complete:** fold-by-level chords (⌘K ⌘1…⌘9), Sublime's "fold tag attributes", and VS Code keys for actions Penumbra does not have.
- **Sublime fidelity:** the Sublime preset keeps its earlier choices (⌘G Go to Line, ⌘L Go to Line); it is Sublime-style, not Sublime-exact, and Find Next lives on ⌥⌘G because of that.

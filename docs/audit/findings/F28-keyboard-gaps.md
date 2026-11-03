# F28 — Keyboard gaps: presets, folding bindings, rebinding UI

- **Priority:** P3 · **Severity:** Medium · **Confidence:** Confirmed · **Provenance:** A+B
- **Status:** Open · **Owner:** Unassigned

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

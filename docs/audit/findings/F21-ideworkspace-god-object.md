# F21 — IDEWorkspace god object and forced root recompute

- **Priority:** P2 · **Severity:** High · **Confidence:** Confirmed · **Provenance:** A
- **Status:** Open · **Owner:** Unassigned

## Evidence

- `IDEWorkspace` (Umbra/Sources/Umbra/Workspace/IDEWorkspace.swift:87-89): `@MainActor @Observable`, 6,065 lines + ~20 extensions, ~30 sub-stores in one body. 123 files consume it via `@Environment`, 160 reference it.
- `IDERootView.body:42-48` deliberately reads epoch/preference properties (`let _ =`) to force root recompute; `.id(workspace.layoutEpoch):96` tears down the editor layout subtree per epoch bump (host cache mitigates pane hosts).
- Mitigations already present: `@Observable` per-property tracking; guarded writes on hot paths (`noteActiveDocumentEdited`, `refreshPresentation`); per-window instances via `WindowGroup`.
- Same disease, smaller: `TextInputView` 5,608 lines, `TextView` 3,718, `EditorIntelligenceController` 3,465. Keymap actions thread 4 layers (Keymap → Dispatcher → `performKeymapAction` → `TextView.perform` → controller → host), silently swallowing unhandled keys.

## Root cause

Workspace state accreted in one observable because every feature needed "just one more" shared property.

## Fix sketch

Extract sub-stores at seams the current work does not touch (start with the least-coupled: appearance/preferences, then problems, then run/agent). Narrow `IDERootView`'s forced reads to a dedicated layout-epoch token. Do not rewrite; do not big-bang.

## Complexity / Dependencies

L, incremental. Each extraction is independently shippable.

## Acceptance criteria

- SwiftUI Instruments: root body evaluations during typing/scroll drop measurably after each extraction; no behaviour change in UmbraTests.

## Tests / benchmarks

- UmbraTests suite; SwiftUI Instruments body counts before/after per extraction.

## Out of scope

Replacing SwiftUI chrome or the AppKit editor host — evidence does not support it.

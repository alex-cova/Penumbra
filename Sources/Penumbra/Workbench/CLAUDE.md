# Workbench (`Penumbra/Workbench`)

Loaded when working under `Sources/Penumbra/Workbench`. Moved out of the root CLAUDE.md.

- Multi-pane editor layout with horizontal/vertical splits (`EditorWorkbench`, `EditorLayout`).
- Per-pane tab groups with preview (temporary) tabs, pin, and back/forward tab history (`EditorPane`, `EditorTabHistory`, `TabListEngine`).
- `WorkbenchDocument` holding editor state; `PenumbraStateBuilder` for `TextViewState` construction.
- Session restoration (`EditorRestorationState`, Codable layout/document snapshots).
- `PenumbraWorkbenchWorkspaceBridge` syncs open documents into EIP `Workspace`.
- `PenumbraWorkbenchEditorAdapter` implements `EditorAdapter` at workbench scope.

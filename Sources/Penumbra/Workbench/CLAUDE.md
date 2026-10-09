# Workbench (`Penumbra/Workbench`)

Loaded when working under `Sources/Penumbra/Workbench`. Moved out of the root CLAUDE.md.

- Multi-pane editor layout with horizontal/vertical splits (`EditorWorkbench`, `EditorLayout`).
- Per-pane tab groups with preview (temporary) tabs, pin, and back/forward tab history (`EditorPane`, `EditorTabHistory`, `TabListEngine`).
- `WorkbenchDocument` holding editor state; `PenumbraStateBuilder` for `TextViewState` construction.
- Session restoration (`EditorRestorationState`, Codable layout/document snapshots).
- `PenumbraWorkbenchWorkspaceBridge` syncs open documents into EIP `Workspace`.
- `PenumbraWorkbenchEditorAdapter` implements `EditorAdapter` at workbench scope.
- **Language definitions** (`LanguageDefinition`, `LanguageDefinitionRegistry`, `LanguageDefinition+BuiltIns`): one value per language holding its identifier, display name, file extensions and names, alias identifiers, Markdown fence tags, optional `LanguageConfiguration`, Set Syntax visibility and optional grammar. `LanguageDefinitionRegistry.shared` (thread-safe, immutable snapshot reads) is what `LanguageIdentifier`, `FenceLanguageName`, `LanguageConfigurationRegistry.builtIns`, `TreeSitterLanguage.bundled(forIdentifier:)` / `BundledLanguages` and Umbra's `IDELanguageSupport` read. `builtIns` is identity only so `Penumbra` alone detects file types; `PenumbraLanguages` installs the bundled grammars (`BundledGrammars`) on first use without replacing a host's. A later registration wins an extension. Register at launch: prepared grammars are cached. Tests: `LanguageMappingCompatibilityTests` (every pre-existing mapping), `LanguageDefinitionRegistryTests`. Guide: `docs/ADDING_A_LANGUAGE.md`; plan: `docs/LANGUAGE_SUPPORT_PLAN.md`.

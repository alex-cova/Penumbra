# Plan: Adopt the Runestone APIs from `required-changes-runestone.md` in Umbra

Do this **after** the engine work in `required-changes-runestone.md` has landed. Until then, keep the current Umbra workarounds (`UmbraKeymap`, `GoToLineCommand` prompt, host `EditorActionID("findInFiles")`, disk `FindInFilesService`).

Scope is Umbra + `UmbraCore` + `UmbraTests` only. Do not re-implement engine behavior in the app.

## Preconditions (engine must already provide)

Confirm each item in Runestone before touching Umbra:

1. **`Keymap.sublime`** binds ⌘D → `.selectNextOccurrence` and ⌘⇧D → `.duplicateLines` (no host rebind needed).
2. **`CommandPaletteController`** (or a small engine Go-to-Line helper it owns) handles `.goToLine`: prompt for a 1-based line, call `TextView.goToLine(_:)`. Hosts may still wrap `editorActionHandler` and intercept first.
3. **Find in Files is an engine action + search API:**
   - `EditorActionID.findInFiles` exists.
   - `Keymap.sublime` binds ⌘⇧F to it.
   - Hits are `(url, utf16Range, line)` so a host can open the file and set `TextView.selectedRange`.
   - Either `WorkspaceSearchEngine` can scan a folder, or a `ProjectSearchProviding` (name may differ) protocol exists for the host to supply files / run the scan.
4. **Goto Anything operators** work in one palette field:
   - `:` → go to line (`PaletteQueryScope` line case, applied via `TextView.goToLine`).
   - `#` → text search (buffer / project), **not** a second file sigil.
   - `@` → symbols (already), unprefixed → files (already), `>` → commands (already).
   - `presentQuickOpen` / Search Everywhere honor those prefixes.

If any item is missing or the public types differ, stop and update this plan against the actual APIs — do not keep a parallel Umbra implementation “just in case.”

## What stays in Umbra (host-owned)

These are product chrome, not engine workarounds:

- Find / Go / View menus in `UmbraApp.swift` (including **Find in Files…** and **Go to Line…**).
- The Find in Files **results panel** (`FindInFilesPanel`) and `openDocument(from:selecting:)`.
- Project root, sidebar, ignore-directory policy, opening files from palette hits.
- Wiring palette data sources (`fileEntriesProvider`, `onOpenFile`, `symbolIndex`, `workspaceRoot`).

## Task 1 — Drop the Sublime keymap overlay

**Today.** `KeymapPreset.sublime` assigns `UmbraKeymap.sublime`, which copies `Keymap.sublime` and rebinds ⌘D / ⌘⇧D / ⌘⇧F / ⌘G. Tests assert the engine preset is *wrong* and the overlay is *right*.

**After.**

- `IDEPreferences.KeymapPreset.keymap` for `.sublime` returns `Keymap.sublime` directly.
- Delete `Example/UmbraCore/UmbraKeymap.swift` (or shrink it to nothing).
- Replace `UmbraKeymap.findInFiles` with `EditorActionID.findInFiles`.
- In `installUmbraActionHandler`, match `.findInFiles` (engine ID), not a host-minted ID.

**Tests.** Rewrite `UmbraKeymapTests`:

- Assert `Keymap.sublime` itself maps ⌘D / ⌘⇧D / ⌘G / ⌘⇧F / ⌘P / ⌘⇧P / ⌘R as above.
- Delete `testUmbraOverlayDoesNotEditEngineSublimePreset`.
- Structural check: `IDEPreferences.swift` contains `Keymap.sublime`, not `UmbraKeymap.sublime`.

## Task 2 — Stop intercepting Go to Line

**Today.** Umbra wraps `editorActionHandler` after palette + intelligence, prompts with `NSAlert`, and applies via `GoToLineCommand.apply` → `TextView.goToLine`.

**After.** The engine handler already does prompt + apply. Umbra must not steal `.goToLine`.

- Remove `.goToLine` from `installUmbraActionHandler`.
- Remove `showGoToLine` / `promptGoToLine` / `isPromptingGoToLine` / `applyGoToLine` from `IDEWorkspace`.
- Go menu **Go to Line…** should call the same engine path the keymap uses: `adapter.textView?.perform(.goToLine)` (same pattern as Find / Replace).
- Delete `Example/UmbraCore/GoToLine.swift` once nothing in Umbra calls it.
- Move or drop `GoToLineTests`: parse/apply coverage belongs in Runestone if the engine owns the prompt; Umbra only needs a structural/menu check that Go to Line still calls `perform(.goToLine)`.

Keep a reentrancy guard only if the engine does not already debounce menu + keymap both firing ⌘G.

## Task 3 — Point Find in Files at the engine search API

**Today.** `FindInFilesService` enumerates the project tree, substring-searches UTF-8 files, and returns `FindInFilesHit`. The panel and `IDEProjectModel.allProjectFiles()` both use it.

**After.** Use the engine types. Keep the panel.

Suggested shape (adapt names to whatever Runestone shipped):

1. **Action.** `installUmbraActionHandler` / Find menu / palette command all end in `showFindInFiles()` as they do now, but the action ID is `.findInFiles`. If the engine also presents its own UI for that action, either:
   - let the engine UI win and retire `FindInFilesPanel`, **or**
   - intercept `.findInFiles` (as today) and keep Umbra’s panel. Prefer the engine UI if it lists file + line and can call a host `onOpenHit`. Prefer Umbra’s panel if the engine is scan-only with no results UI.
2. **Scan.** Replace `FindInFilesService.search` with the engine API:
   - If `ProjectSearchProviding`: Umbra implements it using `project.rootURL` + the same ignore list (`FindInFilesService.ignoredDirectoryNames` can move next to `IDEProjectModel` or stay as a small host helper).
   - If `WorkspaceSearchEngine` gained a disk scan: pass the folder URL / file list from `IDEProjectModel`.
3. **Open hit.** Keep `openDocument(from:selecting:)` and map engine hits → `(url, NSRange)`. Delete `FindInFilesOpenTarget` if the engine hit type already has `url` + `range`.
4. **Enumerator.** `IDEProjectModel.allProjectFiles()` can keep using a thin host enumerator (sidebar still needs it) even if search moves to the engine. Do not require the engine to own the file tree.

Delete `Example/UmbraCore/FindInFiles.swift` only after the panel, tests, and project model no longer import those types. If Umbra still needs ignore-list + recursive listing, leave a small `UmbraProjectFiles` helper — that is host policy, not a search engine.

**Tests.** Point `FindInFilesTests` at the **shipped** scan/open-hit functions Umbra actually calls (engine API + Umbra’s `openDocument(from:selecting:)` mapping). Keep: nested-file hit, miss → empty, chosen hit → URL + range on the matching line.

## Task 4 — Wire Goto Anything on ⌘P

**Today.** ⌘P is `presentQuickOpen()` (files only). `#` in the palette means files. `:` does nothing. Go to Line is a separate alert.

**After.**

- `showQuickOpen()` should present the unified field: `presentSearchEverywhere()` **or** `presentQuickOpen()` if that mode now honors `@` / `#` / `:`.
- Confirm a query of `:12` in that field moves the caret (engine). Umbra should not parse `:` itself.
- Keep **Go to Symbol…** (⌘R) and **Command Palette…** (⌘⇧P) as dedicated modes; they are still useful even with sigils on ⌘P.
- Welcome-view / README shortcut copy: ⌘P is Goto Anything (files, `@` symbols, `#` text, `:line`), not only “Go to File”.

No Umbra parser for palette prefixes — if sigils mis-route, that is an engine bug.

## Task 5 — Collapse `UmbraCore` if it is empty

After tasks 1–3:

- If `UmbraCore` has no remaining types, delete the target, drop it from `Package.swift` and the Umbra executable, and move leftover tests to depend on `Runestone` only (or keep a tiny host helper target if project-file enumeration stays shared).
- `UmbraTests` remains; it must not import the Umbra **executable**.

## Task 6 — Docs and leftover comments

- Delete or rewrite `required-changes-runestone.md` so it does not describe workarounds that no longer exist. If any engine gap remains, keep only those bullets.
- Update `Example/README.md` shortcuts if ⌘P meaning changes.
- Strip comments that say “Runestone has no `findInFiles`” / “host rebinds because Keymap.sublime is swapped.”

## Suggested order

1. Keymap overlay (low risk, unlocks tests).
2. Go to Line handler (stop double-prompting once the engine handles `.goToLine`).
3. Find in Files API + tests (largest type churn).
4. Goto Anything presentation.
5. Remove empty `UmbraCore` / update docs.

## Verification

- `git diff --stat -- Example/Umbra Example/UmbraCore Tests/UmbraTests Package.swift` is the only expected app churn (plus README / `required-changes-runestone.md`).
- `swift test --filter UmbraTests` green.
- `swift build --product Umbra` green.
- Manual: Sublime preset — ⌘D next occurrence, ⌘⇧D duplicate, ⌘⇧F Find in Files, ⌘G Go to Line (one prompt, not two), ⌘P accepts `file`, `@symbol`, `#text`, `:N`.
- Choosing a Find in Files hit still opens the file and selects the match.

## Non-goals

- Package Control, plugins, build systems, Vintage, macros, Replace in Files, `.sublime-keymap` files.
- Changing Runestone in this follow-up (that work is the prerequisite).
- Pixel-perfect remaining Sublime bindings (⌃G vs ⌘G, ⌘B sidebar vs definition).

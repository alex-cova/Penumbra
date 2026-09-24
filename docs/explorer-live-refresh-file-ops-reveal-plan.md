# Explorer: live refresh, file operations, reveal active file

Follow-up to the Explorer work (horizontal scroll, git colors, folder roles, Kotlin flattening).
Scope: `Example/Umbra` only. Three features, built in this order because each one depends on the previous:

1. Live tree refresh (foundation)
2. File operations (New / Rename / Duplicate / Trash / Copy Path)
3. Reveal active file (+ selection highlight)

## Current state (what constrains the design)

- `IDEProjectModel` (`IDEProjectModel.swift`) builds the whole tree once in `setRoot` via a synchronous recursive `buildNode`; `rootNode` is a value-type `IDEFileNode` tree. Nothing rebuilds it afterwards, so on-disk changes never appear.
- Expansion state lives separately in `expandedPaths` (keyed by path), so a rebuilt tree keeps its expansion for free.
- `IDEFileTreeRow` has one context-menu item ("Reveal in Finder"), no selection state, and no keyboard handling.
- `IDEWorkspace.revealInSidebar(_:)` (`IDEWorkspace.swift:1433`) already expands ancestors via `project.reveal(url:)` but does not scroll to or highlight the row.
- Open documents are `WorkbenchDocument`s with a mutable `url` and `displayName` (`Sources/Penumbra/Workbench/WorkbenchDocument.swift`); `closeDocument(_:in:)` and `refreshPresentation()` are the existing hooks for tab changes.
- `IDEGitStatusModel` already runs an `FSEventsFileSystemWatcher` on the project root; a second, separate watcher for the tree would duplicate work.

---

## 1. Live tree refresh

**Goal:** files created/deleted/renamed outside Umbra (terminal, Gradle, Finder, git checkout) appear within ~1 s, with expansion, scroll position, and git colors intact.

### Design
- Extract the watcher from `IDEGitStatusModel` into a small shared `IDEProjectWatcher` (new file `IDEProjectWatcher.swift`) that owns one `FSEventsFileSystemWatcher` for the project root and publishes coalesced change batches (`AsyncStream<Set<String>>` of changed directory paths). `IDEGitStatusModel` and `IDEProjectModel` both subscribe. Started/stopped from `IDEWorkspace.applyProjectRoot`.
- Path filter: everything except paths under `IDEProjectModel.ignoredDirectoryNames` (`.build`, `node_modules`, `.gradle`, etc.) and `.git/` internals (git status keeps its own `.git/index`/`HEAD` interest via a flag on the subscription).
- `IDEProjectModel.applyChanges(_ dirs: Set<String>)`: for each changed directory that is currently *loaded in the tree*, re-list just that directory and splice the new children into `rootNode` (replace the subtree, keeping child nodes whose path is unchanged so unaffected branches are not rebuilt). Changed paths whose parent isn't in the tree are ignored.
- Make `buildNode` lazy-friendly: add `reloadChildren(of:)` that lists one level using the same filter/sort as `buildNode`. The initial `setRoot` stays a full build (keeps `allProjectFiles()` and flattening semantics unchanged); only refreshes are incremental.
- Expansion: prune `expandedPaths` entries whose path no longer exists after a refresh.
- Debounce: FSEvents latency 0.5 s plus a 150 ms main-actor coalescing window; never do directory listing on the main actor for large batches (list on a detached task, apply the result on main).
- Downstream refresh triggers, since the file set changed: `IDEGitStatusModel.refresh()` (already subscribed), and invalidate the Go to File candidate list (`project.allProjectFiles()` is called fresh at `IDEWorkspace.swift:1253`, so nothing to do).

### Edge cases
- A watched directory itself is deleted or replaced → drop the subtree; if the *root* disappears, set an "unavailable" state instead of crashing (show the existing empty state with a "Folder not found" line).
- Event storms (`git checkout`, `gradle clean`): cap by collapsing to a full `setRoot`-style rebuild when more than ~200 distinct directories change in one batch.
- Symlink loops: `buildNode` already follows `isDirectory` resource values; add a visited-set of resolved paths in the refresh path only if a loop is reproduced.

### Tests
Umbra is an executable target, so pure logic goes where it can be tested: put the directory-diffing/merge function (`IDEFileTreeMerge.merge(old:new:)`) behind an `internal` API and cover it in a new `Tests/PenumbraTests/Umbra*` file **only if** Umbra logic is moved into a testable library target; otherwise verify manually (see Verification). The porcelain parser now lives in the `GitIntelligence` package as `GitStatusParser` (`Packages/GitIntelligence`). Decision needed before implementation — default: manual verification, no target change.

---

## 2. File operations

**Goal:** New File, New Folder, Rename, Duplicate, Move to Trash, Copy Path, Copy Relative Path from the row context menu, with F2/Enter to rename and ⌘⌫ to trash; open tabs follow renames and close on delete.

### Design
- New `IDEFileOperations` (`IDEFileOperations.swift`), a plain struct over `FileManager` with no UI: `createFile(in:name:)`, `createDirectory(in:name:)`, `rename(_:to:)`, `duplicate(_:)` ("name copy.ext", incrementing), `trash(_:)` via `FileManager.trashItem`. Each returns the resulting URL or throws a typed error (`nameExists`, `invalidName` for `/` or empty or leading/trailing whitespace, `outsideProject`). All validate that the target stays inside the project root.
- Workspace layer (`IDEWorkspace`): `createFile(in:)`, `renameItem(_:to:)`, etc. that call `IDEFileOperations`, then:
  - **Rename / move:** for every open `WorkbenchDocument` whose `url` equals or is under the old path, set `url` (and `displayName` when the file itself was renamed), call `refreshPresentation()`, and re-sync `workspaceBridge` / language identifier if the extension changed. Update `expandedPaths` entries under a renamed folder (`project.rename(from:to:)`). Update `recentFiles` and the git-status model (`refresh()`).
  - **Trash:** always confirm with an `NSAlert` ("Move to Trash", decided; no exceptions for empty or untracked items). Close tabs for affected documents via `closeDocument` (dirty ones prompt through the existing save-changes flow).
  - **Create:** insert the node via `IDEProjectModel.applyChanges` immediately (don't wait for FSEvents), expand the parent, then start inline rename for the new row; for files, open it after the name is committed.
  - Errors surface through the existing `presentError(_:)` (`IDEWorkspace.swift:1724`).
- Inline rename in the row: `IDEFileTreeRow` swaps `title` for a `TextField` when `renamingID == node.id` (state owned by `IDEFileTreeView`, `@FocusState` for focus). Preselect the name without extension (Finder/VS Code behavior). Return commits, Esc cancels, focus loss commits. Blank or unchanged name = cancel.
- Menu additions in `IDEFileTreeRow.contextMenu`: New File…, New Folder… (on folders; on files they target the parent), Rename, Duplicate, separator, Copy Path, Copy Relative Path, Reveal in Finder, separator, Move to Trash. Package rows created by "Flatten Packages" map to their real directory URL (their `id` already is the directory path), so "New File" inside a flattened package works; "Rename" on a flattened row renames only the last path segment and is disabled otherwise to avoid surprising multi-directory moves.
- Java nicety (optional, phase 2 of this feature): new `.java`/`.kt` file in a source root pre-fills a `package` line from its path. Reuse `IDEFlattenedPackages.isSourceRoot` and the existing `JavaImportInserter`-adjacent helpers only if a package-from-path helper already exists; otherwise skip.

### Edge cases
- Rename to a name differing only in case on a case-insensitive volume: go through a temporary name.
- Renaming/trashing the project root: disabled.
- Externally-dirty documents (open, modified in editor) being renamed: keep buffer, just retarget `url`.
- Undo: not supported in v1 (Trash is recoverable via Finder; state that in the confirmation).

---

## 3. Reveal active file + selection highlight

**Goal:** the row for the current editor tab is highlighted; "Reveal Active File" (menu + optional auto-follow) expands ancestors, scrolls the row into view, and selects it.

### Design
- Selection state: add `selectedPath: String?` to `IDEProjectModel` (observable). Clicking a row sets it; opening a file from anywhere leaves it as is unless auto-follow is on.
- Highlight: `IDEFileTreeRow` gets `isSelected` (background `IDEAppearance.ColorToken.selection`, rounded like other rows) and `isOpen` (subtle bolder weight for files open in tabs). Open-paths set comes from `IDEWorkspace` (`tabsByPane` already holds titles; add a `openDocumentPaths: Set<String>` published in `refreshPresentation()`).
- Scrolling: wrap the `ScrollView` in `ScrollViewReader`; row ids are `"\(depth)-\(node.id)"` today, which changes with flattening/filtering. Switch `FlatNode.id` to `node.id` alone (unique per path in every mode) so `proxy.scrollTo(path, anchor: .center)` is stable. Trigger via a `revealRequest: (path: String, token: UUID)` on `IDEProjectModel` that `IDEFileTreeView` observes with `.onChange`, so repeated reveals of the same file still scroll.
- Flow: `IDEWorkspace.revealActiveFileInSidebar()` = `revealInSidebar(url)` (exists, `IDEWorkspace.swift:1433`) + set `selectedPath` + bump `revealRequest`. If Flatten Packages is on and the file lives in a flattened package, `reveal(url:)` already expands the real directory paths, which match the package rows' ids, so no extra work. If the name filter hides the file, clear the filter first.
- Entry points: command palette action (`EditorActionID`/`CommandRegistry` — register as an Umbra-level command like the other workspace actions), a toolbar/menu item "Reveal Active File in Explorer" (⌥⌘E is free — check `Keymap` presets for conflicts before binding), and the "Reveal in Explorer" tab context-menu item if tabs have one.
- Auto-follow: new preference `explorerAutoReveal` in `IDEPreferences` (**default on**, decided), a toggle in the Explorer header context menu next to "Flatten Packages"; when on, `refreshPresentation()` reveals whenever the selected document changes (skip while the tree filter is active and while the user is mid-rename).
- Keyboard navigation groundwork (cheap while touching selection): make the tree focusable and handle Up/Down/Left/Right/Return with `.onKeyPress` moving `selectedPath` across `flattenedNodes`. Scoped as optional here; full type-to-select is a separate item.

### Edge cases
- File outside the project root → `revealInSidebar` already falls back to Finder.
- File inside an ignored/skipped directory (`.build`, `node_modules`) → not in the tree; show no-op (optionally a brief status-bar message).
- Untitled documents (no `url`) → action disabled.

---

## Suggested milestones

1. **Watcher extraction + incremental refresh** (feature 1): shared watcher, `reloadChildren`, splice, expansion pruning. Ship alone.
2. **Selection + reveal** (feature 3): small, and its `selectedPath`/stable-id changes are prerequisites for inline rename.
3. **File operations** (feature 2): operations layer + workspace tab-following first, then inline rename UI and context menu.

## Verification (manual, `swift run Umbra`)

- Live refresh: with a project open, `touch a.txt`, `rm a.txt`, `mv` a folder, `git checkout` another branch, run `gradle clean build` in the terminal panel — tree and git colors update within ~1 s; expanded folders stay expanded; scroll position doesn't jump; no beachball on a large repo (e.g. this one).
- File ops: create / rename / duplicate / trash on files and folders; rename an open file (tab title and language highlighting follow), rename a folder containing open files (all tabs retarget), trash an open dirty file (save prompt), name collisions, invalid names, case-only rename, rename inside a flattened package.
- Reveal: open a deeply nested file from Go to File, run Reveal Active File → ancestors expand, row scrolls to center and highlights; with filter active, filter clears; with auto-follow on, switching tabs follows.
- `swift build` clean; `swift test` still green.

## Decisions

- Trash: always asks for confirmation.
- Auto-follow (`explorerAutoReveal`): on by default; toggle in the Explorer header context menu.

## Open questions

- OK to move Umbra logic (file ops, tree merge, git parsing) into a testable target, or keep manual verification only? Default: manual verification.

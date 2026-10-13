# External file changes and open-buffer sync

Status: **done** (items 1–5 and 7; item 6 dropped). See "What shipped" below; it overrides the plan where they differ.

## What shipped

**One watching engine.** Review asked that Umbra have exactly one file-watching engine, independent of any language. Before this work there were four: `IDEProjectWatcher` (FSEvents over the root, through JavaIntelligence's `FSEventsFileSystemWatcher`), a second FSEvents stream in `IDEGradleProjectSystem` for build files, and `O_EVTONLY` dispatch sources in `IDENpmProjectSystem` and `IDESwiftPMProjectSystem`. Now:

- `IDEProjectWatcher` is the only engine. `IDEFSEventStream` (`Example/Umbra/FileWatching/`, moved out of JavaIntelligence) is the only FSEvents stream type, and the watcher is its only creator. No per-file `O_EVTONLY` watches (the plan's suggestion for files outside the project).
- One stream watches several roots: the project root plus the parent directory of each open file outside it (`setOpenFiles`). When that set changes, the new stream starts before the old one stops, instead of replaying event ids. A window with no folder still watches its open files.
- `Batch` gained `openFilePaths`: open files outside the root, or under a folder the Explorer ignores. `paths` keeps its project-only meaning.
- Project systems judge paths in `IDEProjectSystem.filesDidChange(_:)`. Their own watchers are deleted.

**Policies** (after [vscode#41250](https://github.com/microsoft/vscode/issues/41250): reload silently / never reload but tell me / ask). `IDEExternalChangePolicy`, Settings ▸ Editor ▸ External Changes, key `com.umbra.editor.externalChangePolicy`:

| Policy | Clean tab | Dirty tab | Deleted |
| --- | --- | --- | --- |
| `always` (default) | reload silently | banner | banner |
| `prompt` | banner | banner | banner |
| `never` | notification only | notification only | notification only |

Under every policy, saving over a newer file asks first (Cancel · Overwrite · Compare). The agent's `saveBuffer` refuses instead and raises the banner.

**Self-save suppression** came out simpler than planned. There is no time window: the baseline is re-read after every save, and judging an event waits for a baseline still being read. So the event of Umbra's own save compares against what that save wrote.

**Also covered:** saving the diff viewer's editable side over a file that changed since the diff loaded it asks Cancel · Overwrite. Files over 2 MB are hashed only at both ends, so for them the modification date must match too.

**Hex** (item 6) was dropped. The hex editor implements no watching. It keeps `noteExternalChange` and its `HexFileIdentity` save check, and is fed by the same batches, now including `openFilePaths`.

**Not done:** per-path policies (the issue's Dropbox case), and reconciling on app activation (not needed so far).

---


Umbra already watches the **project** with FSEvents (`IDEProjectWatcher` → `FSEventsFileSystemWatcher`) and updates Explorer, git, indexes, palette, and local history. **Open editor buffers** are mostly disconnected: text tabs do not track disk except after some git flows (`reloadOpenEditorsAfterGitChange`) or manual **Reload from Disk**; hex is the only editor with explicit external-change UX (`IDEHexSession.externalChange`).

This plan closes that gap using patterns common in VS Code, IntelliJ, and Sublime: **never overwrite dirty buffers silently**; **reload clean buffers automatically** (configurable); **compare + keep** for conflicts; **detect newer disk on save**.

Non-goals for the first ship: cross-process file locking, Dropbox-style sync-folder special cases, and wiring `EditorIntelligence.Workspace.setFileSystemWatcher` (Umbra can keep its own watcher stack).

---

## Summary and order

| # | Item | Size | Kind | Do after |
| --- | --- | --- | --- | --- |
| 1 | `DiskSnapshot` + self-save suppression | S | Foundation | nothing |
| 2 | `IDEOpenDocumentDiskSync` (open-path reconciliation) | M | Core | 1 |
| 3 | Clean-buffer auto-reload + dirty banner (text) | M | UX | 2 |
| 4 | Save-time “disk is newer” conflict | S | Safety | 1, 2 |
| 5 | Preferences + menu/docs | S | Product | 3 |
| 6 | Unify hex banner with shared model (optional polish) | S | Cleanup | 3 |
| 7 | Tests + PerfHarness sanity | M | Quality | 3, 4 |

**Suggested commits:** one per row (7 commits), or combine 1+2 and 3+4 if review prefers fewer PRs.

---

## Goals

1. Every **file-backed** open tab (`WorkbenchDocument` with `url`, `contentKind == .text` or `.binary`) reacts when that path changes on disk.
2. **Clean** buffer: reload in place (preserve scroll/caret when content hash unchanged; see below).
3. **Dirty** buffer: non-modal banner (same actions as hex: Reload, Keep Mine, Compare); never auto-replace text.
4. **Deleted on disk**: banner + offer close tab / keep editing (dirty stays dirty).
5. **Own saves** do not spuriously reload or banner (content-compare + short post-save ignore).
6. **Untitled** buffers (`url == nil`): unchanged.
7. **Outside project root**: still watched while open (see item 2).
8. Git-driven reload (`reloadOpenEditorsAfterGitChange`) becomes a **caller** of the same reload primitive, not a separate code path.

---

## Non-goals (deferred)

- **Cross-process Umbra instances** editing the same file (no lock file; same as today).
- **Global `editor.autoReload` per path pattern** (e.g. exclude `~/Dropbox/**`) — add only if users ask after ship.
- **LSP `didChangeWatchedFiles`** driven from this layer (optional later; Java/TS indexes already get `filesDidChange` from `IDEProjectWatcher`).
- Replacing `PollingFileSystemWatcher` in EditorIntelligence or attaching it from Umbra.

---

## Architecture

### Layering (keep today’s split)

```
FSEvents (project + optional open-only paths)
    → IDEProjectWatcher (batch, explorer/git/index)     [unchanged role]
    → IDEOpenDocumentDiskSync (per open url, editor sync) [new]
```

`IDEProjectWatcher.onBatch` should call into disk sync **after** coalescing, in addition to today’s handlers:

```swift
// IDEWorkspace.applyProjectRoot — extend existing onBatch closure
openDocumentDiskSync.handleProjectBatch(batch.paths)
```

Open files **outside** the project tree are not in that batch; sync maintains **supplemental watches** (one `DispatchSource` per open file, same pattern as npm’s `package.json` watcher in `IDENpmProjectSystem`) or adds paths to a small secondary `FSEventsFileSystemWatcher` rooted at common parent — prefer **per-file `O_EVTONLY`** for simplicity and bounded descriptor count.

### `DiskSnapshot` (item 1)

Small value type in `Example/Umbra/` (or `Sources/Penumbra` only if reuse is needed — start in Umbra):

- Fields: `size`, `modificationDate` (or `FileChangeStamp`), optional `contentHash` (SHA-256 of file bytes, computed off main actor).
- `static func capture(url: URL) async -> DiskSnapshot?`
- `func differs(from other: DiskSnapshot) -> Bool` — mtime/size first; hash when both sides have it.

**Self-save suppression:** when Umbra finishes `document.save(from:to:)`, record `lastWrittenSnapshot[url] = snapshot` and `ignoreExternalUntil[url] = now + ε` (ε = 0.5–1 s). On external event, if snapshot equals `lastWrittenSnapshot`, treat as no-op even inside ε.

Also bump a `diskGeneration` on `WorkbenchDocument` (or a side table keyed by `document.id`) when disk content is adopted, so split panes stay coherent (alongside existing `contentGeneration`).

### `IDEOpenDocumentDiskSync` (item 2)

`@MainActor` type owned by `IDEWorkspace` (like `IDEProjectWatcher`):

- `register(document: WorkbenchDocument)` / `unregister(document:)` when tabs open/close or url changes.
- `handleProjectBatch(paths: Set<String>)` — for each open url whose path is in `paths`, schedule `reconcile(url:)`.
- `reconcile(url:)` (async, utility priority):
  1. Read snapshot from disk; if missing → `handleDeleted`.
  2. If matches suppressed self-save → return.
  3. If matches **baseline snapshot** taken at last load/reload/save → return (touch-only or identical bytes).
  4. Else dispatch policy (item 3).

**Baseline:** set when `installReloaded`, after successful save, and when opening a file. Store per absolute path (standardized).

**Reload primitive:** extract from `reloadOpenEditorsAfterGitChange` + `reloadTabFromDisk`:

- `reloadDocumentFromDisk(_ document: WorkbenchDocument, encoding: TextFileEncoding?, allowDirty: Bool) async`
- Uses existing `loadDocument(from:preferring:)` + `installReloaded` + `showDocument` for visible panes + `contentGeneration &+= 1`.
- Refactor `reloadOpenEditorsAfterGitChange` to call this for text/binary instead of duplicating loops.

### Text UX (item 3)

**Policy** (read from `IDEPreferences`, item 5):

| `externalChangePolicy` | Clean buffer | Dirty buffer |
| --- | --- | --- |
| `autoReload` (default) | Reload silently | Banner |
| `prompt` | Banner (Reload / Keep) | Banner |
| `never` | Banner only | Banner |

Default **`autoReload`** matches VS Code / IntelliJ expectations for clean tabs.

**Banner:** SwiftUI strip above the editor in `IDEEditorPaneHost` (mirror hex copy: “Changed on disk”, Reload, Keep Mine, Compare). State: `IDEExternalChangeState` per document id (`none | pendingReload | deletedOnDisk`).

- **Keep Mine:** dismiss banner; optionally set a flag so repeated identical disk events do not re-spam until disk changes again (store last dismissed snapshot).
- **Compare:** open existing diff viewer (`IDEDiffRequest`) — working tree = buffer (`openBufferText` / export), other side = disk (same as git diff infrastructure).

**Viewport:** after silent reload, prefer `refreshCleanKeepingViewport` pattern from hex if we add a text equivalent (re-`setState` with mapped scroll/caret); minimum bar: reload via `installReloaded` + `showDocument` and accept caret reset if hard — note in tests.

### Save conflict (item 4)

Before `document.save(from:to:)` writes, capture disk snapshot:

- If document **is dirty** and disk snapshot **≠ baseline** (another process changed file since open/last reload): present alert — **Overwrite**, **Cancel**, **Compare** (IntelliJ / VS Code “content on disk is newer”).
- If document **is clean** but disk changed since baseline: treat as reload path first (should be rare if item 3 works).

Wire in `saveActiveDocument`, `saveBuffer`, and agent save paths that call `document.save`.

### Preferences (item 5)

Settings ▸ Editor (new subsection **External changes**):

- `umbra.editor.externalChangePolicy`: `autoReload` | `prompt` | `never` (UserDefaults; include in preferences snapshot if other editor prefs do).
- Optional later: “Reload clean files when Umbra becomes active” (on `NSApplication.didBecomeActive`) — only if batch watcher misses events in testing.

Document in `Example/Umbra/CLAUDE.md` (file watching + editor bullets).

### Hex unification (item 6, optional)

Point `noteExternalChange` at `IDEOpenDocumentDiskSync` for `.binary` instead of separate logic; keep `IDEHexSession.externalChange` as a view binding or thin wrapper over shared state.

---

## Touch points (code)

| Area | File(s) |
| --- | --- |
| Watcher batch hook | `IDEWorkspace.applyProjectRoot` (`onBatch`) |
| Open/close registration | `openDocument`, `closeDocument`, `installReloaded`, `saveActiveDocument` |
| Git reload refactor | `IDEWorkspace.reloadOpenEditorsAfterGitChange` |
| Manual reload | `reloadTabFromDisk` → shared primitive |
| UI | `IDEEditorPaneHost`, new `IDEExternalChangeBanner.swift` |
| Prefs | `IDEPreferences`, `IDEPreferencesEditorPane` (or existing Editor section) |
| Diff compare | `IDEWorkspace+Diff.swift` (buffer vs disk helper) |
| Hex | `IDEWorkspace+Hex.swift`, `IDEHexRootView.swift` |

**Do not** put AppKit UI in `Sources/Penumbra`; keep policy in Umbra. Penumbra may gain only neutral helpers (`DiskSnapshot` is optional in Penumbra if tests want it without Umbra).

---

## Testing

| Test | What |
| --- | --- |
| `IDEOpenDocumentDiskSyncTests` | Temp dir: write file, open document, rewrite on disk → clean doc reloads (policy auto); dirty doc sets banner flag; self-save does not reload |
| `IDEExternalChangeSaveConflictTests` | Dirty buffer + disk change → save presents conflict (mock alert or injectable gate) |
| Refactor coverage | Existing git reload tests still pass; add one test that external batch triggers same reload as git for clean file |
| Hex | Existing `HexWorkspaceTests` external change; ensure path still works after unification |

Manual: edit open file in another editor; `git pull` with clean/dirty tabs; save while external change; file outside project folder open in tab.

**Performance:** reconciliation runs off main actor; only open urls (typically &lt; 20). No full-tree walk. `PerfHarness enter-session` unchanged; optional note in plan results if any regression.

---

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| FSEvents flood during build | Project batch already coalesces 150 ms; sync only intersects with **open paths** |
| Format-on-save tools rewrite disk | Content hash compare; self-save snapshot |
| Large files | Hash only when mtime/size changed; cap hash size (e.g. first+last 64 KiB + size) for &gt; 2 MB if needed — same threshold as local history |
| Split panes same document | Single baseline per url; one `contentGeneration` bump |
| Encoding | Reload uses `document.encoding` (`preferring:`) like today |

---

## Rollout

1. Land items 1–4 behind no flag (behavior default is industry-standard).
2. Update `Example/Umbra/CLAUDE.md` and root `CLAUDE.md` one-liner under Umbra if needed.
3. No migration; new UserDefaults keys default to `autoReload`.

---

## Success criteria

- External edit to an open **clean** text file appears in the tab without user action (default policy).
- External edit to an open **dirty** text file shows banner; buffer unchanged until user chooses Reload.
- Save with newer disk file shows conflict; Compare works.
- Explorer/git/index behavior unchanged.
- Hex behavior preserved or improved via shared sync.

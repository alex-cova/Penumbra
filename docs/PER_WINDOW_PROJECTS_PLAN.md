# Per-window projects in Umbra

Status: proposal, design decisions settled (see "Decisions"). Nothing here is implemented.

## Goal

Every Umbra window owns one project (or none). Dropping a folder on the Dock icon, ⌘O on a folder, File ▸ Open Recent and `open -a Umbra <dir>` open that folder in its own window (or native window tab), next to the ones already open. Closing a window closes only its project. Quitting and relaunching brings back the last window; other projects come back through Open Recent.

## Where we are today

Umbra is one process with **one `IDEWorkspace`**, and every window shares it.

- `UmbraApp` holds `@State private var workspace = IDEWorkspace()` and injects it into each `WindowGroup(id: "main")` window (`Example/Umbra/UmbraApp.swift:7`). A second window (Dock reopen, `openWindow(id: "main")`) renders the same tabs, sidebar and project as the first, so the two are mirrors, not independent editors.
- The whole menu bar (`.commands { … }`, ~200 lines) reads that captured `workspace` directly.
- `IDEAppDelegate.shared?.workspace = self` (`IDEWorkspace.swift:489`) gives the delegate a single weak reference. The new `application(_:open:)` sends every URL to it, and a dropped folder **replaces** the current project (`openDroppedURLs` → `applyProjectRoot`).
- Persistence is one `session.json` (`IDESessionStore`) that mixes app-wide data (preferences, recent files/projects) with per-window data (layout restoration, project bookmark, sidebar/terminal state). `loadSession()` runs inside `IDEWorkspace.init`, and `IDEWindowCloseGuard` / `applicationWillTerminate` write it back.
- Several stores are process-global JSON files that assume a single writer: `breakpoints.json`, `run-configurations.json`, `gradle-trust.json`, `jdk-selection.json`, plus the Java index shards under Caches (`JavaIndexPaths`) and the Gradle model cache.
- `IDEPreferences.shared` and `IDEEditorTheme.shared` are singletons, which is right for app-wide settings but means preferences are saved *through* the workspace session.
- `IDEWorkspace` still reaches for `NSApp.keyWindow` / `NSApp.mainWindow` (lines ~149, 1573, 4897, 4927, 4949) instead of its own window.

## Design decisions (recommended)

1. **One `IDEWorkspace` per window**, created by the window's root view. No shared mutable project state between windows.
2. **Same folder, same window.** Opening a folder that is already open in a window focuses that window instead of creating a second one. This removes the worst multi-writer cases (two Java indexes, two file watchers and two Gradle syncs on one tree) and matches VS Code and IntelliJ behavior. Two windows on one project can be a later, explicit feature.
3. **Routing rule for opening a folder.**
   - Folder already open → focus that window (select its tab if it is in a tab group).
   - Key window is empty (welcome screen, no project, no dirty documents) → reuse it, no prompt.
   - Key window already has a project and the open is user-initiated in that window (⌘O, Open Folder…, Open Recent) → **ask**: "Open in New Window" / "Replace This Window's Project" / Cancel. A "Remember my choice" checkbox writes the `Open folders in` preference (Ask / New window / Replace), which Settings can reset. Replace runs the window's normal `confirmCloseWindow` unsaved-documents flow first.
   - External opens (Dock drop, `open -a Umbra <dir>`, Finder) never prompt: they open a new window, because no window asked for them.
   - A file goes to the window whose project contains it, else to the key window, else a new window.
4. **App-wide vs window state split.** App-wide (preferences, theme, keymap, recent files/projects, notification switches) is loaded once and shared. Window-wide (project root, tab layout, sidebar/terminal state, run configuration selection) is stored per window.
5. **Restore only the last window.** Relaunch restores one window: the one that was key at quit, or the last one closed if the user closed them all. Other windows the user had open are not reopened; their projects stay one click away in Open Recent. No windows index is needed, just a single `last-window.json`.
6. **Native macOS window tabs are in scope.** Every project stays one `NSWindow` with its own `IDEWorkspace`; AppKit tab groups merge those windows. New project windows follow the system "Prefer tabs" setting (`tabbingMode = .automatic`), and Window ▸ Merge All Windows / Show Tab Bar work as in any Mac app. Umbra's own editor tabs live inside the window, so users see project tabs above editor tabs.
7. **Heavy per-project services stay per-window** (`IDEJavaSupport`, Gradle runner, debug session, terminals, watcher). The JDK index is large and identical across windows, so it moves to a process-wide shared object in phase 4.

## Plan

### Phase 1 — Window-scoped workspace and menus (no behavior change for one window)

**Status: implemented** (not committed). Deviations and leftovers:

- `IDEWindowScene` creates its workspace in `onAppear`, not as a `@State` default, because SwiftUI can re-initialize the struct and would build and discard a whole workspace each time. The workspace registers with `IDEWindowRegistry` at the end of `bootstrap()` and unregisters when its window closes.
- `IDEAppCommands` is split into one small `View` per menu (`IDEFileCommands`, `IDEGoCommands`, …) taking a non-optional workspace, so the menu bodies moved verbatim. With no focused window, menus show a disabled "No Open Window" item; File keeps New Window (⌘⇧N).
- **Session stopgap:** replaced by Phase 2.
- `--open` / `--open-folder` are applied once per process, by the first window.
- Native tabs work at the AppKit level: Window ▸ Merge All Windows, Move Tab to New Window and closing tabs behave, each tab keeping its own workspace.
- **Tab bar vs. toolbar (fixed):** the native tab bar is a 28pt strip under the system titlebar, and AppKit grows the top safe-area inset by that much, which made the toolbar row 56pt tall with its buttons under the tab bar. `IDEWindowChrome` (in `IDERootView.swift`) now splits the inset into titlebar and tab bar. In a window the toolbar row shrinks to the titlebar (28pt) and the tab bar gets the strip below it; in full screen the tab bar strip goes above the toolbar row. The traffic lights center on the actual row. It is derived from the inset alone: an earlier version that also read `tabGroup.isTabBarVisible` went stale after moving a tab out and collapsed the row to 0pt. Checked by measuring element positions through accessibility (windowed single, merged, merged full screen, and after splitting a tab out); not checked by eye, since screenshots are unavailable in this environment.

The riskiest structural change; everything else builds on it.

- Add `IDEWindowScene` (a `View`) that owns `@State private var workspace = IDEWorkspace(…)` and renders today's `IDERootView`. `UmbraApp` no longer holds a workspace.
- Publish it with `.focusedSceneValue(\.ideWorkspace, workspace)` (a `FocusedValueKey`), and pull the whole `.commands` block into `struct IDEAppCommands: Commands` using `@FocusedValue(\.ideWorkspace) private var workspace`. Every item becomes `workspace?.…` with `.disabled(workspace == nil)`. `IDEMenuShortcuts` already takes the preset as a parameter, so it moves as is; the preset comes from `IDEPreferences.shared`.
- Replace `IDEAppDelegate.workspace` with `IDEWindowRegistry` (new, `@MainActor`): weak references to every workspace, keyed by an `IDEWindowID` (UUID). Workspaces register in `init` and unregister in `deinit`/`teardown`.
- Give `IDEWorkspace` a `weak var window: NSWindow?`, set by `IDEWindowConfiguratorView.viewDidMoveToWindow`, and replace the `NSApp.keyWindow` / `mainWindow` uses with it (sheets, first-responder resets, alerts must target *their* window, not whichever is key).
- Move the `--open` / `--open-folder` launch arguments out of `IDEWorkspace.init` into the app-launch path so only the first window honors them.
- Ensure `.handlesExternalEvents(matching: ["*"])` stays (SwiftUI must not spawn windows for URLs itself; Phase 3 opens them explicitly).
- Set `tabbingMode` and a shared `tabbingIdentifier` explicitly in `IDEWindowConfiguratorView` instead of relying on defaults. Check that Umbra's custom titlebar/toolbar chrome leaves room for the native tab bar; if the titlebar is hidden or transparent, that is the first thing to fix here, not in Phase 3.

Exit criteria: with one window, behavior is unchanged; with ⌘N / Dock reopen the second window is an independent empty workspace and menu commands act on the focused window; two windows can be merged into a tab group and back, each keeping its own workspace.

### Phase 2 — Split persistence: app state vs window state

**Status: implemented** (not committed). What was built, and where it differs from the text below:

- `IDESessionStore.swift` now holds `IDEAppSessionRecord` (`app.json`), `IDEWindowSession` (`last-window.json`), `IDESessionFiles` (paths, atomic reads and writes, migration; the directory is injectable for tests) and `IDELegacySession`, the old `AppSession`, which is only read for migration. `IDEAppState` (new) is the single owner of recents and the preferences snapshot; `IDEWorkspace`'s recent lists forward to it.
- **No window IDs and no `WindowGroup(for:)`:** with only the last window restored, nothing needs to address a specific window, so `IDEWorkspace.init(windowID:restoring:)` became a check in `bootstrap()`: a window opened while no other window is open restores `last-window.json`; any other starts empty.
- **Which window is "last" (added during implementation):** `IDEWindowRegistry` keeps windows most-recently-key first, and `sessionWindow` is the first one that is not *pristine*. A pristine window is a blank one opened next to other windows and still blank. Without that rule, clicking into a new blank window and quitting replaced your project with an empty window. A closing session window hands over to the next non-pristine one; if none remains, its own close-time save stands.
- Migration leaves `session.json` byte-identical; it is skipped once `app.json` exists.
- Tests: `Tests/PenumbraTests/IDESessionFilesTests.swift` (15 tests: migration, older-format sessions, corrupt files, round trips, shared recents, no rewrite when unchanged). The registry's session-window rules are covered by running the app (restore, blank second window, closing the project window, reopen with none open), not by unit tests.

- New `IDEAppSessionStore` (`app.json`): preferences snapshot, recent files, recently edited, recent projects, notification switches. Loaded once by `IDEPreferences`/an `IDEAppState` object, saved with a debounce, written atomically.
- New `IDEWindowSessionStore` (`last-window.json`, a single record): `EditorRestorationState`, `projectRootBookmark`, sidebar/structure/gradle widths and visibility, terminal tabs. Only one window is ever restored, so there is no index and no per-window files to garbage-collect.
- `IDEWorkspace.init(windowID:restoring:)` takes the state it should restore (or `nil` for an empty window) instead of calling `IDESessionStore.load()`. Only the first window at launch gets the restored state; later windows start empty. `makeSession`/`saveSession` split accordingly.
- **Which window is "last":** the registry tracks the most recently key workspace. A window's state is written to `last-window.json` when it becomes non-key after edits (debounced) and when it closes, but a closing window only overwrites the file if it is the most recently key one, so closing a background window never replaces the state of the one you were working in.
- **Migration:** on first launch with the old `session.json` and no `app.json`, split it: app-wide fields go to `app.json`, the rest becomes `last-window.json`. Keep `session.json` untouched for one release so a downgrade still works.
- Recent lists are shared, so a write from any window must merge with, not overwrite, what another window just recorded (single `IDEAppState` owner, no per-workspace copies).
- Restore path: `UmbraApp` opens the first window with the restored state via `WindowGroup(id: "main", for: IDEWindowID.self)`; windows opened with a value get that ID, the plain "no value" window gets a fresh ID.

Exit criteria: a window with its project and tabs survives quit + relaunch when other windows were open (the key one wins); old `session.json` users keep their project.

### Phase 3 — Routing external opens and the Dock

**Status: implemented** (not committed). Where it differs from the text below:

- **`IDEOpenRouter`** (pure, `IDEOpenRouter.swift`) returns `.focus`, `.reuse`, `.replace`, `.askReplaceOrNew` or `.newWindow` for a folder, and a window or `.newWindow` for a file. `IDEWindowRegistry.open(urls:origin:)` acts on it; the workspace provides `openProjectFolder`, `replaceProject(with:)`, `askHowToOpenFolder` (the sheet with "Remember my choice") and `focusWindow`. `Open folders in` is an `IDEPreferences` setting (Ask / New window / Replace) with a picker in Settings ▸ Project. It is not part of the preferences snapshot.
- **SwiftUI opens its own window for every external event unless told otherwise.** `handlesExternalEvents(matching: ["*"])` (the old setting) opened a blank window per `open -a` on top of ours; an empty set stopped the launch window from opening at all. The scene now matches a name no event uses (`UmbraApp.swift`), so only our routing decides.
- **Cold launch:** opens wait until the first window has registered (`hasHadWindow`), so the restored window exists first; the folder then goes through the rule (reuse if the restored window is empty, else a new window). Without that wait the queued open asked for a new window before the first one registered, and the first window skipped its restore.
- **Registration order bug found on the way:** a window's key-window notification can arrive before its workspace registers; `didBecomeActive` now ignores unregistered workspaces, because adding them made `register` return early and skip the new window's folder.
- **New windows with a folder** use a job queue (`newWindowJobs`): the next workspace to register takes the job and opens its URLs, and a pending job also stops that window from restoring the last one (opening a folder with no windows open shows just that folder).
- **Menus:** File ▸ New Window (⌘⇧N), New Window Tab (joins the key window's tab group; also the tab bar's + button through `newWindowForTab:`), Open Folder… and Open Recent now work with no window focused. Open Recent lists the shared `IDEAppState` lists.
- **Titles:** a window's title is `file · project` (or the project name), which is also its tab title.
- **Not done:** `representedURL` (the title is hidden, so it has no visible effect).
- Tests: `IDEOpenRouterTests` (19). Checked by running a scratch app bundle with `open -a`: new window per project, reopening a project focuses it, files go to their project's window, a blank key window takes a folder, open with no windows, cold launch with a folder, the prompt's Cancel / New Window / Replace / Remember, New Window Tab.

- The delegate cannot call `openWindow`. Extend `IDEWindowReopenBridge` to register an `openWindow(value:)` closure with the registry, which queues requests until it exists (cold launch, before any window has appeared; this is today's `pendingOpenURLs` mechanism generalized).
- `IDEWindowRegistry.open(urls:)` applies the routing rule from the design decisions above. It needs a "project root → workspace" lookup (standardized, symlink-resolved path) and an `isEmpty` predicate on the workspace (no project, no documents, none dirty).
- Cold launch with a dropped folder: restore the last window as usual, then route the dropped folder through the same rule. Reuse the restored window only if it is empty; otherwise the dropped folder opens beside it, without a prompt (external open).
- "Open Recent", the welcome screen, ⌘O on a folder and Open Folder… use the same entry point instead of `applyProjectRoot` on the current workspace. When the current window already has a project, that entry point shows the "Open in New Window / Replace This Window's Project / Cancel" prompt from design decision 3 (a sheet on that window, with the remember-my-choice checkbox and the `Open folders in` setting). The router returns a decision (`.focus(window)`, `.reuse(window)`, `.askReplaceOrNew(window)`, `.newWindow`) and the UI layer acts on it, so the prompt logic stays testable.
- Add File ▸ New Window (⌘⇧N, new empty project window) and File ▸ New Window Tab (only shown when tabbing is preferred). Check the shortcut against the Sublime keymap presets before choosing one; ⌘T and ⌘N already have meanings in the editor.
- Tabs: when the system prefers tabs (or the user chose New Window Tab), a new project window is attached with `addTabbedWindow(_:ordered:)` to the key window's tab group; otherwise it is a separate window. "Focus existing" selects the tab when the target lives in a tab group and brings the group forward.
- Window title/`representedURL` show the project folder name, which is also the native tab title; add the Window menu list (SwiftUI does this for `WindowGroup`).
- Keep `applicationShouldHandleReopen` behavior: no visible windows → reopen the last window from `last-window.json`, else a welcome window.

Exit criteria: dropping three different folders on the Dock icon gives three windows (or three tabs with tabs preferred); dropping one already open focuses it; a file inside an open project lands in that project's window; ⌘O with a project open asks replace-or-new and both answers work, including cancel.

### Phase 4 — Shared stores and services that assumed one writer

**Status: implemented** (not committed). Where it differs from the text below:

- **One instance per store for the whole app** (`IDESharedServices.shared`, `Example/Umbra/IDESharedServices.swift`): `GradleTrustStore`, `JDKSelectionStore`, `JavaRunConfigurationStore`, `JavaBreakpointStore` and the JDK shard hub. `IDEJavaSupport`, `IDEJDKSelection` and `IDEWorkspace` take them instead of building their own. The plan said "created by the registry"; they live in their own type because the registry is about windows, not services. The stores are already thread-safe, so a plain shared instance is enough; no actor was needed.
- **Re-read before write** (`FileChangeStamp`, `Sources/JavaIntelligence/Storage/`): each store compares its file's modification date before every read and mutation and reloads when another writer changed it, so a second instance on the same file, or a second Umbra process, no longer drops entries. An unreadable file keeps what is in memory. Two instances on one file are tested as stand-ins for two windows. **Bug caught by those tests:** `URL.resourceValues` caches on the `URL` value, and the stores ask about the same `URL` every time, so the first version never noticed a change; the stamp now reads through `FileManager`.
- **JDK index shared** (`JavaSharedShardHub`, `Sources/JavaIntelligence/Scanning/`): one indexing run per shard, callers that arrive meanwhile wait for it, and one parsed `JavaIndexShardReader` is handed to every window (at most 4 kept, least recently used dropped). Shard writes were already atomic (`Data.write(.atomic)`) and reads memory-mapped, so no cross-process lock was added: a second reader sees the old or the new file, never half of one. Checked in the app with three windows: the first window's request ran, the other two reused the parsed reader. **Not shared:** jar and project shards and the Gradle model cache stay per window; with the same-folder rule two windows rarely want the same ones, and jars shared between projects would be the next candidate.
- **Preferences repaint every window:** `applyPreferencesToAllHosts()` (theme, font, layout toggles, zoom, keymap) now goes through `IDEWindowRegistry.applyPreferencesToAllWindows`, where before it only reached the window whose Settings view called it. Checked in the app: one Zoom In with three windows open applied to all three. The `IDEEditorTheme.shared` rebuild was already once per change.
- **Notifications:** each window keeps its own `IDENotificationCenter` (entries and toasts stay with their window), but Do Not Disturb and the category switches now follow `UserDefaults` changes made by another window's center; before, each center read them once at launch.
- Tests: `SharedStoreTests` (11), `JavaSharedShardHubTests` (6), three more cross-window cases in `IDENotificationCenterTests`. Full suite: 3030 tests, 0 failures.

- `breakpoints.json`, `run-configurations.json`, `gradle-trust.json`, `jdk-selection.json`: today each is loaded once and rewritten whole. With several workspaces that is last-writer-wins. Route each through one process-wide actor-owned store instance (created by the registry, injected into each workspace) that re-reads before merging its own key, or keys writes by project root so windows on different projects never touch the same entry. Gradle trust is security-relevant: a trust decision in one window must be visible in another without a restart.
- Java index (`JavaIndexPaths` shards, `refs.idx`) and Gradle model cache: with the same-folder rule two windows only share the JDK's shards. Verify shard writes are atomic and add a cross-process-safe lock if a second Umbra *process* can exist. Share the JDK stub index between windows behind one object owned by the registry so a second window does not re-index or double the memory of the JDK.
- `IDEEditorTheme.shared` / `IDEPreferences.shared`: a preference change must repaint every window. Confirm the observation path reaches all workspaces, since today it only has one observer.
- Notifications: keep one `IDENotificationCenter` per window (toasts belong to the window they came from) but keep Do Not Disturb and category switches in shared `UserDefaults`, which they already use.

### Phase 5 — Lifecycle and teardown

- Window close: `IDEWindowCloseGuard` asks only its own workspace (`confirmCloseWindow`), saves that window's state, then tears the workspace down.
- Add `IDEWorkspace.teardown()`: stop the file watcher, terminals (kill child shells), debug session, Gradle runs and indexing, and balance the security-scoped `startAccessingSecurityScopedResource()` calls made in `applyProjectRoot` / `openDroppedURLs` (they are never stopped today, which only mattered while there was one project).
- Replace-in-window (from the Open Folder prompt) reuses the same path: confirm close, `teardown()`, then apply the new root to the same window, so nothing from the old project survives.
- Closing a tab in a native tab group is a window close, so it goes through the same guard and teardown as any window.
- `applicationShouldTerminate`: gather unsaved documents across all workspaces in one prompt. `applicationWillTerminate`: save the most recently key window to `last-window.json`, the shared app state and the index. Other windows are not persisted.
- Confirm the workspace actually deallocates after close (Debug Memory Graph, or a `deinit` log in a test). `navigationBuffers`, Java support callbacks and the `[weak self]` closures are the usual suspects. A leak here means a closed project keeps its index and watcher alive.

### Phase 6 — Tests, docs, polish

- Unit tests (`Tests/PenumbraTests` is a library target; Umbra is an executable, so put the routing logic in a small pure type, e.g. `IDEOpenRouter`, that can be tested without AppKit): folder already open → focus; empty key window → reuse; user-initiated open with a populated key window → ask, with the `Open folders in` setting resolving to new/replace without asking; external open → new window without asking; file inside/outside a project; symlinked and trailing-slash paths; cold-launch queueing.
- Session tests: migration from a real old `session.json`, `last-window.json` round trip, a corrupt `last-window.json` falls back to an empty window without losing app state, closing a background window does not overwrite the key window's saved state.
- Manual checklist: Dock drop on cold and warm launch; two windows with different Gradle projects (sync, build, debug in both); Cmd-Q with dirty tabs in two windows; closing the first window then the second; changing theme in window A repaints B; `swift run Umbra` (no bundle) still works; merge windows into tabs and split them again, drag a tab out, close a tab with dirty documents, relaunch with a tab group open (only the key project returns).
- Run the performance checks in `docs/PERFORMANCE_RULES.md` (`PerfHarness enter-session`); no engine code changes are expected, so any regression points at the per-window plumbing.
- Update `CLAUDE.md` (Umbra section) and `Example/README.md` with the window model, and mention `IDEWindowRegistry` there.

## Files most likely to change

| Area | Files |
| --- | --- |
| Scene / menus | `UmbraApp.swift` (split into `IDEWindowScene`, `IDEAppCommands`), `IDEMenuShortcuts.swift` |
| Delegate / routing | `IDEAppDelegate.swift`, new `IDEWindowRegistry.swift`, new `IDEOpenRouter.swift` |
| Workspace | `IDEWorkspace.swift` (init, `window`, `teardown`, session split, `NSApp.keyWindow` uses, `openRecentProject`, `openDroppedURLs`) |
| Window chrome | `IDERootView.swift` (`IDEWindowConfiguratorView` incl. tabbing mode, `IDEWindowCloseGuard`) |
| Persistence | `IDESessionStore.swift` (split, migration), `IDEPreferences*.swift`, `JavaBreakpointStore.swift`, `IDEJDKSelection.swift`, `IDEJavaSupport.swift` (trust store, run configs) |
| Welcome / recents | `IDEWelcomeView.swift`, `UmbraApp.swift` Open Recent menu |

## Risks

- **Menu bar rewrite.** Moving to `@FocusedValue` means menu items are disabled while nothing is focused (for example during a sheet). Test every command that used to work with no window focused, such as Settings and Open Folder.
- **Retention.** Any lingering strong reference keeps a closed project's index, watcher and terminals alive. Phase 5 verification is not optional.
- **JDK index memory** multiplies per window until phase 4 shares it.
- **Session migration** is one-way risky for users mid-project. Keeping the old file for a release is the safety net.
- **Sandbox.** Security-scoped access is per URL, so a restored window must resolve its own bookmark. Do not assume a bookmark from window A works for window B's project.
- **Two Umbra processes** (a debug build alongside an installed app, for example) share the same on-disk stores today. Atomic writes and re-read-before-merge reduce the damage, but they do not make that supported.
- **Native tabs vs. custom chrome.** A hidden or transparent titlebar may not leave room for the AppKit tab bar, and the tab bar adds a second row above Umbra's editor tabs. Check this in Phase 1 before building on it.
- **Tab groups and "restore only the last window".** A tab group of three projects relaunches as one project. That is intended, but users may notice; Open Recent is the way back.
- **Prompt fatigue.** Asking replace-or-new on every ⌘O gets old fast, which is why the prompt carries a remember-my-choice checkbox and a setting.

## Decisions

1. **Same folder:** focus the existing window (or tab). A second window on one project is out of scope for now.
2. **Relaunch:** restore only the last (most recently key) window.
3. **Open Folder…:** if the current window already has a project, ask "Open in New Window" or "Replace This Window's Project"; an empty window is reused without asking. External opens (Dock, `open -a`) always open a new window.
4. **Native macOS window tabs:** supported from the start, one `NSWindow` and one `IDEWorkspace` per project, following the system tab preference.

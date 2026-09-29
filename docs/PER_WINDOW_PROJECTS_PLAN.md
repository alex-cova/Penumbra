# Per-window projects in Umbra

Status: proposal. Nothing here is implemented.

## Goal

Every Umbra window owns one project (or none). Dropping a folder on the Dock icon, ⌘O on a folder, File ▸ Open Recent and `open -a Umbra <dir>` open that folder in its own window, next to the ones already open. Closing a window closes only its project. Quitting and relaunching brings the windows back.

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
3. **New-window rule for external opens.**
   - Folder already open → focus that window.
   - Key window is empty (welcome screen, no project, no dirty documents) → reuse it.
   - Otherwise → open a new window.
   - A file goes to the window whose project contains it, else to the key window, else a new window.
4. **App-wide vs window state split.** App-wide (preferences, theme, keymap, recent files/projects, notification switches) is loaded once and shared. Window-wide (project root, tab layout, sidebar/terminal state, run configuration selection) is stored per window.
5. **Restore all windows that were open at quit**, each with its own project. A window the user closed explicitly is not restored, except that closing the last window keeps it as the "last window" so a plain relaunch still shows the last project.
6. **Heavy per-project services stay per-window** (`IDEJavaSupport`, Gradle runner, debug session, terminals, watcher). The JDK index is large and identical across windows, so it moves to a process-wide shared object in phase 4.

## Plan

### Phase 1 — Window-scoped workspace and menus (no behavior change for one window)

The riskiest structural change; everything else builds on it.

- Add `IDEWindowScene` (a `View`) that owns `@State private var workspace = IDEWorkspace(…)` and renders today's `IDERootView`. `UmbraApp` no longer holds a workspace.
- Publish it with `.focusedSceneValue(\.ideWorkspace, workspace)` (a `FocusedValueKey`), and pull the whole `.commands` block into `struct IDEAppCommands: Commands` using `@FocusedValue(\.ideWorkspace) private var workspace`. Every item becomes `workspace?.…` with `.disabled(workspace == nil)`. `IDEMenuShortcuts` already takes the preset as a parameter, so it moves as is; the preset comes from `IDEPreferences.shared`.
- Replace `IDEAppDelegate.workspace` with `IDEWindowRegistry` (new, `@MainActor`): weak references to every workspace, keyed by an `IDEWindowID` (UUID). Workspaces register in `init` and unregister in `deinit`/`teardown`.
- Give `IDEWorkspace` a `weak var window: NSWindow?`, set by `IDEWindowConfiguratorView.viewDidMoveToWindow`, and replace the `NSApp.keyWindow` / `mainWindow` uses with it (sheets, first-responder resets, alerts must target *their* window, not whichever is key).
- Move the `--open` / `--open-folder` launch arguments out of `IDEWorkspace.init` into the app-launch path so only the first window honors them.
- Ensure `.handlesExternalEvents(matching: ["*"])` stays (SwiftUI must not spawn windows for URLs itself; Phase 3 opens them explicitly).

Exit criteria: with one window, behavior is unchanged; with ⌘N / Dock reopen the second window is an independent empty workspace and menu commands act on the focused window.

### Phase 2 — Split persistence: app state vs window state

- New `IDEAppSessionStore` (`app.json`): preferences snapshot, recent files, recently edited, recent projects, notification switches. Loaded once by `IDEPreferences`/an `IDEAppState` object, saved with a debounce, written atomically.
- New `IDEWindowSessionStore` (`windows/<IDEWindowID>.json` plus a small `windows.json` index with order and the last-key window): `EditorRestorationState`, `projectRootBookmark`, sidebar/structure/gradle widths and visibility, terminal tabs.
- `IDEWorkspace.init(windowID:restoring:)` takes the state it should restore instead of calling `IDESessionStore.load()`. `makeSession`/`saveSession` split accordingly.
- **Migration:** on first launch with the old `session.json` and no `app.json`, split it: app-wide fields go to `app.json`, the rest becomes window 1. Keep `session.json` untouched for one release so a downgrade still works.
- Recent lists are shared, so a write from any window must merge with, not overwrite, what another window just recorded (single `IDEAppState` owner, no per-workspace copies).
- Restore path: `UmbraApp` reads the index and opens one window per entry using `WindowGroup(id: "main", for: IDEWindowID.self)`. Windows opened with a value get that ID; the plain "no value" window gets a fresh ID.

Exit criteria: two windows with different projects and tabs survive quit + relaunch; old `session.json` users keep their project.

### Phase 3 — Routing external opens and the Dock

- The delegate cannot call `openWindow`. Extend `IDEWindowReopenBridge` to register an `openWindow(value:)` closure with the registry, which queues requests until it exists (cold launch, before any window has appeared; this is today's `pendingOpenURLs` mechanism generalized).
- `IDEWindowRegistry.open(urls:)` applies the routing rule from the design decisions above. It needs a "project root → workspace" lookup (standardized, symlink-resolved path) and an `isEmpty` predicate on the workspace (no project, no documents, none dirty).
- Cold launch with a dropped folder: do **not** restore the previous windows and then replace one. Restore the session as usual, then route the dropped folder through the same rule. Reuse only if the restored window is empty.
- "Open Recent", the welcome screen, ⌘O on a folder and Open Folder… use the same entry point instead of `applyProjectRoot` on the current workspace. Open Folder… gets an explicit "in this window" fallback only when the current window is empty. Add File ▸ New Window (⌘⇧N) and ⌘⇧N handling for "New Project Window".
- Window title/`representedURL` show the project folder name; add the Window menu list (SwiftUI does this for `WindowGroup`).
- Keep `applicationShouldHandleReopen` behavior: no visible windows → reopen the last window from the index, else a welcome window.

Exit criteria: dropping three different folders on the Dock icon gives three windows; dropping one already open focuses it; a file inside an open project lands in that project's window.

### Phase 4 — Shared stores and services that assumed one writer

- `breakpoints.json`, `run-configurations.json`, `gradle-trust.json`, `jdk-selection.json`: today each is loaded once and rewritten whole. With several workspaces that is last-writer-wins. Route each through one process-wide actor-owned store instance (created by the registry, injected into each workspace) that re-reads before merging its own key, or keys writes by project root so windows on different projects never touch the same entry. Gradle trust is security-relevant: a trust decision in one window must be visible in another without a restart.
- Java index (`JavaIndexPaths` shards, `refs.idx`) and Gradle model cache: with the same-folder rule two windows only share the JDK's shards. Verify shard writes are atomic and add a cross-process-safe lock if a second Umbra *process* can exist. Share the JDK stub index between windows behind one object owned by the registry so a second window does not re-index or double the memory of the JDK.
- `IDEEditorTheme.shared` / `IDEPreferences.shared`: a preference change must repaint every window. Confirm the observation path reaches all workspaces, since today it only has one observer.
- Notifications: keep one `IDENotificationCenter` per window (toasts belong to the window they came from) but keep Do Not Disturb and category switches in shared `UserDefaults`, which they already use.

### Phase 5 — Lifecycle and teardown

- Window close: `IDEWindowCloseGuard` asks only its own workspace (`confirmCloseWindow`), saves that window's state, then tears the workspace down.
- Add `IDEWorkspace.teardown()`: stop the file watcher, terminals (kill child shells), debug session, Gradle runs and indexing, and balance the security-scoped `startAccessingSecurityScopedResource()` calls made in `applyProjectRoot` / `openDroppedURLs` (they are never stopped today, which only mattered while there was one project).
- `applicationShouldTerminate`: gather unsaved documents across all workspaces in one prompt. `applicationWillTerminate`: save every window plus the index.
- Confirm the workspace actually deallocates after close (Debug Memory Graph, or a `deinit` log in a test). `navigationBuffers`, Java support callbacks and the `[weak self]` closures are the usual suspects. A leak here means a closed project keeps its index and watcher alive.

### Phase 6 — Tests, docs, polish

- Unit tests (`Tests/PenumbraTests` is a library target; Umbra is an executable, so put the routing logic in a small pure type, e.g. `IDEOpenRouter`, that can be tested without AppKit): folder already open → focus; empty key window → reuse; else new window; file inside/outside a project; symlinked and trailing-slash paths; cold-launch queueing.
- Session tests: migration from a real old `session.json`, per-window round trip, corrupt window file is skipped without losing the others.
- Manual checklist: Dock drop on cold and warm launch; two windows with different Gradle projects (sync, build, debug in both); Cmd-Q with dirty tabs in two windows; closing the first window then the second; changing theme in window A repaints B; `swift run Umbra` (no bundle) still works.
- Run the performance checks in `docs/PERFORMANCE_RULES.md` (`PerfHarness enter-session`); no engine code changes are expected, so any regression points at the per-window plumbing.
- Update `CLAUDE.md` (Umbra section) and `Example/README.md` with the window model, and mention `IDEWindowRegistry` there.

## Files most likely to change

| Area | Files |
| --- | --- |
| Scene / menus | `UmbraApp.swift` (split into `IDEWindowScene`, `IDEAppCommands`), `IDEMenuShortcuts.swift` |
| Delegate / routing | `IDEAppDelegate.swift`, new `IDEWindowRegistry.swift`, new `IDEOpenRouter.swift` |
| Workspace | `IDEWorkspace.swift` (init, `window`, `teardown`, session split, `NSApp.keyWindow` uses, `openRecentProject`, `openDroppedURLs`) |
| Window chrome | `IDERootView.swift` (`IDEWindowConfiguratorView`, `IDEWindowCloseGuard`) |
| Persistence | `IDESessionStore.swift` (split, migration), `IDEPreferences*.swift`, `JavaBreakpointStore.swift`, `IDEJDKSelection.swift`, `IDEJavaSupport.swift` (trust store, run configs) |
| Welcome / recents | `IDEWelcomeView.swift`, `UmbraApp.swift` Open Recent menu |

## Risks

- **Menu bar rewrite.** Moving to `@FocusedValue` means menu items are disabled while nothing is focused (for example during a sheet). Test every command that used to work with no window focused, such as Settings and Open Folder.
- **Retention.** Any lingering strong reference keeps a closed project's index, watcher and terminals alive. Phase 5 verification is not optional.
- **JDK index memory** multiplies per window until phase 4 shares it.
- **Session migration** is one-way risky for users mid-project. Keeping the old file for a release is the safety net.
- **Sandbox.** Security-scoped access is per URL, so a restored window must resolve its own bookmark. Do not assume a bookmark from window A works for window B's project.
- **Two Umbra processes** (a debug build alongside an installed app, for example) share the same on-disk stores today. Atomic writes and re-read-before-merge reduce the damage, but they do not make that supported.

## Open questions for you

1. Should a window on a folder that is already open focus the existing one (recommended), or is a second window on the same project wanted?
2. On relaunch, restore every window that was open, or only the last one?
3. Should Open Folder… (⌘O in the Sublime keymap) open in a new window by default, or replace the current window's project when that window already has one? The plan assumes new window, with reuse only of an empty window.
4. Do you want native macOS window tabs (merging windows into one tab bar) later? It affects whether windows are `NSWindow`-per-project or tab-grouped, and is cheaper to decide now.

# Per-window projects: follow-up work

Status: items 1 to 5 implemented in the working tree, not committed (see "Results"). The plan was revised after checking every claim against the code and after the decisions listed at the end.

These are the leftovers from `docs/PER_WINDOW_PROJECTS_PLAN.md` (phases 1 to 5, committed on `main`). Each item says what is wrong today, what to change, how to know it worked, and what it depends on.

## Summary and order

| # | Item | Size | Kind | Do after |
| --- | --- | --- | --- | --- |
| 1 | Sidebar widths reset on every save (both widths) | S | Bug (predates the window work) | nothing |
| 2 | Menus: resolve the workspace late and optionally, delete `placeholder` | S | Cleanup | nothing |
| 3 | Read a shard's stamp from its header, not by parsing the shard | S | Performance (every sync) | nothing |
| 4 | Test coverage: session-window rules, preference fan-out, retention guards | M | Tests (+ one small refactor) | 2 |
| 5 | Share jar readers: fast re-sync, no duplicate parsing, bounded memory | M | Speed / memory | 3, and a measurement gate |

Size: S is a focused change plus tests, M touches several files and needs a measurement. Each item is one commit.

Order: 1, 2, 3, 4, 5. Items 1 to 3 are independent and small. Item 4 follows 2 so the source guard is written against the final menu code. Item 5 follows 3 because it relies on a cheap "is this shard current?" check.

Cross-process safety (file locks, a second Umbra process) is deliberately **not** in this plan; see "Deferred" at the end.

### Results

Full suite after all five items: 3090 tests, 5 skipped, 0 failures. `PerfHarness enter-session synthetic --lines 20000` (release): Enter 0.8 ms at the top, 11 ms mid-file, scroll page 3 ms; nothing on the typing path changed, run for the record.

| # | Done | Notes |
| --- | --- | --- |
| 1 | yes | `IDEWorkspace.sidebarWidth`; both widths seeded in `bootstrap()` (`seedPanelWidths(from:)`); `IDERootView` loads the file once and mirrors both widths; `saveSession`/`makeSession` take optional widths. 4 tests. **Not verified by hand:** drag, quit, relaunch, and a second window. |
| 2 | yes | Seven menu views use `private var workspace: IDEWorkspace? { ref.workspace }`; `IDEWorkspace.placeholder` deleted. Open-recent's local was renamed `target` so the guard in item 4 can police the name `workspace`. **Not verified by hand:** the menus with no window and after closing a window. |
| 3 | yes | `JavaIndexShardReader.readStamp(at:)` reads 24 bytes; `indexOne` uses it. 5 tests. Measured (debug): 9.4 ms per 5000-class shard with the reader, 14 µs with `readStamp`; all 700 shards of this machine's jar cache: 75 ms against 737 ms. |
| 4 | yes | 4a `IDESessionWindowPolicy` (14 tests; registry delegates to it); 4b `IDEPreferenceFanOutTests` (3, restore the user's preferences; mutation-checked); 4c.1 to 4c.3 `IDERetentionGuardTests` (7); 4c.4 `IDEHostedWindowRetentionTests` behind `UMBRA_UI_TESTS=1`, 10 of 10 runs passed. |
| 5 | yes | See item 5. |

Deviations from the plan as written: 4c.3 is a source guard on the panel's callbacks (`[weak workspace]`) plus a test that a terminal host view is freed, because the callbacks the panel installs are built inside SwiftUI and cannot be reproduced in a test. 4c.4 covers hosting-view retention, not the delegate bug (which has its own test, mutation-checked). The retained-jar budget is 40,000 names, not 100,000 (see the measurement below).

### Item 5 measurement (this machine, debug build, 700 jar shards, 216k names, 107 MB of shard files)

| Step | Time | Footprint |
| --- | --- | --- |
| Old behaviour: one window parses every jar serially | 0.74 s | +96 MB per window |
| Window A, first load through the hub (parallel) | 0.12 s | +107 MB |
| Window B asks for the same jars | 0.06 s (stamp checks) | +0 MB, 700 of 700 readers are the same objects |
| After both windows release, with a 100k-name budget | 0.116 s to reopen | 68 MB still held |

Parsing everything in parallel is cheap enough that keeping released readers saves about 60 ms for up to 68 MB, so the budget was cut to 40,000 names (about 25 MB). The sharing is the main gain: the second window costs nothing, and the first load is about six times faster than the old serial loop. **Not done:** the two-window run in the app with `heap <pid>` / `footprint`, and a timed re-sync in the app.

### What changed from the first draft

- **1:** the mirror-on-change design did not fix the bug for a window that is never dragged; it also affects the Gradle width. Reworked (`@State` plus seeding, as decided).
- **2:** the menus already use the cheaper pattern (an optional `workspace`) in two places. The `act { }` helper and `content(current)` restructure are dropped in favour of it, since `content(current)` reintroduces the capture risk it tried to prevent.
- **3 (new):** `JavaIndexScheduler.indexOne` parses the whole shard only to compare its stamp. The stamp sits at a fixed offset in the header.
- **4:** the preference-fan-out test would have rewritten the developer's real `UserDefaults`; fixed. The retention guard rules follow the new menu shape.
- **Cross-process locking (old item 4):** removed. You do not run two processes against one data directory, so the locks, the store changes, the model-cache digest and the launch notice are all deferred.
- **5 (old item 5):** the cache policy is now "keep immutable release jars, hold changing jars weakly, both checked against the file's stamp on every use", progress for waiting windows is specified, and there is a measurement gate.

---

## 1. Sidebar widths reset on every save

### Problem

`IDEWorkspace.saveSession(sidebarWidth:gradleSidebarWidth:terminalHeight:)` (`IDEWorkspace.swift:3382`) defaults `sidebarWidth` to `IDEAppearance.Spacing.sidebarWidth`, while the other two fall back to the workspace's own values. Nearly every caller (terminal tab changes, opening a folder, closing a tab, quit, a window closing; about 30 call sites) passes nothing, so each writes the default sidebar width into `last-window.json`. Only the debounced call in `IDERootView` after a resize passes the real width, which lives in the view's `@State`.

A second, related defect: `IDERootView` initialises both `@State` widths from `IDEWindowSessionStore.load()` (two separate file reads), but the workspace's `gradleSidebarWidth` is only set in `loadSession`, i.e. when the window restores. A window that does not restore (opened next to another, or one that shows a folder the user asked for) displays the saved Gradle width while the workspace holds 220, and writes 220 as soon as it becomes the session window. So the Gradle width has the same bug on every non-restored window.

### Change

The first draft mirrored the width with `.onChange` and initialised the `@State` from the workspace. That does not work: a property initialiser cannot read `@Environment`, and `.onChange` never fires for the initial value, so a window that is never dragged would keep saving the default. Instead:

- `IDEWorkspace` gets `var sidebarWidth` next to `gradleSidebarWidth`; `makeSession` uses it (`sidebarWidth ?? self.sidebarWidth`).
- Seed both widths in the workspace itself, not the view: `bootstrap()` sets `sidebarWidth` and `gradleSidebarWidth` from the last saved window (`loadSession` for a restoring window, `IDEWindowSessionStore.load()` for the others, skipped when `isSessionPersistenceEnabled` is false). The view's `@State` keeps reading the same file, so both agree from the first frame.
- `IDERootView` loads the file once (one `let` used by both `@State` initialisers) and mirrors the drag into the workspace with `.onChange(of: sidebarWidth) { workspace.sidebarWidth = $1 }`, as it already does for the Gradle width.
- Remove the `sidebarWidth:` default from `saveSession` and make the parameter optional like the other two (`sidebarWidth: Double? = nil`), so a caller cannot reintroduce the default.

### Tests and verification

- Unit: `makeSession()` with no arguments returns the workspace's `sidebarWidth`, `gradleSidebarWidth`, `terminalHeight` (the `IDEWorkspaceLifecycleTests` setup, persistence disabled).
- Unit: a session with non-default widths round-trips through `loadSession` into both workspace properties.
- Unit: after `bootstrap()` of a non-restoring workspace with a stored session on disk (use a temp file through the store's URL seam, or extract the seeding into a function taking the loaded session), both widths equal the stored ones.
- Manual: drag the sidebar, open a terminal tab, quit, relaunch: width kept. Open a second window next to the first, open a folder in it, quit: both widths kept. Same after closing the window that was last active.

### Risk

Low. The subtle part is ordering: seeding must happen before the first `saveSession` of a fresh window (bootstrap runs first).

---

## 2. Menus: resolve the workspace late and optionally, delete `placeholder`

### Problem

Seven menu views (`IDEAppCommands.swift:190, 212, 243, 299, 331, 386, 405`) expose `private var workspace: IDEWorkspace { ref.workspace ?? IDEWorkspace.placeholder }`, and `IDEJDKMenuFromRef` does the same at line 511. `placeholder` is a never-bootstrapped static workspace.

What the first draft got wrong: `??` takes an autoclosure, so the placeholder is only built when the window behind a stale menu item has closed, not at launch. The real defects are smaller and different: a click on a stale item would run an action against a dummy workspace, and the code path that uses it is hard to reason about.

The file already contains the better pattern: `IDEAppCommands` and `IDEFileCommands` use `private var workspace: IDEWorkspace? { ref?.workspace }` with `workspace?.foo()` and `.disabled(workspace == nil)`. Closures capture only `self`, which holds the weak handle, so there is no retention risk, and a stale click does nothing.

### Change

Apply the existing pattern to the remaining seven views:

- `private var workspace: IDEWorkspace? { ref.workspace }`; actions become `workspace?.showFind()`; `Task { await workspace?.save…() }` as in `IDEFileCommands`.
- Reads: `preset` comes from `IDEPreferences.shared.keymapPreset` (what `IDEFileCommands` already does; `workspace.preferences` is that same singleton). `.disabled(workspace == nil)` on items that need a window, `.disabled(!(workspace?.canEditRunConfiguration ?? false))` for conditions. Toggles use the existing `binding(_:)` helper, which returns a constant `false` binding when the workspace is gone.
- `IDEJDKMenuFromRef`: `if let workspace = ref.workspace { IDEJDKMenuContent().environment(workspace) }`. The menu content is built per body evaluation and not stored, so this is safe; note in the code why.
- Delete `IDEWorkspace.placeholder` and its doc comment (`IDEWorkspace.swift:146`).

Rejected: the first draft's `if let current = ref.workspace { content(current) }` plus an `act { }` helper. It introduces a local that closures can capture strongly, which is the exact bug class the menus were rewritten to avoid, and it adds a new idiom next to an existing one.

The compiler finds every missed site because `workspace` becomes optional. Read by hand: multi-line closures (Save, Save As, terminal tab close, language picker) and anything combining `workspace?` with `await`.

### Tests and verification

- The source guard from item 4 (3c) runs over the new shape.
- Build; drive File, Go, Run, Git, Java, HTTP and View items on the front window through accessibility scripting as in phase 5; open each menu with no window (it shows "No Open Window"); close a window, open each menu in the remaining one, and check no stale action fires.

### Risk

Low: about 100 mechanical call sites, compiler-checked.

---

## 3. Read a shard's stamp from its header

### Problem

`JavaIndexScheduler.indexOne` decides "up to date" with `try? JavaIndexShardReader(url: shardURL)` and compares `existing.stamp`. The reader's `init` parses the whole name table and offset index eagerly (`JavaIndexStore.swift:107`); the existing comment in `IDEJavaSupport` puts that at about 750 ms for a Gradle project's jars. So every sync, for every jar, pays a full parse just to read 16 bytes, and throws the reader away. The hub (`JavaSharedShardHub`) then parses the shard again for its own cache.

### Change

- Add `JavaIndexShardReader.readStamp(at url: URL) -> JavaStamp?`: read the first 24 bytes (magic 4, version 4, size 8, modification date 8; offsets as in `init`), validate magic and version, return the stamp. No table parsing.
- `indexOne` and the hub's freshness check use it.
- Keep one layout definition: have `init` call the same header parse so the two cannot drift.

### Tests and verification

- `readStamp` equals `JavaIndexShardReader(url:).stamp` for a written shard; nil for a missing file, a truncated file, bad magic and a wrong format version.
- Existing `JavaIndexSchedulerTests` still pass.
- Measure: re-sync of a project with a few hundred up-to-date jars, before and after (time to `allFinished`). Record the numbers in this file.

### Risk

Low. Benefits every window and every sync, independent of the rest of the plan.

---

## 4. Test coverage

Three gaps, each with a different seam.

### 4a. Session-window rules

**Gap.** `IDEWindowRegistry.sessionWindow`, the hand-over in `unregister`, and `shouldRestoreLastWindow` are only checked by running the app. They are coupled to `IDEWorkspace`, which is too heavy to build a scenario with.

**Seam.** Extract the decisions into a pure value type, `IDESessionWindowPolicy`, the way `IDEOpenRouter` was extracted (it has its own file and tests):

- State: the registered windows most recently key first, as `[(id, isPristine)]`, plus the pending new-window job count.
- `sessionWindow` → id of the first non-pristine window.
- `successor(afterClosing:)` → the id that takes over and saves, or nil when the closing window was not the session window or no non-pristine window remains.
- `shouldRestoreLastWindow` → no windows and no pending jobs.
- Ordering: `activated(_:)` (move to front, ignored for unregistered ids) and `registered(_:isKey:)` (front if key, else append).

`isPristine` is live state on the workspace, so the registry builds the snapshot on each query from its weak entries; the policy holds only the ordering and the job count. The registry's surface stays identical.

**Cases.**

- A blank window opened next to others never becomes the session window, even when key.
- Making it non-pristine makes it the session window if it is the most recently key.
- Closing the session window hands over to the most recently key non-pristine window, and to nobody when only pristine windows remain (the closing window's own save stands).
- Closing a background window changes nothing.
- `activated` for an unregistered id is ignored (the phase 3 bug).
- A registered key window goes to the front; a non-key one goes to the back.
- No restore while another window is open or a new-window job is pending; restore when neither.

### 4b. Preference fan-out

**Gap.** `applyPreferencesToAllHosts()` reaching every window was checked once by hand. Nothing stops it regressing to "current window only".

**Hazard in the first draft.** `IDEPreferences.shared` writes every property to `UserDefaults.standard` in `didSet`. A test that toggles `showMinimap` through it changes the developer's real settings.

**Test.** Two bootstrapped workspaces (persistence disabled, a keeper window registered so neither restores). Snapshot the preference under test (`showMinimap`, `tabWidth`) before and restore it in `defer`, through the same setter so `UserDefaults` ends as it started. Change it, call `applyPreferencesToAllHosts()`, assert both workspaces' editor text views picked it up. Also: a workspace that has not registered yet is still updated (`applyPreferencesToAllWindows(including:)`); a torn-down window is skipped without crashing. If this pattern appears a second time, inject a `UserDefaults` suite into `IDEPreferences` instead of snapshotting.

### 4c. Retention guards

**Gap.** The teardown test bootstraps a workspace and proves it is freed, but cannot see the causes found in the running app: the window delegate not forwarding `windowWillClose`, menu closures capturing the workspace, terminal callbacks.

**Checks, cheapest first.**

1. **Delegate forwarding.** Unit-test `IDEWindowCloseGuard` with a stub upstream delegate that the test holds strongly (the guard's `upstream` is weak on purpose: a strong one would keep SwiftUI's window controller alive after close). `responds(to:)` is true for selectors only the stub implements (`windowWillClose(_:)`, `windowDidResize(_:)`); calling them reaches the stub; `windowShouldClose` consults the stub.
2. **Menu capture guard.** A source-level test reading `IDEAppCommands.swift` via `#filePath`, failing on: a stored `let workspace: IDEWorkspace` (non-optional, non-ref), `IDEWorkspace.placeholder`, a method reference such as `action: workspace.`, and `ref.workspace` bound to a local (`let x = ref.workspace`, `if let x = ref.workspace`) inside a menu view except the JDK menu. After item 2 the rule is that the only way to reach the workspace is the optional `workspace` property, read at the moment of use. Crude, but it guards the regression that happened and runs in milliseconds.
3. **Terminal callbacks.** Create an `IDETerminalHostView` with the callbacks the panel installs (`onTitleUpdate`, `onDirectoryUpdate`, and the rest), drop every other reference, assert the workspace they were wired to is freed. No shell needed.
4. **Hosting-view retention (stretch).** `IDERootView().environment(workspace)` in an `NSHostingView` inside an offscreen `NSWindow` with the real close guard installed; close the window, release everything, assert the workspace is freed. Needs a window server. Gate it behind an environment variable (`UMBRA_UI_TESTS=1`) rather than a runtime window-server probe, so it is an explicit opt-in locally and in CI. Run it ten times in a row before keeping it.

### Verification

`swift test --filter` on the new suites, then the full suite.

### Risk

4a refactors working code: keep the registry's public surface identical and use the phase 2 manual scenarios as the regression check. 4c.4 is the only flaky candidate.

---

---

## 5. Share jar readers: fast re-sync, no duplicate parsing, bounded memory

### Problem

Jar shards are indexed and parsed per window. Two windows on two Gradle projects using the same libraries each run their own `JavaIndexScheduler` over those jars and each parse the same shard into their own heap (`IDEJavaSupport` opens `JavaIndexShardReader(url:)` per target at lines ~1021 and ~1025). The reader's parse result (name table, offset index, name list) is heap, not mapped memory, so this is real per-window cost.

It also costs a single window: every Gradle sync re-parses all jar shards from disk (the ~750 ms noted in `IDEJavaSupport`) even when nothing changed, and `indexOne` parses each one a second time just to read its stamp (fixed by item 3).

Phase 4 already shares the JDK shard through `JavaSharedShardHub`; this extends that to jars.

### Gate: measure before building

Two windows on two Gradle projects with overlapping dependencies: `heap <pid> | grep JavaIndexShardReader` for live readers, `footprint` for the process, and the time a re-sync of an unchanged project spends loading readers (after item 3). Record the numbers in this file, and also the heap cost of one typical reader, which sets the budget below. Proceed only if the duplicated heap or the re-sync load time is material. If it is small, record that and drop the item. Note the reader holds three copies of the name data (`allQualifiedNames`, the offset table keys, the string table); if that dominates, shrinking it is a cheaper fix than sharing and helps every case.

### Scope: which shards

| Shard | Share between windows? | Why |
| --- | --- | --- |
| JDK | yes (done) | identical for every project |
| **Jar** | **yes** | same file, read-only; different projects routinely share jars |
| Project sources (`sources.idx`, `refs.idx`) | **no** | keyed by source root, rewritten on every `.java` change on disk (`stubRefreshTask`); a shared reader would go stale under the window that is not the one editing |
| Gradle model cache | **no** | keyed by project root (one window per root), small, read once per open |

### Cache policy: fast, bounded, never stale

Staleness is handled by one rule that applies to every jar: **the reader's stamp is compared with the jar's current stamp (size and modification date) on every request**, and a mismatch rebuilds the shard and replaces the reader. A stat per jar is cheap, so no cached reader can be served stale, whatever the jar is. What the classification below decides is only how long an unused reader is kept.

- **Immutable jars: keep strongly, in a bounded LRU.** A release artifact in a dependency cache never changes at a given path: a path under Gradle's `modules-2/files-2.1/` or Maven's `.m2/repository/` whose file name does not contain `SNAPSHOT`. These are the jars every project shares (Guava, JUnit, Spring), so their readers stay loaded after the last window stops using them, and reopening a project or re-syncing costs a stat per jar instead of a parse. The LRU is bounded by an estimated heap budget (for example the sum of `allQualifiedNames.count` across readers as a proxy, with the limit chosen from the gate's measurement), not by a count, so it cannot grow with the number of projects opened.
- **Changing jars: hold weakly.** `SNAPSHOT` artifacts, `changing` or dynamic-version modules, local `libs/*.jar`, and module outputs can be rewritten in place. Their readers live only while some window's `jarSources` holds them and are freed with the last window. Rebuilt jars are caught by the stamp rule above.
- **Memory pressure.** The host (`IDESharedServices`) drops the strong LRU on a memory-pressure event (`DispatchSource.makeMemoryPressureSource`, a public API) and keeps the weak part as is; the library itself schedules nothing in the background.
- The classification is one small pure function (`isImmutableArtifact(path:)`) with its own tests, so the rule can be tightened (for example to read a Gradle cache metadata flag) without touching the hub.

### Change

- **Batch API on the hub.** `JavaSharedShardHub.shards(for: [(root, shardURL)], onProgress:)`. For each root: return the cached reader if `readStamp` matches the root's stamp; wait on the in-flight run if another window started it; otherwise include it in one scheduler call for the roots nobody is indexing (keeping the scheduler's bounded concurrency, which is what makes hundreds of jars fast).
- **Progress for waiters.** The window's status line counts `rootFinished` / `rootSkipped` events against its own target total (`indexAllTargets`). A window whose roots were all started by another window would receive nothing and sit on "Indexing dependencies… (0/N)". The hub therefore emits `rootSkipped(reason: "indexed by another window")` (or `rootFinished`) to each waiter as the awaited run completes; `rootStarted` and the per-class counts go to the starter only. Roots served from the cache report `rootSkipped("up to date")`.
- **Cancellation.** Runs are unstructured tasks owned by the hub, as in the JDK case: a window that changes project and stops consuming progress must not cancel a run other windows wait on.
- **Wire it in.** `IDEJavaSupport`'s jar path (the `jarIndexTargets` passed to `scheduler.index` and the `Task.detached` reader loading in `indexAllTargets`) goes through the hub, which returns the readers directly, so the second open-and-parse pass disappears. The window's scheduler stays for project shards. `jarSources` keeps strong references to the readers it uses.
- **Invalidation.** `IDEJavaSupport` deletes jar shards before a forced re-index (`removeItem(at: paths.jarShard(jar))`, ~line 909). Add `hub.invalidate(_ shardURL:)` (drops the reader from both the LRU and the weak map) and call it there; deleting a file another window has mapped is safe on macOS (the inode lives until unmapped).
- Update the "Not shared: jar …" line in `PER_WINDOW_PROJECTS_PLAN.md` (line 112) and `Example/Umbra/CLAUDE.md`.

### Tests and verification

- Hub: two concurrent batch requests with overlapping roots index each shared root once; the readers for a shared root are the same object; a waiter's progress reaches its total (`rootSkipped`/`rootFinished` per root, `allFinished` once); a changed stamp re-indexes and replaces the reader (for both an immutable and a changing jar); `invalidate` makes the next request rebuild; a starter that stops listening does not cancel the run.
- Policy: an immutable jar's reader survives the last holder releasing it; a changing jar's reader does not; the LRU stays under its budget when many jars are requested; dropping on memory pressure empties the strong part only.
- `isImmutableArtifact`: Gradle and Maven cache paths, `-SNAPSHOT` names, local `libs/` jars, module build outputs.
- The measurement from the gate, repeated after; record both. Add a re-sync timing (unchanged project, warm and cold).
- PerfHarness is not relevant (nothing on the typing path); run it once anyway for the record.

### Risk

Medium. The weak lifetime must not free a reader a window still needs (`jarSources` holds strong references), and cross-window progress is the fiddly part; the waiter events above are the simplest rule that keeps the counters correct. The strong LRU is what can cost memory, which is why it is budgeted and dropped on pressure.

---

## Decisions made

1. **No second process is supported or used**, so cross-process safety is deferred (below).
2. **Item 1 keeps `@State` with seeding**, no `@Bindable` rework.
3. **Item 5 cache policy:** fastest reasonable option that cannot go stale: stamp check on every request, strong bounded LRU for immutable release jars, weak for changing ones.
4. **Item 4c.4 (hosting-view retention test) is kept** behind `UMBRA_UI_TESTS=1`; run it ten times in a row locally before it stays.
5. **Project shards and the model cache stay per window.** If that changes, item 5 grows: shared project readers need change notifications so a rewrite by one window refreshes the other's reader.

## Deferred: cross-process safety

Removed from this plan because two Umbra processes against one data directory is not a scenario in use. For the record, what would be needed if it becomes one, so the work does not have to be rediscovered:

- The four JSON stores (`GradleTrustStore`, `JDKSelectionStore`, `JavaRunConfigurationStore`, `JavaBreakpointStore`) reload on a changed modification date (`FileChangeStamp`), which makes a second process non-destructive in most cases but leaves a short read-modify-write race. Closing it needs an advisory `flock` around reload, mutate and write.
- Two processes can index the same shard at once: duplicate CPU only, never corruption (writes are atomic). A shard lock must be polled asynchronously (`LOCK_NB` plus `Task.sleep`), because a blocking `flock` inside the cooperative pool can starve it, and lock files belong in one `locks/` directory rather than next to hundreds of shards.
- `GradleProjectModelCache.store` writes `meta.json` and `model.json` separately, so another process could pair a new fingerprint with an old model. No lock is needed: an optional SHA-256 of `model.json` in the metadata, written model first, rejects a mismatched pair and leaves old entries valid.
- A launch-time notice ("Another Umbra is running") needs a non-blocking `flock` on an `instance.lock` file held for the process lifetime.
- `IDESharedServices` documents the current position ("not a supported setup, just no longer destructive"); that stays accurate.

## Out of scope here

Two windows on the same project (the plan's decision 1 keeps focus-existing), restoring more than the last window, regenerating `Example/Umbra.xcodeproj` (it was already missing about 55 sources before the window work and needs its own pass), shrinking the reader's in-memory name tables (mentioned in item 5's gate; its own item if the measurement points at it), and the manual checklist items in the main plan (Gradle across windows, the quit prompt with real unsaved editors, theme repaint across windows, tab-group edge cases), which need a person at the keyboard or an automation that can type into the editor.

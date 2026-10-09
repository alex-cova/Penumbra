# Local History: automatic labels, history-dialog extras, working-day retention

## Context
Local History already ships (commit `4616679`, `Example/Umbra/LocalHistory/`, documented at `Example/Umbra/CLAUDE.md:59`). It records saves, baselines, agent writes, refactorings, reverts and external changes per file, and has a History sidebar tab. Measured against IntelliJ's Local History page, the user picked three gaps to close (not whole-project snapshotting):
1. **Automatic labels.** Project-wide labels for IDE events: Gradle sync, build, test runs, run, and git commit, pull and branch switch. A project-wide **Put Label**, plus revert or diff of the whole project back to a label.
2. **History dialog extras.** Search revisions by content, **Create Patch**, **Show History for Selection**.
3. **Retention like IntelliJ.** Keep N *working days* per file (days the file changed), not N calendar days.

All of this is Umbra-only (`Example/Umbra`), so the Penumbra and EditorIntelligence App Store constraints are untouched. Nothing new runs on the typing path, and store work stays inside the `IDELocalHistoryStore` actor.

## 1. Data model: project labels (`IDELocalHistoryStore.swift`)
- Add `enum IDELocalHistoryMilestone: Codable, Equatable` with these cases:
  - `userLabel`
  - `gradleSync(succeeded: Bool)`
  - `build(tasks: String, succeeded: Bool)`
  - `tests(passed: Int, failed: Int, skipped: Int)`
  - `run(String)`
  - `commit(String)`
  - `beforePull`
  - `beforeBranchSwitch(String)`
- Add a source case `IDELocalHistorySource.project(IDELocalHistoryMilestone)`.
  - A project label is an `IDELocalHistoryEvent` with `path == ""`, no `before`/`after`, and `label` set to its display name.
  - It never touches `known`.
  - Old `index.jsonl` files still decode, because the case is additive.
- `recordProjectLabel(_ milestone:, name:, at:) -> IDELocalHistoryEvent?`.
  - An automatic label is skipped when the newest event is an identical automatic label. Re-running the same tests with no edits in between adds nothing.
- Reading:
  - `events(forPath:)` and `events(under:)` also return project labels inside the range they cover, so labels show between a file's revisions as in IntelliJ.
  - `recentEvents` returns them as they are.
- `state(ofPath:at:) -> String??` gives a file's known content hash at a moment: the `after` of its last event at or before that time. Double-optional means "unknown" vs "deleted".
- `changes(since label:) -> [(path, atLabel: String?, now: String?)]` lists every path whose newest event is after the label and whose state differs. A path first seen after the label with `before == nil` counts as "did not exist".
- Add `isPinned` on the event: a file label (`.label`) or a `.project(.userLabel)`. Pruning keeps pinned events past the age limit (it used to keep `label != nil`, which would now keep automatic labels forever). For every pinned project label it also keeps each path's last event at or before the label, so "Revert Project to Label" still has the texts it needs.

## 2. Working-day retention (`IDELocalHistoryStore.prune`)
- `prune(now:, workingDays:, maxBytes:, calendar:)` works per path. It counts the distinct calendar days of that path's events and keeps the events on the newest `workingDays` days. Automatic project labels are kept on the project's newest `workingDays` days with any event. The size cap, the pinned rules and the orphan-object sweep stay.
- Also fix the O(n²) size loop while there. Today it rebuilds `referenced()` after every removal. The fix: reference-count hashes once, decrement as events drop, and stop when the total fits.
- Defaults:
  - `IDELocalHistoryRecorder.pruneOncePerDay` reads the same `umbra.localHistory.days` key, meaning working days now.
  - The default changes from 7 to **5**, IntelliJ's default.
  - The same default goes in `IDEPreferences.swift:687`.
- Settings ▸ General (`IDEPreferencesView.swift:194`): "Keep for Days" becomes "Keep for Working Days", with the help text "Days on which a file changed; idle days don't count."

## 3. Recording the milestones
`IDELocalHistoryRecorder` gets `recordMilestone(_:)`, which builds the name through `IDELocalHistoryPresentation.title`. It is called from:

| Event | Hook |
|---|---|
| Gradle sync finished or failed (not cancelled) | `IDEWorkspace.notifyGradleSync` (`IDEWorkspace.swift:4508`) |
| Build / other Gradle tasks | `notifyGradleTasks` (:4526), before the existing early return for test/run tasks |
| Gradle `run`/`bootRun` | same function: `isRunTask` → `.run(task)` |
| Test run results | `applyGradleTestOutput` (:4585) after `testResults.finishRun(parsed)`, using `parsed.passedCount/failedCount/skippedCount` |
| Single-file run | `launchActiveJava(mode: .run)` (called from `runActiveJava` :1610), `.run(fileName)` |
| Commit | `IDEGitStatus.commit()` (`IDEGitStatus.swift:302`) onSuccess |
| Pull / Pull & Push | `IDEGitStatus.pull()` / `pullAndPush()` (:384/:374), before `runGitAction` |
| Branch switch | `IDEGitStatus.switchBranch` (:320), before `runGitAction` |

`IDEGitStatus` gets an `onMilestone: (@MainActor (IDELocalHistoryMilestone) -> Void)?` closure. `IDEWorkspace` sets it next to `onWorkingTreeChanged` (`IDEWorkspace.swift:223`) to call `localHistory.recordMilestone`. That keeps git independent of Local History.

**Project-wide Put Label** (`IDEWorkspace+LocalHistory.swift`):
- `putLocalHistoryLabel()` becomes project-wide. It uses the same alert, now worded "Name the project's current state…". It first saves baselines for every open text document (`recordBaseline`), then records `.project(.userLabel)`.
- The old per-file label stays as **Put Label on This File…** in the editor's right-click ▸ Local History submenu (`localHistoryContextMenuItems`).
- View ▸ Put Label (`IDEAppCommands.swift:540`), the palette command (`IDEWorkspace.swift:5021`) and the panel's tag button create project labels.

**Label actions** (new functions in `IDEWorkspace+LocalHistory.swift`):
- `localHistoryShowChanges(since label:)` builds one `IDEDiffRequest` per changed path: `.text(atLabel)` on the left and `.workingTree` on the right, or empty text for created/deleted files. It opens the first with `openDiff(_:siblings:)` so Previous/Next File walk the rest. A missing blob shows the existing "no longer stored" notice.
- `localHistoryRevertProject(to label:)` confirms with an `NSAlert` that lists up to 10 files ("and N more"). It then calls `localHistoryRestore(path:to:)` for each path. Each restore is recorded as `.revert` under one shared group id; this means adding a `group:` parameter to `localHistoryRestore` and the `record` it calls. It reports "Reverted N files" through `notifications`. Unsaved open buffers are changed in place, as one undo step, the same way file reverts already work.
- In file scope, a label row compares or reverts **that file** to its state at the label, using `state(ofPath:at:)`.

## 4. History dialog extras
**Search by content** (`IDELocalHistoryPanel`):
- A search field in the header, `.task(id: query)` with a 200 ms delay.
- The store gains `matchingEvents(_ ids:, containing query:) -> Set<UUID>`. It decompresses each distinct `after` hash once and matches case- and diacritic-insensitively, with `String.range(of:options:)`. It returns the events whose revision text contains the query.
- An empty query shows everything. Labels always show.
- The empty-state message becomes "No revision contains “…”."

**Create Patch**:
- Add `IDEDiffPatchBuilder.unifiedPatch(left: String?, right: String?, path: String, context: Int = 3) -> String?` (`Example/Umbra/Diff/IDEDiffPatchBuilder.swift`).
  - It uses `IDEDiffComputer.lineChunks(…, maximumMiddle: 20_000)`.
  - It merges chunks whose context overlaps into one hunk and writes standard `@@ -a,b +c,d @@` headers. A `nil` side becomes `/dev/null` with a `new file mode` / `deleted file mode` line.
  - It reuses the `GitLines` rules: CRLF kept, `\ No newline at end of file`.
  - The current single-hunk `patch(for:)` stays as it is.
- Workspace functions `localHistoryCreatePatch(for event:)` (that revision → now) and `localHistoryCreatePatch(since label:)` (every changed file → now, joined).
  - Texts are read off the main actor.
  - An `NSSavePanel` defaults to `<file or project>.patch` inside the project folder, and the panel offers "Copy Patch".
  - "Now" means the open buffer when there is one, through `openBufferText(for:)`, else the disk.

**Show History for Selection**:
- The pure tracker goes in a new file, `IDELocalHistorySelection.swift` (beside Presentation): `static func revisions(newestFirst texts: [String?], selecting lines: Range<Int>) -> [Int]`.
  - It walks from now back through each revision and maps the tracked line range back through `IDEDiffComputer.lineChunks` between neighbours. A chunk inside the range grows or shrinks it, and a chunk before it shifts it.
  - It returns the indices of revisions whose change touched the range.
  - It stops once the range has disappeared, i.e. those lines were introduced by that revision.
- A new scope `IDELocalHistoryScope.selection(path: String, lines: Range<Int>)`.
  - The panel caption reads "Lines 12–40 of Foo.java".
  - Loading reads up to 200 revision texts in the store actor and runs the tracker in a `Task.detached`. A newer selection or reload drops the stale result.
  - The segmented picker gets a "Selection" segment while the scope is active, the same way "This Folder" works.
- Entry points:
  - Editor right-click ▸ Local History ▸ **Show History for Selection**, enabled only with a non-empty selection. The line range comes from the active `textView.selectedRange` over `openBufferText`.
  - The palette command `localHistory.showSelection`.
  - View ▸ Show Local History for Selection.

## 5. Presentation and UI (`IDELocalHistoryPresentation.swift`, `IDELocalHistoryPanel.swift`)
- `title`/`symbol` handle `.project(…)`, with these titles and symbols:

| Event | Title | Symbol |
|---|---|---|
| Gradle sync | "Gradle sync" / "Gradle sync failed" | `arrow.triangle.2.circlepath.circle` |
| Build | "Build succeeded: build" / "Build failed: …" | `hammer` |
| Tests | "Tests passed (42)" / "Tests failed: 3 of 45" | `checkmark.diamond` / `xmark.diamond` |
| Run | "Run bootRun" | `play` |
| Commit | "Commit: first line" | `checkmark.circle` |
| Pull | "Before pull" | none listed |
| Branch switch | "Before switching to x" | none listed |
| User label | its name | `tag.fill` |

- `groups(_:)` never merges a project label with neighbouring events; each label is its own group.
- `isAgent` filter: labels stay visible, for orientation.
- The panel draws project labels as a distinct label row: a tinted background, with the name and time.
- The row's context menu in Recent Changes or a folder offers:
  - Show Changes Since This Label
  - Revert Project to This Label…
  - Create Patch Since This Label…
- In This File / Selection the row's context menu offers:
  - Compare with Current
  - Revert File to This Label
- A file revision's context menu gains **Create Patch…**.

## 6. Docs
Update the Local History bullet in `Example/Umbra/CLAUDE.md:59` with the new sources and milestones, the working-day retention (default 5), the project Put Label versus Put Label on This File, the label actions, search, Create Patch and History for Selection.

## Files
- Modified:
  - `Example/Umbra/LocalHistory/IDELocalHistoryStore.swift`
  - `IDELocalHistoryRecorder.swift`
  - `IDEWorkspace+LocalHistory.swift`
  - `IDELocalHistoryPanel.swift`
  - `IDELocalHistoryPresentation.swift`
  - `Example/Umbra/Diff/IDEDiffPatchBuilder.swift`
  - `Example/Umbra/IDEWorkspace.swift` (milestone hooks, `onMilestone` wiring, palette entries)
  - `Example/Umbra/IDEGitStatus.swift`
  - `Example/Umbra/IDEAppCommands.swift`
  - `Example/Umbra/IDEPreferences.swift`
  - `Example/Umbra/IDEPreferencesView.swift`
  - `Example/Umbra/CLAUDE.md`
- New: `Example/Umbra/LocalHistory/IDELocalHistorySelection.swift`

## Verification
- **Unit tests** (`Tests/PenumbraTests`):
  - `IDELocalHistoryStoreTests`:
    - project labels don't affect `known`
    - consecutive identical automatic labels collapse
    - `state(ofPath:at:)` and `changes(since:)`, including created and deleted files
    - working-day pruning: idle days don't count, and each file is counted separately
    - pinned user labels keep the states they need
    - old index lines still decode
  - `IDELocalHistoryPresentationTests`: label titles and symbols; labels are never grouped with saves.
  - New `IDELocalHistorySelectionTests`: inserts above the range shift it; edits inside are reported; an edit below is ignored; the range is followed to the revision that introduced it.
  - `IDEDiffPatchBuilderTests`: `unifiedPatch` with several hunks, overlapping context, a new file, a deleted file, and no final newline, each checked with real `git apply --check`, as the existing tests do.
  - `IDELocalHistoryIntegrationTests`:
    - commit, sync and test hooks record labels
    - Revert Project to Label restores two files (one open with unsaved edits as one undo step, one closed) and records one `.revert` group
    - Show Changes Since Label opens a diff with siblings
- Run `swift test --filter 'IDELocalHistory|IDEDiffPatchBuilder'`, then `swift build`.
- **Manual:**
  - In `swift run Umbra`, open a Gradle Java project.
  - Edit and save a file, run Build Project, run a test class and commit, then check that Recent Changes shows the labels in order.
  - Revert Project to the label before the commit.
  - Select lines and run Show History for Selection.
  - Search for a string that only an old revision contains.
  - Create Patch, then `git apply --check` it.
- No typing-path change, so PerfHarness is not needed.

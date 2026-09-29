# Plan: the smaller gaps left by the IntelliJ keymap work

`docs/INTELLIJ_KEYMAP_FEATURES_PLAN.md` closed every phase except 7 (Generate Code with AI, blocked on decisions) and a short list of "smaller gaps". This plan covers those five:

| # | Gap | Effort |
|---|---|---|
| A | Revert only works on the active file | S–M |
| B | Replace in Files has no file mask or scope, and no preview of the new line text | M |
| C | Workspace Go to Symbol only covers open files: no project-wide Java members | L |
| D | Go to Type Declaration from a *use* of a type-variable value reaches its bound, not the type parameter | S |
| E | The debugger ignores the adapter's `output` events | M |

Everything below was read from the code as it is on `main` (`b06097c`). Where a fact still has to be confirmed before building, it says **confirm**. Nothing here has been built.

## Ground rules (unchanged from the parent plan)

- **App Store safety** (CLAUDE.md). `Sources/Penumbra` and `Sources/EditorIntelligence` spawn no processes and make no network calls. Git stays in `Example/Umbra` / `Packages/GitIntelligence`; the debug adapter stays in `Example/Umbra`. New pure logic (file masks, preview segments, the member index) is fine in the library targets.
- **Performance rules** (`docs/PERFORMANCE_RULES.md`). Nothing here sits on the typing path, but C adds a per-keystroke lookup in a palette and E can flood the main actor. Both have a bound stated below.
- **Each item ships with tests** (`Tests/PenumbraTests/<Subject>Tests.swift`, one class per file), a line in the CLAUDE.md feature list, and an update to the status table of the parent plan.
- **Be honest about the app.** As before, no way exists here to launch or screenshot Umbra. Every UI change is "built, not run" until someone runs it; say so in the status line rather than "done".
- Commit one item at a time.

## Suggested order

| Order | Item | Why here |
|---|---|---|
| 1 | D type variable → parameter | Smallest, self-contained, no UI. **Done** (tests in `JavaGoToTypeDefinitionTests`; not committed yet) |
| 2 | A multi-file revert | Reuses `revertToHead(paths:)`; mostly UI. **Done, UI built not run** (git side tested in `GitRepositoryIntegrationTests`; Explorer-folder revert, step 7, not built; long lists go in 200-path chunks, not `--pathspec-from-file`) |
| 3 | B Replace in Files mask, scope, new-line preview | Two independent halves; the preview half also improves Rename's sheet. **Done, UI built not run** (scopes: Project, Directory, Open Files and, per decision 4, Changed Files (git); tests `FileMaskTests`, `ProjectSearchEngineTests`, `WorkspaceEditPlanPreviewTests`; Rename keeps `.singleLine`) |
| 4 | E debugger console | Adapter change plus a new view; needs two decisions. **Done, UI built not run** (decisions taken as recommended: separate stdout/stderr, read-only console; a dedicated `IDEDebugConsoleLog` and view rather than a protocol shared with the Gradle tab, whose incremental view stopped rendering once its 10,000-line cap started dropping lines, since fixed to follow line numbers (`IDEGradleConsoleView`, `IDEGradleConsoleViewTests`) with an "earlier lines not shown" notice; adapter jar rebuilt; tests `JavaDebugAdapterTests`, `JavaDebugSessionConsoleTests`, `IDEDebugConsoleLogTests`) |
| 5 | C project-wide symbols | Largest; changes the index shard format. **Done, UI built not run.** The spike changed the design: no shard format change, a lazy two-layer in-memory table instead (see "Spike findings"). Tests `JavaMemberIndexTests`, `SymbolsPaletteMembersTests`, `IDEJavaMembersPaletteSourceTests`; `PerfHarness java-members` |

Total is roughly 8–12 working days by the parent plan's scale (S under a day, M 1–3 days, L over 3).

---

## D. Go to Type Declaration from a type-variable value

**Today.** `JavaGoToTypeDefinition` (`Sources/JavaIntelligence/Navigation/`) types the expression under the caret with `JavaExpressionTyper.typed(...)`. That function deliberately replaces a value of type `T` with `T`'s bound (`Object` when unbounded), because member lookup needs the bound (`JavaExpressionTyper.swift`, in `typed`). So `expressionTypeHits` receives `Object` or the bound and jumps there. The rest of the machinery already works: `typeHits(of: .typeVariable(name))` finds the parameter with `JavaDeclarationLocator.typeParameterRange(name:in:atByteOffset:)`, and it is what a *declaration* (`T value`) already uses.

**Design.** Keep the bound for everything that needs it, and additionally remember the variable.

1. `JavaExpressionTyper.Typed` gains `var typeVariable: String?`, set in `typed(...)` when the bound substitution happens (the `Typed(type: resolvedBound, ...)` branch). No existing caller reads it, so nothing else changes. There are four call sites of `typed(`; confirm none copies a `Typed` field by field.
2. `expressionTypeHits` checks `typed.typeVariable` first. If `JavaDeclarationLocator.typeParameterRange` finds the parameter from the caret's scope, return that hit; otherwise fall back to the bound as today.
3. Scope of the locator: **confirm** that it finds both class-level (`class Box<T>`) and method-level (`<U extends Number> void f(U u)`) parameters from a caret inside the body, and that a nested class sees its outer class's `T`.

**Limits, stated up front.** A type variable declared in another file (an unsubstituted `E` reached through a library class) cannot be located by the current-file locator, so it keeps going to the bound. Arrays (`T[] a; a[0]`) probably already work because the bound rewrite only applies when the resolved type *is* the variable; a test will show.

**Tests** (`TypeDefinitionNavigationTests`, extend it): value of class-level `T` → the `T` in `class Box<T>`; method-level `<U extends Number>`; bounded `T extends Comparable<T>` still goes to `T`; field of type `T`; call result `box.get()` where the declared return type is `T` inside the generic class; nested class using the outer `T`; `T[]` element; `List<T>` element (`list.get(0)`); a variable declared elsewhere falls back to its bound; a concrete substitution (`Box<Baz>.get()` → `Baz`) is unchanged.

**Effort** S. **Risk** low: one optional field.

---

## A. Multi-file revert

**Today.** `IDEWorkspace.revertActiveFile()` confirms with an `NSAlert` (Cancel is the default button), then calls `IDEGitStatusModel.revert(path:then:onFailure:)`, which checks `GitRepository.existsInHead` and runs `revertToHead(paths: [relative])`. `revertToHead` already accepts several paths (`git restore --source=HEAD --staged --worktree -- <paths>`) and git refuses the *whole* command if any path is not in `HEAD`. `reloadOpenEditorsAfterGitChange(discardingEditsIn:)` already takes a set of paths. The Source Control panel lists `IDEGitChange` rows (each with `staged` / `unstaged` status) but holds a single selection (`selectedChangePath`, used for the diff), and its rows have stage / unstage / open buttons only.

**Design.**

1. **`GitRepository`.** Add `pathsInHead(_ relativePaths: [String]) async -> Set<String>`: one `git ls-tree -r --name-only HEAD -- <paths>` instead of N `existsInHead` processes. Feed long lists through `--pathspec-from-file=-` with `--pathspec-file-nul` on stdin (**confirm** the minimum git version Umbra needs; the alternative is chunks of ~200 arguments) so a "revert everything" cannot hit the argument-length limit. `revertToHead` gets the same treatment.
2. **`IDEGitStatusModel.revert(paths:)`.** Partition the request into *revertable* (in `HEAD`) and *skipped* (untracked, or staged as new). Revert the first group in one `git restore`, then report the second: "3 files were skipped: they are not in the last commit." Partial, not all-or-nothing, because the confirmation dialog states exactly which files will change and which will not. Keep `revert(path:)` as a one-element wrapper so `revertActiveFile` is unchanged.
3. **Selection.** `selectedChangePaths: Set<String>` next to `selectedChangePath` (which stays the primary row that drives the diff). ⌘-click and ⇧-click extend it in the Changes and Staged lists.
4. **UI.** A context menu on a change row ("Revert…", acting on the whole selection when the row is in it, else on that row), and a "Revert All…" beside "Stage All" for the Changes section. No shortcut; ⌥⌘Z stays "revert the active file".
5. **Confirmation.** One alert for the whole batch: the count, the first ten names, "and N more", a line for how many have **unsaved edits in open editors** (they are discarded too), and the skipped group with the reason. Cancel is the default answer; the destructive button is marked `hasDestructiveAction`. No "don't ask again", as in the parent plan.
6. **Editors.** After the restore, call `reloadOpenEditorsAfterGitChange(discardingEditsIn: Set(paths))` (already the right shape). A file that git *restores* (it was deleted in the working tree) has no open tab; nothing to do. Refresh git status afterwards, as `runGitAction` already does.
7. **Directories** (optional, same PR if small): "Revert…" on an Explorer folder expands to the changed files under it (from `gitStatus.changes`) and goes through the same confirmation. Skip if it complicates the Explorer menu.

**Tests** (`GitRepositoryIntegrationTests`, real scratch repos): `pathsInHead` with tracked, untracked, staged-new, deleted and renamed files; multi-path revert of a staged-plus-unstaged mix; restoring a file deleted from disk; a path with spaces and non-ASCII characters; 1,000 paths (stdin path); a skipped path leaves the working tree of the others reverted and reports itself. Model-level test of the partition and message. The alert text and the multi-selection UI are built but not run.

**Effort** S–M. **Risk.** Destructive by nature; the mitigations are the explicit list in the dialog, Cancel as default, and testing only on scratch repositories.

---

## B. Replace in Files: file mask, scope, and a preview of the new line

Two halves that do not depend on each other; ship the preview first if they are split.

### B1. File mask and scope

**Today.** `ProjectSearchEngine.files(under:policy:)` walks the whole project root with a `FileEnumerationPolicy` (ignored directory names, skipped extensions, hidden files, a byte cap), then `search(_:files:)` reads each file. `EditorIntelligenceController.searchProject(...)` and `IDEWorkspace.replaceInFiles()` pass no mask, and `replaceInFiles` uses the search only to pick files before planning against each file's current text. Phase 5's guarantee, that what Replace changes is exactly what the search listed, comes from both using `WorkspaceSearchQuery.compiledRegularExpression()`.

**Design.** One filter object used by both Find and Replace, so the two can never disagree on the file set.

1. **`FileMask`** (pure, `Sources/EditorIntelligence/Search/`). Parses a comma- or space-separated list such as `*.java, !*Test.java, src/**`. Supports `*`, `**`, `?`, a leading `!` for exclusion, and matches the file name when a pattern has no `/`, else the path relative to the search root. Case-insensitive, as macOS volumes are by default. An empty mask matches everything. An invalid pattern reports itself (shown next to the field) and matches nothing rather than everything.
2. **`ProjectSearchFilter`** = `{ mask: FileMask?, directory: URL?, onlyFiles: Set<URL>? }`, `Sendable`. `directory` narrows the walk to a folder inside the project root (a path outside the root is rejected, in the same spirit as the applier that never writes outside it); `onlyFiles` backs the Open Files scope.
3. **Engine.** `search(_:in:policy:filter:)` and `files(under:policy:filter:)` apply the filter **during enumeration**: a negated directory pattern (`!build/**`) prunes the walk, and a file that fails the mask is never opened or size-checked. Existing callers keep working through a default `nil` filter.
4. **Controller and workspace.** `searchProject(..., filter:)`; `findInFilesFilter` state on `IDEWorkspace` next to the option toggles; `replaceInFiles()` passes the same filter.
5. **UI (`FindInFilesPanel`).** A row under the option toggles: a mask field (placeholder `*.java, !*Test.java`) and a scope menu: *Project*, *Directory…* (also offered from the Explorer's context menu as "Find in Files here"), *Open Files*. Changing either re-runs the search, debounced like the toggles (`rerunIfSearching`). Session-only, like the toggles; not persisted.
6. **Open editors.** Unchanged: a file with unsaved edits is planned against the editor's text. Note the existing limit that a match existing only on disk in such a file is not found.

**Tests.** `FileMaskTests` (table: name-only vs path patterns, `**` across directories, negation order, case-insensitivity, an invalid pattern, empty mask). `ProjectSearchEngineTests` on a temp tree: mask, negated directory prunes the walk (assert a file inside it is never read), directory scope, a scope outside the root is refused, open-files scope. An extension of the existing "search and planner agree on offsets and lines" test with a filter set. The panel is built, not run.

### B2. Preview of the new line text

**Today.** `WorkspaceEditPlanEntry` carries `oldText`, `newText` and `lineText` (the line *before* the change). `IDEWorkspaceEditPreviewSheet` shows the old line with the matched text highlighted; nothing shows what the line will become. The sheet is shared with Rename.

**Design.** Compute the after-line where it is drawn; store nothing new per entry (a plan can hold 2,000 entries).

1. A pure helper in `EditorIntelligence` (`WorkspaceEditPlanEntry.previewLine`): from `lineText`, the entry's `range.start.column` / `range.end.column` (UTF-16, same line) and `newText`, return `(before, removed, added, after)` segments. A match that spans line breaks returns `nil` and the sheet falls back to today's single line.
2. The sheet gets a `style: .singleLine | .diff`. Replace in Files uses `.diff`: two rows per entry, `−` the old line with `removed` tinted, `+` the new line with `added` tinted, shown only when the two differ. Rename keeps `.singleLine` unless a later change opts in.
3. Long lines are cut to a window around the match (about 60 characters each side, with ellipses) so rows stay compact. Tabs render as four spaces, as now. Identical before and after (the planner already drops a match replaced by itself) never appears.

**Tests** (`WorkspaceEditPlanPreviewTests`): plain match, match at line start and end, several matches on one line (each row previews its own replacement only), accents and emoji (UTF-16 offsets), CRLF, a regex replacement with capture groups (`$1`), an empty replacement (deletion), and a multi-line match returning `nil`.

**Effort** M in total (B1 ≈ 2 days, B2 ≈ 1). **Risk.** The preview sheet is shared with Rename, so its existing tests must still pass unchanged; keep `.singleLine` byte-for-byte what it is today.

---

## E. Debugger console: show the program's output

**Today.** The adapter's `launch` starts the target JVM with `redirectErrorStream(true)` and `drainTargetOutput` forwards each line as `{"event": "output", "text": ...}`. `JavaDebugSession.handleEventLine` only knows `stopped` and `terminated`, so the text is dropped. A launched program's stdout and stderr are therefore invisible in Umbra unless the run went through the terminal. Three related facts:

- The target's **stdin is not connected**.
- A **Gradle attach** session has no adapter-owned process (its output goes to the Gradle tab), so it produces no `output` events.
- A console already exists for Gradle: `IDEGradleConsoleLog` (bounded to 10,000 lines, with a dropped-lines notice) and `IDEGradleConsoleView` (an incremental `NSTextView`).

**Design.**

1. **Adapter.**
   - Read stdout and stderr on two threads (drop `redirectErrorStream`) and tag events with `stream`. The order between the two streams becomes approximate. If exact interleaving matters more than colour, keep the merged stream (**decision 1** below).
   - **Batch** lines into one event `{event: "output", lines: [{stream, text}]}` flushed every ~50 ms or 200 lines. A `println` loop can otherwise emit 100k events a second at the main actor.
   - Flush a **partial line** after ~100 ms of silence, so prompts written without a newline (`Enter name: `) appear.
   - Add the process's exit code to the `terminated` event.
   - Rebuild the jar with `build.sh` (the parent plan's standing note).
2. **Session.** `JavaDebugSession.console` (a bounded log, cleared when a new session starts) appended from `handleEventLine`; notes for "Launching", "Program exited with code N", "Debugger disconnected". The session's read loop already delivers lines in batches off the main actor.
3. **Log and view.** Extract the shared bounded-log behaviour into a small protocol so `IDEGradleConsoleView` can render either log (each line is text plus `isError` / `isNote`), and add an `IDEDebugConsoleLog`. Do not change what the Gradle tab shows. **Confirm** what `GradleOutputLine` carries before choosing the protocol shape.
4. **UI.** A `Debugger | Console` picker in the Debug panel's toolbar row. The Console does not steal focus when output arrives; the picker shows an unread dot instead. A Clear button, selectable text, and a footer line "Read-only: the program's input is not connected." A Gradle attach session shows the note "Output is in the Gradle tab".
5. **Optional stretch (not part of the estimate):** an input line that writes to the target's stdin through a new adapter command. Only worthwhile if debugging programs that read `System.in` matters; **decision 2**.

**Tests.** `JavaDebugAdapterTests` with a fixture that prints to stdout and stderr: events arrive with the right `stream`; 5,000 lines arrive in far fewer events, none lost, in order (per stream); a partial line is flushed; the exit code arrives in `terminated`. `JavaDebugSessionEvaluateTests`-style session test: console fills from a real JVM, is bounded at the cap with a dropped count, and is cleared on restart. The view and picker are built, not run.

**Effort** M. **Risks.** Main-actor flooding (mitigated by batching plus the line cap); approximate stream ordering; partial-line timing being heuristic.

---

## C. Project-wide Java members in Go to Symbol

**Today.** `goToSymbol` (⌥⌘O) is `SymbolsPaletteProvider` over `SymbolIndex.allSymbols()`, which Umbra feeds from **open documents only**. The Classes tab (`IDEJavaClassesPaletteProvider`) is separate: it searches `JavaIndex.classes(matching:)`, a name table with camel-hump matching, for **types only**. `JavaClassStub` does hold `fields` and `methods`, but member stubs have **no source position** (only the class has `origin: .source(url, nameRange:)`), and `JavaIndex.projectClassStubs()` decodes one stub per class and is documented as unfit for the typing path. The persistent name index (`sources.idx`, `JavaNameIndexStore`) is what makes class lookup fast; the identifier index (`refs.idx`) lists files that mention a name, not where it is declared.

**Options considered.**

| | Approach | Verdict |
|---|---|---|
| 1 | Add **member entries** to the persistent name index, written by the pass that already parses each source file, with an overlay for open buffers like the class table has | **Recommended.** Same architecture as classes; incremental; fast lookup |
| 2 | Build an in-memory member table lazily from `projectClassStubs()` and resolve positions on selection by re-parsing | No format change, but the first use decodes every stub, and the table must be rebuilt as `JavaIndex.generation` changes on every edit unless it is invalidated per class, which is more code than option 1 |
| 3 | Search identifiers in `refs.idx` | Lists mentions, not declarations; rejected |

**Spike findings (structure, read from the code; the measurements are still to take).**

- `sources.idx` is one `PJIX` shard **per source root** (`JavaIndexScheduler.indexOne`): every class stub of the root, written whole. A root is re-read and rewritten in full whenever its stamp changes; there is no per-file stub update. So "written by the pass that already parses each file" means `SourceRoot.readSourceFiles()` → `JavaSourceStubBuilder.build`, and a member table would be rewritten with the rest of the shard.
- The class name table is **not persisted separately**: `JavaIndex.baseNameIndex` is rebuilt in memory at `setSources` from each shard's `allQualifiedNames` (the shard header), and `overlayNameIndex` is rebuilt from the open-buffer stubs on every overlay change. A member table would follow the same two-layer shape (base from the shards, overlay from open buffers). `JavaNameIndexStore` is the `refs.idx` identifier index, not the class table.
- `JavaMethodStub` / `JavaFieldStub` have **no source position** and no `nameRange`; only `JavaClassStub.origin` does. Members sit inside the encoded class body, so listing them today means decoding every class body (`StubCoder.decode`), which is what `projectClassStubs()` costs.
- Consequence for option 1: the stubs need a member `nameRange` (builder, `StubCoder`, and a shard format bump to v4), plus a small member section in the shard header so a lookup never decodes a body. Stored positions go stale when a file changes after it was indexed; the watcher re-indexes the root, but the palette should verify the name at the range on selection and fall back to locating the member by owner and name.
- **Measured** (`swift run -c release PerfHarness java-members <dir>`; a real 11.3k-file, 12k-class multi-module Gradle project, and the JDK 21 `java.base` sources):

  | | real project | `java.base` |
  |---|---|---|
  | files / classes | 11,312 / 12,046 | 3,441 / 6,550 |
  | members (methods, constructors, fields, enum constants) | 147,981 | 79,634 |
  | parse of every file | 3.3 s | 1.7 s |
  | shard written whole (`sources.idx`) | 10.6 MB, 68 ms | 18.0 MB, 61 ms |
  | shard opened (header only) | 6 ms | 8 ms |
  | **decode every class stub** | **46 ms** | 27 ms |
  | flat member-name table | 8.1 MB (57 B/member) | 4.4 MB (58 B/member) |
  | word-initial buckets on top | +2.2 MB (2.7 buckets per member) | |
  | `CompletionMatcher` over every member, top 100 sorted | 30–37 ms | 16–19 ms |
  | bucket by word initial + subsequence pre-check + running top 100 | **p95 ≤ 7.9 ms** (one-letter queries; 1–3 ms typical) | |

  Two things `CompletionMatcher` needs to be fast enough: it allocates two arrays per call, so every cheap reject (the word-initial bucket, then "the query letters appear in order in the name", both provably never dropping a match: the harness asserts the same hit count) has to run before it; and ranking keeps a running top 100 instead of sorting every hit.
- **Decision (revised from "option 1 recommended"): a two-layer in-memory table, no shard format change.** Decoding all stubs costs ~50 ms, so the reason to persist members in the shard is gone: the base table is built **lazily on the first member query** from the project shards (precedence 1) and dropped on `setSources`, and a small overlay table follows the open buffers like `overlayNameIndex` (an overlay class masks the base entries of the same qualified name). A project that never opens Go to Symbol pays nothing, and existing users are not re-indexed. What is given up: members carry no stored position, so the palette locates the member in its file on selection (one parse, by owner, name and parameter keys, which also cures stale positions). The shard-format work in step 1 below is therefore **not needed**; steps 2 to 4 stand.

**Design (option 1).**

0. **Spike first (half a day).** Read `JavaNameIndexStore`, `StubCoder` and the source-stub builder, and **confirm** that declaration name ranges are available where stubs are built, how `NameEntry` and the overlay table are versioned, and what a shard format bump costs (one full re-index, as the parent plan's "shard format v3" did). Measure class and member counts on a real Gradle project and on `PerfHarness java-completion synthetic`. If the spike shows option 1 is much larger than expected, fall back to option 2 and write down why.
1. **Model and coder.** `MemberEntry { ownerQualifiedName, name, kind (method, constructor, field, enum constant, record component), signatureText, nameByteRange }` next to `NameEntry`, stored and decoded with the same shard, with a format version bump that triggers one re-index. Anonymous and local classes are excluded; only *declared* members are listed, not inherited ones (IntelliJ's behaviour).
2. **Index API.** `JavaIndex.members(matching:limit:)`: first-character pre-check, then `CompletionMatcher` (camel humps: `gN` → `getName`), ranked by match tier, then kind, then project precedence, honouring the overlay so an open buffer's members replace its file's stored ones and a deleted file's disappear. Runs off the main actor; per keystroke it is one bounded scan of the member table.
3. **Palette.** `IDEJavaSymbolsPaletteProvider` in Umbra, modelled on the classes provider: title is the member name, subtitle `Owner · (String, int)`, an icon per kind, footer the relative path, and the same `onOpen(url, byteRange, split)` action (⌥↩ for a split). It sits in the Symbols section and in the `@` sigil. Results from `SymbolIndex` for the same Java files are dropped or de-duplicated by (file, line) so a symbol never appears twice. Library members (JARs, the JDK) stay out until "Include non-project items" is wired, as for classes.
4. **Non-Java files** keep working through `SymbolIndex` exactly as today.

**As built (differences from the steps above).** No `MemberEntry` in the shard and no format bump: `JavaMemberTable` (`Sources/JavaIntelligence/Index/JavaMemberIndex.swift`) is built in memory from the decoded project stubs. Constructors are **not** listed (their name is the class name, which the Classes tab already finds), and neither are javac's enum `values`/`valueOf` or a record's derived accessors (a record's components are listed once, as components). The palette source is not a provider of its own: it feeds the existing Symbols provider (`symbolsAdditionalItems`, `symbolsExcludedDocuments`), because two providers with the same section title would draw two "Symbols" headings. On selection `JavaMemberLocator` parses the file (the editor's text when it is open) and finds the member by owner, name and parameter types, falling back to the class; a member's icon says its kind and static members are tinted differently. Not built: an include-non-project-items switch (library members stay out), and a members-only filter.

**Bounds.** Table memory is `members × (a few strings and two ints)`; state the measured number for 100k members in the PR. Lookup latency must stay in the single-digit milliseconds at that size, off the main actor; the palette already debounces and drops stale queries.

**Tests.** Coder round trip, and an old-format shard triggering re-index instead of failing. Index tests on a fixture project: methods, fields, constructors, enum constants, record components, nested classes; camel-hump match; overlay precedence over the stored file; removal when a file is deleted or a member renamed; exclusion of inherited and anonymous members. Provider test for ordering and de-duplication. A `PerfHarness` scenario for member lookup latency and table size. Because the index changes, run `JavaCompletionCorpusTests` and the reference-index tests too.

**Effort** L. **Risks.** The shard format bump (one full re-index for existing users, and a migration path that must never leave a half-read shard), and index size growth. A large project pays memory for members it will rarely search; the numbers from the spike decide whether that is acceptable.

---

## Decisions I need from you

1. **E, stream order.** Separate stdout and stderr (colour, exact order lost between the two) or one merged stream (exact order, no colour)? Recommendation: separate.
2. **E, stdin.** Is an input line for programs that read `System.in` wanted, or is a read-only console enough for now? Recommendation: read-only.
3. **A, partial revert.** Revert what can be reverted and report the rest (recommended), or refuse the whole batch if any file cannot be reverted?
4. **B1, scopes.** Project, Directory and Open Files as planned, or also "Changed files (git)"? The last is cheap once the filter exists, since `gitStatus.changes` already lists them.
5. **C, format bump.** Is a one-time full re-index acceptable for the member table (option 1), or should the first version take option 2 and avoid touching the shard format?

## Verification

- `swift build` and `swift test` clean after each item; run the test class named for the subject first, then the full suite.
- C: `swift run -c release PerfHarness ...` for member lookup latency and table size, on the parent commit and on the change; Debug timings prove nothing.
- E and A involve real processes: use the existing real-JVM adapter tests and scratch git repositories, never the working repo.
- After each item, update CLAUDE.md's feature list, this plan's table, and the "smaller gaps" bullet in `INTELLIJ_KEYMAP_FEATURES_PLAN.md`.
- Finish with a manual pass through Umbra for the UI parts (revert dialog and multi-selection, the mask and scope row, the diff preview, the Console picker, the symbol palette), since none of that can be exercised without launching the app.
